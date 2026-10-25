#!/usr/bin/env bash
# install.sh отказывает, если Docker стоит из snap, — до любых действий.
#
# Регрессия: snap-docker отвечает на `docker compose version`, установщик считал Docker
# готовым, а стек не поднимался: песочница snap не даёт монтировать /opt/rocket-home
# («read-only file system»). Найдено живым прогоном на Armbian (NanoPi NEO Core2).
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

stub() { printf '#!/bin/sh\n%s\n' "$2" >"$tmp/$1"; chmod +x "$tmp/$1"; }
stub dpkg 'echo arm64'
# apt-get не должен быть вызван: гард стоит раньше установки пакетов
stub apt-get "touch '$tmp/apt-called'; exit 1"
stub sudo 'exec "$@"'

# snap знает пакет docker → отказ с объяснением и командой удаления
stub snap '[ "$1 $2" = "list docker" ] && exit 0; exit 1'
if out="$(PATH="$tmp:$PATH" bash "$ROOT/install.sh" --headless 2>&1)"; then
    echo "FAIL: snap-docker прошёл проверку"; exit 1
fi
echo "$out" | grep -q "Docker установлен из snap" \
    || { echo "FAIL: нет внятного отказа: $out"; exit 1; }
echo "$out" | grep -q "snap remove --purge docker" \
    || { echo "FAIL: отказ не предлагает следующий шаг: $out"; exit 1; }
[ ! -e "$tmp/apt-called" ] || { echo "FAIL: до отказа уже ставились пакеты"; exit 1; }

# snap есть, но docker в нём нет → гард молчит, установка идёт дальше (до apt-get)
stub snap 'exit 1'
PATH="$tmp:$PATH" bash "$ROOT/install.sh" --headless >/dev/null 2>&1 || true
[ -e "$tmp/apt-called" ] || { echo "FAIL: без snap-docker установка не дошла до пакетов"; exit 1; }
