#!/usr/bin/env bash
# token-agent.sh против мок-облака (без docker/mosquitto):
#   happy path (JWT в bridge.conf + ротация), 401→refresh→retry, протухший refresh
#   → needs_relink, чистое завершение по TERM.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
AGENT="$ROOT/deploy/mosquitto/token-agent.sh"
tmp="$(mktemp -d)"
MOCK_PID=""
AGENT_PID=""
# Длительность фейкового «брокера» несёт метку прогона ($$ — дробной частью, sleep её
# принимает). Проверки ищут его через `pgrep -f`, то есть ПО ВСЕЙ СИСТЕМЕ: с общей
# длительностью «брокер», переживший прошлый прогон (упавший тест, ctrl-c, kill агента
# мимо группы), валил бы каждый следующий — и отказ выглядел бы как регрессия агента,
# хотя агент ни при чём. Поймано 21.09.2026 ровно так.
B1="300.$$"
B2="301.$$"
B3="302.$$"
B4="303.$$"
B5="304.$$"
B6="305.$$"
B7="306.$$"
B8="307.$$"
B9="308.$$"
cleanup() {
    [ -n "$AGENT_PID" ] && kill "$AGENT_PID" 2>/dev/null || true
    [ -n "$MOCK_PID" ] && kill "$MOCK_PID" 2>/dev/null || true
    pkill -f "sleep 30[0-9]\.$$\$" 2>/dev/null || true
    rm -rf "$tmp"
}
trap cleanup EXIT

# мок-облако
node "$ROOT/tests/fixtures/mock-api.mjs" >"$tmp/port" &
MOCK_PID=$!
for _ in $(seq 1 50); do [ -s "$tmp/port" ] && break; sleep 0.1; done
PORT="$(head -1 "$tmp/port")"
[ -n "$PORT" ] || { echo "FAIL: мок-API не стартовал"; exit 1; }

# фейковый mosquitto_sub: состояние моста из файла
mkdir -p "$tmp/bin"
echo "1" >"$tmp/bridge-state"
cat >"$tmp/bin/mosquitto_sub" <<EOF
#!/usr/bin/env bash
cat "$tmp/bridge-state"
EOF
chmod +x "$tmp/bin/mosquitto_sub"
export PATH="$tmp/bin:$PATH"

# Важно: & стоит на самой команде env (не на bash-функции) — иначе $! указывает
# на обёрточный сабшелл, TERM не доходит до агента и sleep-«брокер» сиротеет.
agent_start() {
    env API_BASE_URL="http://127.0.0.1:$PORT" OAUTH_CLIENT_ID=test-client \
        CLOUD_MQTT_HOST=mq.example CLOUD_MQTT_PORT=8883 CLOUD_BRIDGE_PROTOCOL=mqttv311 \
        MQTT_USER=local MQTT_PASSWORD=pw \
        AGENT_TOKENS_FILE="$tmp/tokens.json" AGENT_BRIDGE_CONF="$tmp/bridge.conf" \
        AGENT_STATUS_FILE="$tmp/status.json" \
        AGENT_CHECK_INTERVAL=1 AGENT_JWT_MAX_AGE=1 AGENT_BRIDGE_GRACE=3600 \
        TZ=UTC ${AGENT_ENV:-} \
        sh "$AGENT" "$@" 2>>"$tmp/agent.log" &
    AGENT_PID=$!
}

wait_for() { # wait_for <сек> <команда...>
    local n=$(( $1 * 10 )); shift
    for _ in $(seq 1 "$n"); do "$@" 2>/dev/null && return 0; sleep 0.1; done
    return 1
}

# ── 1. happy path: свежий JWT до старта брокера + ротация без рестарта ────────
printf '{"access_token":"good-access","refresh_token":"good-refresh","expires_at":9999999999,"obtained_at":1}' >"$tmp/tokens.json"
agent_start sleep "$B1"

wait_for 5 grep -q 'remote_password token=jwt-1' "$tmp/bridge.conf" \
    || { echo "FAIL: bridge.conf с jwt-1 не появился"; cat "$tmp/bridge.conf" 2>/dev/null; exit 1; }
grep -q 'remote_username loc123' "$tmp/bridge.conf" || { echo "FAIL: locationId"; exit 1; }
grep -q 'address mq.example:8883' "$tmp/bridge.conf" || { echo "FAIL: address"; exit 1; }
wait_for 5 sh -c "jq -e '.state == \"ok\"' '$tmp/status.json' >/dev/null" \
    || { echo "FAIL: статус не ok: $(cat "$tmp/status.json")"; exit 1; }
# статус читаем не-root'ом (bridge.conf пишется под umask 077 — не должен протечь)
[ "$(stat -c %a "$tmp/status.json")" = "644" ] \
    || { echo "FAIL: права status.json = $(stat -c %a "$tmp/status.json"), ожидалось 644"; exit 1; }
[ "$(stat -c %a "$tmp/bridge.conf")" = "600" ] \
    || { echo "FAIL: права bridge.conf = $(stat -c %a "$tmp/bridge.conf"), ожидалось 600"; exit 1; }
# ротация: JWT_MAX_AGE=1с → через пару циклов токен свежее
wait_for 10 sh -c "grep -qE 'token=jwt-[2-9]' '$tmp/bridge.conf'" \
    || { echo "FAIL: JWT не ротируется"; exit 1; }

# чистое завершение: TERM гасит и агента, и «брокер» (sleep)
kill -TERM "$AGENT_PID"
wait_for 5 sh -c "! kill -0 $AGENT_PID 2>/dev/null" || { echo "FAIL: агент не завершился"; exit 1; }
pgrep -f "sleep $B1" >/dev/null && { echo "FAIL: дочерний mosquitto (sleep) жив"; exit 1; }
AGENT_PID=""

# ── 2. протухший access + невалидный refresh → needs_relink, брокер живёт ────
rm -f "$tmp/bridge.conf" "$tmp/status.json"
printf '{"access_token":"stale-access","refresh_token":"dead-refresh","expires_at":9999999999,"obtained_at":1}' >"$tmp/tokens.json"
agent_start sleep "$B2"
wait_for 5 sh -c "jq -e '.state == \"needs_relink\"' '$tmp/status.json' >/dev/null" \
    || { echo "FAIL: needs_relink не выставлен: $(cat "$tmp/status.json" 2>/dev/null)"; exit 1; }
[ ! -f "$tmp/bridge.conf" ] || { echo "FAIL: bridge.conf не должен существовать"; exit 1; }
wait_for 5 pgrep -f "sleep $B2" >/dev/null || { echo "FAIL: брокер не стартовал при needs_relink"; exit 1; }
kill -TERM "$AGENT_PID"; wait "$AGENT_PID" 2>/dev/null || true
AGENT_PID=""

# ── 3. протухший access + валидный refresh → авто-восстановление ─────────────
rm -f "$tmp/bridge.conf" "$tmp/status.json"
printf '{"access_token":"stale-access","refresh_token":"good-refresh","expires_at":9999999999,"obtained_at":1}' >"$tmp/tokens.json"
agent_start sleep "$B3"
wait_for 5 grep -q 'remote_password token=jwt-' "$tmp/bridge.conf" \
    || { echo "FAIL: 401→refresh→retry не сработал"; exit 1; }
jq -e '.access_token == "good-access"' "$tmp/tokens.json" >/dev/null \
    || { echo "FAIL: tokens.json не обновлён после refresh"; exit 1; }
kill -TERM "$AGENT_PID"; wait "$AGENT_PID" 2>/dev/null || true
AGENT_PID=""

# ── общие помощники для кейсов grant-режима ─────────────────────────────────
broker_pid() { pgrep -x sleep -a 2>/dev/null | awk -v b="$1" '$3 == b {print $1; exit}'; }
# pid_changed <метка> <старый pid> <сек> — брокер перезапущен (новый pid)
broker_up() { [ -n "$(broker_pid "$1")" ]; }
pid_changed() {
    for _ in $(seq 1 $(( $3 * 10 ))); do
        p="$(broker_pid "$1")"
        [ -n "$p" ] && [ "$p" != "$2" ] && return 0
        sleep 0.1
    done
    return 1
}
agent_stop() { kill -TERM "$AGENT_PID"; wait "$AGENT_PID" 2>/dev/null || true; AGENT_PID=""; }
stats() { curl -s "http://127.0.0.1:$PORT/__stats" | jq -r .requests; }
NIGHT="$(date -u -d '2026-10-01 03:30:00' +%s)"
NOON="$(date -u -d '2026-10-01 12:00:00' +%s)"
tokens() { # tokens <access> <refresh> <expires_at>
    printf '{"access_token":"%s","refresh_token":"%s","expires_at":%s,"obtained_at":1}' "$1" "$2" "$3" >"$tmp/tokens.json"
}
fresh() { rm -f "$tmp/bridge.conf" "$tmp/status.json" "$tmp/now" "$tmp/agent.log"; echo "1" >"$tmp/bridge-state"; }

# ── 4. grant: обрыв облака не рестартует брокер и не ротирует пароль ─────────
fresh; tokens grant-access grant-refresh 9999999999
agent_start sleep "$B4"
wait_for 5 grep -q 'remote_password token=gjwt-' "$tmp/bridge.conf" \
    || { echo "FAIL[4]: нет токена моста: $(cat "$tmp/bridge.conf" 2>/dev/null)"; exit 1; }
conf="$(cat "$tmp/bridge.conf")"; pid="$(broker_pid "$B4")"
echo "0" >"$tmp/bridge-state"
sleep 4
[ "$(broker_pid "$B4")" = "$pid" ] || { echo "FAIL[4]: брокер перезапущен при grant-пароле"; exit 1; }
[ "$(cat "$tmp/bridge.conf")" = "$conf" ] || { echo "FAIL[4]: grant-пароль ротировался"; exit 1; }
agent_stop

# ── 5. short: обрыв с протухшим паролем в памяти — рестарт без grace ────────
fresh; tokens good-access good-refresh 9999999999
date +%s >"$tmp/now"
AGENT_ENV="AGENT_NOW_FILE=$tmp/now" agent_start sleep "$B5"
wait_for 5 grep -q 'remote_password token=jwt-' "$tmp/bridge.conf" || { echo "FAIL[5]: нет JWT"; exit 1; }
wait_for 5 broker_up "$B5" || { echo "FAIL[5]: брокер не стартовал"; exit 1; }
pid="$(broker_pid "$B5")"
echo $(( $(cat "$tmp/now") + 4000 )) >"$tmp/now"; echo "0" >"$tmp/bridge-state"
pid_changed "$B5" "$pid" 6 \
    || { echo "FAIL[5]: протухший пароль в памяти — нет немедленного рестарта"; exit 1; }
agent_stop

# ── 6. grant: ночь в окне обновления — refresh + ровно один рестарт ──────────
fresh; echo "$NIGHT" >"$tmp/now"; tokens grant-access grant-refresh $(( NIGHT + 10 * 86400 ))
AGENT_ENV="AGENT_NOW_FILE=$tmp/now" agent_start sleep "$B6"
wait_for 6 sh -c "jq -e '.detail == \"grant renewed\"' '$tmp/status.json' >/dev/null" \
    || { echo "FAIL[6]: грант не обновлён: $(cat "$tmp/status.json")"; exit 1; }
jq -e ".expires_at > $(( NIGHT + 300 * 86400 ))" "$tmp/tokens.json" >/dev/null \
    || { echo "FAIL[6]: expires_at не продлён"; exit 1; }
grep -q 'token=gjwt-' "$tmp/bridge.conf" || { echo "FAIL[6]: нет нового токена моста"; exit 1; }
pid2="$(broker_pid "$B6")"
sleep 3
[ "$(broker_pid "$B6")" = "$pid2" ] || { echo "FAIL[6]: лишний рестарт после обновления"; exit 1; }
[ "$(grep -c 'плановое обновление гранта' "$tmp/agent.log")" = 1 ] \
    || { echo "FAIL[6]: обновлений гранта не одно: $(grep -c 'плановое обновление гранта' "$tmp/agent.log")"; exit 1; }
agent_stop

# ── 7. grant: сбой сети при refresh — refresh_pending, брокер не трогаем ─────
fresh; echo "$NIGHT" >"$tmp/now"; tokens grant-access flaky-refresh $(( NIGHT + 10 * 86400 ))
AGENT_ENV="AGENT_NOW_FILE=$tmp/now" agent_start sleep "$B7"
wait_for 5 broker_up "$B7" || { echo "FAIL[7]: брокер не стартовал"; exit 1; }
pid="$(broker_pid "$B7")"
wait_for 6 sh -c "jq -e '.state == \"refresh_pending\"' '$tmp/status.json' >/dev/null" \
    || { echo "FAIL[7]: нет refresh_pending: $(cat "$tmp/status.json")"; exit 1; }
[ "$(broker_pid "$B7")" = "$pid" ] || { echo "FAIL[7]: брокер перезапущен при неудачном refresh"; exit 1; }
agent_stop

# ── 8. grant: днём вне срочного окна — ждём ночи; в срочном — сразу ──────────
fresh; echo "$NOON" >"$tmp/now"; tokens grant-access grant-refresh $(( NOON + 10 * 86400 ))
AGENT_ENV="AGENT_NOW_FILE=$tmp/now" agent_start sleep "$B8"
wait_for 5 grep -q 'token=gjwt-' "$tmp/bridge.conf" || { echo "FAIL[8]: нет токена моста"; exit 1; }
sleep 3
jq -e ".expires_at == $(( NOON + 10 * 86400 ))" "$tmp/tokens.json" >/dev/null \
    || { echo "FAIL[8]: днём вне срочного окна refresh не должен идти"; exit 1; }
tokens grant-access grant-refresh $(( NOON + 3 * 86400 ))
wait_for 6 sh -c "jq -e '.detail == \"grant renewed\"' '$tmp/status.json' >/dev/null" \
    || { echo "FAIL[8]: в срочном окне refresh не пошёл днём"; exit 1; }
agent_stop

# ── 9. needs_relink: мост снят, облако больше не дёргаем ─────────────────────
fresh; echo "0" >"$tmp/bridge-state"; tokens stale-access dead-refresh 9999999999
agent_start sleep "$B9"
wait_for 5 sh -c "jq -e '.state == \"needs_relink\"' '$tmp/status.json' >/dev/null" \
    || { echo "FAIL[9]: needs_relink не выставлен"; exit 1; }
n="$(stats)"; sleep 4
[ "$(stats)" = "$n" ] || { echo "FAIL[9]: после needs_relink агент продолжает ходить в облако ($n → $(stats))"; exit 1; }
agent_stop

echo "token-agent: OK"
