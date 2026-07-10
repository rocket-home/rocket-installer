#!/usr/bin/env bash
# gen-configs.sh во временном ROCKET_ROOT: рендер z2m-конфига, static-мост,
# идемпотентность (не перетирает без FORCE), переключение в oauth удаляет static-конфиг.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

mkdir -p "$tmp/deploy/mosquitto/conf.d" "$tmp/data" "$tmp/secrets"
cp -r "$ROOT/templates" "$tmp/templates"
export ROCKET_ROOT="$tmp" ENV_FILE="$tmp/.env"

cat >"$ENV_FILE" <<'EOF'
CLOUD_AUTH_MODE=static
CLOUD_MQTT_HOST=mq.rocket-home.ru
CLOUD_MQTT_PORT=8883
CLOUD_BRIDGE_PROTOCOL=mqttv311
CLOUD_MQTT_USERNAME=user-uuid
CLOUD_MQTT_PASSWORD=secret-pass
LOCAL_MQTT_USER=local
LOCAL_MQTT_PASSWORD=localpass
Z2M_BASE_TOPIC=zigbee2mqtt
Z2M_FRONTEND_PORT=4000
Z2M_FRONTEND_AUTH_TOKEN=fronttoken
Z2M_ADAPTER=ember
EOF

"$ROOT/scripts/gen-configs.sh" >/dev/null

z2m="$tmp/data/zigbee2mqtt/configuration.yaml"
grep -q "password: 'localpass'" "$z2m" || { echo "FAIL: пароль не отрендерен"; exit 1; }
grep -q "adapter: ember" "$z2m" || { echo "FAIL: serial.adapter не добавлен"; exit 1; }
grep -q "auth_token: 'fronttoken'" "$z2m" || { echo "FAIL: auth_token фронта"; exit 1; }
grep -q 'network_key: GENERATE' "$z2m" || { echo "FAIL: network_key GENERATE"; exit 1; }

bridge="$tmp/deploy/mosquitto/conf.d/bridge.conf"
grep -q 'address mq.rocket-home.ru:8883' "$bridge" || { echo "FAIL: мост address"; exit 1; }
grep -q 'bridge_protocol_version mqttv311' "$bridge" || { echo "FAIL: версия протокола"; exit 1; }
grep -q 'bridge_capath /etc/ssl/certs' "$bridge" || { echo "FAIL: TLS capath"; exit 1; }
grep -q 'remote_password secret-pass' "$bridge" || { echo "FAIL: пароль моста"; exit 1; }
grep -q 'notifications_local_only true' "$bridge" || { echo "FAIL: notifications_local_only"; exit 1; }
grep -q 'topic # both 2' "$bridge" || { echo "FAIL: topic-маппинг"; exit 1; }

# идемпотентность: правка руками переживает повторный запуск без FORCE
echo "# manual edit" >>"$z2m"
"$ROOT/scripts/gen-configs.sh" >/dev/null
grep -q '# manual edit' "$z2m" || { echo "FAIL: конфиг z2m перетёрт без FORCE"; exit 1; }

# переключение в oauth: static-мост удаляется (с бэкапом)
"$ROOT/scripts/env-set.sh" CLOUD_AUTH_MODE oauth
touch "$tmp/secrets/tokens.json"
"$ROOT/scripts/gen-configs.sh" >/dev/null
[ ! -f "$bridge" ] || { echo "FAIL: static bridge.conf остался в oauth-режиме"; exit 1; }
ls "$bridge".bak-* >/dev/null 2>&1 || { echo "FAIL: нет бэкапа bridge.conf"; exit 1; }

echo "gen-configs: OK"
