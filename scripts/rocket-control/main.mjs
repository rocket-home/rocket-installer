// rocket TUI — action-first меню (по образцу infra-control/main.mjs).
// TUI — тонкая оболочка над make: каждый пункт печатает и вызывает make-цель.
import { intro, outro, select, note, log } from "./io.mjs";
import { ensure, Cancelled } from "./prompts.mjs";
import { envExists, readEnv } from "./lib/env.mjs";
import { wizardSetup } from "./wizards/setup.mjs";
import {
  actionStatus,
  actionLogs,
  actionPermitJoin,
  actionUpdate,
  actionRelink,
  actionDoctor,
  actionBackup,
} from "./actions/day2.mjs";
import {
  settingsDevice,
  settingsCloud,
  settingsAddons,
} from "./settings/settings.mjs";

export const ACTIONS = [
  { value: "status",  label: "Статус",                   hint: "контейнеры, мост, токены, фронт" },
  { value: "logs",    label: "Логи",                     hint: "по сервису, снимок/поток" },
  { value: "permit",  label: "Permit join",              hint: "открыть/закрыть zigbee-сеть" },
  { value: "update",  label: "Обновить zigbee2mqtt",     hint: "по матрице совместимости, с бэкапом" },
  { value: "relink",  label: "Переподключить облако",    hint: "повторная OAuth-линковка + рестарт моста" },
  { value: "doctor",  label: "Doctor",                   hint: "диагностика всего сетапа" },
  { value: "backup",  label: "Бэкапы",                   hint: "сделать / восстановить" },
  { value: "set_device", label: "Настройки: стик" },
  { value: "set_cloud",  label: "Настройки: облако",     hint: "oauth ↔ static ↔ off" },
  { value: "set_addons", label: "Настройки: Node-RED" },
  { value: "wizard",  label: "Установка (визард)",       hint: "первичная настройка с нуля" },
  { value: "exit",    label: "Выход" },
];

const HANDLERS = {
  status: actionStatus,
  logs: actionLogs,
  permit: actionPermitJoin,
  update: actionUpdate,
  relink: actionRelink,
  doctor: actionDoctor,
  backup: actionBackup,
  set_device: settingsDevice,
  set_cloud: settingsCloud,
  set_addons: settingsAddons,
  wizard: wizardSetup,
};

export async function runRocket(argv = []) {
  intro("rocket — Rocket Home hub");

  if (argv.includes("--wizard")) {
    const ok = await wizardSetup();
    outro(ok ? "Установка завершена." : "Установка не завершена.");
    process.exitCode = ok ? 0 : 1;
    return;
  }

  if (!envExists()) {
    note("Конфигурация не найдена — начнём с визарда установки.", "Первый запуск");
    await wizardSetup();
  } else {
    const env = readEnv();
    note(
      `Облако: ${env.CLOUD_AUTH_MODE || "oauth"} · z2m: ${env.Z2M_IMAGE_TAG || "?"} · стик: ${env.ZIGBEE_DEVICE_BYID || "не задан"}`,
      "Конфигурация",
    );
  }

  for (;;) {
    let choice;
    try {
      choice = ensure(
        await select({ message: "rocket", options: ACTIONS, maxItems: 14 }),
      );
    } catch (e) {
      if (e instanceof Cancelled) break;
      throw e;
    }
    if (choice === "exit") break;

    const handler = HANDLERS[choice];
    if (!handler) {
      log.warn(`Неизвестный пункт меню: ${String(choice)}`);
      continue;
    }
    try {
      await handler();
    } catch (e) {
      if (e instanceof Cancelled) continue; // Escape в промпте → назад в меню
      log.error(String(e?.stack ?? e));
    }
  }

  outro("Завершено.");
}
