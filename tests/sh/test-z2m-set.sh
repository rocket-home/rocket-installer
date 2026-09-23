#!/usr/bin/env bash
# Настройки z2m на лету идут через bridge/request/options. Скрипт обязан: слать ровно тот
# JSON, что просили (log_level строкой, transmit_power числом); печатать restart_required
# словами самого z2m; чёрный список считать из retained bridge/info, а не переписывать
# вслепую; любой мусор во входе останавливать до публикации. Разбор сопряжения 23.09.2026.
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

mkdir -p "$tmp/scripts/lib" "$tmp/bin" "$tmp/deploy"
cp "$ROOT"/scripts/z2m-set.sh "$tmp/scripts/"
cp "$ROOT"/scripts/lib/*.sh "$tmp/scripts/lib/"
cp "$ROOT/deploy/docker-compose.yml" "$tmp/deploy/"
export ROCKET_ROOT="$tmp" ENV_FILE="$tmp/.env" PATH="$tmp/bin:$PATH"
cat >"$ENV_FILE" <<EOF
LOCAL_MQTT_USER=local
LOCAL_MQTT_PASSWORD=secret
Z2M_BASE_TOPIC=zigbee2mqtt
ZIGBEE_DEVICE_HOST=/dev/null
EOF

# Фейковый docker: mosquitto_rr записывает аргументы и отвечает заготовкой,
# mosquitto_sub отдаёт retained bridge/info.
cat >"$tmp/bin/docker" <<EOF
#!/usr/bin/env bash
case "\$*" in
    *mosquitto_rr*)  printf '%s\n' "\$@" >"$tmp/rr.args"; cat "$tmp/rr.response" ;;
    *mosquitto_sub*) cat "$tmp/info.json" ;;
esac
exit 0
EOF
chmod +x "$tmp/bin/docker"

run() { bash "$tmp/scripts/z2m-set.sh" "$@" 2>&1; }
arg_after() { awk -v k="$1" 'p{print; exit} $0==k{p=1}' "$tmp/rr.args"; }
payload() { arg_after -m | jq -c .; }

# ── log: строка, без рестарта ─────────────────────────────────────────────────
echo '{"data":{"restart_required":false},"status":"ok"}' >"$tmp/rr.response"
out="$(run log debug)" || { echo "FAIL: log debug упал: $out"; exit 1; }
[ "$(payload)" = '{"options":{"advanced":{"log_level":"debug"}}}' ] \
    || { echo "FAIL: payload log: $(payload)"; exit 1; }
[ "$(arg_after -t)" = "zigbee2mqtt/bridge/request/options" ] || { echo "FAIL: топик запроса: $(arg_after -t)"; exit 1; }
[ "$(arg_after -e)" = "zigbee2mqtt/bridge/response/options" ] || { echo "FAIL: топик ответа: $(arg_after -e)"; exit 1; }
grep -q "рестарт не нужен" <<<"$out" || { echo "FAIL: нет фразы про ненужный рестарт: $out"; exit 1; }
grep -q "z2m-restart" <<<"$out" && { echo "FAIL: предлагает рестарт, когда z2m его не просил: $out"; exit 1; }

# ── tx-power: число, z2m просит рестарт ───────────────────────────────────────
echo '{"data":{"restart_required":true},"status":"ok"}' >"$tmp/rr.response"
out="$(run tx-power 20)" || { echo "FAIL: tx-power 20 упал: $out"; exit 1; }
[ "$(payload)" = '{"options":{"advanced":{"transmit_power":20}}}' ] \
    || { echo "FAIL: payload tx-power (число, не строка): $(payload)"; exit 1; }
grep -q "make z2m-restart" <<<"$out" || { echo "FAIL: нет подсказки про рестарт: $out"; exit 1; }

# ── unblock: список считается из bridge/info, регистр не важен ───────────────
echo '{"config":{"blocklist":["0x00158d000214fedc","0x00158D0002C8B942"]}}' >"$tmp/info.json"
run unblock 0x00158D000214FEDC >/dev/null || { echo "FAIL: unblock одного упал"; exit 1; }
[ "$(payload)" = '{"options":{"blocklist":["0x00158D0002C8B942"]}}' ] \
    || { echo "FAIL: payload unblock одного: $(payload)"; exit 1; }
run unblock all >/dev/null || { echo "FAIL: unblock all упал"; exit 1; }
[ "$(payload)" = '{"options":{"blocklist":[]}}' ] || { echo "FAIL: payload unblock all: $(payload)"; exit 1; }
rm -f "$tmp/rr.args"
out="$(run unblock 0x0000000000000001)" || { echo "FAIL: unblock отсутствующего должен быть нулевым: $out"; exit 1; }
[ ! -f "$tmp/rr.args" ] || { echo "FAIL: отсутствующий ieee не должен порождать запрос"; exit 1; }
grep -q "не в чёрном списке" <<<"$out" || { echo "FAIL: нет объяснения, что ieee не в списке: $out"; exit 1; }
echo '{"config":{"blocklist":[]}}' >"$tmp/info.json"
out="$(run unblock all)" || { echo "FAIL: unblock all на пустом списке: $out"; exit 1; }
[ ! -f "$tmp/rr.args" ] || { echo "FAIL: пустой список не должен порождать запрос"; exit 1; }

# ── мусор во входе останавливается ДО публикации ──────────────────────────────
for bad in "log verbose" "tx-power 99" "tx-power 20dBm" "tx-power" "unblock foo" "raw not-json" "raw" "nothing"; do
    rm -f "$tmp/rr.args"
    # shellcheck disable=SC2086
    if run $bad >/dev/null; then echo "FAIL: '$bad' должен отвергаться"; exit 1; fi
    [ ! -f "$tmp/rr.args" ] || { echo "FAIL: '$bad' дошёл до публикации"; exit 1; }
done

# ── z2m отверг настройку — падаем с его словами ───────────────────────────────
echo '{"error":"Invalid payload","status":"error"}' >"$tmp/rr.response"
if out="$(run log info)"; then echo "FAIL: ошибка z2m должна ронять скрипт"; exit 1; fi
grep -q "Invalid payload" <<<"$out" || { echo "FAIL: причина z2m не напечатана: $out"; exit 1; }

# ── z2m молчит — падаем с подсказкой, куда смотреть ───────────────────────────
: >"$tmp/rr.response"
if out="$(run log info)"; then echo "FAIL: молчание z2m должно ронять скрипт"; exit 1; fi
grep -q "make status" <<<"$out" || { echo "FAIL: нет подсказки при молчании: $out"; exit 1; }

echo ok
