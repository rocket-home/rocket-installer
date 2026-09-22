#!/usr/bin/env bash
# load_env читает .env в переменные скрипта и НЕ экспортирует их дальше.
#
# Регрессия дорогая и невидимая: экспортированное значение перебивает --env-file у docker
# compose, и make update поднимал СТАРЫЙ образ, записав в .env новый тег (прогон 21.09.2026).
# Второе требование — читать файл буквально: сорсинг выполнял бы `KEY=два слова` как команду
# и раскрывал `$`, то есть скрипт и контейнер видели бы разные значения.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

export ROCKET_ROOT="$tmp" ENV_FILE="$tmp/.env"
cat >"$ENV_FILE" <<'EOF'
# комментарий и пустая строка ниже игнорируются

Z2M_IMAGE_TAG=1.42.0
WITH_SPACES=a b c
WITH_DOLLAR=pa$$w0rd`echo hacked`
QUOTED="x y"
SINGLE='z'
не_ключ=пропустить
EOF

# shellcheck disable=SC1091
. "$ROOT/scripts/lib/common.sh"
load_env

[ "$Z2M_IMAGE_TAG" = "1.42.0" ] || { echo "FAIL: тег не прочитан: '$Z2M_IMAGE_TAG'"; exit 1; }
[ "$WITH_SPACES" = "a b c" ] || { echo "FAIL: пробелы: '$WITH_SPACES'"; exit 1; }
[ "$WITH_DOLLAR" = 'pa$$w0rd`echo hacked`' ] || { echo "FAIL: значение раскрыто как код: '$WITH_DOLLAR'"; exit 1; }
[ "$QUOTED" = "x y" ] || { echo "FAIL: кавычки не сняты: '$QUOTED'"; exit 1; }
[ "$SINGLE" = "z" ] || { echo "FAIL: одинарные кавычки: '$SINGLE'"; exit 1; }

# ГЛАВНОЕ: дочерний процесс переменную видеть не должен — иначе она перебьёт --env-file
seen="$(bash -c 'echo "${Z2M_IMAGE_TAG-UNSET}"')"
[ "$seen" = "UNSET" ] || { echo "FAIL: значение утекло в окружение дочернего процесса: '$seen'"; exit 1; }

# отсутствующий .env — внятный отказ с подсказкой
rm -f "$ENV_FILE"
# die внутри подстановки завершает субшелл через exit, поэтому `|| true` ставим снаружи
out="$( (load_env) 2>&1 )" || true
case "$out" in *env-init*) ;; *) echo "FAIL: нет подсказки make env-init: $out"; exit 1 ;; esac

echo "ok"
