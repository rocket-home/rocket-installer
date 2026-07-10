#!/usr/bin/env bash
# Общие функции для всех скриптов rocket-installer.
# Подключение:  . "$(dirname "$0")/lib/common.sh"  (из scripts/*)
set -euo pipefail

ROCKET_ROOT="${ROCKET_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)}"
ENV_FILE="${ENV_FILE:-$ROCKET_ROOT/.env}"
COMPOSE_FILE="$ROCKET_ROOT/deploy/docker-compose.yml"
# используются скриптами, подключающими этот файл
# shellcheck disable=SC2034
MATRIX_FILE="$ROCKET_ROOT/config/compatibility-matrix.json"
# shellcheck disable=SC2034
SECRETS_DIR="$ROCKET_ROOT/secrets"
# shellcheck disable=SC2034
DATA_DIR="$ROCKET_ROOT/data"

# Цветной вывод только в TTY
if [ -t 1 ]; then
    _C_RED=$'\033[31m'; _C_GRN=$'\033[32m'; _C_YEL=$'\033[33m'; _C_OFF=$'\033[0m'
else
    _C_RED=""; _C_GRN=""; _C_YEL=""; _C_OFF=""
fi

log()  { printf '%s\n' "$*"; }
ok()   { printf '%s✔%s %s\n' "$_C_GRN" "$_C_OFF" "$*"; }
warn() { printf '%s!%s %s\n' "$_C_YEL" "$_C_OFF" "$*" >&2; }
err()  { printf '%s✘%s %s\n' "$_C_RED" "$_C_OFF" "$*" >&2; }
die()  { err "$*"; exit 1; }

require_cmd() {
    command -v "$1" >/dev/null 2>&1 || die "не найдена команда '$1' — запустите: make check-tools"
}

# Бэкап файла перед перезаписью: file → file.bak-YYYYmmdd-HHMMSS
backup_file() {
    local f="$1"
    [ -f "$f" ] || return 0
    cp -p "$f" "$f.bak-$(date +%Y%m%d-%H%M%S)"
}

# docker compose с нашим env-файлом и compose-файлом.
# COMPOSE_PROFILES приходит из .env (load_env) — управляет nodered.
compose() {
    require_cmd docker
    docker compose --env-file "$ENV_FILE" -f "$COMPOSE_FILE" "$@"
}

# Загрузить .env в окружение текущего скрипта (без экспорта секретов дальше по цепочке).
load_env() {
    [ -f "$ENV_FILE" ] || die ".env не найден ($ENV_FILE) — запустите: make env-init"
    set -a
    # shellcheck disable=SC1090
    . "$ENV_FILE"
    set +a
}

# Значение одного ключа из .env (пусто, если ключа нет).
env_get() {
    local key="$1"
    [ -f "$ENV_FILE" ] || return 0
    sed -n "s/^${key}=//p" "$ENV_FILE" | tail -1
}
