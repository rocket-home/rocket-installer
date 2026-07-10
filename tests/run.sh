#!/usr/bin/env bash
# Раннер sh-тестов: выполняет tests/sh/test-*.sh, каждый — самостоятельный скрипт
# (exit 0 = pass). TAP-подобный вывод, суммарный exit 1 при любом провале.
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

pass=0
fail=0
for t in "$ROOT"/tests/sh/test-*.sh; do
    name="$(basename "$t")"
    if out="$(bash "$t" 2>&1)"; then
        echo "ok - $name"
        pass=$((pass + 1))
    else
        echo "not ok - $name"
        echo "$out" | sed 's/^/    /'
        fail=$((fail + 1))
    fi
done
echo "# sh-тесты: $pass ok, $fail fail"
[ "$fail" -eq 0 ]
