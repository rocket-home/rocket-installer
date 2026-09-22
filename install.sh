#!/usr/bin/env bash
# Установщик Rocket Home hub для Ubuntu/Debian.
# Публикуется как https://rocket-home.ru/install.sh; запуск:
#   curl -fsSL https://rocket-home.ru/install.sh | bash
# Флаги (после bash -s --): --headless (без TUI-визарда), --dir=/opt/rocket-home,
#   --version=<git tag> (по умолчанию — последний релиз), --link (только симлинк rocket).
set -euo pipefail

REPO_URL="${ROCKET_REPO_URL:-https://github.com/rocket-home/rocket-installer.git}"
INSTALL_DIR="/opt/rocket-home"
# Не VERSION: /etc/os-release экспортирует свою VERSION и перетёр бы её
ROCKET_VERSION=""     # пусто = дефолтная ветка/последний релиз
HEADLESS=0
LINK_ONLY=0

for arg in "$@"; do
    case "$arg" in
        --headless) HEADLESS=1 ;;
        --link) LINK_ONLY=1 ;;
        --dir=*) INSTALL_DIR="${arg#--dir=}" ;;
        --version=*) ROCKET_VERSION="${arg#--version=}" ;;
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
    # os-release читаем в сабшелле: он определяет VERSION/ID/NAME и затёр бы
    # одноимённые переменные скрипта
    os_id="$(. /etc/os-release && printf '%s %s' "${ID:-}" "${ID_LIKE:-}")"
    case "$os_id" in
        *debian*|*ubuntu*) ;;
        *) die "поддерживаются Ubuntu/Debian (обнаружено: $os_id)" ;;
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
say "базовые пакеты (make, curl, git, jq, gettext-base)…"
export DEBIAN_FRONTEND=noninteractive
$SUDO apt-get update -qq
# make обязателен: весь инструмент — make-цели (на cloud-образах его нет)
$SUDO apt-get install -y -qq make ca-certificates curl git jq gettext-base udev >/dev/null

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
# npm проверяем ОТДЕЛЬНО от node, а не заодно: в Debian/Ubuntu `nodejs` и `npm` — разные
# пакеты, и машина с node из apt npm'а не имеет. Проверка одного лишь node говорила
# «уже установлен — пропуск», а установка падала двадцатью строками ниже на `npm ci` —
# с уже склонированным кодом, без зависимостей TUI и без симлинка rocket.
node_ok() { command -v node >/dev/null 2>&1 && [ "$(node -e 'console.log(process.versions.node.split(".")[0])')" -ge 18 ]; }
npm_ok()  { command -v npm >/dev/null 2>&1; }
if node_ok && npm_ok; then
    say "Node.js $(node --version) и npm $(npm --version) уже установлены — пропуск"
elif node_ok; then
    # node устраивает — не трогаем его (им может пользоваться что-то ещё), ставим только npm
    say "Node.js $(node --version) есть, npm нет — ставлю npm…"
    $SUDO apt-get install -y -qq npm >/dev/null 2>&1 || true
    npm_ok || {
        warn "пакет npm недоступен — ставлю Node.js 22 LTS (NodeSource), он несёт npm с собой"
        curl -fsSL https://deb.nodesource.com/setup_22.x | $SUDO bash - >/dev/null
        $SUDO apt-get install -y -qq nodejs >/dev/null
    }
else
    say "устанавливаю Node.js 22 LTS (NodeSource)…"
    curl -fsSL https://deb.nodesource.com/setup_22.x | $SUDO bash - >/dev/null
    $SUDO apt-get install -y -qq nodejs >/dev/null
fi
npm_ok || die "npm так и не появился — поставьте вручную и повторите"

# ── Группы ─────────────────────────────────────────────────────────────────────
for grp in docker dialout; do
    if getent group "$grp" >/dev/null && ! id -nG "$TARGET_USER" | tr ' ' '\n' | grep -qx "$grp"; then
        $SUDO usermod -aG "$grp" "$TARGET_USER"
        warn "пользователь $TARGET_USER добавлен в $grp — полноценно после перелогина"
    fi
done

# ── Код ────────────────────────────────────────────────────────────────────────
existing_install=0
if [ -d "$INSTALL_DIR/.git" ]; then
    existing_install=1
    say "обновляю $INSTALL_DIR…"
    $SUDO git -C "$INSTALL_DIR" fetch --tags --quiet
else
    say "скачиваю rocket-installer → $INSTALL_DIR…"
    $SUDO git clone --quiet "$REPO_URL" "$INSTALL_DIR"
fi
if [ -z "$ROCKET_VERSION" ]; then
    ROCKET_VERSION="$($SUDO git -C "$INSTALL_DIR" tag --list 'v*' --sort=-v:refname | head -1)"
fi
if [ -n "$ROCKET_VERSION" ]; then
    $SUDO git -C "$INSTALL_DIR" checkout --quiet "$ROCKET_VERSION"
    say "версия: $ROCKET_VERSION"
else
    warn "релизных тегов нет — использую дефолтную ветку"
    # существующая установка: fetch без checkout оставил бы старый код
    if [ "$existing_install" = "1" ]; then
        $SUDO git -C "$INSTALL_DIR" pull --ff-only --quiet
    fi
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

# Мастер интерактивен. Если терминала нет вовсе (cron, ssh без -t, provisioning-скрипт) —
# это не авария: код установлен, команда rocket заведена, просто настройку делают позже.
# Проверяем через открытие /dev/tty, а НЕ через `exec </dev/tty`: при `curl | bash` bash
# дочитывает текст этого скрипта из fd 0, и глобальный редирект украл бы у него остаток.
if ! { [ -t 0 ] || : </dev/tty; } 2>/dev/null; then
    warn "нет управляющего терминала — визард пропущен (установка при этом завершена)"
    say "настройте позже:  rocket        # или: cd $INSTALL_DIR && make setup"
    say "либо без мастера: cd $INSTALL_DIR && make env-init && \$EDITOR .env && make gen-configs up smoke"
    exit 0
fi

# Docker проверяем ОТДЕЛЬНО от визарда. Раньше `|| die "docker недоступен"` висел на всём
# запуске мастера, поэтому любой его ненулевой код приписывался докеру: пользователь читал
# «перелогиньтесь», хотя docker был исправен, а мастер падал совсем по другой причине.
if docker info >/dev/null 2>&1; then
    wizard_cmd=("$INSTALL_DIR/bin/rocket" --wizard)          # группа docker уже действует
elif sg docker -c 'docker info' >/dev/null 2>&1; then
    wizard_cmd=(sg docker -c "'$INSTALL_DIR/bin/rocket' --wizard")   # компенсируем группу
else
    die "docker недоступен: перелогиньтесь и запустите: rocket"
fi

say "запускаю визард первичной настройки…"
say "эквивалент вручную: cd $INSTALL_DIR && make setup"
# Зовём bin/rocket, а не `make setup`: make схлопывает ЛЮБОЙ код рецепта в свой 2, и коды
# «нет терминала» (3) и «отменено пользователем» (130) до нас бы не доехали.
rc=0
"${wizard_cmd[@]}" || rc=$?
case "$rc" in
    0)   say "готово." ;;
    3)   die "нет терминала для мастера: запустите его сами — rocket (или переустановите с --headless)" ;;
    130) warn "установка отменена — продолжить: rocket"; exit 130 ;;
    *)   die "визард завершился с ошибкой (код $rc) — подробности выше; повторить: rocket" ;;
esac
