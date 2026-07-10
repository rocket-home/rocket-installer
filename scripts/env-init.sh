#!/usr/bin/env bash
# Идемпотентная инициализация .env из templates/env.tmpl (только if-not-exists,
# существующий .env никогда не перетирается) + автогенерация секретов для пустых
# автогенерируемых ключей.
. "$(dirname "$0")/lib/common.sh"

if [ ! -f "$ENV_FILE" ]; then
    cp "$ROCKET_ROOT/templates/env.tmpl" "$ENV_FILE"
    chmod 600 "$ENV_FILE"
    ok ".env создан из templates/env.tmpl"
else
    log ".env уже существует — не трогаю (правки: make env-set)"
fi

gen_secret() { head -c 32 /dev/urandom | od -An -tx1 | tr -d ' \n' | head -c 32; }

# Автогенерируемые секреты: только если ключ пуст.
for key in LOCAL_MQTT_PASSWORD Z2M_FRONTEND_AUTH_TOKEN; do
    if [ -z "$(env_get "$key")" ]; then
        "$ROCKET_ROOT/scripts/env-set.sh" "$key" "$(gen_secret)"
        ok "$key: сгенерирован"
    fi
done

mkdir -p "$SECRETS_DIR" "$DATA_DIR"
chmod 700 "$SECRETS_DIR"
