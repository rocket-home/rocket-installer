#!/usr/bin/env bash
# Живой поток событий сопряжения: окно открыто/закрыто, прибор вошёл, анонсировался,
# интервью началось/прошло/упало, прибор ушёл.
# Использование: pair-watch.sh [секунд]   (0 или пусто — до Ctrl+C)
#
# ЗАЧЕМ. `make logs SERVICE=zigbee2mqtt` показывает вход и интервью только при log_level info,
# а на хабе может стоять warning — и лог молчит, пока прибор мигает (разбор 23.09.2026).
# bridge/event z2m публикует при любом уровне лога, а по MQTT видно ещё и, сработала ли
# сама команда permit_join. Читается это без grep по километрам debug-строк.
. "$(dirname "$0")/lib/common.sh"
require_cmd jq
load_env

base="${Z2M_BASE_TOPIC:-zigbee2mqtt}"
time_sec="${1:-0}"
[[ "$time_sec" =~ ^[0-9]+$ ]] || die "аргумент — число секунд (0 = без ограничения)"
limit=()
[ "$time_sec" -gt 0 ] && limit=(-W "$time_sec")

# Формат вывода. bridge/info — retained и переиздаётся по любому поводу, поэтому из него
# печатаем только СМЕНУ состояния окна; всё остальное — построчно, с локальным временем.
read -r -d '' JQ_FORMAT <<'JQ' || true
def ts: now | strflocaltime("%H:%M:%S");
def name($d): ($d.friendly_name // $d.ieee_address // "?");
foreach inputs as $line ({pj: null, out: null};
  .out = null
  | ($line | index(" ")) as $i
  | (if $i == null then null else {t: $line[0:$i], p: ($line[$i+1:] | try fromjson catch null)} end) as $m
  | if $m == null or $m.p == null then .
    elif ($m.t | endswith("/bridge/info")) then
      ($m.p.permit_join) as $now
      | if $now == null or $now == .pj then .
        else .pj = $now
          | .out = (if $now then "● сеть открыта для сопряжения" else "○ сеть закрыта" end)
        end
    elif ($m.t | endswith("/bridge/response/permit_join")) then
      .out = (if $m.p.status == "ok" then
                (if ($m.p.data.value == true) or (($m.p.data.time // 0) > 0)
                 then "⏱ команда принята: открыть сеть на \($m.p.data.time // "?") с"
                 else "⏹ команда принята: закрыть сеть" end)
              else "✘ permit_join отвергнут: \($m.p.error // "без причины")" end)
    elif ($m.t | endswith("/bridge/event")) then
      $m.p as $e
      | .out = (
          if $e.type == "device_joined" then "→ вошёл в сеть: \(name($e.data))"
          elif $e.type == "device_announce" then "↺ анонсировал себя: \(name($e.data))"
          elif $e.type == "device_interview" then
            (if $e.data.status == "started" then "… интервью началось: \(name($e.data))"
             elif $e.data.status == "successful" then
               (if $e.data.supported == true
                then "✔ опознан: \(name($e.data)) — \($e.data.definition.description // "") (\($e.data.definition.vendor // "") \($e.data.definition.model // ""))"
                else "! интервью прошло, но модели нет в справочнике z2m: \(name($e.data))" end)
             else "✘ интервью не удалось: \(name($e.data)) — переопросите или сопрягите заново" end)
          elif $e.type == "device_leave" then "← покинул сеть: \(name($e.data))"
          else null end)
    else . end;
  select(.out != null) | "\(ts)  \(.out)")
JQ

if [ "$time_sec" -gt 0 ]; then
    log "наблюдаю ${base}/bridge/{event,info,response/permit_join} ${time_sec} с"
else
    log "наблюдаю ${base}/bridge/{event,info,response/permit_join} — Ctrl+C для выхода"
fi
# Истечение -W — штатный конец наблюдения, а не ошибка: mosquitto_sub при этом печатает
# «Timed out» и выходит с 27. Остальные коды (нет брокера, отказ авторизации) — настоящие.
set +e
compose exec -T mqtt mosquitto_sub -h localhost -u "$LOCAL_MQTT_USER" -P "$LOCAL_MQTT_PASSWORD" \
    "${limit[@]}" -v \
    -t "$base/bridge/event" -t "$base/bridge/response/permit_join" -t "$base/bridge/info" \
    2> >(grep -vx 'Timed out' >&2) \
    | jq -nR --unbuffered -r "$JQ_FORMAT"
rc="${PIPESTATUS[0]}"
set -e
case "$rc" in
    0|27) exit 0 ;;
    *) die "mosquitto_sub завершился с кодом $rc — брокер запущен? (make status)" ;;
esac
