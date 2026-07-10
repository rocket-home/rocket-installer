# Обновление прошивки Z-Stack (CC2652 / SONOFF ZBDongle-P)

Матрица (`config/compatibility-matrix.json`) требует build-дату **20210708+**;
рекомендуемая — 20240710.

1. Остановить стек: `make down` (координатор должен быть свободен).
2. Скачать прошивку `CC1352P2_CC2652P_launchpad_coordinator_YYYYMMDD.hex` из
   https://github.com/Koenkk/Z-Stack-firmware (каталог coordinator).
3. Прошить без разборки донгла (BSL активируется автоматически):

   ```bash
   docker run --rm --device /dev/ttyUSB0 -v "$PWD":/fw python:3.12-slim bash -c \
     "pip -q install cc2538-bsl pyserial intelhex && \
      cc2538-bsl.py -p /dev/ttyUSB0 -evw --bootloader-sonoff-usb /fw/CC1352P2_CC2652P_launchpad_coordinator_20240710.hex"
   ```

4. `make detect-firmware` — убедиться, что версия обновилась.
5. `make up && make smoke`.

Сеть zigbee и спаренные устройства сохраняются (ключи лежат в NVRAM донгла и в
`data/zigbee2mqtt/`); бэкап перед прошивкой всё равно обязателен: `make backup`.
