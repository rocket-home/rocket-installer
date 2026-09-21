#!/usr/bin/env bash
# Отказ `make up` без стика обязан объяснять себя. До этой проверки наружу выходил сырой
# вывод docker про "/dev/ttyACM0" — путь из дефолта compose, которого пользователь не
# задавал, без слова «zigbee» и без единой подсказки. Поймано e2e-прогоном 21.09.2026.
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
export ROCKET_ROOT="$tmp" ENV_FILE="$tmp/.env"
mkdir -p "$tmp/data"

run() { "$ROOT/scripts/check-device.sh" 2>&1; }

# ── пусто ──────────────────────────────────────────────────────────────────────
echo 'ZIGBEE_DEVICE_HOST=' >"$ENV_FILE"
out="$(run)"; code=$?
[ "$code" = "0" ] && { echo "FAIL: пустой стик пропущен"; exit 1; }
grep -q 'make detect-device' <<<"$out" || { echo "FAIL: нет подсказки detect-device: $out"; exit 1; }
grep -qi 'стик' <<<"$out" || { echo "FAIL: отказ не называет предмет: $out"; exit 1; }

# ── путь есть, устройства нет (ровно случай прогона) ───────────────────────────
echo 'ZIGBEE_DEVICE_HOST=/dev/ttyACM0-нет-такого' >"$ENV_FILE"
out="$(run)"; code=$?
[ "$code" = "0" ] && { echo "FAIL: несуществующий стик пропущен"; exit 1; }
grep -q 'SKIP_DEVICE_CHECK=1' <<<"$out" || { echo "FAIL: нет аварийного выхода: $out"; exit 1; }

# ── escape hatch ───────────────────────────────────────────────────────────────
SKIP_DEVICE_CHECK=1 "$ROOT/scripts/check-device.sh" >/dev/null 2>&1 \
    || { echo "FAIL: SKIP_DEVICE_CHECK=1 не пропускает"; exit 1; }

# ── symlink: docker его не примет, а сам скажет невнятно ───────────────────────
ln -s /dev/null "$tmp/zigbee-link"
echo "ZIGBEE_DEVICE_HOST=$tmp/zigbee-link" >"$ENV_FILE"
out="$(run)"; code=$?
[ "$code" = "0" ] && { echo "FAIL: symlink пропущен"; exit 1; }
grep -q 'symlink' <<<"$out" || { echo "FAIL: symlink не назван причиной: $out"; exit 1; }

# ── живой character device проходит ────────────────────────────────────────────
echo 'ZIGBEE_DEVICE_HOST=/dev/null' >"$ENV_FILE"
"$ROOT/scripts/check-device.sh" >/dev/null 2>&1 \
    || { echo "FAIL: настоящий character device не прошёл"; exit 1; }

# ── ссылка с кодом внутри не просит код вводить (находка 3) ────────────────────
grep -q 'Код уже в ссылке' "$ROOT/scripts/oauth-link.sh" \
    || { echo "FAIL: oauth-link снова просит ввести код под ссылкой с кодом"; exit 1; }

echo "ok"
