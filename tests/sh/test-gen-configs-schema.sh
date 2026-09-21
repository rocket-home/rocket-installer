#!/usr/bin/env bash
# Схема сгенерированного конфига обязана соответствовать МАЖОРНОЙ версии образа.
# Матрица до сих пор отдаёт 1.x для старых прошивок и CC2531, а 1.x падает валидацией
# на ключах 2.x (version/homeassistant.enabled/frontend.enabled).
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
cp -r "$ROOT/templates" "$tmp/templates"
export ROCKET_ROOT="$tmp" ENV_FILE="$tmp/.env"

gen() { # gen <tag> <outdir>
    rm -rf "$tmp/data" "$tmp/deploy"; mkdir -p "$tmp/deploy/mosquitto/conf.d" "$tmp/data"
    cat >"$ENV_FILE" <<EOF
CLOUD_AUTH_MODE=off
LOCAL_MQTT_USER=local
LOCAL_MQTT_PASSWORD=pw
Z2M_BASE_TOPIC=zigbee2mqtt
Z2M_FRONTEND_PORT=4000
Z2M_FRONTEND_AUTH_TOKEN=tok
Z2M_IMAGE_TAG=$1
EOF
    "$ROOT/scripts/gen-configs.sh" >/dev/null
}

gen 1.42.0
c="$tmp/data/zigbee2mqtt/configuration.yaml"
grep -q '^version:' "$c" && { echo "FAIL: 1.x получил ключ version (схема 2.x)"; exit 1; }
grep -q '^homeassistant: false' "$c" || { echo "FAIL: 1.x homeassistant должен быть булевым"; exit 1; }
grep -A2 '^frontend:' "$c" | grep -q 'enabled:' && { echo "FAIL: 1.x frontend.enabled"; exit 1; }
grep -A2 '^availability:' "$c" | grep -q 'enabled:' && { echo "FAIL: 1.x availability.enabled"; exit 1; }
grep -q 'network_key: GENERATE' "$c" || { echo "FAIL: 1.x без network_key GENERATE"; exit 1; }

gen 2.6.0
grep -q '^version: 4' "$c" || { echo "FAIL: 2.x без version: 4"; exit 1; }
grep -A1 '^homeassistant:' "$c" | grep -q 'enabled: false' || { echo "FAIL: 2.x homeassistant.enabled"; exit 1; }

# пустой тег = поведение по умолчанию (последняя схема), без падения
gen ""
grep -q '^version: 4' "$c" || { echo "FAIL: пустой тег должен давать схему 2.x"; exit 1; }
echo ok
