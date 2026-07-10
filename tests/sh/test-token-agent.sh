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
cleanup() {
    [ -n "$AGENT_PID" ] && kill "$AGENT_PID" 2>/dev/null || true
    [ -n "$MOCK_PID" ] && kill "$MOCK_PID" 2>/dev/null || true
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
        sh "$AGENT" "$@" &
    AGENT_PID=$!
}

wait_for() { # wait_for <сек> <команда...>
    local n=$(( $1 * 10 )); shift
    for _ in $(seq 1 "$n"); do "$@" 2>/dev/null && return 0; sleep 0.1; done
    return 1
}

# ── 1. happy path: свежий JWT до старта брокера + ротация без рестарта ────────
printf '{"access_token":"good-access","refresh_token":"good-refresh","expires_at":9999999999,"obtained_at":1}' >"$tmp/tokens.json"
agent_start sleep 300

wait_for 5 grep -q 'remote_password token=jwt-1' "$tmp/bridge.conf" \
    || { echo "FAIL: bridge.conf с jwt-1 не появился"; cat "$tmp/bridge.conf" 2>/dev/null; exit 1; }
grep -q 'remote_username loc123' "$tmp/bridge.conf" || { echo "FAIL: locationId"; exit 1; }
grep -q 'address mq.example:8883' "$tmp/bridge.conf" || { echo "FAIL: address"; exit 1; }
wait_for 5 sh -c "jq -e '.state == \"ok\"' '$tmp/status.json' >/dev/null" \
    || { echo "FAIL: статус не ok: $(cat "$tmp/status.json")"; exit 1; }
# ротация: JWT_MAX_AGE=1с → через пару циклов токен свежее
wait_for 10 sh -c "grep -qE 'token=jwt-[2-9]' '$tmp/bridge.conf'" \
    || { echo "FAIL: JWT не ротируется"; exit 1; }

# чистое завершение: TERM гасит и агента, и «брокер» (sleep)
kill -TERM "$AGENT_PID"
wait_for 5 sh -c "! kill -0 $AGENT_PID 2>/dev/null" || { echo "FAIL: агент не завершился"; exit 1; }
pgrep -f "sleep 300" >/dev/null && { echo "FAIL: дочерний mosquitto (sleep) жив"; exit 1; }
AGENT_PID=""

# ── 2. протухший access + невалидный refresh → needs_relink, брокер живёт ────
rm -f "$tmp/bridge.conf" "$tmp/status.json"
printf '{"access_token":"stale-access","refresh_token":"dead-refresh","expires_at":9999999999,"obtained_at":1}' >"$tmp/tokens.json"
agent_start sleep 301
wait_for 5 sh -c "jq -e '.state == \"needs_relink\"' '$tmp/status.json' >/dev/null" \
    || { echo "FAIL: needs_relink не выставлен: $(cat "$tmp/status.json" 2>/dev/null)"; exit 1; }
[ ! -f "$tmp/bridge.conf" ] || { echo "FAIL: bridge.conf не должен существовать"; exit 1; }
wait_for 5 pgrep -f "sleep 301" >/dev/null || { echo "FAIL: брокер не стартовал при needs_relink"; exit 1; }
kill -TERM "$AGENT_PID"; wait "$AGENT_PID" 2>/dev/null || true
AGENT_PID=""

# ── 3. протухший access + валидный refresh → авто-восстановление ─────────────
rm -f "$tmp/bridge.conf" "$tmp/status.json"
printf '{"access_token":"stale-access","refresh_token":"good-refresh","expires_at":9999999999,"obtained_at":1}' >"$tmp/tokens.json"
agent_start sleep 302
wait_for 5 grep -q 'remote_password token=jwt-' "$tmp/bridge.conf" \
    || { echo "FAIL: 401→refresh→retry не сработал"; exit 1; }
jq -e '.access_token == "good-access"' "$tmp/tokens.json" >/dev/null \
    || { echo "FAIL: tokens.json не обновлён после refresh"; exit 1; }
kill -TERM "$AGENT_PID"; wait "$AGENT_PID" 2>/dev/null || true
AGENT_PID=""

echo "token-agent: OK"
