#!/usr/bin/env bash
# Восстановление из бэкапа (make restore ARCHIVE=...). Останавливает стек,
# раскладывает data/ + secrets/ + .env, текущее состояние предварительно
# сохраняется в отдельный pre-restore архив. Подтверждение: CONFIRM=1.
. "$(dirname "$0")/lib/common.sh"

archive="${1:?использование: restore.sh <archive.tar.gz>}"
[ -f "$archive" ] || die "архив не найден: $archive"
tar -tzf "$archive" >/dev/null 2>&1 || die "архив повреждён или не tar.gz: $archive"

if [ "${CONFIRM:-}" != "1" ]; then
    warn "Восстановление ПЕРЕЗАПИШЕТ data/, secrets/ и .env содержимым архива:"
    warn "  $archive"
    die  "подтверждение: make restore ARCHIVE=... CONFIRM=1"
fi

log "останавливаю стек…"
compose down >/dev/null 2>&1 || true

pre="$ROCKET_ROOT/backups/pre-restore-$(date +%Y%m%d-%H%M%S).tar.gz"
mkdir -p "$ROCKET_ROOT/backups"
umask 077
tar -C "$ROCKET_ROOT" -czf "$pre" data secrets .env 2>/dev/null || true
log "текущее состояние сохранено: $pre"

tar -C "$ROCKET_ROOT" -xzf "$archive"
chmod 600 "$ENV_FILE" 2>/dev/null || true
chmod 700 "$SECRETS_DIR" 2>/dev/null || true
ok "восстановлено из $archive"
log "запуск: make up && make smoke"
