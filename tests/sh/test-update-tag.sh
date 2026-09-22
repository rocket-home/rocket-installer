#!/usr/bin/env bash
# make update обязан поднять НОВЫЙ образ и применить конфиг ДО запуска.
#
# Две регрессии, пойманные живым прогоном 21.09.2026:
#   1) load_env экспортировал .env, окружение перебивало --env-file, и после записи нового тега
#      поднимался старый образ (в .env 2.6.0, контейнер 1.42.0);
#   2) update не звал gen-configs, а строку `adapter:` пишет только он — z2m 2.x без неё
#      отказывался стартовать ("No valid USB adapter found").
# Фейковый docker считает тег ТАК ЖЕ, как настоящий compose: окружение важнее --env-file, —
# иначе тест не заметил бы возврата первой регрессии.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

mkdir -p "$tmp/scripts/lib" "$tmp/bin" "$tmp/data/zigbee2mqtt" "$tmp/deploy/mosquitto/conf.d" "$tmp/secrets"
cp -r "$ROOT/templates" "$tmp/templates"
cp -r "$ROOT/config" "$tmp/config"
cp "$ROOT/deploy/docker-compose.yml" "$tmp/deploy/"
cp "$ROOT"/scripts/*.sh "$tmp/scripts/"
cp "$ROOT"/scripts/lib/*.sh "$tmp/scripts/lib/"

export ROCKET_ROOT="$tmp" ENV_FILE="$tmp/.env"
cat >"$ENV_FILE" <<'EOF'
CLOUD_AUTH_MODE=off
LOCAL_MQTT_USER=local
LOCAL_MQTT_PASSWORD=secret
Z2M_BASE_TOPIC=zigbee2mqtt
Z2M_FRONTEND_PORT=4000
Z2M_FRONTEND_AUTH_TOKEN=fronttoken
Z2M_IMAGE_TAG=1.42.0
Z2M_ADAPTER=
ADAPTER_FAMILY=ember
ZIGBEE_DEVICE_HOST=/dev/null
EOF

# probe отдаём фикстурой — честный шов самого detect-firmware.sh
echo '{"family":"ember","firmware":"7.4.3","model":"","confidence":"probe"}' >"$tmp/probe.json"
export ROCKET_PROBE_CMD="cat $tmp/probe.json"

# бэкап и smoke заглушаем: тест про порядок и содержимое, а не про их внутренности
for s in backup smoke-cloud; do
    cat >"$tmp/scripts/$s.sh" <<EOF
#!/usr/bin/env bash
echo "$s" >>"$tmp/calls.log"
exit 0
EOF
    chmod +x "$tmp/scripts/$s.sh"
done

cat >"$tmp/bin/docker" <<EOF
#!/usr/bin/env bash
# Считаем эффективный тег так же, как compose: переменная окружения важнее --env-file.
for a in "\$@"; do
    if [ "\$a" = "up" ]; then
        echo "up" >>"$tmp/calls.log"
        tag="\${Z2M_IMAGE_TAG:-\$(sed -n 's/^Z2M_IMAGE_TAG=//p' "$ENV_FILE" | tail -1)}"
        printf '%s' "\$tag" >"$tmp/effective-tag"
        cp "$tmp/data/zigbee2mqtt/configuration.yaml" "$tmp/config-at-up.yaml" 2>/dev/null || true
    fi
done
exit 0
EOF
chmod +x "$tmp/bin/docker"
export PATH="$tmp/bin:$PATH"

: >"$tmp/calls.log"
bash "$tmp/scripts/update.sh" >"$tmp/update.log" 2>&1 || { echo "FAIL: update упал:"; cat "$tmp/update.log"; exit 1; }

grep -q '^Z2M_IMAGE_TAG=2\.6\.0$' "$ENV_FILE" || { echo "FAIL: в .env не записан рекомендованный тег"; exit 1; }

got="$(cat "$tmp/effective-tag" 2>/dev/null || echo NONE)"
[ "$got" = "2.6.0" ] || { echo "FAIL: поднят образ '$got' вместо 2.6.0 (окружение перебило --env-file)"; exit 1; }

grep -q '^  adapter: ember$' "$tmp/config-at-up.yaml" || {
    echo "FAIL: на момент up в конфиге нет строки adapter — z2m 2.x с таким не стартует"; exit 1; }

# Порядок: бэкап → конфиги → запуск → проверка
order="$(tr '\n' ' ' <"$tmp/calls.log")"
case "$order" in
    "backup "*"up "*"smoke-cloud "*) ;;
    *) echo "FAIL: ожидался порядок backup → up → smoke, получено: $order"; exit 1 ;;
esac

# Повторный запуск на актуальном .env ничего не поднимает
: >"$tmp/calls.log"
bash "$tmp/scripts/update.sh" >>"$tmp/update.log" 2>&1
grep -q '^up$' "$tmp/calls.log" && { echo "FAIL: второй update зря пересоздал контейнеры"; exit 1; }

echo "ok"
