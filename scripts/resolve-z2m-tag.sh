#!/usr/bin/env bash
# Подбор тега zigbee2mqtt по матрице совместимости.
# Входы: FAMILY, FIRMWARE, MODEL (env или позиционно: resolve-z2m-tag.sh [family] [firmware] [model]);
# по умолчанию берутся ADAPTER_FAMILY/FIRMWARE_VERSION из .env.
# Выход (stdout, JSON):
#   {"ok":bool, "family", "firmware", "recommended", "min", "max",
#    "adapter", "adapter_override", "advice", "fallback"}
# ok=false — совместимого тега нет (advice объясняет, что делать);
# fallback — legacy_stable для «продолжить на свой риск».
# Чистая функция от (матрица, family, firmware, model) — табличные тесты в tests/.
. "$(dirname "$0")/lib/common.sh"
require_cmd jq

FAMILY="${1:-${FAMILY:-$(env_get ADAPTER_FAMILY)}}"
FIRMWARE="${2:-${FIRMWARE:-$(env_get FIRMWARE_VERSION)}}"
MODEL="${3:-${MODEL:-}}"
MATRIX="${MATRIX:-$MATRIX_FILE}"

[ -n "$FAMILY" ] || die "семейство адаптера неизвестно: make detect-firmware или задайте FAMILY="

jq -n \
    --slurpfile m "$MATRIX" \
    --arg family "$FAMILY" \
    --arg fw "$FIRMWARE" \
    --arg model "$MODEL" '
# сравнение версий: semver и build-даты приводим к массивам чисел
def vparse: split(".") | map(tonumber? // 0);
def vlte(a; b): (a | vparse) <= (b | vparse);
def vgte(a; b): (a | vparse) >= (b | vparse);

$m[0] as $matrix
| $matrix.families[$family] as $f
| if $f == null then
    {ok: false, family: $family, firmware: $fw,
     advice: "Неизвестное семейство адаптера: \($family). Поддерживаются: \($matrix.families | keys | join(", ")).",
     fallback: $matrix.z2m.legacy_stable}
  else
    # первое совпавшее правило (пустой fw матчится только правилами без границ)
    ([ $f.rules[]
       | select(
           ((.firmware.min == null) or ($fw != "" and vgte($fw; .firmware.min)))
           and
           ((.firmware.max == null) or ($fw != "" and vlte($fw; .firmware.max)))
           and
           ((.firmware.min == null and .firmware.max == null) or ($fw != ""))
         )
     ] | first) as $rule
    | ($f.hardware_overrides[$model] // null) as $ovr
    | (if $ovr != null then $ovr else $rule end) as $eff
    | if $eff == null then
        {ok: false, family: $family, firmware: $fw,
         advice: "Прошивка \($fw) не найдена в матрице совместимости — обновите матрицу или прошивку (docs/).",
         fallback: $matrix.z2m.legacy_stable}
      elif ($eff.z2m.recommended // "") == "" then
        {ok: false, family: $family, firmware: $fw,
         advice: ($eff.advice // "Совместимого тега zigbee2mqtt нет."),
         fallback: $matrix.z2m.legacy_stable}
      else
        {ok: true, family: $family, firmware: $fw,
         recommended: $eff.z2m.recommended,
         min: ($eff.z2m.min // null), max: ($eff.z2m.max // null),
         adapter: $f.z2m_adapter,
         adapter_override: ($eff.adapter_override // $rule.adapter_override // null),
         advice: ($eff.advice // $rule.advice // null),
         fallback: $matrix.z2m.legacy_stable}
      end
  end'
