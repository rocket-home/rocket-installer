# Обновление прошивки EmberZNet (EFR32 / SONOFF ZBDongle-E / SLZB-06M)

Для zigbee2mqtt 2.x (драйвер `ember`) нужна прошивка **EZSP ≥ 7.4.x**
(см. `config/compatibility-matrix.json`).

1. Остановить стек: `make down`.
2. Прошивка: https://github.com/darkxst/silabs-firmware-builder (ncp-uart-hw для
   ZBDongle-E) — файл `.gbl`.
3. Прошить тем же инструментом, которым пользуется probe:

   ```bash
   docker run --rm --device /dev/ttyACM0 -v "$PWD":/fw rocket-probe:local \
     -c "universal-silabs-flasher --device /dev/zigbee flash --firmware /fw/ncp-uart-hw-….gbl" \
     || pipx run universal-silabs-flasher --device /dev/ttyACM0 flash --firmware ncp-uart-hw-….gbl
   ```

   (для SLZB-06M удобнее веб-интерфейс самого адаптера)

4. `make detect-firmware` — версия должна стать 7.4.x+.
5. `make up && make smoke`. Перед прошивкой: `make backup`.
