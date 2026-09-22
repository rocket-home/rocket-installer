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
# Профили считает compose_profiles(): аддоны из .env плюс zigbee по наличию стика.
#
# Имя проекта задаём ЯВНО. Без -p compose берёт basename каталога compose-файла, то есть
# "deploy" для ЛЮБОЙ копии репо: вторая копия (тестовая, распакованный бэкап, ворктри)
# молча делит с боевой контейнеры, сеть и volume mosquitto_dynamic — а в нём лежит
# bridge.conf с чужим токеном, с которым агент сознательно стартует при недоступном облаке.
COMPOSE_PROJECT="${COMPOSE_PROJECT_NAME:-rocket-home}"

# Есть ли у этого узла zigbee-стик. Источник правды — .env плюс файловая система, а не
# отдельный флаг: флаг разъехался бы с реальностью, а новый ключ в .env потребовал бы
# миграции всех установленных хабов (там COMPOSE_PROFILES уже занят аддонами).
zigbee_enabled() {
    local dev
    dev="$(env_get ZIGBEE_DEVICE_HOST)"
    [ -n "$dev" ] && [ -c "$dev" ]
}

# Активные профили compose = аддоны из .env (nodered) + вычисленный zigbee.
# Передаём окружением осознанно: это единственная переменная, которую мы ставим выше
# --env-file, и ставим потому, что ВЫЧИСЛЯЕМ её, а не читаем.
compose_profiles() {
    local p
    p="$(env_get COMPOSE_PROFILES)"
    if zigbee_enabled; then
        p="${p:+$p,}zigbee"
    fi
    printf '%s' "$p"
}

compose() {
    require_cmd docker
    COMPOSE_PROFILES="$(compose_profiles)" \
        docker compose -p "$COMPOSE_PROJECT" --env-file "$ENV_FILE" -f "$COMPOSE_FILE" "$@"
}

# Ждать готовности сервиса по healthcheck контейнера.
#
# ПОЧЕМУ НЕ `curl --retry`. Сколько секунд поднимается z2m после пересоздания, знает только он
# сам: инициализация координатора у ember занимает больше, чем любое разумное число ретраев.
# Прогон 21.09.2026: smoke краснел на полностью исправном хабе, визард печатал «Установка не
# завершена», а тот же make smoke минутой позже был зелёным. У сервиса в compose описан
# healthcheck со start_period 40s — спрашиваем docker, а не гадаем.
# Коды: 0 — здоров, 1 — не дождались, 2 — контейнер умер или крутится в перезапусках.
wait_healthy() {
    local svc="$1" timeout="${2:-180}" deadline cid state
    deadline=$(( $(date +%s) + timeout ))
    while :; do
        cid="$(compose ps -q "$svc" 2>/dev/null | head -1)"
        if [ -n "$cid" ]; then
            state="$(docker inspect -f \
                '{{.State.Status}}:{{if .State.Health}}{{.State.Health.Status}}{{end}}:{{.RestartCount}}' \
                "$cid" 2>/dev/null || true)"
            case "$state" in
                running:healthy:*) return 0 ;;
                running::*)        return 0 ;;   # healthcheck не описан — раз running, ждать нечего
                exited:*|dead:*)   return 2 ;;
                restarting:*:[3-9]*|restarting:*:[1-9][0-9]*) return 2 ;;  # крэш-луп
            esac
        fi
        [ "$(date +%s)" -lt "$deadline" ] || return 1
        sleep "${ROCKET_HEALTH_POLL:-3}"
    done
}

# Загрузить .env в переменные ТЕКУЩЕГО скрипта — намеренно БЕЗ export.
#
# ПОЧЕМУ БЕЗ ЭКСПОРТА. docker compose ставит переменные ОКРУЖЕНИЯ выше --env-file. Пока
# load_env экспортировал всё (set -a), любой скрипт «замораживал» .env в момент своего старта:
# make update писал новый Z2M_IMAGE_TAG в файл и тут же поднимал СТАРЫЙ тег из собственного
# окружения (прогон 21.09.2026: в .env уже 2.6.0, а контейнер из 1.42.0; отдельный make up
# следом поднимал верный). Кому переменная нужна в дочернем процессе — экспортирует её ЯВНО
# и точечно (envsubst в gen-configs.sh), чтобы экспорт был виден там, где он что-то значит.
#
# ПОЧЕМУ НЕ СОРСИНГ. `. "$ENV_FILE"` — третья интерпретация файла: compose и TUI
# (rocket-control/lib/env.mjs) читают .env буквально, а bash выполняет его как код —
# `KEY=два слова` запускает команду `слова`, `$`, кавычки и backticks раскрываются. Значение
# в контейнере и значение в скрипте расходились бы молча. Читаем так же буквально, как все.
load_env() {
    [ -f "$ENV_FILE" ] || die ".env не найден ($ENV_FILE) — запустите: make env-init"
    local line key value
    while IFS= read -r line || [ -n "$line" ]; do
        case "$line" in ''|'#'*) continue ;; esac
        case "$line" in *=*) ;; *) continue ;; esac
        key="${line%%=*}"
        value="${line#*=}"
        case "$key" in
            [A-Za-z_]*) ;;
            *) continue ;;
        esac
        [[ "$key" =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]] || continue
        # Окружающие кавычки снимаем — ровно так же, как парсер env-file у compose
        case "$value" in
            \"*\") value="${value:1:${#value}-2}" ;;
            \'*\') value="${value:1:${#value}-2}" ;;
        esac
        printf -v "$key" '%s' "$value" 2>/dev/null \
            || warn ".env: ключ $key пропущен (readonly)"
    done <"$ENV_FILE"
}

# Значение одного ключа из .env (пусто, если ключа нет).
env_get() {
    local key="$1"
    [ -f "$ENV_FILE" ] || return 0
    sed -n "s/^${key}=//p" "$ENV_FILE" | tail -1
}
