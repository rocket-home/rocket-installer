#!/bin/sh
# Token-agent: супервизор mosquitto для CLOUD_AUTH_MODE=oauth.
#
# Контракт с облаком (как у шлюза milafire-k3):
#   - access-токен (~1 год) + refresh-токен в /mosquitto/secrets/tokens.json;
#   - MQTT-пароль моста = "token=<JWT>" из GET /api/mqtt/v1/.../token?lifetime=grant;
#   - hmq НЕ перепроверяет exp на живой сессии, но реконнект с протухшим JWT провалится;
#   - mosquitto читает remote_password ТОЛЬКО при старте: свои реконнекты моста он делает
#     паролем из памяти, и новый bridge.conf ему до рестарта не виден.
#
# Стратегия (ADR 0051 janus):
#   - grant-режим (облако ответило lifetime=grant): JWT моста живёт до конца OAuth-гранта,
#     брокер сверяет отзыв гранта при каждом CONNECT. Пароль в памяти mosquitto валиден весь
#     срок — обрыв облака мост переживает сам, без рестартов и ротаций;
#   - refresh access-токена отзывает старый грант, а с ним пароль моста в памяти, поэтому
#     refresh идёт только вместе с рестартом mosquitto: окно — за REFRESH_WINDOW до истечения
#     (заранее, чтобы сбой сети в последние дни не оставил хаб без моста), попытки ночью
#     (NIGHT_START..NIGHT_END по TZ), повторы с backoff; за URGENT_WINDOW — в любое время;
#   - short-режим (старое облако, lifetime=short): прежняя ротация JWT раз в JWT_MAX_AGE без
#     рестарта; обрыв с протухшим паролем в памяти — немедленный рестарт со свежим токеном;
#   - мост лежит дольше BRIDGE_GRACE по другой причине — рестарт, backoff 90с→5м→15м;
#   - без валидного refresh → needs_relink (или wrong_location): брокер работает локально,
#     без моста, облако не дёргается до повторной линковки (смены tokens.json).
#
# Env: API_BASE_URL, OAUTH_CLIENT_ID, CLOUD_MQTT_HOST, CLOUD_MQTT_PORT,
#      CLOUD_BRIDGE_PROTOCOL, MQTT_USER, MQTT_PASSWORD.
set -u

# Пути переопределяемы для тестов вне контейнера (AGENT_*)
TOKENS_FILE="${AGENT_TOKENS_FILE:-/mosquitto/secrets/tokens.json}"
BRIDGE_CONF="${AGENT_BRIDGE_CONF:-/mosquitto/dynamic/bridge.conf}"
STATUS_FILE="${AGENT_STATUS_FILE:-/mosquitto/data/agent-status.json}"
CHECK_INTERVAL="${AGENT_CHECK_INTERVAL:-60}"    # период цикла, с
JWT_MAX_AGE="${AGENT_JWT_MAX_AGE:-2100}"        # 35 мин: ротация JWT (short-режим, живёт ~1ч)
BRIDGE_GRACE="${AGENT_BRIDGE_GRACE:-90}"        # с: даём mosquitto самому переподняться
REFRESH_WINDOW="${AGENT_REFRESH_WINDOW:-$((60 * 24 * 3600))}"  # окно refresh до expires_at
URGENT_WINDOW="${AGENT_URGENT_WINDOW:-$((7 * 24 * 3600))}"     # остаток, когда ночь не ждём
NIGHT_START="${AGENT_NIGHT_START:-3}"           # час (по TZ контейнера) начала ночного окна
NIGHT_END="${AGENT_NIGHT_END:-5}"               # час конца (не включительно)
CURL="curl -sS -m 15"

MOSQ_PID=""
JWT_ISSUED_AT=0
JWT_EXP=0            # срок JWT в bridge.conf (по часам хаба: now + expiresIn)
JWT_LIFETIME=short   # short | grant — что выдало облако
MOSQ_JWT_EXP=0       # срок пароля, с которым стартовал текущий mosquitto
MOSQ_JWT_MARGIN=60
MOSQ_HAS_BRIDGE=0    # стартовал ли текущий mosquitto с мостом
MOSQ_PW_REVOKED=0    # grant-режим: refresh после старта mosquitto отозвал пароль в памяти
REFRESH_NEXT_TRY=0
REFRESH_STEP=0       # индекс backoff refresh: 300с → 900с → 1800с
TERMINAL=""          # needs_relink | wrong_location — ждём повторной линковки
TERMINAL_TOKENS=""   # отпечаток tokens.json в момент терминального отказа
LOCATION_ID=""
BRIDGE_DOWN_SINCE=0
RESTART_BACKOFF=0   # индекс: 0→90с, 1→300с, 2+→900с
LAST_RESTART=0

# AGENT_NOW_FILE — подмена часов для тестов (файл с unix-временем).
now() {
    if [ -n "${AGENT_NOW_FILE:-}" ] && [ -s "$AGENT_NOW_FILE" ]; then cat "$AGENT_NOW_FILE"; else date +%s; fi
}

# Час суток по TZ контейнера (busybox и GNU date понимают -d @unix).
hour_now() { date -d "@$(now)" +%H | sed 's/^0//'; }

in_night() {
    h="$(hour_now)"
    [ "$h" -ge "$NIGHT_START" ] && [ "$h" -lt "$NIGHT_END" ]
}

status() { # status <state> [detail]
    printf '{"state":"%s","detail":"%s","updated_at":%s,"jwt_issued_at":%s,"location_id":"%s"}\n' \
        "$1" "${2:-}" "$(now)" "$JWT_ISSUED_AT" "$LOCATION_ID" >"$STATUS_FILE.tmp" \
        && chmod 644 "$STATUS_FILE.tmp" \
        && mv "$STATUS_FILE.tmp" "$STATUS_FILE"
    # 644 явно: секретов в статусе нет, а хостовые status.sh/doctor читают файл
    # под обычным пользователем (агент работает под root с umask 077)
}

tokens_get() { jq -r ".$1 // empty" "$TOKENS_FILE" 2>/dev/null; }

# HTTP-запрос с кодом ответа: тело → $body, код → $code (без башизмов — alpine ash).
http_call() {
    resp="$($CURL -w '\n%{http_code}' "$@")" || return 1
    code="$(printf '%s\n' "$resp" | tail -n1)"
    body="$(printf '%s\n' "$resp" | sed '$d')"
}

# Обновить пару токенов по refresh (public client, без секрета).
# 0 = успех; 1 = терминально (нужна повторная линковка); 2 = временная ошибка (сеть/5xx).
refresh_access() {
    rt="$(tokens_get refresh_token)"
    [ -n "$rt" ] || return 1
    http_call -X POST "$API_BASE_URL/oauth/token" \
        -H 'Accept: application/json' \
        --data-urlencode grant_type=refresh_token \
        --data-urlencode "refresh_token=$rt" \
        --data-urlencode "client_id=$OAUTH_CLIENT_ID" || return 2
    case "$code" in
        200) ;;
        400|401|403) echo "token-agent: refresh отклонён ($code) — нужна повторная линковка" >&2; return 1 ;;
        *) return 2 ;;
    esac
    access="$(printf '%s' "$body" | jq -r '.access_token // empty')"
    [ -n "$access" ] || return 2
    new_rt="$(printf '%s' "$body" | jq -r '.refresh_token // empty')"
    [ -n "$new_rt" ] || new_rt="$rt"
    expires_in="$(printf '%s' "$body" | jq -r '.expires_in // 31536000')"
    jq -n --arg a "$access" --arg r "$new_rt" \
        --argjson exp "$(( $(now) + expires_in ))" --argjson at "$(now)" \
        '{access_token:$a, refresh_token:$r, expires_at:$exp, obtained_at:$at}' \
        >"$TOKENS_FILE.tmp" && chmod 600 "$TOKENS_FILE.tmp" && mv "$TOKENS_FILE.tmp" "$TOKENS_FILE"
    echo "token-agent: access-токен обновлён" >&2
    # Старый access-токен отозван облаком — вместе с ним и grant-пароль моста в памяти mosquitto.
    [ "$MOSQ_HAS_BRIDGE" = 1 ] && [ "$JWT_LIFETIME" = grant ] && MOSQ_PW_REVOKED=1
    return 0
}

# Получить свежий MQTT-JWT в глобалы JWT + LOCATION_ID (не через сабшелл —
# иначе значения потеряются). 0 = успех; 1 = терминально; 2 = временная ошибка.
fetch_jwt() {
    access="$(tokens_get access_token)"
    [ -n "$access" ] || return 1
    attempt=0
    # Локация берётся из .env, если закреплена: дефолтный /api/mqtt/v1/token при аккаунте
    # без локаций СОЗДАЁТ новую («Дом») и хаб тихо уезжает на чужой mount point.
    if [ -n "${CLOUD_LOCATION_ID:-}" ]; then
        token_url="$API_BASE_URL/api/mqtt/v1/locations/$CLOUD_LOCATION_ID/token?lifetime=grant"
    else
        token_url="$API_BASE_URL/api/mqtt/v1/token?lifetime=grant"
    fi
    while :; do
        http_call -H "Authorization: Bearer $access" \
            -H 'Accept: application/json' "$token_url" || return 2
        case "$code" in
            200)
                JWT="$(printf '%s' "$body" | jq -r '.token // empty')"
                LOCATION_ID="$(printf '%s' "$body" | jq -r '.locationId // empty')"
                # Режим — только по явному полю: expiresIn зависит от настройки TTL облака.
                JWT_NEW_LIFETIME="$(printf '%s' "$body" | jq -r 'if .lifetime == "grant" then "grant" else "short" end')"
                JWT_NEW_EXPIRES_IN="$(printf '%s' "$body" | jq -r '.expiresIn // 3600')"
                [ -n "$JWT" ] || return 2
                # Расхождение с закреплённой локацией — это не «подстроиться», а отказ:
                # опубликовать дом под чужим mount point хуже, чем остаться без моста.
                if [ -n "${CLOUD_LOCATION_ID:-}" ] && [ -n "$LOCATION_ID" ] \
                   && [ "$LOCATION_ID" != "$CLOUD_LOCATION_ID" ]; then
                    status wrong_location "выдан токен локации $LOCATION_ID вместо $CLOUD_LOCATION_ID"
                    TERMINAL=wrong_location
                    return 1
                fi
                return 0 ;;
            401)
                # ровно один refresh + retry (как milafire)
                [ "$attempt" -ge 1 ] && return 1
                refresh_access || return $?
                access="$(tokens_get access_token)"
                attempt=1 ;;
            *) return 2 ;;
        esac
    done
}

write_bridge_conf() { # write_bridge_conf <jwt>
    # umask в сабшелле — не протекает на последующие записи (status-файл должен
    # оставаться читаемым с хоста)
    (
    umask 077
    cat >"$BRIDGE_CONF.tmp" <<EOF
connection rocket
address ${CLOUD_MQTT_HOST}:${CLOUD_MQTT_PORT}
bridge_protocol_version ${CLOUD_BRIDGE_PROTOCOL}
bridge_capath /etc/ssl/certs
try_private false
topic # both 2
remote_username ${LOCATION_ID}
remote_password token=$1
notifications true
notifications_local_only true
notification_topic \$SYS/broker/connection/rocket/state
restart_timeout 10 60
EOF
    )
    mv "$BRIDGE_CONF.tmp" "$BRIDGE_CONF"
    JWT_ISSUED_AT="$(now)"
    JWT_LIFETIME="${JWT_NEW_LIFETIME:-short}"
    JWT_EXP=$(( JWT_ISSUED_AT + ${JWT_NEW_EXPIRES_IN:-3600} ))
}

# Срок и режим JWT из уже лежащего bridge.conf — при старте без облака агенту надо знать,
# с каким паролем поднимается mosquitto. exp — из самого JWT (часы облака), lifetime=bridge
# в claims — grant-режим.
load_conf_jwt() {
    [ -s "$BRIDGE_CONF" ] || return 1
    pw="$(sed -n 's/^remote_password token=//p' "$BRIDGE_CONF")"
    payload="$(printf '%s' "$pw" | cut -d. -f2 | tr '_-' '/+')"
    while [ $(( ${#payload} % 4 )) -ne 0 ]; do payload="$payload="; done
    claims="$(printf '%s' "$payload" | base64 -d 2>/dev/null)" || return 1
    exp="$(printf '%s' "$claims" | jq -r '.exp // 0' 2>/dev/null)" || return 1
    JWT_EXP="${exp:-0}"
    if [ "$(printf '%s' "$claims" | jq -r '.lifetime // empty' 2>/dev/null)" = bridge ]; then
        JWT_LIFETIME=grant
    else
        JWT_LIFETIME=short
    fi
}

# 0 = получили и записали свежий JWT; 1 = needs_relink; 2 = временная ошибка.
rotate_jwt() {
    fetch_jwt || return $?
    write_bridge_conf "$JWT"
}

start_mosquitto() {
    "$@" &
    MOSQ_PID=$!
    LAST_RESTART="$(now)"
    if [ -s "$BRIDGE_CONF" ]; then MOSQ_HAS_BRIDGE=1; else MOSQ_HAS_BRIDGE=0; fi
    MOSQ_JWT_EXP="$JWT_EXP"
    MOSQ_PW_REVOKED=0
    # Запас на реконнект: минута, но не больше четверти срока (иначе короткий TTL = цикл рестартов).
    life=$(( JWT_EXP - LAST_RESTART ))
    MOSQ_JWT_MARGIN=60
    [ "$life" -gt 0 ] && [ $(( life / 4 )) -lt 60 ] && MOSQ_JWT_MARGIN=$(( life / 4 ))
    return 0
}

restart_mosquitto() {
    stop_mosquitto
    start_mosquitto "$@"
}

tokens_fingerprint() { cksum "$TOKENS_FILE" 2>/dev/null | cut -d' ' -f1; }

# Терминальный отказ облака: мост снимается (иначе grant-пароль в памяти жил бы до года),
# брокер работает локально, облако не дёргаем до повторной линковки.
go_terminal() { # go_terminal <detail> "$@"
    detail="$1"; shift
    [ -n "$TERMINAL" ] || TERMINAL=needs_relink
    rm -f "$BRIDGE_CONF"
    TERMINAL_TOKENS="$(tokens_fingerprint)"
    if [ "$TERMINAL" = wrong_location ]; then
        status wrong_location "$detail"
    else
        status needs_relink "$detail"
    fi
    [ "$MOSQ_HAS_BRIDGE" = 1 ] && restart_mosquitto "$@"
    return 0
}

# Пароль моста в памяти mosquitto заведомо не пройдёт CONNECT: истёк или отозван refresh-ем.
mosq_password_dead() {
    [ "$MOSQ_HAS_BRIDGE" = 1 ] || return 1
    [ "$MOSQ_PW_REVOKED" = 1 ] && return 0
    [ "$(now)" -ge $(( MOSQ_JWT_EXP - MOSQ_JWT_MARGIN )) ]
}

stop_mosquitto() {
    [ -n "$MOSQ_PID" ] || return 0
    kill -TERM "$MOSQ_PID" 2>/dev/null || true
    wait "$MOSQ_PID" 2>/dev/null || true
    MOSQ_PID=""
}

# retained-состояние моста: "1"/"0"; пусто = не публиковалось (мост ещё не поднимался)
bridge_state() {
    mosquitto_sub -h localhost -u "$MQTT_USER" -P "$MQTT_PASSWORD" \
        -t '$SYS/broker/connection/rocket/state' -C 1 -W 3 2>/dev/null || true
}

on_term() {
    status stopping
    stop_mosquitto
    exit 0
}
trap on_term TERM INT

# ── Старт ──────────────────────────────────────────────────────────────────────
if [ ! -s "$TOKENS_FILE" ]; then
    echo "token-agent: нет $TOKENS_FILE — выполните линковку (make oauth-link); мост выключен" >&2
    rm -f "$BRIDGE_CONF"
    status needs_relink "no tokens file"
else
    rotate_jwt; rc=$?
    case "$rc" in
        0) status ok ;;
        1) [ -n "$TERMINAL" ] || TERMINAL=needs_relink
           rm -f "$BRIDGE_CONF"; TERMINAL_TOKENS="$(tokens_fingerprint)"
           [ "$TERMINAL" = wrong_location ] || status needs_relink "refresh rejected at startup" ;;
        *) status bridge_down "cloud unreachable at startup"
           # сеть недоступна: локальный брокер важнее моста — стартуем с тем,
           # что есть (старый bridge.conf либо без него), агент дообновит
           load_conf_jwt || true
           ;;
    esac
fi

start_mosquitto "$@"

# ── Цикл ───────────────────────────────────────────────────────────────────────
while :; do
    sleep "$CHECK_INTERVAL" &
    wait $! || true   # sleep фоном — trap срабатывает сразу, не через 60с

    # процесс умер сам (ошибка конфига и т.п.) — перезапускаем как обычный супервизор
    if ! kill -0 "$MOSQ_PID" 2>/dev/null; then
        echo "token-agent: mosquitto умер — перезапуск" >&2
        start_mosquitto "$@"
        continue
    fi

    [ -s "$TOKENS_FILE" ] || { status needs_relink "no tokens file"; continue; }

    # Терминальный отказ: облако не дёргаем, пока tokens.json не сменится (повторная линковка).
    if [ -n "$TERMINAL" ]; then
        [ "$(tokens_fingerprint)" = "$TERMINAL_TOKENS" ] && continue
        echo "token-agent: tokens.json обновлён — пробуем мост снова" >&2
        TERMINAL=""
        rotate_jwt; rc=$?
        case "$rc" in
            0) restart_mosquitto "$@"; status ok "relinked" ;;
            1) go_terminal "refresh rejected after relink" "$@" ;;
            *) status bridge_down "cloud unreachable after relink" ;;
        esac
        continue
    fi

    # (a) short-режим: проактивная ротация JWT без рестарта (пароль для будущего старта)
    if [ "$JWT_LIFETIME" != grant ] && [ $(( $(now) - JWT_ISSUED_AT )) -gt "$JWT_MAX_AGE" ]; then
        rotate_jwt; rc=$?
        case "$rc" in
            0) status ok "jwt rotated" ;;
            1) go_terminal "refresh rejected" "$@"; continue ;;
            *) status rotating "cloud unreachable, will retry" ;;
        esac
    fi

    # (c) refresh access заранее. В grant-режиме — только вместе с рестартом mosquitto и ночью.
    exp="$(tokens_get expires_at)"
    if [ -n "$exp" ] && [ $(( exp - $(now) )) -lt "$REFRESH_WINDOW" ] && [ "$(now)" -ge "$REFRESH_NEXT_TRY" ]; then
        left=$(( exp - $(now) ))
        if [ "$JWT_LIFETIME" != grant ]; then
            refresh_access || true
        elif in_night || [ "$left" -lt "$URGENT_WINDOW" ]; then
            echo "token-agent: плановое обновление гранта (осталось $(( left / 86400 )) дн.)" >&2
            refresh_access; rc=$?
            [ "$rc" = 0 ] && { rotate_jwt; rc=$?; }
            case "$rc" in
                0) restart_mosquitto "$@"
                   REFRESH_STEP=0; REFRESH_NEXT_TRY=0
                   status ok "grant renewed"
                   continue ;;
                1) go_terminal "refresh rejected" "$@"; continue ;;
                *) case "$REFRESH_STEP" in 0) d=300 ;; 1) d=900 ;; *) d=1800 ;; esac
                   REFRESH_STEP=$(( REFRESH_STEP + 1 ))
                   REFRESH_NEXT_TRY=$(( $(now) + d ))
                   status refresh_pending "attempt ${REFRESH_STEP}, $(( left / 86400 )) days left" ;;
            esac
        fi
    fi

    # (b) мониторинг моста
    st="$(bridge_state)"
    if [ "$st" = "1" ]; then
        BRIDGE_DOWN_SINCE=0
        RESTART_BACKOFF=0
        [ "$REFRESH_STEP" -gt 0 ] || status ok
        continue
    fi
    [ "$BRIDGE_DOWN_SINCE" -eq 0 ] && BRIDGE_DOWN_SINCE="$(now)"

    # Пароль в памяти mosquitto заведомо не пройдёт — ждать grace бессмысленно.
    if mosq_password_dead; then
        rotate_jwt; rc=$?
        case "$rc" in
            0) echo "token-agent: мост offline, пароль моста в памяти недействителен — рестарт со свежим токеном" >&2
               restart_mosquitto "$@"
               BRIDGE_DOWN_SINCE="$(now)"
               status bridge_down "restarted broker: stale bridge password"
               continue ;;
            1) go_terminal "refresh rejected" "$@"; continue ;;
            *) ;;   # облако недоступно — со старым паролем рестарт не поможет, дальше обычный grace
        esac
    fi

    down_for=$(( $(now) - BRIDGE_DOWN_SINCE ))
    [ "$down_for" -lt "$BRIDGE_GRACE" ] && continue

    case "$RESTART_BACKOFF" in
        0) delay=90 ;;
        1) delay=300 ;;
        *) delay=900 ;;
    esac
    if [ $(( $(now) - LAST_RESTART )) -lt "$delay" ]; then
        status bridge_down "down ${down_for}s, next restart in backoff"
        continue
    fi

    echo "token-agent: мост offline ${down_for}с — рестарт mosquitto со свежим токеном" >&2
    rotate_jwt; rc=$?
    [ "$rc" = 1 ] && { go_terminal "refresh rejected" "$@"; continue; }
    restart_mosquitto "$@"   # даже при недоступном облаке рестарт не повредит
    RESTART_BACKOFF=$(( RESTART_BACKOFF + 1 ))
    status bridge_down "restarted broker (backoff step $RESTART_BACKOFF)"
done
