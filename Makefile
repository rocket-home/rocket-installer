# rocket-installer — исполняемый слой. TUI (rocket) — тонкая оболочка над этими целями:
# каждый пункт меню печатает и вызывает make-цель, всё воспроизводимо без TUI.
SHELL := /usr/bin/env bash
ROOT  := $(abspath $(dir $(lastword $(MAKEFILE_LIST))))
ENV_FILE ?= $(ROOT)/.env
export ROCKET_ROOT := $(ROOT)
export ENV_FILE

# Имя проекта — явно (см. compose() в scripts/lib/common.sh): без -p им стало бы "deploy"
# у любой копии репо, и копии делили бы контейнеры и volume.
COMPOSE_PROJECT_NAME ?= rocket-home
export COMPOSE_PROJECT_NAME
# Через scripts/compose.sh, а не напрямую: имя проекта, env-файл и — главное — набор
# активных профилей (профиль zigbee включается по наличию стика) считает compose() в
# scripts/lib/common.sh. Своя строка здесь означала бы второй, расходящийся набор сервисов.
COMPOSE = $(ROOT)/scripts/compose.sh

.DEFAULT_GOAL := help

.PHONY: help
help: ## Список целей
	@grep -hE '^[a-z][a-z0-9-]*:.*##' $(MAKEFILE_LIST) | awk 'BEGIN{FS=":.*## "} {printf "  \033[36m%-18s\033[0m %s\n", $$1, $$2}'

## ── Подготовка ────────────────────────────────────────────────────────────────

.PHONY: check-tools
check-tools: ## Проверить тулинг (docker, jq, envsubst, …) с командами установки
	@$(ROOT)/scripts/check-tools.sh

.PHONY: env-init
env-init: ## Создать .env из шаблона (идемпотентно) + автогенерация секретов
	@$(ROOT)/scripts/env-init.sh

.PHONY: env-set
env-set: ## Записать ключ в .env: make env-set KEY=... VALUE=...
	@$(ROOT)/scripts/env-set.sh "$(KEY)" "$(VALUE)"

.PHONY: udev-install
udev-install: ## Установить udev-правила стика и добавить пользователя в dialout/docker (sudo)
	@$(ROOT)/scripts/udev-install.sh

.PHONY: detect-device
detect-device: ## Найти zigbee-стики (JSON-список кандидатов)
	@$(ROOT)/scripts/detect-device.sh

.PHONY: detect-firmware
detect-firmware: ## Определить семейство/прошивку координатора (probe-контейнер, JSON)
	@$(ROOT)/scripts/detect-firmware.sh

.PHONY: resolve-tag
resolve-tag: ## Подобрать тег zigbee2mqtt по матрице совместимости (JSON)
	@$(ROOT)/scripts/resolve-z2m-tag.sh

.PHONY: oauth-link
oauth-link: ## Линковка с rocket-home.ru (OAuth device grant) → secrets/tokens.json
	@$(ROOT)/scripts/oauth-link.sh

.PHONY: relink
relink: oauth-link ## Повторная линковка + перезапуск моста
	@$(COMPOSE) restart mqtt

.PHONY: import-legacy
import-legacy: ## Импорт живого хаба со старого стека: make import-legacy [LEGACY_DIR=... | LEGACY_CONTAINER=...]
	@$(ROOT)/scripts/import-legacy.sh

.PHONY: gen-configs
gen-configs: ## Сгенерировать конфиги (zigbee2mqtt, мост) из шаблонов с бэкапами
	@$(ROOT)/scripts/gen-configs.sh

## ── Стек ──────────────────────────────────────────────────────────────────────

.PHONY: up
up: ## Запустить/пересоздать стек (применяет новый device/env — не plain restart!)
	@$(ROOT)/scripts/check-device.sh
	@$(COMPOSE) up -d --build --force-recreate

.PHONY: down
down: ## Остановить стек (данные сохраняются)
	@$(COMPOSE) down

.PHONY: restart
restart: up ## Синоним up: только force-recreate применяет device/env

.PHONY: status
status: ## Состояние контейнеров, моста и токенов
	@$(ROOT)/scripts/status.sh

.PHONY: logs
logs: ## Логи: make logs [SERVICE=mqtt|zigbee2mqtt|nodered] [TAIL=100] [FOLLOW=1]
	@if [ "$(FOLLOW)" = "1" ]; then \
		$(COMPOSE) logs -f --tail=$(or $(TAIL),100) $(SERVICE); \
	else \
		$(COMPOSE) logs --tail=$(or $(TAIL),100) $(SERVICE); \
	fi

.PHONY: smoke
smoke: ## Сквозная проверка: локальный брокер, мост в облако, фронт z2m
	@$(ROOT)/scripts/smoke-cloud.sh

.PHONY: doctor
doctor: ## Диагностика всего сетапа (накапливает ошибки, не падает на первой)
	@$(ROOT)/scripts/doctor.sh

## ── Эксплуатация ──────────────────────────────────────────────────────────────

.PHONY: permit-join-on
permit-join-on: ## Открыть сеть для подключения устройств: make permit-join-on [TIME=254]
	@$(ROOT)/scripts/permit-join.sh on $(or $(TIME),254)

.PHONY: permit-join-off
permit-join-off: ## Закрыть сеть
	@$(ROOT)/scripts/permit-join.sh off

.PHONY: pair-watch
pair-watch: ## Живой поток событий сопряжения (окно, вход, интервью): make pair-watch [TIME=сек]
	@$(ROOT)/scripts/pair-watch.sh $(or $(TIME),0)

.PHONY: z2m-log
z2m-log: ## Уровень лога z2m без рестарта: make z2m-log LEVEL=debug|info|warning|error
	@$(ROOT)/scripts/z2m-set.sh log "$(LEVEL)"

.PHONY: z2m-tx-power
z2m-tx-power: ## Мощность передатчика координатора, дБм (потом make z2m-restart): make z2m-tx-power DBM=20
	@$(ROOT)/scripts/z2m-set.sh tx-power "$(DBM)"

.PHONY: z2m-unblock
z2m-unblock: ## Убрать прибор из чёрного списка z2m: make z2m-unblock IEEE=0x…|all
	@$(ROOT)/scripts/z2m-set.sh unblock "$(IEEE)"

.PHONY: z2m-restart
z2m-restart: ## Перезапустить только zigbee2mqtt (после настроек, требующих рестарта)
	@$(COMPOSE) restart zigbee2mqtt

.PHONY: update
update: ## Обновить zigbee2mqtt по матрице: stop z2m → probe → resolve → backup → up
	@$(ROOT)/scripts/update.sh

.PHONY: backup
backup: ## Бэкап data/ + secrets/ + .env (останавливает z2m на время tar)
	@$(ROOT)/scripts/backup.sh

.PHONY: restore
restore: ## Восстановление из бэкапа: make restore ARCHIVE=path.tar.gz
	@$(ROOT)/scripts/restore.sh "$(ARCHIVE)"

## ── TUI / разработка ──────────────────────────────────────────────────────────

.PHONY: setup
setup: ## Визард первичной установки (TUI)
	@node $(ROOT)/scripts/rocket.mjs --wizard

.PHONY: test
test: ## Тесты: node --test (TUI) + sh-тесты
	@cd $(ROOT) && node --test --experimental-test-module-mocks scripts/rocket-control/__tests__/
	@$(ROOT)/tests/run.sh

.PHONY: lint
lint: ## shellcheck (warning+) на все скрипты
	@shellcheck --severity=warning $(ROOT)/scripts/*.sh $(ROOT)/scripts/lib/*.sh \
		$(ROOT)/deploy/mosquitto/*.sh $(ROOT)/install.sh $(ROOT)/bin/rocket \
		$(ROOT)/tests/run.sh $(ROOT)/tests/sh/*.sh
