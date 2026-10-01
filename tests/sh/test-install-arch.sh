#!/usr/bin/env bash
# install.sh отказывает 32-битной системе, даже если ядро 64-битное.
#
# Регрессия: 32-битная Raspberry Pi OS на Pi 4/5 грузит 64-битное ядро, uname -m отвечает
# aarch64 — старая проверка пропускала такую систему, и установка падала на середине.
# Проверка архитектуры стоит раньше любых действий, поэтому скрипт можно гонять на заглушках.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

stub() { printf '#!/bin/sh\necho %s\n' "$2" >"$tmp/$1"; chmod +x "$tmp/$1"; }

# 64-битное ядро, 32-битные пакеты → отказ с понятным текстом
stub uname aarch64
stub dpkg armhf
if out="$(PATH="$tmp:$PATH" bash "$ROOT/install.sh" 2>&1)"; then
    echo "FAIL: armhf-система на aarch64-ядре прошла проверку"; exit 1
fi
echo "$out" | grep -q "неподдерживаемая архитектура: armhf" \
    || { echo "FAIL: нет внятного отказа: $out"; exit 1; }

# без dpkg решает ядро: i686 → отказ
stub uname i686
printf '#!/bin/sh\nexit 127\n' >"$tmp/dpkg"; chmod +x "$tmp/dpkg"
if out="$(PATH="$tmp:$PATH" bash "$ROOT/install.sh" 2>&1)"; then
    echo "FAIL: i686 прошёл проверку"; exit 1
fi
echo "$out" | grep -q "неподдерживаемая архитектура: i686" \
    || { echo "FAIL: нет внятного отказа для i686: $out"; exit 1; }
