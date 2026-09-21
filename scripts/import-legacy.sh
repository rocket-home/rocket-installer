#!/usr/bin/env bash
# Импорт живого хаба со старого стека (питоновский z2m-менеджер) в rocket-installer.
#
# Переносит ВСЁ состояние zigbee2mqtt: database.db (сеть), coordinator_backup.json
# (network_key/pan_id/tclk_seed), state.json, extension/ (локальный движок автоматизаций)
# и configuration.yaml — и правит в конфиге ровно то, что обязано поменяться на новом стеке.
#
#   make import-legacy                        # из контейнера z2m-zigbee2mqtt-1
#   make import-legacy LEGACY_DIR=/path/data  # из распакованного бэкапа
#
# ВАЖНО: старый z2m должен быть ОСТАНОВЛЕН — иначе database.db и state.json расходятся
# с тем, что уже произошло в сети (одноразовые вхождения автоматизаций могут повториться).
. "$(dirname "$0")/lib/common.sh"
load_env

LEGACY_CONTAINER="${LEGACY_CONTAINER:-z2m-zigbee2mqtt-1}"
LEGACY_DIR="${LEGACY_DIR:-}"
dest="$DATA_DIR/zigbee2mqtt"

running() { docker ps --format '{{.Names}}' 2>/dev/null | grep -qx "$LEGACY_CONTAINER"; }

if [ -z "$LEGACY_DIR" ]; then
    require_cmd docker
    docker ps -a --format '{{.Names}}' | grep -qx "$LEGACY_CONTAINER" \
        || die "контейнер $LEGACY_CONTAINER не найден — укажите LEGACY_DIR=<путь к /app/data>"
    if running; then
        warn "$LEGACY_CONTAINER ещё работает: database.db и state.json расширения будут сняты «на ходу»."
        warn "Остановите его (docker stop $LEGACY_CONTAINER) и повторите, либо подтвердите: CONFIRM=1"
        [ "${CONFIRM:-}" = "1" ] || exit 1
    fi
fi

if [ -d "$dest" ] && [ -n "$(ls -A "$dest" 2>/dev/null)" ]; then
    bk="$dest.bak-$(date +%Y%m%d-%H%M%S)"
    mv "$dest" "$bk"
    warn "прежнее содержимое data/zigbee2mqtt отложено в $(basename "$bk")"
fi
mkdir -p "$dest"

if [ -n "$LEGACY_DIR" ]; then
    [ -d "$LEGACY_DIR" ] || die "нет каталога: $LEGACY_DIR"
    cp -a "$LEGACY_DIR/." "$dest/"
    log "данные скопированы из $LEGACY_DIR"
else
    docker cp "$LEGACY_CONTAINER:/app/data/." "$dest/" >/dev/null
    log "данные скопированы из контейнера $LEGACY_CONTAINER"
    # docker cp для bind-mount'а отдаёт файл ИСТОЧНИКА на хосте, а не то, что видит
    # процесс в контейнере: если хостовой файл подменяли, конфиг окажется устаревшим
    # (у нас так и было — потерялся бы retain, дописанный z2m). Живой снимаем через exec.
    if running; then
        if docker exec "$LEGACY_CONTAINER" cat /app/data/configuration.yaml >"$dest/configuration.yaml.live" 2>/dev/null; then
            if ! cmp -s "$dest/configuration.yaml" "$dest/configuration.yaml.live"; then
                warn "конфиг в контейнере отличается от хостового — беру версию из контейнера"
                mv "$dest/configuration.yaml.live" "$dest/configuration.yaml"
            else
                rm -f "$dest/configuration.yaml.live"
            fi
        else
            rm -f "$dest/configuration.yaml.live"
        fi
    fi
fi

conf="$dest/configuration.yaml"
[ -f "$conf" ] || die "в перенесённых данных нет configuration.yaml"
cp -p "$conf" "$conf.imported-$(date +%Y%m%d-%H%M%S)"

# Правки, без которых стек установщика не поднимется:
#   serial.port — внутри контейнера путь всегда /dev/zigbee (compose мапит хостовой узел);
#   mqtt.user/password — брокер установщика заводит ОДНОГО пользователя и запрещает анонимов,
#     со старыми кредами z2m получит CONNACK 5 и не опубликует ни одного устройства;
#   permit_join — сеть не должна остаться открытой навсегда (открывают через make permit-join-on).
ROCKET_MQTT_USER="$LOCAL_MQTT_USER" ROCKET_MQTT_PASS="$LOCAL_MQTT_PASSWORD" awk '
    BEGIN { u = ENVIRON["ROCKET_MQTT_USER"]; p = ENVIRON["ROCKET_MQTT_PASS"] }
    /^[A-Za-z_]/ { sect = $0; sub(/:.*/, "", sect) }
    sect == "serial" && /^  port:/ { print "  port: /dev/zigbee"; next }
    sect == "mqtt"   && /^  user:/     { print "  user: " u; next }
    sect == "mqtt"   && /^  password:/ { print "  password: \x27" p "\x27"; next }
    /^permit_join:[[:space:]]*true/ { print "permit_join: false"; pj = 1; next }
    { print }
    END { if (pj) print "# permit_join выключен при импорте (открывать: make permit-join-on)" > "/dev/stderr" }
' "$conf" >"$conf.tmp" && mv "$conf.tmp" "$conf"

# Владелец: в volume старого стека файлы под root, контейнеры установщика ходят под ним же,
# но хостовые скрипты (status/doctor/бэкап) читают каталог под обычным пользователем.
if [ "$(id -u)" != "0" ] && [ -w "$(dirname "$dest")" ]; then
    chown -R "$(id -u):$(id -g)" "$dest" 2>/dev/null || sudo -n chown -R "$(id -u):$(id -g)" "$dest" 2>/dev/null || \
        warn "не удалось сменить владельца $dest — сделайте вручную: sudo chown -R $(id -u):$(id -g) $dest"
fi

devices="$(awk '/^devices:/{f=1} f && /friendly_name/{n++} END{print n+0}' "$conf")"
retains="$(awk '/^devices:/{f=1} f && /retain:/{n++} END{print n+0}' "$conf")"
ok "импортировано: устройств $devices, явных retain $retains"
if [ -f "$dest/database.db" ]; then
    ok "database.db перенесён ($(wc -c <"$dest/database.db") б)"
else
    warn "database.db не найден — сеть Zigbee не переедет!"
fi
if [ -f "$dest/coordinator_backup.json" ]; then
    ok "coordinator_backup.json перенесён (ключи сети)"
else
    warn "coordinator_backup.json не найден — восстановление сети при замене стика будет невозможно"
fi
if [ -d "$dest/extension" ]; then
    ok "extension/ перенесён ($(find "$dest/extension" -type f | wc -l) файлов)"
fi
log "Дальше: make up  (старый стек должен быть остановлен — порты и стик заняты)"
