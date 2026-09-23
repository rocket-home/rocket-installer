#!/usr/bin/env bash
# permit-join шлёт payload, понятный обоим мажорам z2m: 1.x требует `value` (без него —
# «Invalid payload», а скрипт рапортовал «сеть открыта»; хаб 23.09.2026), 2.x требует `time`.
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
mkdir -p "$tmp/scripts/lib" "$tmp/bin" "$tmp/deploy"
cp "$ROOT"/scripts/permit-join.sh "$tmp/scripts/"
cp "$ROOT"/scripts/lib/*.sh "$tmp/scripts/lib/"
cp "$ROOT/deploy/docker-compose.yml" "$tmp/deploy/"
export ROCKET_ROOT="$tmp" ENV_FILE="$tmp/.env" PATH="$tmp/bin:$PATH"
printf 'LOCAL_MQTT_USER=local\nLOCAL_MQTT_PASSWORD=secret\nZ2M_BASE_TOPIC=zigbee2mqtt\nZIGBEE_DEVICE_HOST=/dev/null\n' >"$ENV_FILE"
cat >"$tmp/bin/docker" <<EOS
#!/usr/bin/env bash
printf '%s\n' "\$@" >"$tmp/pub.args"; exit 0
EOS
chmod +x "$tmp/bin/docker"
arg_after() { awk -v k="$1" 'p{print; exit} $0==k{p=1}' "$tmp/pub.args"; }

bash "$tmp/scripts/permit-join.sh" on 120 >/dev/null || { echo "FAIL: on упал"; exit 1; }
[ "$(arg_after -t)" = "zigbee2mqtt/bridge/request/permit_join" ] || { echo "FAIL: топик: $(arg_after -t)"; exit 1; }
[ "$(arg_after -m | jq -c .)" = '{"value":true,"time":120}' ] || { echo "FAIL: payload on: $(arg_after -m)"; exit 1; }

bash "$tmp/scripts/permit-join.sh" off >/dev/null || { echo "FAIL: off упал"; exit 1; }
[ "$(arg_after -m | jq -c .)" = '{"value":false,"time":0}' ] || { echo "FAIL: payload off: $(arg_after -m)"; exit 1; }

bash "$tmp/scripts/permit-join.sh" maybe >/dev/null 2>&1 && { echo "FAIL: неизвестный режим принят"; exit 1; }
echo ok
