#!/usr/bin/env bash
# Узел без стика обязан подниматься: профиль zigbee включается по наличию устройства.
#
# Регрессия: пока z2m был без профиля, compose ВСЕГДА мапил devices: и docker отвечал
# "error gathering device information … no such file or directory" — `make up` падал с кодом 1,
# хотя SKIP_DEVICE_CHECK=1 обещает поднять брокер и мост в облако (прогон 21.09.2026).
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

export ROCKET_ROOT="$tmp" ENV_FILE="$tmp/.env"
mkdir -p "$tmp/deploy" "$tmp/scripts/lib" "$tmp/bin"
cp "$ROOT/deploy/docker-compose.yml" "$tmp/deploy/"
cp "$ROOT/scripts/lib/common.sh" "$tmp/scripts/lib/"
cp "$ROOT/scripts/compose.sh" "$tmp/scripts/"

write_env() {  # write_env <устройство> <профили из .env>
    cat >"$ENV_FILE" <<EOF
ZIGBEE_DEVICE_HOST=$1
COMPOSE_PROFILES=$2
EOF
}

# shellcheck disable=SC1091
. "$tmp/scripts/lib/common.sh"

# /dev/null — существующий символьный девайс: годится как «стик на месте»
write_env /dev/null ""
got="$(compose_profiles)"
[ "$got" = "zigbee" ] || { echo "FAIL: со стиком ожидался zigbee, получено '$got'"; exit 1; }

write_env /dev/null "nodered"
got="$(compose_profiles)"
[ "$got" = "nodered,zigbee" ] || { echo "FAIL: аддон потерян: '$got'"; exit 1; }

write_env /нет/такого/устройства ""
got="$(compose_profiles)"
[ -z "$got" ] || { echo "FAIL: без стика профиль zigbee не нужен, получено '$got'"; exit 1; }

write_env "" "nodered"
got="$(compose_profiles)"
[ "$got" = "nodered" ] || { echo "FAIL: пустой стик: '$got'"; exit 1; }

# Структура compose-файла: z2m под профилем, брокер — всегда
python3 - "$tmp/deploy/docker-compose.yml" <<'PY'
import sys, yaml
c = yaml.safe_load(open(sys.argv[1]))
z = c["services"]["zigbee2mqtt"]
assert z.get("profiles") == ["zigbee"], f"у zigbee2mqtt ожидался profiles: [zigbee], есть {z.get('profiles')}"
assert "profiles" not in c["services"]["mqtt"], "брокер обязан подниматься всегда, без профиля"
PY

# Сквозная проверка: compose.sh без стика не падает и не просит профиль zigbee
cat >"$tmp/bin/docker" <<'EOF'
#!/usr/bin/env bash
echo "COMPOSE_PROFILES=${COMPOSE_PROFILES-}" >>"$DOCKER_CALLS"
exit 0
EOF
chmod +x "$tmp/bin/docker"
export DOCKER_CALLS="$tmp/calls.log" PATH="$tmp/bin:$PATH"

write_env /нет/такого/устройства ""
: >"$DOCKER_CALLS"
bash "$tmp/scripts/compose.sh" up -d || { echo "FAIL: compose.sh без стика вернул ненулевой код"; exit 1; }
grep -q '^COMPOSE_PROFILES=$' "$DOCKER_CALLS" || { echo "FAIL: без стика профиль не должен включаться: $(cat "$DOCKER_CALLS")"; exit 1; }

write_env /dev/null ""
: >"$DOCKER_CALLS"
bash "$tmp/scripts/compose.sh" up -d
grep -q 'zigbee' "$DOCKER_CALLS" || { echo "FAIL: со стиком ожидался профиль zigbee: $(cat "$DOCKER_CALLS")"; exit 1; }

echo "ok"
