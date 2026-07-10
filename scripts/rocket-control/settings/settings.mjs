// Настройки: стик / облако / аддоны. Меняют .env через make env-set,
// затем предлагают make gen-configs + make up.
import { select, confirm, text, note, log } from "../io.mjs";
import { ensure, runMakeStep } from "../prompts.mjs";
import { runMakeCapture, formatMakeCommand } from "../lib/make.mjs";
import { readEnv } from "../lib/env.mjs";

async function envSet(key, value) {
  log.step(`→ ${formatMakeCommand("env-set", [`KEY=${key}`, "VALUE=…"])}`);
  const { code } = await runMakeCapture("env-set", {
    extraArgs: [`KEY=${key}`, `VALUE=${value}`],
  });
  if (code !== 0) throw new Error(`env-set ${key}: exit ${code}`);
}

async function offerApply() {
  const apply = ensure(
    await confirm({ message: "Применить сейчас (gen-configs + up)?" }),
  );
  if (!apply) {
    note("Применение позже: make gen-configs && make up", "Отложено");
    return;
  }
  await runMakeStep("gen-configs");
  await runMakeStep("up");
}

export async function settingsDevice() {
  const found = JSON.parse(
    (await runMakeCapture("detect-device")).stdout || "[]",
  );
  const options = found.map((d) => ({
    value: d,
    label: `${d.path}${d.description ? ` — ${d.description}` : ""}`,
    hint: d.known ? `похоже: ${d.family}` : undefined,
  }));
  options.push({ value: "back", label: "Назад" });
  const choice = ensure(await select({ message: "Стик:", options }));
  if (choice === "back") return;
  await envSet("ZIGBEE_DEVICE_BYID", choice.path);
  await envSet("ZIGBEE_DEVICE_HOST", choice.realpath);
  if (choice.family) await envSet("ADAPTER_FAMILY", choice.family);
  await offerApply();
}

export async function settingsCloud() {
  const env = readEnv();
  const mode = ensure(
    await select({
      message: `Режим облака (текущий: ${env.CLOUD_AUTH_MODE || "oauth"}):`,
      options: [
        { value: "oauth", label: "OAuth (вход через rocket-home.ru)" },
        { value: "static", label: "Логин/пароль MQTT" },
        { value: "off", label: "Выключить мост" },
        { value: "back", label: "Назад" },
      ],
    }),
  );
  if (mode === "back") return;
  await envSet("CLOUD_AUTH_MODE", mode);
  if (mode === "oauth") {
    const link = ensure(
      await confirm({ message: "Выполнить линковку сейчас (make oauth-link)?" }),
    );
    if (link) await runMakeStep("oauth-link");
  } else if (mode === "static") {
    const user = ensure(
      await text({
        message: "Логин MQTT:",
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
  await offerApply();
}

export async function settingsAddons() {
  const env = readEnv();
  const enabled = (env.COMPOSE_PROFILES || "").includes("nodered");
  const next = ensure(
    await confirm({
      message: `Node-RED сейчас ${enabled ? "включён" : "выключен"}. Включить?`,
      initialValue: enabled,
    }),
  );
  if (next === enabled) return;
  await envSet("COMPOSE_PROFILES", next ? "nodered" : "");
  await offerApply();
}
