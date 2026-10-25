# Обновление прошивки Z-Stack (CC2652 / CC1352)

Пользовательская инструкция — источник правды:
https://rocket-home.ru/docs/installation/firmware.html (janus,
`docs/source/installation/firmware.rst`). Здесь — шпаргалка с командами; меняешь процедуру —
правь сначала там.

Матрица (`config/compatibility-matrix.json`) требует build-дату **20210708+**;
рекомендуемая — 20250321.

1. `make backup && make down`. Mass erase (`-e`) стирает NVRAM вместе с сетью; при старте z2m
   вернёт её из `data/zigbee2mqtt/coordinator_backup.json`. Отдельный бэкап самого координатора
   (zigpy-znp уже есть в probe-образе, его собирает `make detect-firmware`):

   ```bash
   docker run --rm --device /dev/zigbee -v "$PWD":/fw --entrypoint sh rocket-probe:local -c \
     'python -m zigpy_znp.tools.network_backup /dev/zigbee -o /fw/network-backup.json'
   ```

   Восстановление — `zigpy_znp.tools.network_restore -i`. Файл содержит ключ сети.

2. Образ из https://github.com/Koenkk/Z-Stack-firmware/releases — по радиомодулю (таблица в
   README каталога `coordinator/Z-Stack_3.x.0`):

   | Модуль | Файл |
   |--------|------|
   | SONOFF ZBDongle-P, RFSTAR RF-BM-2652P2, TI LaunchPad CC1352P-2 | `CC1352P2_CC2652P_launchpad_*` |
   | Ebyte E72-2G4M20S1E, Ebyte E79 | `CC1352P2_CC2652P_other_*` (RF-ключ на DIO5/6) |
   | CC2652R / RB / R7, CC1352P7 | одноимённые `CC2652R_*`, `CC2652RB_*`, `CC2652R7_*`, `CC1352P7_*` |

   Модуль не опознать — смотри дамп текущего флеша: `BL_CONFIG` в CCFG (`0x57FD8` для 352 КБ)
   `c50ffec5` = загрузчик на DIO15 → P-семейство, `c50dfec5` = DIO13 → R/RB; флеш 704 КБ → `*7`.

3. Загрузчик. `--bootloader-sonoff-usb` работает только там, где DTR/RTS разведены на
   RESET/BOOT (ZBDongle-P). Остальные (например, E72 на CH340) — зажать BOOT и переподключить
   стик, флаг убрать. ROM-загрузчик синхронизируется один раз за вход, а cc2538-bsl в конце
   всегда шлёт Reset — поэтому стирание, запись и сверка одним вызовом `-evw`:

   ```bash
   docker run --rm --device /dev/ttyUSB0 -v "$PWD":/fw python:3.12-slim bash -c \
     "apt-get update -qq && apt-get install -y -qq git >/dev/null && \
      pip -q install pyserial intelhex git+https://github.com/JelmerT/cc2538-bsl.git@28cce97 && \
      cc2538-bsl -p /dev/ttyUSB0 -evw --bootloader-sonoff-usb /fw/CC1352P2_CC2652P_launchpad_coordinator_20250321.hex"
   ```

   На PyPI пакета `cc2538-bsl` нет — только из git, ревизия закреплена. Успех —
   `Verified (match: 0x…)`; `Timeout … after 'Synch'` = чип не в загрузчике.

4. `make detect-firmware` — версия должна обновиться.
5. `make update && make smoke`.

Стик уходит в другую сеть — `zigpy_znp.tools.nvram_reset` (возвращает и заводской IEEE) и
чистый каталог данных z2m: иначе z2m восстановит старую сеть из `coordinator_backup.json`.
