#!/bin/sh
# Token-agent: супервизор mosquitto для CLOUD_AUTH_MODE=oauth.
#
# Контракт с облаком (как у шлюза milafire-k3):
#   - access-токен (~1 год) + refresh-токен в /mosquitto/secrets/tokens.json;
#   - MQTT-пароль моста = "token=<JWT ~1ч>" из GET /api/mqtt/v1/token (Bearer access);
#   - hmq НЕ перепроверяет exp на живой сессии, но реконнект с протухшим JWT провалится.
#
# Стратегия:
#   - свежий JWT пишется в /mosquitto/dynamic/bridge.conf каждые ~35 мин БЕЗ рестарта
#     (файл нужен только будущему (ре)коннекту);
#   - если мост отвалился (retained $SYS/broker/connection/rocket/state = 0) дольше
#     BRIDGE_GRACE — рестарт дочернего mosquitto со свежим токеном, backoff 90с→5м→15м;
#   - плановый refresh access-токена за 30 дней до expires_at;
#   - без валидного refresh → статус needs_relink, брокер работает локально.
#
# Env: API_BASE_URL, OAUTH_CLIENT_ID, CLOUD_MQTT_HOST, CLOUD_MQTT_PORT,
#      CLOUD_BRIDGE_PROTOCOL, MQTT_USER, MQTT_PASSWORD.
set -u

# Пути переопределяемы для тестов вне контейнера (AGENT_*)
TOKENS_FILE="${AGENT_TOKENS_FILE:-/mosquitto/secrets/tokens.json}"
BRIDGE_CONF="${AGENT_BRIDGE_CONF:-/mosquitto/dynamic/bridge.conf}"
STATUS_FILE="${AGENT_STATUS_FILE:-/mosquitto/data/agent-status.json}"
CHECK_INTERVAL="${AGENT_CHECK_INTERVAL:-60}"    # период цикла, с
JWT_MAX_AGE="${AGENT_JWT_MAX_AGE:-2100}"        # 35 мин: ротация JWT (живёт ~1ч)
BRIDGE_GRACE="${AGENT_BRIDGE_GRACE:-90}"        # с: даём mosquitto самому переподняться
ACCESS_REFRESH_MARGIN=$((30 * 24 * 3600))       # 30 дней до expires_at
CURL="curl -sS -m 15"

MOSQ_PID=""
JWT_ISSUED_AT=0
LOCATION_ID=""
BRIDGE_DOWN_SINCE=0
RESTART_BACKOFF=0   # индекс: 0→90с, 1→300с, 2+→900с
LAST_RESTART=0

now() { date +%s; }

status() { # status <state> [detail]
    printf '{"state":"%s","detail":"%s","updated_at":%s,"jwt_issued_at":%s,"location_id":"%s"}\n' \
        "$1" "${2:-}" "$(now)" "$JWT_ISSUED_AT" "$LOCATION_ID" >"$STATUS_FILE.tmp" \
        && mv "$STATUS_FILE.tmp" "$STATUS_FILE"
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
}

# Получить свежий MQTT-JWT в глобалы JWT + LOCATION_ID (не через сабшелл —
# иначе значения потеряются). 0 = успех; 1 = терминально; 2 = временная ошибка.
fetch_jwt() {
    access="$(tokens_get access_token)"
    [ -n "$access" ] || return 1
    attempt=0
    while :; do
        http_call -H "Authorization: Bearer $access" \
            -H 'Accept: application/json' "$API_BASE_URL/api/mqtt/v1/token" || return 2
        case "$code" in
            200)
                JWT="$(printf '%s' "$body" | jq -r '.token // empty')"
                LOCATION_ID="$(printf '%s' "$body" | jq -r '.locationId // empty')"
                [ -n "$JWT" ] || return 2
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
    mv "$BRIDGE_CONF.tmp" "$BRIDGE_CONF"
    JWT_ISSUED_AT="$(now)"
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
        1) rm -f "$BRIDGE_CONF"; status needs_relink "refresh rejected at startup" ;;
        *) status bridge_down "cloud unreachable at startup"
           # сеть недоступна: локальный брокер важнее моста — стартуем с тем,
           # что есть (старый bridge.conf либо без него), агент дообновит
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

    # (a) проактивная ротация JWT без рестарта
    if [ $(( $(now) - JWT_ISSUED_AT )) -gt "$JWT_MAX_AGE" ]; then
        rotate_jwt; rc=$?
        case "$rc" in
            0) status ok "jwt rotated" ;;
            1) rm -f "$BRIDGE_CONF"; status needs_relink "refresh rejected"; continue ;;
            *) status rotating "cloud unreachable, will retry" ;;
        esac
    fi

    # (c) плановый refresh access задолго до истечения
    exp="$(tokens_get expires_at)"
    if [ -n "$exp" ] && [ $(( exp - $(now) )) -lt "$ACCESS_REFRESH_MARGIN" ]; then
        refresh_access || true
    fi

    # (b) мониторинг моста
    st="$(bridge_state)"
    if [ "$st" = "1" ]; then
        BRIDGE_DOWN_SINCE=0
        RESTART_BACKOFF=0
        status ok
        continue
    fi
    [ "$BRIDGE_DOWN_SINCE" -eq 0 ] && BRIDGE_DOWN_SINCE="$(now)"
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
    rotate_jwt || true   # даже при недоступном облаке рестарт не повредит
    stop_mosquitto
    start_mosquitto "$@"
    RESTART_BACKOFF=$(( RESTART_BACKOFF + 1 ))
    status bridge_down "restarted broker (backoff step $RESTART_BACKOFF)"
done
