# rocket-installer

Установщик и менеджер эксплуатации **zigbee2mqtt + mosquitto** для Ubuntu/Debian с мостом
в облако умного дома [rocket-home.ru](https://rocket-home.ru/).

Исходники: [github.com/rocket-home/rocket-installer](https://github.com/rocket-home/rocket-installer).

## Быстрый старт (неподготовленный пользователь)

```bash
curl -fsSL https://rocket-home.ru/install.sh | bash
```

Скрипт поставит зависимости (docker, node), скачает инструмент в `/opt/rocket-home`
и запустит визард первичной настройки: найдёт zigbee-стик, определит прошивку,
подберёт совместимую версию zigbee2mqtt, слинкует машину с вашим аккаунтом
rocket-home.ru (вход по коду на сайте) и поднимет стек.

Визард интерактивен и берёт клавиатуру из `/dev/tty` — поэтому работает и тогда, когда сам
скрипт пришёл по пайпу от curl. Если терминала нет вовсе (cron, `ssh` без `-t`), установка
всё равно завершится, а визард можно запустить позже командой `rocket`. Поставить сразу без
визарда: `curl -fsSL https://rocket-home.ru/install.sh | bash -s -- --headless`.

Коды возврата визарда (по ним установщик решает, что сказать):

| Код | Что значит |
|-----|------------|
| 0   | установка завершена |
| 1   | шаг не выполнен — подробности выше по выводу |
| 3   | нет терминала для интерактивного ввода |
| 130 | отменено пользователем (Ctrl+C) |

## Опытному пользователю

Всё, что делает TUI, доступно make-целями (TUI печатает эквивалентную команду):

```bash
make help          # список целей
make check-tools   # проверка тулинга + команды установки
make env-init      # .env из шаблона (источник правды конфигурации)
make detect-device # найти стик
make oauth-link    # линковка с облаком (OAuth device grant)
make gen-configs   # рендер конфигов (с бэкапами .bak-*)
make up            # запуск стека (up -d --build --force-recreate)
make smoke         # сквозная проверка: локальный брокер → мост → облако
make doctor        # диагностика
make permit-join-on TIME=254   # открыть сеть для сопряжения
make pair-watch    # события сопряжения живьём: окно, вход, интервью (Ctrl+C — выход)
make z2m-log LEVEL=debug       # уровень лога z2m без рестарта
rocket             # TUI-менеджер (статус, логи, permit join, обновление, бэкапы)
```

Авторизация моста: `CLOUD_AUTH_MODE=oauth` (по умолчанию, токены в `secrets/tokens.json`,
ротацию ведёт token-agent внутри контейнера mosquitto) или `static`
(логин/пароль с [rocket-home.ru/profile/mqtt](https://rocket-home.ru/profile/mqtt)).

Матрица совместимости версий zigbee2mqtt и прошивок координаторов —
`config/compatibility-matrix.json` (обновляется при релизах z2m).

## Структура

- `Makefile` + `scripts/*.sh` — весь исполняемый слой (работает без Node);
- `scripts/rocket-control/` — TUI (Node ≥18, @clack/prompts), тонкая оболочка над make;
- `deploy/` — docker-compose стек (mosquitto с token-agent, zigbee2mqtt, node-red, probe);
  стек поднимается только через `make` / `scripts/compose.sh`: там считаются активные профили
  compose, в том числе `zigbee` — он включается сам, когда в `.env` указан существующий стик,
  и выключен на узле-мосте без него. Вручную: `COMPOSE_PROFILES=zigbee docker compose …`;
- `templates/` — envsubst-шаблоны конфигов;
- `.env` — конфигурация машины (создаётся `make env-init`, в git не попадает);
- `data/`, `secrets/` — рантайм-состояние (в git не попадает).

## Тесты

```bash
make test   # node --test (TUI на моках) + sh-тесты (без железа)
make lint   # shellcheck
```
