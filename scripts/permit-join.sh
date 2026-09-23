#!/usr/bin/env bash
# Открыть/закрыть zigbee-сеть для подключения новых устройств.
# Использование: permit-join.sh on [time_sec] | off
# Через MQTT-запрос к z2m (runtime, конфиг не трогаем; z2m сам закроет сеть по таймеру).
#
# Payload — с обоими полями. z2m 1.x требует `value` и без него отвечает «Invalid payload»
# (поймано 23.09.2026 на хабе с 1.42: окно не открылось, скрипт отчитался «сеть открыта»);
# 2.x читает `time` и лишнее `value` не мешает. Закрытие — `time: 0` по той же причине,
# только наоборот: 2.x без `time` отвергает запрос.
. "$(dirname "$0")/lib/common.sh"
load_env

mode="${1:?использование: permit-join.sh on [time_sec] | off}"
time_sec="${2:-254}"

case "$mode" in
    on)  payload="{\"value\": true, \"time\": $time_sec}" ;;
    off) payload='{"value": false, "time": 0}' ;;
    *) die "неизвестный режим: $mode (on|off)" ;;
esac

compose exec -T mqtt mosquitto_pub -h localhost \
    -u "$LOCAL_MQTT_USER" -P "$LOCAL_MQTT_PASSWORD" \
    -t "${Z2M_BASE_TOPIC}/bridge/request/permit_join" -m "$payload"

if [ "$mode" = "on" ]; then
    ok "сеть открыта на ${time_sec}с — переведите устройство в режим сопряжения"
else
    ok "сеть закрыта"
fi
