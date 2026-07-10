#!/usr/bin/env bash
# Проверка тулинга: таблица «инструмент / найдено / минимум / статус» + готовые
# команды установки под Ubuntu/Debian для каждого отсутствующего (паттерн infra).
# Exit 1, если чего-то из обязательного нет.
. "$(dirname "$0")/lib/common.sh"

declare -A HINTS=(
    [docker]='curl -fsSL https://get.docker.com | sudo sh'
    [compose]='curl -fsSL https://get.docker.com | sudo sh   # docker-compose-plugin входит в docker-ce'
    [jq]='sudo apt-get install -y jq'
    [envsubst]='sudo apt-get install -y gettext-base'
    [curl]='sudo apt-get install -y curl'
    [git]='sudo apt-get install -y git'
    [node]='curl -fsSL https://deb.nodesource.com/setup_22.x | sudo bash - && sudo apt-get install -y nodejs'
    [udevadm]='sudo apt-get install -y udev'
)

fail=0
row() { printf '%-12s %-28s %-10s %s\n' "$1" "$2" "$3" "$4"; }
row "Инструмент" "Найдено" "Минимум" "Статус"

check() {
    local name="$1" min="$2" required="$3" found status
    found="$4"
    if [ -z "$found" ]; then
        if [ "$required" = yes ]; then status="${_C_RED}НЕТ${_C_OFF}"; fail=1; else status="${_C_YEL}нет (опц.)${_C_OFF}"; fi
        row "$name" "—" "$min" "$status"
        log "    ↳ установка: ${HINTS[$name]:-см. документацию}"
    else
        row "$name" "$found" "$min" "${_C_GRN}OK${_C_OFF}"
    fi
}

ver_docker="";   command -v docker >/dev/null 2>&1 && ver_docker="$(docker --version 2>/dev/null | sed 's/,.*//;s/Docker version //')"
ver_compose="";  docker compose version >/dev/null 2>&1 && ver_compose="$(docker compose version --short 2>/dev/null)"
ver_jq="";       command -v jq >/dev/null 2>&1 && ver_jq="$(jq --version 2>/dev/null)"
ver_envsubst=""; command -v envsubst >/dev/null 2>&1 && ver_envsubst="есть"
ver_curl="";     command -v curl >/dev/null 2>&1 && ver_curl="$(curl --version 2>/dev/null | head -1 | awk '{print $2}')"
ver_git="";      command -v git >/dev/null 2>&1 && ver_git="$(git --version 2>/dev/null | awk '{print $3}')"
ver_node="";     command -v node >/dev/null 2>&1 && ver_node="$(node --version 2>/dev/null)"
ver_udevadm="";  command -v udevadm >/dev/null 2>&1 && ver_udevadm="есть"

check docker   "24+"  yes "$ver_docker"
check compose  "2.20+" yes "$ver_compose"
check jq       "1.6+" yes "$ver_jq"
check envsubst "—"    yes "$ver_envsubst"
check curl     "—"    yes "$ver_curl"
check git      "—"    no  "$ver_git"
check node     "18+"  no  "$ver_node"   # нужен только для TUI; make-цели работают без него
check udevadm  "—"    yes "$ver_udevadm"

if [ "$fail" -ne 0 ]; then
    err "Не хватает обязательных инструментов (см. команды установки выше)."
    exit 1
fi
ok "Все обязательные инструменты на месте."
