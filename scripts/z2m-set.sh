#!/usr/bin/env bash
# Настройки zigbee2mqtt на лету — через bridge/request/options (runtime-API z2m 1.x и 2.x).
#
#   z2m-set.sh log <debug|info|warning|error>   уровень лога; применяется без рестарта
#   z2m-set.sh tx-power <дБм>                    мощность передатчика; z2m попросит рестарт
#   z2m-set.sh unblock <ieee|all>                убрать из чёрного списка; z2m попросит рестарт
#   z2m-set.sh raw '<json>'                      произвольный объект options
#
# ЗАЧЕМ. Разбор сопряжения 23.09.2026: вход прибора и интервью z2m пишет на уровне info, а на
# хабе стоял warning — лог молчал, пока уровень не подняли. Править configuration.yaml и
# перезапускать z2m — это 10–40 с без zigbee-сети, а options-запрос применяет log_level
# мгновенно. Нужен ли рестарт после конкретной настройки, знает только z2m: он отвечает
# restart_required, и мы печатаем ровно то, что он сказал.
#
# Ответ ждём через mosquitto_rr: подписка на response-топик открывается ДО публикации запроса,
# иначе ответ можно проскочить (пара mosquitto_sub & + mosquitto_pub такой гарантии не даёт).
. "$(dirname "$0")/lib/common.sh"
require_cmd jq
load_env

base="${Z2M_BASE_TOPIC:-zigbee2mqtt}"
Z2M_RR_TIMEOUT="${Z2M_RR_TIMEOUT:-15}"

usage() {
    die "использование: z2m-set.sh log <debug|info|warning|error> | tx-power <дБм> | unblock <ieee|all> | raw '<json>'"
}

mqtt() {  # mqtt <клиент> <аргументы…> — mosquitto_* внутри контейнера брокера
    local client="$1"; shift
    compose exec -T mqtt "$client" -h localhost -u "$LOCAL_MQTT_USER" -P "$LOCAL_MQTT_PASSWORD" "$@"
}

# Текущий blocklist — из retained bridge/info (z2m кладёт туда весь config).
current_blocklist() {
    local info
    info="$(mqtt mosquitto_sub -t "$base/bridge/info" -C 1 -W 5 2>/dev/null || true)"
    [ -n "$info" ] || die "нет retained $base/bridge/info — zigbee2mqtt запущен? (make status)"
    jq -c '.config.blocklist // []' <<<"$info"
}

# apply <json options> — отправить и разобрать ответ. Код 0 = принято (даже если нужен рестарт).
apply() {
    local options="$1" payload response status
    payload="$(jq -cn --argjson o "$options" '{options: $o}')"
    response="$(mqtt mosquitto_rr -W "$Z2M_RR_TIMEOUT" \
        -t "$base/bridge/request/options" -e "$base/bridge/response/options" -m "$payload" 2>/dev/null || true)"
    [ -n "$response" ] \
        || die "zigbee2mqtt не ответил за ${Z2M_RR_TIMEOUT} с — он запущен? (make status, make logs SERVICE=zigbee2mqtt)"
    status="$(jq -r '.status // "?"' <<<"$response")"
    [ "$status" = "ok" ] || die "zigbee2mqtt отверг настройку: $(jq -r '.error // .' <<<"$response")"
    if [ "$(jq -r '.data.restart_required // false' <<<"$response")" = "true" ]; then
        ok "настройка записана в configuration.yaml"
        warn "вступит в силу после перезапуска zigbee2mqtt: make z2m-restart"
    else
        ok "настройка применена, рестарт не нужен"
    fi
}

cmd="${1:-}"; arg="${2:-}"
case "$cmd" in
    log)
        case "$arg" in
            debug|info|warning|error) ;;
            *) die "уровень лога: debug | info | warning | error (получено: '${arg}')" ;;
        esac
        apply "$(jq -cn --arg l "$arg" '{advanced: {log_level: $l}}')"
        ;;
    tx-power)
        # Диапазон Z-Stack/ember: до +20 дБм; отрицательные значения — тоже легальны (тесты
        # на стенде). Строгий разбор, чтобы «20 dBm» или пустота не улетели в z2m как строка.
        [[ "$arg" =~ ^-?[0-9]{1,2}$ ]] && [ "$arg" -ge -22 ] && [ "$arg" -le 20 ] \
            || die "мощность — целое число дБм от -22 до 20 (получено: '${arg}')"
        apply "$(jq -cn --argjson p "$arg" '{advanced: {transmit_power: $p}}')"
        ;;
    unblock)
        [ -n "$arg" ] || die "укажите ieee (0x…) или all"
        current="$(current_blocklist)"
        if [ "$arg" = "all" ]; then
            [ "$current" != "[]" ] || { ok "чёрный список уже пуст"; exit 0; }
            apply '{"blocklist": []}'
        else
            [[ "$arg" =~ ^0x[0-9a-fA-F]{16}$ ]] || die "ieee выглядит как 0x0011223344556677 (получено: '${arg}')"
            arg="${arg,,}"
            if ! jq -e --arg a "$arg" 'map(ascii_downcase) | index($a) != null' <<<"$current" >/dev/null; then
                ok "$arg и так не в чёрном списке (сейчас там: $current)"; exit 0
            fi
            apply "$(jq -c --arg a "$arg" '{blocklist: map(select(ascii_downcase != $a))}' <<<"$current")"
        fi
        ;;
    raw)
        if [ -z "$arg" ] || ! jq -e 'type == "object"' <<<"$arg" >/dev/null 2>&1; then
            die "raw ожидает JSON-объект options, например '{\"advanced\":{\"log_level\":\"info\"}}'"
        fi
        apply "$arg"
        ;;
    *) usage ;;
esac
