#!/usr/bin/env bash
# Импорт со старого стека: состояние сети переносится целиком, а в конфиге меняются
# ровно три вещи, без которых новый стек не поднимется (serial.port, креды брокера,
# permit_join). Устройства, их retain и ключи сети трогать нельзя.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
export ROCKET_ROOT="$tmp" ENV_FILE="$tmp/.env"
mkdir -p "$tmp/data" "$tmp/legacy/extension/rocket-runner"

cat >"$ENV_FILE" <<'EOF'
LOCAL_MQTT_USER=local
LOCAL_MQTT_PASSWORD=newsecret
EOF

cat >"$tmp/legacy/configuration.yaml" <<'EOF'
homeassistant: false
permit_join: true
mqtt:
  base_topic: zigbee2mqtt
  server: mqtt://mqtt:1883
  user: user
  password: password
serial:
  port: /dev/ttyACM0
advanced:
  log_level: warning
  network_key:
    - 9
    - 8
devices:
  '0x00158d000232033b':
    friendly_name: lamp
    retain: true
  '0x60a423fffed58f08':
    friendly_name: sensor
    retain: false
EOF
printf 'sqlite-ish\n' >"$tmp/legacy/database.db"
printf '{"network_key":{"key":"aa"}}\n' >"$tmp/legacy/coordinator_backup.json"
printf '{"seq":414}\n' >"$tmp/legacy/extension/rocket-runner/state.json"
printf '// runner\n' >"$tmp/legacy/rocket-local-runner.js" 2>/dev/null || true
mv "$tmp/legacy/rocket-local-runner.js" "$tmp/legacy/extension/rocket-local-runner.js"

LEGACY_DIR="$tmp/legacy" "$ROOT/scripts/import-legacy.sh" >/dev/null 2>&1

c="$tmp/data/zigbee2mqtt/configuration.yaml"
[ -f "$tmp/data/zigbee2mqtt/database.db" ] || { echo "FAIL: database.db не перенесён"; exit 1; }
[ -f "$tmp/data/zigbee2mqtt/coordinator_backup.json" ] || { echo "FAIL: ключи сети не перенесены"; exit 1; }
[ -f "$tmp/data/zigbee2mqtt/extension/rocket-runner/state.json" ] || { echo "FAIL: состояние расширения не перенесено"; exit 1; }
[ -f "$tmp/data/zigbee2mqtt/extension/rocket-local-runner.js" ] || { echo "FAIL: расширение не перенесено"; exit 1; }
ls "$tmp/data/zigbee2mqtt/"configuration.yaml.imported-* >/dev/null 2>&1 || { echo "FAIL: нет копии исходного конфига"; exit 1; }

python3 - "$c" <<'PY'
import sys, yaml
d = yaml.safe_load(open(sys.argv[1]))
assert d['serial']['port'] == '/dev/zigbee', d['serial']
assert d['mqtt']['user'] == 'local', d['mqtt']
assert d['mqtt']['password'] == 'newsecret', d['mqtt']
assert d['mqtt']['base_topic'] == 'zigbee2mqtt'
assert d['permit_join'] is False, d['permit_join']
assert d['devices']['0x00158d000232033b']['retain'] is True
assert d['devices']['0x60a423fffed58f08']['retain'] is False
assert d['advanced']['network_key'] == [9, 8], d['advanced']
assert d['advanced']['log_level'] == 'warning'
PY
echo ok
