#!/usr/bin/env bash
# resolve-z2m-tag.sh: табличные тесты по реальной матрице (чистая функция).
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
R="$ROOT/scripts/resolve-z2m-tag.sh"

check() { # check <family> <fw> <model> <jq-предикат>
    local out
    out="$(FAMILY="$1" FIRMWARE="$2" MODEL="$3" "$R" "$1" "$2" "$3")"
    if ! jq -e "$4" >/dev/null <<<"$out"; then
        echo "FAIL: family=$1 fw=$2 model=$3 предикат=$4"
        echo "  получено: $out"
        exit 1
    fi
}

# zstack: свежая прошивка → рекомендация 2.x
check zstack 20240710 "" '.ok == true and (.recommended | startswith("2."))'
# zstack: древняя прошивка → пин на 1.39.1 + совет
check zstack 20200101 "" '.ok == true and .recommended == "1.39.1" and .advice != null'
# zstack: CC2531 hardware override → максимум 1.42.0
check zstack 20211217 CC2531 '.ok == true and .recommended == "1.42.0" and .advice != null'
# zstack: прошивка неизвестна (пусто) → ok=false c fallback
check zstack "" "" '.ok == false and .fallback != null'
# ember: 7.4+ → 2.x, драйвер ember без override
check ember 7.4.3 "" '.ok == true and (.recommended | startswith("2.")) and .adapter == "ember" and .adapter_override == null'
# ember: 6.10–7.3 → legacy 1.42.0 + adapter_override ezsp
check ember 6.10.3 "" '.ok == true and .recommended == "1.42.0" and .adapter_override == "ezsp"'
# ember: слишком старая → ok=false + advice про прошивку
check ember 6.5.0 "" '.ok == false and (.advice | contains("обновите"))'
# deconz: прошивки нет, но правило без границ матчится
check deconz "" "" '.ok == true and .advice != null'
# неизвестное семейство
check nosuch 1.0 "" '.ok == false and (.advice | contains("Неизвестное семейство"))'

echo "resolve-tag: OK"
