#!/usr/bin/env bash
# Линковка машины с аккаунтом rocket-home.ru — OAuth 2.0 Device Authorization Grant
# (RFC 8628), контракт как у шлюза milafire-k3:
#   POST {API_BASE_URL}/oauth/device/code  (public client, scope rh.profile:read rh.mqtt:connect)
#   → пользователь вводит user_code на verification_uri →
#   POST {API_BASE_URL}/oauth/token (grant_type=device_code), поллинг:
#   authorization_pending — ждать, slow_down — интервал +5с.
# Результат: secrets/tokens.json (0600) {access_token, refresh_token, expires_at, obtained_at}.
. "$(dirname "$0")/lib/common.sh"
require_cmd curl
require_cmd jq
load_env

[ -n "${OAUTH_CLIENT_ID:-}" ] || die "OAUTH_CLIENT_ID пуст в .env"
SCOPE="rh.profile:read rh.mqtt:connect"
TOKENS_FILE="$SECRETS_DIR/tokens.json"

resp="$(curl -sS -m 15 -X POST "$API_BASE_URL/oauth/device/code" \
    -H 'Accept: application/json' \
    --data-urlencode "client_id=$OAUTH_CLIENT_ID" \
    --data-urlencode "scope=$SCOPE")" || die "облако недоступно ($API_BASE_URL)"

device_code="$(jq -r '.device_code // empty' <<<"$resp")"
user_code="$(jq -r '.user_code // empty' <<<"$resp")"
verification_uri="$(jq -r '.verification_uri // empty' <<<"$resp")"
verification_uri_complete="$(jq -r '.verification_uri_complete // empty' <<<"$resp")"
interval="$(jq -r '.interval // 5' <<<"$resp")"
expires_in="$(jq -r '.expires_in // 600' <<<"$resp")"
[ -n "$device_code" ] && [ -n "$user_code" ] || die "неожиданный ответ /oauth/device/code: $resp"
[ "$interval" -lt 3 ] && interval=5

log ""
log "┌─────────────────────────────────────────────────────┐"
log "  Откройте на телефоне или компьютере:"
log "    ${verification_uri_complete:-$verification_uri}"
log ""
log "  и введите код:  ${_C_GRN}${user_code}${_C_OFF}"
log "└─────────────────────────────────────────────────────┘"
log "Жду подтверждения (до $((expires_in / 60)) мин, Ctrl+C — отмена)…"

deadline=$(( $(date +%s) + expires_in ))
while :; do
    [ "$(date +%s)" -lt "$deadline" ] || die "код истёк — запустите линковку заново"
    sleep "$interval"
    body="$(curl -sS -m 15 -X POST "$API_BASE_URL/oauth/token" \
        -H 'Accept: application/json' \
        --data-urlencode "grant_type=urn:ietf:params:oauth:grant-type:device_code" \
        --data-urlencode "device_code=$device_code" \
        --data-urlencode "client_id=$OAUTH_CLIENT_ID")" || { warn "сеть моргнула, продолжаю"; continue; }

    error="$(jq -r '.error // empty' <<<"$body")"
    case "$error" in
        "") ;;
        authorization_pending) continue ;;
        slow_down) interval=$((interval + 5)); continue ;;
        access_denied) die "доступ отклонён пользователем" ;;
        expired_token) die "код истёк — запустите линковку заново" ;;
        *) die "ошибка авторизации: $error" ;;
    esac

    access="$(jq -r '.access_token // empty' <<<"$body")"
    refresh="$(jq -r '.refresh_token // empty' <<<"$body")"
    tok_expires_in="$(jq -r '.expires_in // 31536000' <<<"$body")"
    [ -n "$access" ] && [ -n "$refresh" ] || die "неожиданный ответ /oauth/token: $body"

    mkdir -p "$SECRETS_DIR"; chmod 700 "$SECRETS_DIR"
    umask 077
    jq -n --arg a "$access" --arg r "$refresh" \
        --argjson exp "$(( $(date +%s) + tok_expires_in ))" --argjson at "$(date +%s)" \
        '{access_token:$a, refresh_token:$r, expires_at:$exp, obtained_at:$at}' \
        >"$TOKENS_FILE.tmp" && mv "$TOKENS_FILE.tmp" "$TOKENS_FILE"
    ok "Линковка выполнена — токены в secrets/tokens.json"

    # Закрепляем локацию. Без неё token-agent ходит на /api/mqtt/v1/token «по умолчанию»,
    # а тот при аккаунте без локаций СОЗДАЁТ новую («Дом») — хаб молча уедет на чужой
    # mount point. Список берём из identity (scope rh.profile:read уже в гранте), чтобы
    # не создать локацию самим запросом.
    me="$(curl -sS -m 15 -H "Authorization: Bearer $access" -H 'Accept: application/json' \
        "$API_BASE_URL/api/identity/v1/me" 2>/dev/null || true)"
    loc_count="$(jq -r '(.allowedLocations // []) | length' <<<"$me" 2>/dev/null || echo 0)"
    current="$(env_get CLOUD_LOCATION_ID)"

    if [ -n "$current" ]; then
        if [ "$loc_count" -gt 0 ] && ! jq -e --arg id "$current" \
            '(.allowedLocations // []) | any(.id == $id)' >/dev/null <<<"$me"; then
            warn "в .env закреплена локация $current, но грант её не содержит — мост не встанет"
            warn "проверьте: make env-set KEY=CLOUD_LOCATION_ID VALUE=<id из списка ниже>"
            jq -r '(.allowedLocations // [])[] | "  \(.id)  \(.title)"' <<<"$me" 2>/dev/null || true
        else
            ok "локация уже закреплена: $current"
        fi
    elif [ "$loc_count" = "1" ]; then
        loc_id="$(jq -r '.allowedLocations[0].id' <<<"$me")"
        loc_title="$(jq -r '.allowedLocations[0].title // ""' <<<"$me")"
        "$ROCKET_ROOT/scripts/env-set.sh" CLOUD_LOCATION_ID "$loc_id"
        ok "локация закреплена: $loc_title ($loc_id)"
    elif [ "$loc_count" -gt 1 ]; then
        warn "в гранте несколько локаций — выберите, к какой привязан этот хаб:"
        jq -r '(.allowedLocations // [])[] | "  \(.id)  \(.title)"' <<<"$me"
        warn "затем: make env-set KEY=CLOUD_LOCATION_ID VALUE=<id>"
    else
        warn "не удалось получить список локаций — закрепите вручную:"
        warn "  make env-set KEY=CLOUD_LOCATION_ID VALUE=<id локации>"
    fi

    log "Применение к работающему стеку: перезапуск моста (make relink делает это сам)."
    exit 0
done
