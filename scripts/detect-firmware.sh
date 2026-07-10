#!/usr/bin/env bash
# Детект семейства/прошивки координатора probe-контейнером. Выводит JSON probe.py.
# Требует эксклюзивного доступа к serial: работающий zigbee2mqtt останавливается
# на время probe и запускается обратно.
# Тестируемость: ROCKET_PROBE_CMD подменяет запуск контейнера (например, cat фикстуры).
. "$(dirname "$0")/lib/common.sh"
require_cmd jq

DEVICE="${DEVICE:-$(env_get ZIGBEE_DEVICE_HOST)}"
HINT="${HINT:-$(env_get ADAPTER_FAMILY)}"
[ -n "$DEVICE" ] || die "устройство неизвестно: make detect-device, затем env-set ZIGBEE_DEVICE_HOST"

if [ -n "${ROCKET_PROBE_CMD:-}" ]; then
    $ROCKET_PROBE_CMD
    exit $?
fi

require_cmd docker
[ -e "$DEVICE" ] || die "устройство $DEVICE не найдено (стик подключён? make detect-device)"

# z2m держит serial эксклюзивно — на время probe останавливаем
z2m_running=""
if [ -f "$ENV_FILE" ] && [ -n "$(compose ps -q zigbee2mqtt 2>/dev/null)" ]; then
    z2m_running=1
    warn "останавливаю zigbee2mqtt на время probe (serial эксклюзивен)…"
    compose stop zigbee2mqtt >/dev/null
fi
restore() { [ -n "$z2m_running" ] && compose start zigbee2mqtt >/dev/null 2>&1 || true; }
trap restore EXIT

image="rocket-probe:local"
docker build -q -t "$image" "$ROCKET_ROOT/deploy/probe" >/dev/null
docker run --rm --device "$DEVICE:/dev/zigbee" "$image" /dev/zigbee "$HINT"
