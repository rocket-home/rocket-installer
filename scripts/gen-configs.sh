#!/usr/bin/env bash
# Рендер конфигов из templates/ (envsubst с ЯВНЫМ списком переменных — чтобы не
# затронуть $SYS и прочие «чужие» доллары). Все перезаписи — с бэкапом .bak-<ts>.
#
#   data/zigbee2mqtt/configuration.yaml — только если нет (файлом владеет z2m,
#       там живут devices/permit_join/сетевые ключи); FORCE=1 — перегенерация с бэкапом;
#   deploy/mosquitto/conf.d/bridge.conf — static-режим; в oauth-режиме удаляется
#       (динамический bridge.conf пишет token-agent внутри контейнера).
. "$(dirname "$0")/lib/common.sh"
. "$(dirname "$0")/lib/yaml-preserve.sh"
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
    prev=""
    if [ -f "$z2m_conf" ]; then
        prev="$(mktemp)"
        cp "$z2m_conf" "$prev"
    fi
    # Схема конфига зависит от МАЖОРНОЙ версии образа: у 2.x есть `version: 4`,
    # `homeassistant.enabled`, `frontend.enabled`; 1.x на них падает валидацией.
    # Матрица совместимости до сих пор держит legacy-ветки на 1.x (старые прошивки,
    # CC2531), поэтому шаблон выбирается, а не предполагается.
    z2m_major="$(printf '%s' "${Z2M_IMAGE_TAG:-}" | sed -n 's/^\([0-9]\{1,\}\)\..*/\1/p')"
    if [ "${z2m_major:-2}" -lt 2 ] 2>/dev/null; then
        z2m_tmpl="$ROCKET_ROOT/templates/zigbee2mqtt.v1.yaml.tmpl"
    else
        z2m_tmpl="$ROCKET_ROOT/templates/zigbee2mqtt.yaml.tmpl"
    fi
    # envsubst — дочерний процесс: переменные передаём ему ЯВНО, потому что load_env больше
    # не экспортирует .env в окружение (см. комментарий к load_env). Список в префиксе обязан
    # совпадать со списком в аргументе envsubst.
    # shellcheck disable=SC2016
    Z2M_BASE_TOPIC="${Z2M_BASE_TOPIC:-}" LOCAL_MQTT_USER="${LOCAL_MQTT_USER:-}" \
    LOCAL_MQTT_PASSWORD="${LOCAL_MQTT_PASSWORD:-}" Z2M_FRONTEND_PORT="${Z2M_FRONTEND_PORT:-}" \
    Z2M_FRONTEND_AUTH_TOKEN="${Z2M_FRONTEND_AUTH_TOKEN:-}" \
    envsubst '$Z2M_BASE_TOPIC $LOCAL_MQTT_USER $LOCAL_MQTT_PASSWORD $Z2M_FRONTEND_PORT $Z2M_FRONTEND_AUTH_TOKEN' \
        <"$z2m_tmpl" >"$z2m_conf"
    # serial.adapter добавляем только когда семейство известно (пусто = автодетект z2m)
    if [ -n "${Z2M_ADAPTER:-}" ]; then
        sed -i "/^  port: \/dev\/zigbee$/a\\  adapter: ${Z2M_ADAPTER}" "$z2m_conf"
    fi
    if [ -n "$prev" ]; then
        # Переносим то, чем владеет z2m: устройства, группы, permit_join и сетевые
        # параметры внутри advanced. Без этого FORCE=1 стирает сеть целиком.
        sed -i '/^devices: {}$/d' "$z2m_conf"
        preserve_network_identity "$prev" "$z2m_conf"
        preserve_advanced_subkeys "$prev" "$z2m_conf"
        preserve_top_level_blocks "$prev" "$z2m_conf"
        kept="$(awk '/^devices:/{f=1} f&&/friendly_name/{n++} END{print n+0}' "$z2m_conf")"
        ok "zigbee2mqtt: configuration.yaml перегенерирован (перенесено устройств: $kept)"
        rm -f "$prev"
    else
        ok "zigbee2mqtt: configuration.yaml сгенерирован"
    fi
fi

# ── мост mosquitto ─────────────────────────────────────────────────────────────
bridge_conf="$ROCKET_ROOT/deploy/mosquitto/conf.d/bridge.conf"
case "${CLOUD_AUTH_MODE:-oauth}" in
    static)
        [ -n "${CLOUD_MQTT_USERNAME:-}" ] && [ -n "${CLOUD_MQTT_PASSWORD:-}" ] \
            || die "static-режим: заполните CLOUD_MQTT_USERNAME/CLOUD_MQTT_PASSWORD (rocket-home.ru/profile/mqtt)"
        backup_file "$bridge_conf"
        # Явный экспорт для дочернего envsubst — см. комментарий у первого вызова выше.
        # shellcheck disable=SC2016
        CLOUD_MQTT_HOST="${CLOUD_MQTT_HOST:-}" CLOUD_MQTT_PORT="${CLOUD_MQTT_PORT:-}" \
        CLOUD_BRIDGE_PROTOCOL="${CLOUD_BRIDGE_PROTOCOL:-}" \
        CLOUD_MQTT_USERNAME="${CLOUD_MQTT_USERNAME:-}" CLOUD_MQTT_PASSWORD="${CLOUD_MQTT_PASSWORD:-}" \
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
