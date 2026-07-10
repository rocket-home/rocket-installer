#!/usr/bin/env bash
# Установщик Rocket Home hub для Ubuntu/Debian.
# Публикуется как https://rocket-home.ru/install.sh; запуск:
#   curl -fsSL https://rocket-home.ru/install.sh | bash
# Флаги (после bash -s --): --headless (без TUI-визарда), --dir=/opt/rocket-home,
#   --version=<git tag> (по умолчанию — последний релиз), --link (только симлинк rocket).
set -euo pipefail

REPO_URL="${ROCKET_REPO_URL:-https://s3.rocket-home.ru/installer/rocket-installer.git}"
INSTALL_DIR="/opt/rocket-home"
VERSION=""            # пусто = дефолтная ветка/последний релиз
HEADLESS=0
LINK_ONLY=0

for arg in "$@"; do
    case "$arg" in
        --headless) HEADLESS=1 ;;
        --link) LINK_ONLY=1 ;;
        --dir=*) INSTALL_DIR="${arg#--dir=}" ;;
        --version=*) VERSION="${arg#--version=}" ;;
        *) echo "неизвестный флаг: $arg" >&2; exit 2 ;;
    esac
done

say()  { printf '\033[32m▸\033[0m %s\n' "$*"; }
warn() { printf '\033[33m!\033[0m %s\n' "$*" >&2; }
die()  { printf '\033[31m✘\033[0m %s\n' "$*" >&2; exit 1; }

# ── Гварды ─────────────────────────────────────────────────────────────────────
[ -n "${BASH_VERSION:-}" ] || die "нужен bash"
case "$(uname -m)" in
    x86_64|aarch64|arm64) ;;
    *) die "неподдерживаемая архитектура: $(uname -m) (нужна amd64/arm64)" ;;
esac
if [ -r /etc/os-release ]; then
    # shellcheck disable=SC1091
    . /etc/os-release
    case "${ID:-} ${ID_LIKE:-}" in
        *debian*|*ubuntu*) ;;
        *) die "поддерживаются Ubuntu/Debian (обнаружено: ${PRETTY_NAME:-?})" ;;
    esac
else
    die "не удалось определить ОС (/etc/os-release отсутствует)"
fi

SUDO=""
if [ "$(id -u)" -ne 0 ]; then
    command -v sudo >/dev/null 2>&1 || die "нужен root или sudo"
    SUDO="sudo"
    say "потребуются права sudo (установка пакетов, docker, каталог $INSTALL_DIR)"
fi
TARGET_USER="${SUDO_USER:-$USER}"

link_rocket() {
    if [ -w /usr/local/bin ] 2>/dev/null; then
        ln -sf "$INSTALL_DIR/bin/rocket" /usr/local/bin/rocket
    else
        $SUDO ln -sf "$INSTALL_DIR/bin/rocket" /usr/local/bin/rocket
    fi
    say "команда доступна: rocket"
}

if [ "$LINK_ONLY" = "1" ]; then
    link_rocket
    exit 0
fi

# ── Базовые пакеты ─────────────────────────────────────────────────────────────
say "базовые пакеты (curl, git, jq, gettext-base)…"
export DEBIAN_FRONTEND=noninteractive
$SUDO apt-get update -qq
$SUDO apt-get install -y -qq ca-certificates curl git jq gettext-base udev >/dev/null

# ── Docker ─────────────────────────────────────────────────────────────────────
# get.docker.com: свежий docker-ce + docker-compose-plugin единообразно на обеих ОС
# (в дистрибутивных репах docker.io без compose-плагина либо устаревший).
if docker compose version >/dev/null 2>&1; then
    say "docker + compose уже установлены — пропуск"
else
    say "устанавливаю Docker (get.docker.com)…"
    curl -fsSL https://get.docker.com | $SUDO sh
fi

# ── Node.js (для TUI) ──────────────────────────────────────────────────────────
node_ok() { command -v node >/dev/null 2>&1 && [ "$(node -e 'console.log(process.versions.node.split(".")[0])')" -ge 18 ]; }
if node_ok; then
    say "Node.js $(node --version) уже установлен — пропуск"
else
    say "устанавливаю Node.js 22 LTS (NodeSource)…"
    curl -fsSL https://deb.nodesource.com/setup_22.x | $SUDO bash - >/dev/null
    $SUDO apt-get install -y -qq nodejs >/dev/null
fi

# ── Группы ─────────────────────────────────────────────────────────────────────
for grp in docker dialout; do
    if getent group "$grp" >/dev/null && ! id -nG "$TARGET_USER" | tr ' ' '\n' | grep -qx "$grp"; then
        $SUDO usermod -aG "$grp" "$TARGET_USER"
        warn "пользователь $TARGET_USER добавлен в $grp — полноценно после перелогина"
    fi
done

# ── Код ────────────────────────────────────────────────────────────────────────
if [ -d "$INSTALL_DIR/.git" ]; then
    say "обновляю $INSTALL_DIR…"
    $SUDO git -C "$INSTALL_DIR" fetch --tags --quiet
else
    say "скачиваю rocket-installer → $INSTALL_DIR…"
    $SUDO git clone --quiet "$REPO_URL" "$INSTALL_DIR"
fi
if [ -z "$VERSION" ]; then
    VERSION="$($SUDO git -C "$INSTALL_DIR" tag --list 'v*' --sort=-v:refname | head -1)"
fi
if [ -n "$VERSION" ]; then
    $SUDO git -C "$INSTALL_DIR" checkout --quiet "$VERSION"
    say "версия: $VERSION"
else
    warn "релизных тегов нет — использую дефолтную ветку"
fi
$SUDO chown -R "$TARGET_USER" "$INSTALL_DIR"

say "зависимости TUI (npm ci)…"
(cd "$INSTALL_DIR" && npm ci --omit=dev --silent)

link_rocket

# ── Первичная настройка ────────────────────────────────────────────────────────
if [ "$HEADLESS" = "1" ]; then
    say "headless: визард пропущен."
    say "дальше:  cd $INSTALL_DIR && make env-init && \$EDITOR .env && make gen-configs up smoke"
    exit 0
fi

say "запускаю визард первичной настройки…"
# docker-группа ещё не действует в этой сессии — компенсируем sg docker, если надо
if docker info >/dev/null 2>&1; then
    make -C "$INSTALL_DIR" setup
else
    sg docker -c "make -C '$INSTALL_DIR' setup" \
        || die "docker недоступен: перелогиньтесь и запустите: rocket"
fi
