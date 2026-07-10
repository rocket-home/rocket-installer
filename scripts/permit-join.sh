#!/usr/bin/env bash
# Открыть/закрыть zigbee-сеть для подключения новых устройств.
# Использование: permit-join.sh on [time_sec] | off
# Через MQTT-запрос к z2m (runtime, конфиг не трогаем; z2m сам закроет сеть по таймеру).
. "$(dirname "$0")/lib/common.sh"
load_env

mode="${1:?использование: permit-join.sh on [time_sec] | off}"
time_sec="${2:-254}"

case "$mode" in
    on)  payload="{\"time\": $time_sec}" ;;
    off) payload='{"time": 0}' ;;
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
