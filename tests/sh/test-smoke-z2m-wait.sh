#!/usr/bin/env bash
# Проверка ждёт готовности z2m по healthcheck, а не по серии curl.
#
# Регрессия: `curl --retry 6 --retry-delay 5` (≈30с) сдавался раньше, чем поднимался z2m 2.6
# после пересоздания контейнеров, и визард объявлял «Установка не завершена» на полностью
# исправном хабе (прогон 21.09.2026) — минутой позже тот же make smoke был зелёным.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

mkdir -p "$tmp/scripts/lib" "$tmp/bin" "$tmp/deploy"
cp "$ROOT"/scripts/smoke-cloud.sh "$tmp/scripts/"
cp "$ROOT"/scripts/lib/*.sh "$tmp/scripts/lib/"
cp "$ROOT/deploy/docker-compose.yml" "$tmp/deploy/"

export ROCKET_ROOT="$tmp" ENV_FILE="$tmp/.env" PATH="$tmp/bin:$PATH"
export ROCKET_HEALTH_POLL=1 SMOKE_Z2M_TIMEOUT=10

write_env() {  # write_env <устройство>
    cat >"$ENV_FILE" <<EOF
CLOUD_AUTH_MODE=off
LOCAL_MQTT_USER=local
LOCAL_MQTT_PASSWORD=secret
Z2M_FRONTEND_PORT=4000
ZIGBEE_DEVICE_HOST=$1
EOF
}

# Фейковый docker: первые два опроса контейнер «поднимается», дальше — healthy.
# Так воспроизводится ровно та ситуация, в которой прежний smoke краснел.
cat >"$tmp/bin/docker" <<EOF
#!/usr/bin/env bash
case "\$*" in
    *"compose"*" ps -q"*) echo fakecid ;;
    *inspect*)
        n=\$(( \$(cat "$tmp/probes" 2>/dev/null || echo 0) + 1 ))
        echo "\$n" >"$tmp/probes"
        if [ "\$(cat "$tmp/mode")" = "dead" ]; then echo "exited::0"
        elif [ "\$n" -ge 3 ]; then echo "running:healthy:0"
        else echo "running:starting:0"; fi ;;
    *"compose"*exec*mosquitto_sub*) echo "1" ;;   # брокер жив
    *"compose"*exec*) : ;;
    *) : ;;
esac
exit 0
EOF
chmod +x "$tmp/bin/docker"

# curl отвечает успехом только когда контейнер уже признан здоровым
cat >"$tmp/bin/curl" <<EOF
#!/usr/bin/env bash
[ "\$(cat "$tmp/probes" 2>/dev/null || echo 0)" -ge 3 ] && exit 0
exit 7
EOF
chmod +x "$tmp/bin/curl"

# 1) «не готов → готов»: smoke обязан дождаться, а не покраснеть
write_env /dev/null
echo alive >"$tmp/mode"; : >"$tmp/probes"
bash "$tmp/scripts/smoke-cloud.sh" >"$tmp/out1.log" 2>&1 \
    || { echo "FAIL: smoke покраснел, хотя z2m стал healthy:"; cat "$tmp/out1.log"; exit 1; }
[ "$(cat "$tmp/probes")" -ge 3 ] || { echo "FAIL: ожидания готовности не было"; exit 1; }

# 2) контейнер умер — падаем быстро и с указанием, куда смотреть
echo dead >"$tmp/mode"; : >"$tmp/probes"
start=$(date +%s)
if bash "$tmp/scripts/smoke-cloud.sh" >"$tmp/out2.log" 2>&1; then
    echo "FAIL: мёртвый контейнер должен ронять проверку"; exit 1
fi
took=$(( $(date +%s) - start ))
[ "$took" -lt 8 ] || { echo "FAIL: на мёртвом контейнере ждали $took с вместо мгновенного отказа"; exit 1; }
grep -q "make logs SERVICE=zigbee2mqtt" "$tmp/out2.log" \
    || { echo "FAIL: нет подсказки, куда смотреть:"; cat "$tmp/out2.log"; exit 1; }

# 3) узел-мост: стика нет — шаг пропускается, проверка зелёная
write_env ""
echo alive >"$tmp/mode"; : >"$tmp/probes"
bash "$tmp/scripts/smoke-cloud.sh" >"$tmp/out3.log" 2>&1 \
    || { echo "FAIL: узел без стика должен проходить smoke:"; cat "$tmp/out3.log"; exit 1; }
grep -q "пропуск" "$tmp/out3.log" || { echo "FAIL: шаг 3/3 должен быть пропущен"; exit 1; }

echo "ok"
