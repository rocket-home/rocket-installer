#!/usr/bin/env bash
# Бэкап состояния: data/ (включая сеть z2m и её ключи) + secrets/ + .env.
# zigbee2mqtt останавливается на время tar (консистентность database.db) и
# запускается обратно. Результат: backups/rocket-backup-<ts>.tar.gz (0600).
. "$(dirname "$0")/lib/common.sh"
load_env

BACKUP_DIR="${BACKUP_DIR:-$ROCKET_ROOT/backups}"
mkdir -p "$BACKUP_DIR"
archive="$BACKUP_DIR/rocket-backup-$(date +%Y%m%d-%H%M%S).tar.gz"

z2m_running=""
if [ -n "$(compose ps -q zigbee2mqtt 2>/dev/null)" ]; then
    z2m_running=1
    log "останавливаю zigbee2mqtt на время бэкапа…"
    compose stop zigbee2mqtt >/dev/null
fi
restore_z2m() { [ -n "$z2m_running" ] && compose start zigbee2mqtt >/dev/null 2>&1 || true; }
trap restore_z2m EXIT

umask 077
tar -C "$ROCKET_ROOT" -czf "$archive" \
    --exclude='data/mosquitto/agent-status.json' \
    data secrets .env
ok "бэкап: $archive ($(du -h "$archive" | cut -f1))"
