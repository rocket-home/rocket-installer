#!/usr/bin/env bash
# Стик на месте? Проверка перед `make up`.
#
# Без неё отказ приходил сырым выводом docker — «error gathering device information
# while adding custom device "/dev/ttyACM0": no such file or directory». Причину он
# называет, но не говорит ни что это zigbee-стик, ни что с этим делать, а путь в
# сообщении — шаблонный дефолт compose, которого пользователь у себя не задавал.
# Поймано e2e-прогоном 21.09.2026.
#
# Пропустить: SKIP_DEVICE_CHECK=1 make up — для узла, который поднимают ради моста
# в облако, без своей zigbee-сети.
. "$(dirname "$0")/lib/common.sh"
load_env

[ "${SKIP_DEVICE_CHECK:-}" = "1" ] && exit 0

# Подсказки — без значка отказа: причина одна, а строк под ней три, и четыре ✘ подряд
# читаются как четыре разные поломки. На stderr, чтобы не разъезжались с ней в порядке.
hint() { printf '  %s\n' "$*" >&2; }

dev="${ZIGBEE_DEVICE_HOST:-}"
if [ -z "$dev" ]; then
    err "zigbee-стик не выбран: ZIGBEE_DEVICE_HOST пуст."
    hint "найти:     make detect-device"
    hint "записать:  make env-set KEY=ZIGBEE_DEVICE_HOST VALUE=/dev/ttyUSB0"
    hint "без стика: SKIP_DEVICE_CHECK=1 make up  (поднимется только мост в облако)"
    exit 1
fi
if [ ! -e "$dev" ]; then
    err "стик $dev не найден — выдернут, сменил имя или это путь с другой машины."
    hint "найти заново: make detect-device"
    hint "без стика:    SKIP_DEVICE_CHECK=1 make up"
    exit 1
fi
# Docker не принимает symlink как device node, и отказ у него столь же невнятный.
if [ -L "$dev" ]; then
    err "$dev — symlink, docker такой device не примет."
    hint "в ZIGBEE_DEVICE_HOST нужен реальный путь: $(readlink -f "$dev")"
    hint "symlink держите в ZIGBEE_DEVICE_BYID — он переживает пересадку стика в другой порт"
    exit 1
fi
if [ ! -c "$dev" ]; then
    err "$dev — не character device."
    hint "нужен путь вида /dev/ttyUSB0: make detect-device"
    exit 1
fi
