#!/usr/bin/env bash
# Слияние конфига zigbee2mqtt при перегенерации из шаблона.
#
# ЗАЧЕМ. Файлом configuration.yaml владеет сам z2m: он дописывает туда devices (с их
# retain/friendly_name), permit_join, groups и — главное — сетевые параметры
# (advanced.network_key, pan_id, ext_pan_id, channel). Шаблон установщика знает только
# свои ключи и печатает `devices: {}`. Тупая перегенерация = потеря устройств и, если
# ключ сети жил в файле, потеря самой сети (устройства придётся паровать заново).
#
# ЧТО ДЕЛАЕМ. Переносим из старого файла в новый:
#   1) top-level блоки, которых в шаблоне нет вовсе (devices, groups, ota, permit_join,
#      external_converters, device_options …);
#   2) подключи первого уровня внутри advanced:, которых нет в новом advanced:.
# Форматирование при этом наследуется от старого файла — он написан дампером z2m,
# отступ 2 пробела; своего YAML-парсера (и зависимости yq) не заводим.

# preserve_top_level_blocks <old> <new>
preserve_top_level_blocks() {
    local old="$1" new="$2" keys
    [ -f "$old" ] || return 0
    keys="$(mktemp)"
    awk '/^[A-Za-z_][A-Za-z0-9_-]*:/ { k=$0; sub(/:.*/, "", k); print k }' "$new" >"$keys"
    awk -v keysfile="$keys" '
        BEGIN { while ((getline k < keysfile) > 0) have[k] = 1 }
        /^[A-Za-z_][A-Za-z0-9_-]*:/ {
            key = $0; sub(/:.*/, "", key)
            keep = (key in have) ? 0 : 1
        }
        /^[^ \t]/ && !/^[A-Za-z_][A-Za-z0-9_-]*:/ { keep = 0 }
        keep { print }
    ' "$old" >>"$new"
    rm -f "$keys"
}

# preserve_advanced_subkeys <old> <new>
# Дописывает в блок advanced: нового файла подключи из старого, которых там нет
# (network_key, pan_id, ext_pan_id, channel, cache_state, …) — вместе с их вложенными строками.
preserve_advanced_subkeys() {
    local old="$1" new="$2" missing
    [ -f "$old" ] || return 0
    grep -q '^advanced:' "$old" || return 0
    missing="$(mktemp)"

    awk '
        /^advanced:/ { inblk = 1; next }
        /^[^ \t]/    { inblk = 0 }
        inblk && /^  [A-Za-z_]/ { k = $0; sub(/^  /, "", k); sub(/:.*/, "", k); print k }
    ' "$new" >"$missing.new"

    awk -v newkeys="$missing.new" '
        BEGIN { while ((getline k < newkeys) > 0) have[k] = 1 }
        /^advanced:/ { inblk = 1; next }
        /^[^ \t]/    { inblk = 0; keep = 0 }
        inblk && /^  [A-Za-z_]/ {
            k = $0; sub(/^  /, "", k); sub(/:.*/, "", k)
            keep = (k in have) ? 0 : 1
        }
        inblk && keep { print }
    ' "$old" >"$missing"

    if [ -s "$missing" ]; then
        awk -v addfile="$missing" '
            /^advanced:/ { inblk = 1; print; next }
            inblk && /^[^ \t]/ {
                while ((getline l < addfile) > 0) print l
                close(addfile); inblk = 0
            }
            { print }
            END { if (inblk) { while ((getline l < addfile) > 0) print l } }
        ' "$new" >"$new.merged" && mv "$new.merged" "$new"
    fi
    rm -f "$missing" "$missing.new"
}

# preserve_network_identity <old> <new>
# Идентичность сети (network_key, pan_id, ext_pan_id, channel) — из старого конфига.
#
# ПОЧЕМУ ОТДЕЛЬНО ОТ preserve_advanced_subkeys: тот переносит только ОТСУТСТВУЮЩИЕ подключи,
# а шаблон печатает `network_key: GENERATE` — ключ формально есть, и перенос не сработал бы.
#
# Случаев три, и третий стоил бы дома:
#  1) в старом ключ записан явно — он побеждает шаблонный GENERATE (значение бывает списком
#     в несколько строк, поэтому переносим блок целиком);
#  2) в старом стоит сам GENERATE — z2m ещё ни разу не стартовал, беречь нечего;
#  3) в старом ключа НЕТ ВОВСЕ — тогда шаблонный GENERATE ВЫРЕЗАЕТСЯ, а не остаётся.
#     Молчание конфига — рабочее состояние живого хаба: сеть держится NV координатора и
#     database.db, ключи в configuration.yaml не записаны (так переехал боевой хаб 21.09.2026).
#     GENERATE же означает «сделай новые ключи» — то есть переформирование сети и обход дома
#     с перепариванием каждого прибора. Оставить его там, где старый молчал, значило бы
#     разрушить сеть ровно тем путём, ради которого функция и написана.
preserve_network_identity() {
    local old="$1" new="$2" key blk
    [ -f "$old" ] || return 0
    for key in network_key pan_id ext_pan_id channel; do
        blk="$(awk -v k="$key" '
            /^advanced:/ { inblk = 1; next }
            /^[^ \t]/    { inblk = 0; grab = 0 }
            inblk && $0 ~ "^  " k ":" { grab = 1; print; next }
            inblk && grab && /^    / { print; next }
            inblk && grab { grab = 0 }
        ' "$old")"

        if [ -z "$blk" ]; then
            # Случай 3: старый молчал — вычищаем шаблонный ключ вместе с его комментарием,
            # иначе в конфиге останется пояснение про ключи, которых нет.
            awk -v k="$key" '
                /^advanced:/ { inblk = 1; print; next }
                inblk && /^[^ \t]/ { inblk = 0 }
                inblk && $0 ~ "^  #" { buf = buf $0 "\n"; next }
                inblk && $0 ~ "^  " k ":" { skip = 1; buf = ""; next }
                inblk && skip && /^    / { next }
                inblk && skip { skip = 0 }
                { printf "%s", buf; buf = ""; print }
                END { printf "%s", buf }
            ' "$new" >"$new.ni" && mv "$new.ni" "$new"
            continue
        fi

        case "$blk" in *GENERATE*) continue ;; esac   # случай 2

        # случай 1: вырезаем шаблонный блок ключа и вставляем сохранённый в конец advanced
        awk -v k="$key" -v repl="$blk" '
            /^advanced:/ { inblk = 1; print; next }
            inblk && /^[^ \t]/ { print repl; inblk = 0; print; next }
            inblk && $0 ~ "^  " k ":" { skip = 1; next }
            inblk && skip && /^    / { next }
            inblk && skip { skip = 0 }
            { print }
            END { if (inblk) print repl }
        ' "$new" >"$new.ni" && mv "$new.ni" "$new"
    done
}
