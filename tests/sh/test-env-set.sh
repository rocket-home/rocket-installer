#!/usr/bin/env bash
# env-set.sh: обновление, добавление, спецсимволы, сохранение комментариев.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
export ENV_FILE="$tmp/.env"

cat >"$ENV_FILE" <<'EOF'
# комментарий сверху
FOO=old
BAR=keep
EOF

"$ROOT/scripts/env-set.sh" FOO "new value"
grep -qx 'FOO=new value' "$ENV_FILE" || { echo "FAIL: update"; exit 1; }
grep -qx 'BAR=keep' "$ENV_FILE" || { echo "FAIL: соседний ключ пострадал"; exit 1; }
grep -qx '# комментарий сверху' "$ENV_FILE" || { echo "FAIL: комментарий потерян"; exit 1; }

"$ROOT/scripts/env-set.sh" NEW_KEY "appended"
grep -qx 'NEW_KEY=appended' "$ENV_FILE" || { echo "FAIL: append"; exit 1; }

# спецсимволы: слэши, амперсанды, backslash (гроб awk -v), доллар
"$ROOT/scripts/env-set.sh" FOO 'a/b&c\d$e'
grep -qxF 'FOO=a/b&c\d$e' "$ENV_FILE" || { echo "FAIL: спецсимволы: $(grep ^FOO= "$ENV_FILE")"; exit 1; }

# невалидный ключ отклоняется
if "$ROOT/scripts/env-set.sh" 'bad-key' v 2>/dev/null; then
    echo "FAIL: невалидный ключ принят"; exit 1
fi

# значение с переводом строки отклоняется (инъекция ключей)
if "$ROOT/scripts/env-set.sh" FOO "$(printf 'a\nINJECTED=1')" 2>/dev/null; then
    echo "FAIL: перевод строки принят"; exit 1
fi
echo "env-set: OK"
