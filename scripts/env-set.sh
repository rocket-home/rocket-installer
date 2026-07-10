#!/usr/bin/env bash
# Идемпотентная запись одного ключа в .env с сохранением комментариев и порядка.
# Использование: env-set.sh KEY VALUE
. "$(dirname "$0")/lib/common.sh"

key="${1:?использование: env-set.sh KEY VALUE}"
value="${2-}"

[[ "$key" =~ ^[A-Z][A-Z0-9_]*$ ]] || die "недопустимое имя ключа: $key"
[ -f "$ENV_FILE" ] || die ".env не найден — запустите: make env-init"
case "$value" in *$'\n'*) die "значение не может содержать перевод строки";; esac

tmp="$(mktemp "$ENV_FILE.tmp.XXXXXX")"
if grep -q "^${key}=" "$ENV_FILE"; then
    # sed/awk -v с произвольным значением небезопасны (спецсимволы, backslash-эскейпы
    # awk -v) — значение передаём через окружение
    ROCKET_ENV_VALUE="$value" awk -v k="$key" \
        'BEGIN{FS="="; v=ENVIRON["ROCKET_ENV_VALUE"]} $1==k && !done {print k"="v; done=1; next} {print}' \
        "$ENV_FILE" >"$tmp"
else
    cat "$ENV_FILE" >"$tmp"
    printf '%s=%s\n' "$key" "$value" >>"$tmp"
fi
chmod 600 "$tmp"
mv "$tmp" "$ENV_FILE"
