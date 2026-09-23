#!/usr/bin/env bash
# pair-watch читает bridge/event, bridge/response/permit_join и bridge/info и печатает
# события сопряжения человеческими строками. Из retained bridge/info печатается только
# СМЕНА состояния окна (он переиздаётся по любому поводу), мусор во входе игнорируется,
# ограничение по времени доходит до mosquitto_sub как -W.
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

mkdir -p "$tmp/scripts/lib" "$tmp/bin" "$tmp/deploy"
cp "$ROOT"/scripts/pair-watch.sh "$tmp/scripts/"
cp "$ROOT"/scripts/lib/*.sh "$tmp/scripts/lib/"
cp "$ROOT/deploy/docker-compose.yml" "$tmp/deploy/"
export ROCKET_ROOT="$tmp" ENV_FILE="$tmp/.env" PATH="$tmp/bin:$PATH"
cat >"$ENV_FILE" <<EOF
LOCAL_MQTT_USER=local
LOCAL_MQTT_PASSWORD=secret
Z2M_BASE_TOPIC=zigbee2mqtt
ZIGBEE_DEVICE_HOST=/dev/null
EOF

# Эфир как в живом разборе 23.09.2026: окно, розетка вошла и опозналась, старый Aqara
# не прошёл интервью; плюс частичный re-emit bridge/info и строка-мусор.
cat >"$tmp/feed.txt" <<'EOF'
zigbee2mqtt/bridge/info {"permit_join":false,"version":"1.42.0"}
zigbee2mqtt/bridge/response/permit_join {"data":{"time":254,"value":true},"status":"ok"}
zigbee2mqtt/bridge/info {"permit_join":true,"permit_join_timeout":254}
zigbee2mqtt/bridge/info {"permit_join":true,"permit_join_timeout":200}
zigbee2mqtt/bridge/event {"type":"device_joined","data":{"friendly_name":"0xcc86ecfffe4eb0b8","ieee_address":"0xcc86ecfffe4eb0b8"}}
zigbee2mqtt/bridge/event {"type":"device_interview","data":{"friendly_name":"0xcc86ecfffe4eb0b8","ieee_address":"0xcc86ecfffe4eb0b8","status":"started"}}
zigbee2mqtt/bridge/event {"type":"device_interview","data":{"friendly_name":"0xcc86ecfffe4eb0b8","ieee_address":"0xcc86ecfffe4eb0b8","status":"successful","supported":true,"definition":{"model":"TS0121_plug","vendor":"TuYa","description":"10A UK or 16A EU smart plug"}}}
zigbee2mqtt/bridge/event {"type":"device_interview","data":{"friendly_name":"0x00158d0003d058a0","ieee_address":"0x00158d0003d058a0","status":"failed"}}
zigbee2mqtt/bridge/info {"version":"1.42.0"}
мусор без json
zigbee2mqtt/bridge/response/permit_join {"error":"Invalid payload","status":"error"}
zigbee2mqtt/bridge/event {"type":"device_leave","data":{"ieee_address":"0x00158d0009dfabc0"}}
zigbee2mqtt/bridge/info {"permit_join":false}
EOF

# Как настоящий mosquitto_sub: по -W печатает «Timed out» в stderr и выходит с 27;
# файл $tmp/broken переключает его в «брокер недоступен» (код 1).
cat >"$tmp/bin/docker" <<EOF
#!/usr/bin/env bash
case "\$*" in
    *mosquitto_sub*)
        printf '%s\n' "\$@" >"$tmp/sub.args"
        [ -f "$tmp/broken" ] && { echo "Error: Connection refused" >&2; exit 1; }
        cat "$tmp/feed.txt"
        for a in "\$@"; do [ "\$a" = "-W" ] && { echo "Timed out" >&2; exit 27; }; done ;;
esac
exit 0
EOF
chmod +x "$tmp/bin/docker"

out="$(bash "$tmp/scripts/pair-watch.sh" 5 2>&1)" || { echo "FAIL: истечение -W должно быть штатным выходом: $out"; exit 1; }
grep -q "Timed out" <<<"$out" && { echo "FAIL: «Timed out» от mosquitto_sub просочился в вывод"; exit 1; }

expect() {  # expect <подстрока> <сколько раз>
    local n
    n="$(grep -c -- "$1" <<<"$out")"
    [ "$n" = "$2" ] || { echo "FAIL: '$1' ожидалось $2 раз, найдено $n:"; echo "$out"; exit 1; }
}
expect "команда принята: открыть сеть на 254 с" 1
expect "сеть открыта" 1                       # два bridge/info с permit_join:true → одна строка
expect "сеть закрыта" 2                       # начальное состояние и конец окна
expect "вошёл в сеть: 0xcc86ecfffe4eb0b8" 1
expect "интервью началось: 0xcc86ecfffe4eb0b8" 1
expect "опознан: 0xcc86ecfffe4eb0b8 — 10A UK or 16A EU smart plug (TuYa TS0121_plug)" 1
expect "интервью не удалось: 0x00158d0003d058a0" 1
expect "permit_join отвергнут: Invalid payload" 1
expect "покинул сеть: 0x00158d0009dfabc0" 1
grep -q "мусор" <<<"$out" && { echo "FAIL: мусорная строка попала в вывод"; exit 1; }
grep -qE '^[0-9]{2}:[0-9]{2}:[0-9]{2}  ' <<<"$out" || { echo "FAIL: нет отметок времени: $out"; exit 1; }

grep -qx -- "-W" "$tmp/sub.args" && grep -qx "5" "$tmp/sub.args" \
    || { echo "FAIL: ограничение времени не дошло до mosquitto_sub"; exit 1; }
for t in zigbee2mqtt/bridge/event zigbee2mqtt/bridge/response/permit_join zigbee2mqtt/bridge/info; do
    grep -qx "$t" "$tmp/sub.args" || { echo "FAIL: нет подписки на $t"; exit 1; }
done

# без аргумента — без -W; не число — отказ до подписки
rm -f "$tmp/sub.args"
bash "$tmp/scripts/pair-watch.sh" >/dev/null 2>&1 || { echo "FAIL: запуск без аргумента"; exit 1; }
grep -qx -- "-W" "$tmp/sub.args" && { echo "FAIL: без аргумента не должно быть -W"; exit 1; }
rm -f "$tmp/sub.args"
bash "$tmp/scripts/pair-watch.sh" abc >/dev/null 2>&1 && { echo "FAIL: 'abc' должен отвергаться"; exit 1; }
[ ! -f "$tmp/sub.args" ] || { echo "FAIL: 'abc' дошёл до подписки"; exit 1; }

# брокер недоступен — настоящая ошибка, с подсказкой
touch "$tmp/broken"
if out="$(bash "$tmp/scripts/pair-watch.sh" 5 2>&1)"; then echo "FAIL: недоступный брокер должен ронять скрипт"; exit 1; fi
grep -q "make status" <<<"$out" || { echo "FAIL: нет подсказки при недоступном брокере: $out"; exit 1; }

echo ok
