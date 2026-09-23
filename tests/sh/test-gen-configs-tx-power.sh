#!/usr/bin/env bash
# transmit_power: 20 попадает в конфиг для Z-Stack/ember и автодетекта, но не для deconz и
# zigate — вместе с комментарием, чтобы файл не описывал ключ, которого в нём нет.
# Заводские 9 дБм не доносили beacon до выключателя в подрозетнике (23.09.2026).
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
cp -r "$ROOT/templates" "$tmp/templates"
export ROCKET_ROOT="$tmp" ENV_FILE="$tmp/.env"

gen() {  # gen <тег образа> <адаптер>
    rm -rf "$tmp/data" "$tmp/deploy"; mkdir -p "$tmp/deploy/mosquitto/conf.d" "$tmp/data"
    cat >"$ENV_FILE" <<EOF
CLOUD_AUTH_MODE=off
LOCAL_MQTT_USER=local
LOCAL_MQTT_PASSWORD=pw
Z2M_BASE_TOPIC=zigbee2mqtt
Z2M_FRONTEND_PORT=4000
Z2M_FRONTEND_AUTH_TOKEN=tok
Z2M_IMAGE_TAG=$1
Z2M_ADAPTER=$2
EOF
    "$ROOT/scripts/gen-configs.sh" >/dev/null
}
c="$tmp/data/zigbee2mqtt/configuration.yaml"

for adapter in zstack ember ""; do
    gen 2.6.0 "$adapter"
    grep -q '^  transmit_power: 20$' "$c" || { echo "FAIL: adapter='$adapter' без transmit_power"; exit 1; }
done
gen 1.42.0 zstack
grep -q '^  transmit_power: 20$' "$c" || { echo "FAIL: схема 1.x без transmit_power"; exit 1; }

for adapter in deconz zigate; do
    gen 2.6.0 "$adapter"
    grep -q 'transmit_power' "$c" && { echo "FAIL: $adapter получил transmit_power"; exit 1; }
    grep -q 'Мощность передатчика' "$c" && { echo "FAIL: $adapter: осиротевший комментарий"; exit 1; }
    grep -q '^  last_seen: ISO_8601$' "$c" || { echo "FAIL: $adapter: соседний ключ пострадал"; exit 1; }
done
echo ok
