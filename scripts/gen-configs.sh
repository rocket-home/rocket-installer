#!/usr/bin/env bash
# Рендер конфигов из templates/ (envsubst с ЯВНЫМ списком переменных — чтобы не
# затронуть $SYS и прочие «чужие» доллары). Все перезаписи — с бэкапом .bak-<ts>.
#
#   data/zigbee2mqtt/configuration.yaml — только если нет (файлом владеет z2m,
#       там живут devices/permit_join/сетевые ключи); FORCE=1 — перегенерация с бэкапом;
#   deploy/mosquitto/conf.d/bridge.conf — static-режим; в oauth-режиме удаляется
#       (динамический bridge.conf пишет token-agent внутри контейнера).
. "$(dirname "$0")/lib/common.sh"
require_cmd envsubst
load_env

FORCE="${FORCE:-0}"

# ── zigbee2mqtt ────────────────────────────────────────────────────────────────
z2m_conf="$DATA_DIR/zigbee2mqtt/configuration.yaml"
mkdir -p "$(dirname "$z2m_conf")"
if [ -f "$z2m_conf" ] && [ "$FORCE" != "1" ]; then
    log "zigbee2mqtt: configuration.yaml уже существует — не трогаю (FORCE=1 для перегенерации)"
else
    [ -n "${LOCAL_MQTT_PASSWORD:-}" ] || die "LOCAL_MQTT_PASSWORD пуст — запустите: make env-init"
    [ -n "${Z2M_FRONTEND_AUTH_TOKEN:-}" ] || die "Z2M_FRONTEND_AUTH_TOKEN пуст — запустите: make env-init"
    backup_file "$z2m_conf"
    # shellcheck disable=SC2016
    envsubst '$Z2M_BASE_TOPIC $LOCAL_MQTT_USER $LOCAL_MQTT_PASSWORD $Z2M_FRONTEND_PORT $Z2M_FRONTEND_AUTH_TOKEN' \
        <"$ROCKET_ROOT/templates/zigbee2mqtt.yaml.tmpl" >"$z2m_conf"
    # serial.adapter добавляем только когда семейство известно (пусто = автодетект z2m)
    if [ -n "${Z2M_ADAPTER:-}" ]; then
        sed -i "/^  port: \/dev\/zigbee$/a\\  adapter: ${Z2M_ADAPTER}" "$z2m_conf"
    fi
    ok "zigbee2mqtt: configuration.yaml сгенерирован"
fi

# ── мост mosquitto ─────────────────────────────────────────────────────────────
bridge_conf="$ROCKET_ROOT/deploy/mosquitto/conf.d/bridge.conf"
case "${CLOUD_AUTH_MODE:-oauth}" in
    static)
        [ -n "${CLOUD_MQTT_USERNAME:-}" ] && [ -n "${CLOUD_MQTT_PASSWORD:-}" ] \
            || die "static-режим: заполните CLOUD_MQTT_USERNAME/CLOUD_MQTT_PASSWORD (rocket-home.ru/profile/mqtt)"
        backup_file "$bridge_conf"
        # shellcheck disable=SC2016
        envsubst '$CLOUD_MQTT_HOST $CLOUD_MQTT_PORT $CLOUD_BRIDGE_PROTOCOL $CLOUD_MQTT_USERNAME $CLOUD_MQTT_PASSWORD' \
            <"$ROCKET_ROOT/templates/bridge-static.conf.tmpl" >"$bridge_conf"
        chmod 600 "$bridge_conf"
        ok "мост: static bridge.conf сгенерирован"
        ;;
    oauth)
        if [ -f "$bridge_conf" ]; then
            backup_file "$bridge_conf"
            rm -f "$bridge_conf"
            log "мост: static bridge.conf удалён (oauth-режим — конфиг ведёт token-agent)"
        fi
        [ -s "$SECRETS_DIR/tokens.json" ] || warn "oauth-режим: нет secrets/tokens.json — выполните: make oauth-link"
        ok "мост: oauth-режим (динамический конфиг внутри контейнера)"
        ;;
    off)
        if [ -f "$bridge_conf" ]; then backup_file "$bridge_conf"; rm -f "$bridge_conf"; fi
        log "мост: выключен (CLOUD_AUTH_MODE=off)"
        ;;
    *) die "неизвестный CLOUD_AUTH_MODE=${CLOUD_AUTH_MODE} (oauth|static|off)" ;;
esac

log "Применение: make up  (пересоздаёт контейнеры)"
