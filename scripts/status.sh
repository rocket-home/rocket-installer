#!/usr/bin/env bash
# Сводное состояние: контейнеры, мост в облако, agent-status, фронт z2m.
. "$(dirname "$0")/lib/common.sh"
load_env

log "── Контейнеры ──────────────────────────────────────────────"
compose ps || true

log ""
log "── Мост в облако (${CLOUD_MQTT_HOST}:${CLOUD_MQTT_PORT}, ${CLOUD_AUTH_MODE}) ──"
state="$(compose exec -T mqtt mosquitto_sub -h localhost \
    -u "$LOCAL_MQTT_USER" -P "$LOCAL_MQTT_PASSWORD" \
    -t '$SYS/broker/connection/rocket/state' -C 1 -W 3 2>/dev/null || true)"
case "$state" in
    1) ok "мост подключён" ;;
    0) err "мост ОТКЛЮЧЁН" ;;
    *) warn "состояние моста неизвестно (стек не запущен или мост не сконфигурирован)" ;;
esac

if [ "${CLOUD_AUTH_MODE}" = "oauth" ]; then
    agent="$DATA_DIR/mosquitto/agent-status.json"
    if [ -f "$agent" ]; then
        log "token-agent: $(jq -r '"\(.state) (\(.detail // "-")), обновлён \(.updated_at | todate)"' "$agent" 2>/dev/null || cat "$agent")"
        [ "$(jq -r .state "$agent" 2>/dev/null)" = "needs_relink" ] && warn "нужна повторная линковка: make relink"
    else
        warn "agent-status.json ещё не создан (контейнер mqtt не запускался?)"
    fi
    if [ -s "$SECRETS_DIR/tokens.json" ]; then
        exp="$(jq -r '.expires_at // 0' "$SECRETS_DIR/tokens.json")"
        log "access-токен: истекает $(date -d "@$exp" '+%Y-%m-%d' 2>/dev/null || echo '?')"
    else
        warn "нет secrets/tokens.json — выполните: make oauth-link"
    fi
fi

log ""
log "── zigbee2mqtt ─────────────────────────────────────────────"
if ! zigbee_enabled; then
    log "не предусмотрен: стик не задан (узел работает мостом в облако)"
elif curl -fsS -m 3 -o /dev/null "http://localhost:${Z2M_FRONTEND_PORT}/"; then
    ok "фронт: http://$(hostname -I 2>/dev/null | awk '{print $1}'):${Z2M_FRONTEND_PORT}/  (auth_token: ${Z2M_FRONTEND_AUTH_TOKEN})"
else
    warn "фронт z2m недоступен на :${Z2M_FRONTEND_PORT}"
fi
