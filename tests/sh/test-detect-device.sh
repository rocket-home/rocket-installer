#!/usr/bin/env bash
# detect-device.sh на фикстурном /dev-дереве с фейковым udevadm (без железа).
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

# фикстурное dev-дерево: ttyUSB0 (ZBDongle-P) + by-id-симлинк на него, ttyACM0 (неизвестный)
mkdir -p "$tmp/dev/serial/by-id"
touch "$tmp/dev/ttyUSB0" "$tmp/dev/ttyACM0"
ln -s ../../ttyUSB0 "$tmp/dev/serial/by-id/usb-ITead_Sonoff_Zigbee_3.0_USB_Dongle_Plus-if00"

# фейковый udevadm: отвечает свойствами по имени устройства
cat >"$tmp/fake-udevadm" <<EOF
#!/usr/bin/env bash
case "\$*" in
    *ttyUSB0*) printf 'ID_VENDOR_ID=10c4\nID_MODEL_ID=ea60\nID_MODEL=Sonoff_Zigbee_3.0_USB_Dongle_Plus\n' ;;
    *ttyACM0*) printf 'ID_VENDOR_ID=dead\nID_MODEL_ID=beef\nID_MODEL=Unknown_Gadget\n' ;;
esac
EOF
chmod +x "$tmp/fake-udevadm"

out="$(ROCKET_DEV_ROOT="$tmp" ROCKET_UDEVADM="$tmp/fake-udevadm" "$ROOT/scripts/detect-device.sh")"

jq -e 'length == 2' >/dev/null <<<"$out" \
    || { echo "FAIL: ожидалось 2 устройства (by-id дедуплицирован с ttyUSB0): $out"; exit 1; }
# by-id путь предпочтён сырому ttyUSB0 и распознан как zstack
jq -e '.[0].path | contains("by-id")' >/dev/null <<<"$out" \
    || { echo "FAIL: by-id не предпочтён: $out"; exit 1; }
jq -e '.[0].known == true and .[0].family == "zstack" and .[0].vid == "10c4"' >/dev/null <<<"$out" \
    || { echo "FAIL: ZBDongle-P не распознан: $out"; exit 1; }
jq -e '.[1].known == false' >/dev/null <<<"$out" \
    || { echo "FAIL: неизвестный VID:PID помечен known: $out"; exit 1; }

echo "detect-device: OK"
