#!/usr/bin/env bash
# Подготовка хоста под zigbee-стик: udev-правила (стабильный /dev/zigbee + права)
# и членство пользователя в dialout (tty) и docker. Идемпотентно; требует sudo.
. "$(dirname "$0")/lib/common.sh"

RULES_SRC="$ROCKET_ROOT/udev/99-zigbee.rules"
RULES_DST="/etc/udev/rules.d/99-zigbee.rules"
TARGET_USER="${SUDO_USER:-$USER}"

SUDO=""
if [ "$(id -u)" -ne 0 ]; then
    require_cmd sudo
    SUDO="sudo"
fi

if [ -f "$RULES_DST" ] && cmp -s "$RULES_SRC" "$RULES_DST"; then
    log "udev-правила уже установлены и актуальны"
else
    $SUDO cp "$RULES_SRC" "$RULES_DST"
    $SUDO udevadm control --reload-rules
    $SUDO udevadm trigger --subsystem-match=tty
    ok "udev-правила установлены ($RULES_DST), правила перечитаны"
fi

for grp in dialout docker; do
    if ! getent group "$grp" >/dev/null; then
        warn "группа $grp не существует — пропуск (docker ещё не установлен?)"
        continue
    fi
    if id -nG "$TARGET_USER" | tr ' ' '\n' | grep -qx "$grp"; then
        log "$TARGET_USER уже в группе $grp"
    else
        $SUDO usermod -aG "$grp" "$TARGET_USER"
        ok "$TARGET_USER добавлен в группу $grp (вступит в силу после перелогина)"
    fi
done
