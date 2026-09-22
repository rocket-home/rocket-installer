#!/usr/bin/env bash
# Сквозная проверка после установки/обновления:
#   1) локальный брокер отвечает под LOCAL_MQTT_USER (pub/sub);
#   2) мост в облако подключён ($SYS/broker/connection/rocket/state == 1, ждём до 90с);
#   3) фронт zigbee2mqtt отвечает по HTTP.
# Exit 1 при любом провале.
. "$(dirname "$0")/lib/common.sh"
load_env

fail=0

log "1/3 локальный брокер…"
if compose exec -T mqtt mosquitto_pub -h localhost -u "$LOCAL_MQTT_USER" -P "$LOCAL_MQTT_PASSWORD" \
    -t rocket-installer/smoke -m "ping-$$" 2>/dev/null \
   && [ -n "$(compose exec -T mqtt mosquitto_sub -h localhost -u "$LOCAL_MQTT_USER" -P "$LOCAL_MQTT_PASSWORD" \
        -t '$SYS/broker/version' -C 1 -W 5 2>/dev/null)" ]; then
    ok "локальный pub/sub работает"
else
    err "локальный брокер не отвечает (docker compose logs mqtt)"
    fail=1
fi

if [ "${CLOUD_AUTH_MODE}" != "off" ]; then
    log "2/3 мост в облако (${CLOUD_MQTT_HOST}:${CLOUD_MQTT_PORT})… ждём до 90с"
    state=""
    for _ in $(seq 1 18); do
        state="$(compose exec -T mqtt mosquitto_sub -h localhost -u "$LOCAL_MQTT_USER" -P "$LOCAL_MQTT_PASSWORD" \
            -t '$SYS/broker/connection/rocket/state' -C 1 -W 3 2>/dev/null || true)"
        [ "$state" = "1" ] && break
        sleep 5
    done
    if [ "$state" = "1" ]; then
        ok "мост подключён к облаку"
    else
        err "мост не подключился (state='${state:-нет данных}')."
        if [ "${CLOUD_AUTH_MODE}" = "oauth" ]; then
            err "  подсказка: make status (agent-status), make relink; логи: make logs SERVICE=mqtt"
        else
            err "  подсказка: проверьте CLOUD_MQTT_USERNAME/PASSWORD (rocket-home.ru/profile/mqtt); логи: make logs SERVICE=mqtt"
        fi
        fail=1
    fi
else
    log "2/3 мост выключен (CLOUD_AUTH_MODE=off) — пропуск"
fi

if ! zigbee_enabled; then
    log "3/3 zigbee2mqtt на этом узле не предусмотрен (стик не задан) — пропуск"
else
    z2m_timeout="${SMOKE_Z2M_TIMEOUT:-180}"
    log "3/3 zigbee2mqtt… ждём готовности контейнера (до ${z2m_timeout}с)"
    rc=0
    wait_healthy zigbee2mqtt "$z2m_timeout" || rc=$?
    case "$rc" in
        0)
            # healthcheck живёт ВНУТРИ контейнера (127.0.0.1) и ничего не знает о пробросе
            # порта на хост — один честный запрос снаружи всё равно делаем.
            if curl -fsS -m 10 --retry 3 --retry-delay 2 -o /dev/null "http://localhost:${Z2M_FRONTEND_PORT}/"; then
                ok "фронт отвечает: http://<ip-машины>:${Z2M_FRONTEND_PORT}/ (токен: см. make status)"
            else
                err "контейнер z2m здоров, но порт ${Z2M_FRONTEND_PORT} не отвечает с хоста (проброс портов / файрвол)"
                fail=1
            fi
            ;;
        2)
            err "контейнер z2m упал или перезапускается: make logs SERVICE=zigbee2mqtt"
            err "  частые причины: стик занят или недоступен, неверный serial.adapter (make update)"
            fail=1
            ;;
        *)
            err "z2m не стал healthy за ${z2m_timeout}с: make logs SERVICE=zigbee2mqtt"
            fail=1
            ;;
    esac
fi

if [ "$fail" -eq 0 ]; then
    ok "Smoke: всё зелёное. Устройства, добавленные в z2m, появятся в rocket-home.ru."
else
    die "Smoke: есть проблемы (см. выше)."
fi
