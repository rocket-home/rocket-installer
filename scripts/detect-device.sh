#!/usr/bin/env bash
# Поиск zigbee-стиков. Выводит JSON-массив кандидатов:
#   [{"path","realpath","vid","pid","family","known":bool,"description"}...]
# Порядок предпочтения путей: /dev/zigbee → /dev/serial/by-id/* → /dev/ttyUSB*/ttyACM*.
# Семейство — эвристика по VID:PID из config/compatibility-matrix.json (точный ответ
# даёт make detect-firmware). Тестируемость: ROCKET_DEV_ROOT подменяет корень /dev,
# ROCKET_UDEVADM — команду udevadm.
. "$(dirname "$0")/lib/common.sh"
require_cmd jq

DEV_ROOT="${ROCKET_DEV_ROOT:-}"
UDEVADM="${ROCKET_UDEVADM:-udevadm}"

# vid:pid → family из матрицы (первое совпавшее семейство; пересечения решает probe)
family_by_ids() {
    jq -r --arg id "$1" \
        '.families | to_entries[] | select(.value.usb_ids | index($id)) | .key' \
        "$MATRIX_FILE" 2>/dev/null | head -1
}

usb_ids_of() { # usb_ids_of <realpath> → "vid pid"
    local dev="$1" info vid pid
    info="$($UDEVADM info -q property -n "$dev" 2>/dev/null)" || return 0
    vid="$(printf '%s\n' "$info" | sed -n 's/^ID_VENDOR_ID=//p' | head -1)"
    pid="$(printf '%s\n' "$info" | sed -n 's/^ID_MODEL_ID=//p' | head -1)"
    printf '%s %s' "$vid" "$pid"
}

emit() { # emit <path> <realpath>
    local path="$1" real="$2" vid pid ids family known desc
    read -r vid pid <<<"$(usb_ids_of "$real")" || true
    ids="${vid}:${pid}"
    family=""
    known=false
    if [ -n "$vid" ] && [ -n "$pid" ]; then
        family="$(family_by_ids "$ids")"
        [ -n "$family" ] && known=true
    fi
    desc="$($UDEVADM info -q property -n "$real" 2>/dev/null | sed -n 's/^ID_MODEL=//p' | head -1)"
    jq -n --arg path "$path" --arg real "$real" --arg vid "${vid:-}" --arg pid "${pid:-}" \
        --arg family "${family:-}" --argjson known "$known" --arg desc "${desc:-}" \
        '{path:$path, realpath:$real, vid:$vid, pid:$pid, family:$family, known:$known, description:$desc}'
}

seen=""
{
    # 1. стабильный симлинк из наших udev-правил
    [ -e "$DEV_ROOT/dev/zigbee" ] && printf '%s\n' "$DEV_ROOT/dev/zigbee"
    # 2. by-id (стабильные имена)
    for p in "$DEV_ROOT"/dev/serial/by-id/*; do [ -e "$p" ] && printf '%s\n' "$p"; done
    # 3. сырые tty
    for p in "$DEV_ROOT"/dev/ttyUSB* "$DEV_ROOT"/dev/ttyACM*; do [ -e "$p" ] && printf '%s\n' "$p"; done
} 2>/dev/null | while read -r path; do
    real="$(readlink -f "$path")"
    case " $seen " in *" $real "*) continue;; esac
    seen="$seen $real"
    emit "$path" "$real"
done | jq -s '.'
