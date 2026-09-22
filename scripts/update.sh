#!/usr/bin/env bash
# Обновление zigbee2mqtt с проверкой матрицы совместимости:
#   stop z2m → probe прошивки → resolve-tag → сравнение с текущим → backup →
#   env-set Z2M_IMAGE_TAG → up → smoke.
# Несовместимый/неизвестный вариант — стоп с инструкцией (обход: TAG=x.y.z FORCE=1).
. "$(dirname "$0")/lib/common.sh"
require_cmd jq
load_env

current="$Z2M_IMAGE_TAG"
current_adapter="${Z2M_ADAPTER:-}"   # запоминаем ДО env-set: ниже сравниваем, менялся ли адаптер

if [ -n "${TAG:-}" ]; then
    target="$TAG"
    if [ "${FORCE:-}" != "1" ]; then
        die "ручной TAG=$TAG требует FORCE=1 (обход матрицы — на свой риск)"
    fi
    warn "обход матрицы: ставим $TAG принудительно"
else
    log "детект прошивки координатора…"
    probe_json="$("$ROCKET_ROOT/scripts/detect-firmware.sh")"
    family="$(jq -r '.family' <<<"$probe_json")"
    firmware="$(jq -r '.firmware' <<<"$probe_json")"
    model="$(jq -r '.model' <<<"$probe_json")"
    log "прошивка: family=$family firmware=${firmware:-?} model=${model:-?}"
    [ "$family" != "unknown" ] || die "координатор не распознан: $(jq -r '.error' <<<"$probe_json")"

    "$ROCKET_ROOT/scripts/env-set.sh" ADAPTER_FAMILY "$family"
    [ -n "$firmware" ] && "$ROCKET_ROOT/scripts/env-set.sh" FIRMWARE_VERSION "$firmware"

    resolved="$(FAMILY="$family" FIRMWARE="$firmware" MODEL="$model" "$ROCKET_ROOT/scripts/resolve-z2m-tag.sh")"
    if [ "$(jq -r '.ok' <<<"$resolved")" != "true" ]; then
        err "совместимого тега нет: $(jq -r '.advice' <<<"$resolved")"
        die "обход (на свой риск): make update TAG=$(jq -r '.fallback' <<<"$resolved") FORCE=1"
    fi
    target="$(jq -r '.recommended' <<<"$resolved")"
    advice="$(jq -r '.advice // empty' <<<"$resolved")"
    [ -n "$advice" ] && warn "$advice"
    adapter="$(jq -r '.adapter_override // .adapter' <<<"$resolved")"
    "$ROCKET_ROOT/scripts/env-set.sh" Z2M_ADAPTER "$adapter"
fi

# Выйти можно только если совпал И тег, И адаптер: env-set Z2M_ADAPTER выше уже случился, а
# строку `adapter:` в configuration.yaml пишет лишь gen-configs. Прежний ранний выход оставлял
# хаб с новым адаптером в .env и старым (или отсутствующим) в конфиге — z2m 2.x с таким не
# стартует вовсе.
if [ "$target" = "$current" ] && [ "${adapter:-$current_adapter}" = "$current_adapter" ]; then
    ok "уже на рекомендуемой версии: $current (адаптер: ${current_adapter:-автодетект})"
    exit 0
fi

log "обновление zigbee2mqtt: $current → $target"
log "бэкап перед обновлением…"
"$ROCKET_ROOT/scripts/backup.sh"

"$ROCKET_ROOT/scripts/env-set.sh" Z2M_IMAGE_TAG "$target"

# Конфиг — часть обновления, а не побочный эффект. Строку `adapter:` в configuration.yaml
# пишет ТОЛЬКО gen-configs (gen-configs.sh), а схема файла зависит от мажорной версии образа.
# Без этого шага z2m 2.x отказывается стартовать: "USB adapter discovery error (No valid USB
# adapter found)" — прогон 21.09.2026, руками лечилось FORCE=1 make gen-configs.
# FORCE=1 безопасен: устройства, группы и идентичность сети переносятся (lib/yaml-preserve.sh,
# тест tests/sh/test-gen-configs-preserve.sh), прежний файл остаётся рядом как .bak-<ts>.
FORCE=1 "$ROCKET_ROOT/scripts/gen-configs.sh"

compose up -d --build --force-recreate
"$ROCKET_ROOT/scripts/smoke-cloud.sh" || {
    err "smoke после обновления не прошёл; откат: make env-set KEY=Z2M_IMAGE_TAG VALUE=$current && FORCE=1 make gen-configs && make up"
    err "прежний configuration.yaml — рядом: data/zigbee2mqtt/configuration.yaml.bak-<время>"
    err "данные до обновления — в свежем архиве backups/ (make restore ARCHIVE=...)"
    exit 1
}
ok "zigbee2mqtt обновлён до $target"
