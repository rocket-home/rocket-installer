#!/usr/bin/env bash
# FORCE=1 не должен разрушать то, чем владеет z2m: устройства с их опциями, группы,
# permit_join и идентичность сети. Регрессия дорогая: потеря network_key = пересоздание
# сети (все устройства паруются заново), потеря devices = потеря retain/friendly_name.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

mkdir -p "$tmp/deploy/mosquitto/conf.d" "$tmp/data/zigbee2mqtt" "$tmp/secrets"
cp -r "$ROOT/templates" "$tmp/templates"
export ROCKET_ROOT="$tmp" ENV_FILE="$tmp/.env"

cat >"$ENV_FILE" <<'EOF'
CLOUD_AUTH_MODE=off
LOCAL_MQTT_USER=local
LOCAL_MQTT_PASSWORD=newpass
Z2M_BASE_TOPIC=zigbee2mqtt
Z2M_FRONTEND_PORT=4000
Z2M_FRONTEND_AUTH_TOKEN=fronttoken
Z2M_ADAPTER=
EOF

# «старый» конфиг — как его ведёт сам z2m на живом хабе
cat >"$tmp/data/zigbee2mqtt/configuration.yaml" <<'EOF'
homeassistant: false
permit_join: false
mqtt:
  base_topic: zigbee2mqtt
  server: mqtt://mqtt:1883
  user: olduser
  password: oldpass
serial:
  port: /dev/ttyACM0
advanced:
  log_level: warning
  last_seen: ISO_8601
  network_key:
    - 1
    - 3
    - 5
  pan_id: 6754
  ext_pan_id: GENERATE
groups:
  '1':
    friendly_name: kitchen
devices:
  '0x00158d000232033b':
    friendly_name: lamp
    retain: true
  '0x60a423fffed58f08':
    friendly_name: sensor
    retain: false
EOF

FORCE=1 "$ROOT/scripts/gen-configs.sh" >/dev/null
z2m="$tmp/data/zigbee2mqtt/configuration.yaml"

grep -q "password: 'newpass'" "$z2m" || { echo "FAIL: шаблонные ключи не обновились"; exit 1; }
grep -q "port: /dev/zigbee" "$z2m"   || { echo "FAIL: serial.port не из шаблона"; exit 1; }

# устройства и их опции
[ "$(grep -c 'friendly_name' "$z2m")" = "3" ] || { echo "FAIL: потеряны devices/groups"; exit 1; }
grep -q 'retain: true'  "$z2m" || { echo "FAIL: потерян retain: true"; exit 1; }
grep -q 'retain: false' "$z2m" || { echo "FAIL: потерян retain: false"; exit 1; }
grep -q "^  '0x00158d000232033b':" "$z2m" || { echo "FAIL: потеряно устройство по ieee"; exit 1; }
grep -q '^groups:' "$z2m" || { echo "FAIL: потеряны groups"; exit 1; }
grep -q '^permit_join: false' "$z2m" || { echo "FAIL: потерян permit_join"; exit 1; }
grep -q '^devices: {}' "$z2m" && { echo "FAIL: остался пустой devices из шаблона"; exit 1; }

# идентичность сети: шаблонный GENERATE не должен победить реальный ключ
grep -q 'network_key: GENERATE' "$z2m" && { echo "FAIL: network_key затёрт на GENERATE"; exit 1; }
grep -A3 'network_key:' "$z2m" | grep -q -- '- 3' || { echo "FAIL: потерян network_key"; exit 1; }
grep -q 'pan_id: 6754' "$z2m" || { echo "FAIL: потерян pan_id"; exit 1; }
# ext_pan_id в старом был GENERATE — остаётся шаблонный, это не потеря
grep -q 'ext_pan_id: GENERATE' "$z2m" || { echo "FAIL: ext_pan_id пропал"; exit 1; }

# YAML должен остаться валидным и семантически целым
python3 - "$z2m" <<'PY'
import sys, yaml
d = yaml.safe_load(open(sys.argv[1]))
assert len(d['devices']) == 2, d['devices']
assert d['devices']['0x00158d000232033b']['retain'] is True
assert d['devices']['0x60a423fffed58f08']['retain'] is False
assert d['advanced']['network_key'] == [1, 3, 5], d['advanced']['network_key']
assert d['advanced']['pan_id'] == 6754
assert d['permit_join'] is False
assert d['mqtt']['password'] == 'newpass'
assert d['serial']['port'] == '/dev/zigbee'
PY
echo "ok"
