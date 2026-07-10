#!/usr/bin/env bash
# Диагностика сетапа. Накапливает FAIL и продолжает (не падает на первой ошибке);
# в конце — сводка и exit 1 при любых FAIL.
. "$(dirname "$0")/lib/common.sh"

FAILS=0
pass() { ok "$*"; }
failm() { err "$*"; FAILS=$((FAILS + 1)); }

log "── Тулинг ──"
if "$ROCKET_ROOT/scripts/check-tools.sh" >/dev/null 2>&1; then pass "инструменты на месте"; else failm "не хватает инструментов (make check-tools)"; fi

log "── Конфигурация ──"
if [ -f "$ENV_FILE" ]; then pass ".env существует"; else failm ".env отсутствует (make env-init)"; fi
[ -f "$ENV_FILE" ] || { err "дальнейшие проверки невозможны без .env"; exit 1; }
load_env

log "── Zigbee-стик ──"
dev="${ZIGBEE_DEVICE_HOST:-}"
if [ -z "$dev" ]; then
    failm "ZIGBEE_DEVICE_HOST не задан (make detect-device)"
elif [ ! -e "$dev" ]; then
    failm "устройство $dev не существует (стик выдернут? make detect-device)"
elif [ ! -c "$dev" ]; then
    failm "$dev — не character device (symlink? нужен realpath)"
else
    pass "стик: $dev"
fi
if [ -f /etc/udev/rules.d/99-zigbee.rules ]; then pass "udev-правила установлены"; else failm "udev-правила не установлены (make udev-install)"; fi
if id -nG | tr ' ' '\n' | grep -qx dialout; then pass "пользователь в dialout"; else warn "пользователь не в dialout (make udev-install + перелогин)"; fi

log "── Docker и контейнеры ──"
if docker info >/dev/null 2>&1; then
    pass "docker живой"
    for svc in mqtt zigbee2mqtt; do
        st="$(compose ps --format '{{.State}}' "$svc" 2>/dev/null | head -1)"
        if [ "$st" = "running" ]; then pass "контейнер $svc: running"; else failm "контейнер $svc: ${st:-не запущен} (make up)"; fi
    done
else
    failm "docker недоступен (демон не запущен / нет прав; перелогин после установки?)"
fi

log "── Часы ──"
# TLS и JWT чувствительны к сдвигу часов (грабли milafire/SNTP)
if command -v timedatectl >/dev/null 2>&1; then
    if timedatectl show -p NTPSynchronized --value 2>/dev/null | grep -qx yes; then
        pass "часы синхронизированы (NTP)"
    else
        warn "NTP-синхронизация не подтверждена — TLS/OAuth могут сбоить при сдвиге часов"
    fi
fi

log "── Облако ──"
case "${CLOUD_AUTH_MODE:-oauth}" in
    oauth)
        if [ -s "$SECRETS_DIR/tokens.json" ]; then
            pass "tokens.json есть"
            exp="$(jq -r '.expires_at // 0' "$SECRETS_DIR/tokens.json" 2>/dev/null)"
            if [ "$exp" -gt "$(date +%s)" ]; then pass "access-токен не истёк"; else failm "access-токен истёк (make relink)"; fi
        else
            failm "нет secrets/tokens.json (make oauth-link)"
        fi
        agent="$DATA_DIR/mosquitto/agent-status.json"
        if [ -f "$agent" ]; then
            st="$(jq -r '.state // "?"' "$agent" 2>/dev/null)"
            case "$st" in
                ok) pass "token-agent: ok" ;;
                needs_relink) failm "token-agent: нужна повторная линковка (make relink)" ;;
                *) warn "token-agent: $st" ;;
            esac
        fi
        ;;
    static)
        if [ -n "${CLOUD_MQTT_USERNAME:-}" ] && [ -n "${CLOUD_MQTT_PASSWORD:-}" ]; then pass "static-креды заданы"; else failm "static-креды пусты (rocket-home.ru/profile/mqtt)"; fi
        ;;
    off) log "мост выключен (CLOUD_AUTH_MODE=off)" ;;
esac
bridge_state="$(compose exec -T mqtt mosquitto_sub -h localhost -u "$LOCAL_MQTT_USER" -P "$LOCAL_MQTT_PASSWORD" \
    -t '$SYS/broker/connection/rocket/state' -C 1 -W 3 2>/dev/null || true)"
if [ "${CLOUD_AUTH_MODE:-oauth}" != "off" ]; then
    if [ "$bridge_state" = "1" ]; then pass "мост подключён"; else failm "мост не подключён (state='${bridge_state:-?}'; make logs SERVICE=mqtt)"; fi
fi

log "── Диск ──"
avail_kb="$(df -Pk "$ROCKET_ROOT" | awk 'NR==2 {print $4}')"
if [ "${avail_kb:-0}" -lt 1048576 ]; then failm "меньше 1 ГиБ свободно ($((avail_kb / 1024)) МиБ)"; else pass "свободно $((avail_kb / 1024 / 1024)) ГиБ"; fi

log ""
if [ "$FAILS" -eq 0 ]; then
    ok "Doctor: всё зелёное."
else
    die "Doctor: проблем — $FAILS (см. выше)."
fi
