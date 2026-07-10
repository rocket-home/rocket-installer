#!/bin/sh
# Вход контейнера mqtt. Готовит password-файл и права, затем:
#   CLOUD_AUTH_MODE=oauth  → exec token-agent.sh (супервизор: сам держит mosquitto
#                            дочерним процессом и ротирует MQTT-JWT в bridge.conf);
#   иначе (static/off)     → exec mosquitto напрямую (мост — статический conf.d).
set -e

# conf.d может быть read-only; страхуемся от чужого listener.conf
rm -f /mosquitto/conf.d/listener.conf 2>/dev/null || true

# password_file прописан в mosquitto.conf всегда — файл обязан существовать,
# иначе брокер не стартует даже при allow_anonymous. conf.d обычно bind ro,
# но без маунта include_dir на несуществующий каталог валит брокер.
mkdir -p /mosquitto/etc /mosquitto/dynamic /mosquitto/conf.d 2>/dev/null || true
touch /mosquitto/etc/password
chown root:root /mosquitto/etc/password 2>/dev/null || true
chmod 600 /mosquitto/etc/password

if [ -n "${MQTT_USER:-}" ] && [ -n "${MQTT_PASSWORD:-}" ]; then
    if [ ! -s /mosquitto/etc/password ]; then
        mosquitto_passwd -c -b /mosquitto/etc/password "$MQTT_USER" "$MQTT_PASSWORD"
    else
        mosquitto_passwd -b /mosquitto/etc/password "$MQTT_USER" "$MQTT_PASSWORD"
    fi
    chown root:root /mosquitto/etc/password 2>/dev/null || true
    chmod 600 /mosquitto/etc/password
else
    echo "MQTT_USER/MQTT_PASSWORD не заданы — локальный пользователь не создан" >&2
fi

# НЕ вызываем upstream /docker-entrypoint.sh: он делает chown -R /mosquitto и
# падает на read-only conf.d. Правим права только на writable-каталогах.
if [ "$(id -u)" = "0" ]; then
    for d in /mosquitto/data /mosquitto/etc /mosquitto/log; do
        [ -d "$d" ] && chown -R mosquitto:mosquitto "$d" 2>/dev/null || true
    done
fi

if [ "${CLOUD_AUTH_MODE:-}" = "oauth" ]; then
    exec /token-agent.sh "$@"
fi

# static/off: динамический bridge.conf от прошлого oauth-режима не должен остаться
rm -f /mosquitto/dynamic/bridge.conf
exec "$@"
