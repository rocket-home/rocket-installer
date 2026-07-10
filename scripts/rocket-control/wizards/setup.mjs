// Визард первичной установки: стик → прошивка → тег z2m → облако → аддоны →
// конфиги → запуск → smoke. Каждый шаг печатает make-эквивалент и пропускаем.
import { note, log, select, confirm, text } from "../io.mjs";
import { ensure, promptDangerous, runMakeStep, Cancelled } from "../prompts.mjs";
import { runMakeCapture, formatMakeCommand } from "../lib/make.mjs";
import { readEnv } from "../lib/env.mjs";
import { realpathSync } from "node:fs";

const TITLE = "Установка Rocket Home hub";
const TOTAL = 9;
const step = (n, name) => `${TITLE} · шаг ${n}/${TOTAL} · ${name}`;

async function envSet(key, value) {
  const args = [`KEY=${key}`, `VALUE=${value}`];
  log.step(`→ ${formatMakeCommand("env-set", [`KEY=${key}`, "VALUE=…"])}`);
  const { code } = await runMakeCapture("env-set", { extraArgs: args });
  if (code !== 0) throw new Error(`env-set ${key}: exit ${code}`);
}

async function captureJson(target, options = {}) {
  log.step(`→ ${formatMakeCommand(target, options.extraArgs ?? [])}`);
  const { code, stdout } = await runMakeCapture(target, options);
  if (code !== 0) return null;
  try {
    return JSON.parse(stdout);
  } catch {
    return null;
  }
}

async function stepTools() {
  note("Проверяю тулинг (docker, jq, envsubst…).", step(1, "Тулинг"));
  const { code } = await runMakeStep("check-tools");
  if (code !== 0) {
    log.error("Не хватает инструментов — установите по подсказкам выше и перезапустите визард.");
    return false;
  }
  await runMakeStep("env-init");
  return true;
}

async function stepDevice() {
  note("Ищу zigbee-стик.", step(2, "Стик"));
  const found = (await captureJson("detect-device")) ?? [];
  const options = found.map((d) => ({
    value: d,
    label: `${d.path}${d.description ? ` — ${d.description}` : ""}`,
    hint: d.known ? `похоже: ${d.family}` : "неизвестный VID:PID",
  }));
  options.push({ value: "manual", label: "Указать путь вручную…" });
  options.push({ value: "skip", label: "Пропустить (настрою позже)" });

  const choice = ensure(
    await select({ message: "Какой стик использовать?", options }),
  );
  if (choice === "skip") return true;

  let byid;
  let real;
  let family = "";
  if (choice === "manual") {
    byid = ensure(
      await text({
        message: "Путь к устройству (например /dev/serial/by-id/usb-…):",
        validate: (v) => (v && v.startsWith("/dev/") ? undefined : "нужен путь в /dev/"),
      }),
    );
    try {
      real = realpathSync(byid);
    } catch {
      log.error(`${byid}: устройство не найдено`);
      return false;
    }
  } else {
    byid = choice.path;
    real = choice.realpath;
    family = choice.family ?? "";
  }
  await envSet("ZIGBEE_DEVICE_BYID", byid);
  await envSet("ZIGBEE_DEVICE_HOST", real);
  if (family) await envSet("ADAPTER_FAMILY", family);
  log.success(`Стик: ${byid} (устройство: ${real})`);

  const doUdev = ensure(
    await confirm({
      message: "Установить udev-правила и добавить пользователя в dialout/docker (нужен sudo)?",
    }),
  );
  if (doUdev) await runMakeStep("udev-install");
  return true;
}

async function stepFirmware() {
  note(
    "Определяю семейство и прошивку координатора (probe-контейнер, ~1 мин).",
    step(3, "Прошивка"),
  );
  const run = ensure(await confirm({ message: "Запустить автоопределение прошивки?" }));
  if (run) {
    const probe = await captureJson("detect-firmware");
    if (probe && probe.family !== "unknown") {
      await envSet("ADAPTER_FAMILY", probe.family);
      if (probe.firmware) await envSet("FIRMWARE_VERSION", probe.firmware);
      log.success(
        `Координатор: ${probe.family}, прошивка ${probe.firmware || "?"}${probe.model ? ` (${probe.model})` : ""}`,
      );
      return true;
    }
    log.warn(`Автоопределение не удалось${probe?.error ? `: ${probe.error}` : ""}.`);
  }
  const family = ensure(
    await select({
      message: "Семейство адаптера (вручную):",
      options: [
        { value: "zstack", label: "TI Z-Stack (ZBDongle-P, CC2652, CC2531)" },
        { value: "ember", label: "Silicon Labs EFR32 (ZBDongle-E, SLZB-06M)" },
        { value: "deconz", label: "ConBee / RaspBee" },
        { value: "zigate", label: "ZiGate" },
        { value: "skip", label: "Не знаю — пропустить" },
      ],
    }),
  );
  if (family === "skip") return true;
  await envSet("ADAPTER_FAMILY", family);
  const fw = ensure(
    await text({
      message: "Версия прошивки, если известна (Enter — пропустить):",
      defaultValue: "",
    }),
  );
  if (fw) await envSet("FIRMWARE_VERSION", fw);
  return true;
}

async function stepTag() {
  note("Подбираю совместимую версию zigbee2mqtt по матрице.", step(4, "Версия z2m"));
  const env = readEnv();
  if (!env.ADAPTER_FAMILY) {
    log.warn(
      `Семейство неизвестно — оставляю консервативный тег ${env.Z2M_IMAGE_TAG} (обновить позже: make update).`,
    );
    return true;
  }
  const res = await captureJson("resolve-tag");
  if (!res) {
    log.warn("resolve-tag не дал ответа — оставляю текущий тег.");
    return true;
  }
  if (res.ok) {
    if (res.advice) log.warn(res.advice);
    const apply = ensure(
      await confirm({
        message: `Рекомендуемая версия zigbee2mqtt: ${res.recommended}. Применить?`,
      }),
    );
    if (apply) {
      await envSet("Z2M_IMAGE_TAG", res.recommended);
      await envSet("Z2M_ADAPTER", res.adapter_override ?? res.adapter ?? "");
    }
    return true;
  }
  log.error(res.advice ?? "Совместимого тега нет.");
  const risky = await promptDangerous(
    `Продолжить на свой риск с legacy-версией ${res.fallback}?`,
  );
  if (!risky) return false;
  await envSet("Z2M_IMAGE_TAG", res.fallback);
  return true;
}

async function stepCloud() {
  note("Подключение к облаку rocket-home.ru.", step(5, "Облако"));
  const mode = ensure(
    await select({
      message: "Способ авторизации:",
      options: [
        {
          value: "oauth",
          label: "Войти через rocket-home.ru (рекомендуется)",
          hint: "код на сайте, без ручных паролей",
        },
        {
          value: "static",
          label: "Логин/пароль MQTT",
          hint: "креды со страницы rocket-home.ru/profile/mqtt",
        },
        { value: "off", label: "Без облака (только локально)" },
      ],
    }),
  );
  await envSet("CLOUD_AUTH_MODE", mode);
  if (mode === "oauth") {
    const { code } = await runMakeStep("oauth-link");
    if (code !== 0) {
      log.warn("Линковка не завершена — можно повторить позже: make oauth-link");
    }
  } else if (mode === "static") {
    const user = ensure(
      await text({
        message: "Логин MQTT (UUID со страницы профиля):",
        validate: (v) => (v ? undefined : "обязательное поле"),
      }),
    );
    const pass = ensure(
      await text({
        message: "Пароль MQTT:",
        validate: (v) => (v ? undefined : "обязательное поле"),
      }),
    );
    await envSet("CLOUD_MQTT_USERNAME", user);
    await envSet("CLOUD_MQTT_PASSWORD", pass);
  }
  return true;
}

async function stepAddons() {
  note("Дополнительно.", step(6, "Аддоны"));
  const nodered = ensure(
    await confirm({ message: "Установить Node-RED (локальные автоматизации)?", initialValue: false }),
  );
  await envSet("COMPOSE_PROFILES", nodered ? "nodered" : "");
  return true;
}

async function stepConfigs() {
  note("Генерирую конфиги (с бэкапами .bak-*).", step(7, "Конфиги"));
  const { code } = await runMakeStep("gen-configs");
  return code === 0;
}

async function stepUp() {
  note("Запускаю стек (docker build + up, первый раз — несколько минут).", step(8, "Запуск"));
  const { code } = await runMakeStep("up");
  return code === 0;
}

async function stepSmoke() {
  note("Сквозная проверка.", step(9, "Проверка"));
  const { code } = await runMakeStep("smoke");
  const env = readEnv();
  note(
    [
      `Веб-интерфейс zigbee2mqtt: http://<ip-машины>:${env.Z2M_FRONTEND_PORT || 4000}/`,
      `  токен входа: ${env.Z2M_FRONTEND_AUTH_TOKEN || "(см. .env)"}`,
      env.COMPOSE_PROFILES?.includes("nodered") ? "Node-RED: http://<ip-машины>:1880/" : null,
      "Устройства: rocket → «Permit join», затем режим сопряжения на устройстве.",
      "Панель облака: https://rocket-home.ru/",
    ]
      .filter(Boolean)
      .join("\n"),
    "Готово",
  );
  return code === 0;
}

export async function wizardSetup() {
  const steps = [
    stepTools,
    stepDevice,
    stepFirmware,
    stepTag,
    stepCloud,
    stepAddons,
    stepConfigs,
    stepUp,
    stepSmoke,
  ];
  try {
    for (const s of steps) {
      // eslint-disable-next-line no-await-in-loop
      const cont = await s();
      if (!cont) {
        log.warn("Визард остановлен — можно перезапустить: make setup (или rocket → Установка).");
        return false;
      }
    }
    return true;
  } catch (e) {
    if (e instanceof Cancelled) {
      log.warn("Визард отменён.");
      return false;
    }
    throw e;
  }
}
