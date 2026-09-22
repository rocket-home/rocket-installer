// Полный проход визарда установки на моках: happy path (OAuth) и
// остановка при несовместимой прошивке без согласия на риск.
import { test, beforeEach } from "node:test";
import assert from "node:assert/strict";
import { existsSync, readFileSync, rmSync } from "node:fs";
import { join } from "node:path";
import { tmpdir } from "node:os";
import { installMocks, reset, state } from "./_harness.mjs";

installMocks();
const { wizardSetup } = await import("../wizards/setup.mjs");

const DEVICE = {
  path: "/dev/serial/by-id/usb-sonoff",
  realpath: "/dev/ttyUSB0",
  family: "zstack",
  known: true,
  description: "Sonoff Dongle Plus",
};

function targets() {
  return state.makeCalls.map((c) => c.target);
}

beforeEach(() => reset());

test("happy path: oauth, probe ok, рекомендованный тег применён", async () => {
  reset({
    answers: [
      DEVICE,        // select: какой стик
      true,          // confirm: udev-install
      true,          // confirm: запустить probe
      true,          // confirm: применить рекомендованный тег
      "oauth",       // select: способ авторизации
      false,         // confirm: node-red
    ],
    // визард сверяется с .env: семейство уже определено пробой
    envFile: { ADAPTER_FAMILY: "zstack", Z2M_IMAGE_TAG: "1.42.0", Z2M_FRONTEND_PORT: "4000" },
  });
  state.makeStdoutByTarget = {
    "detect-device": JSON.stringify([DEVICE]),
    "detect-firmware": JSON.stringify({
      family: "zstack",
      firmware: "20240710",
      model: "",
      confidence: "probe",
    }),
    "resolve-tag": JSON.stringify({
      ok: true,
      recommended: "2.6.0",
      adapter: "zstack",
      adapter_override: null,
      fallback: "1.42.0",
    }),
  };

  const ok = await wizardSetup();
  assert.equal(ok, true);

  const t = targets();
  for (const expected of [
    "check-tools", "env-init", "detect-device", "udev-install",
    "detect-firmware", "resolve-tag", "oauth-link", "gen-configs", "up", "smoke",
  ]) {
    assert.ok(t.includes(expected), `ожидался вызов make ${expected}; было: ${t.join(", ")}`);
  }
  // порядок ключевых шагов: конфиги до запуска, запуск до smoke
  assert.ok(t.indexOf("gen-configs") < t.indexOf("up"));
  assert.ok(t.indexOf("up") < t.indexOf("smoke"));

  // env-set зафиксировал устройство и тег
  const envSets = state.makeCalls
    .filter((c) => c.target === "env-set")
    .map((c) => c.extraArgs.join(" "));
  assert.ok(envSets.some((a) => a.includes("KEY=ZIGBEE_DEVICE_HOST") && a.includes("VALUE=/dev/ttyUSB0")));
  assert.ok(envSets.some((a) => a.includes("KEY=Z2M_IMAGE_TAG") && a.includes("VALUE=2.6.0")));
  assert.ok(envSets.some((a) => a.includes("KEY=CLOUD_AUTH_MODE") && a.includes("VALUE=oauth")));
});

test("несовместимая прошивка: отказ от риска останавливает визард до запуска", async () => {
  reset({
    answers: [
      DEVICE,        // стик
      false,         // udev не ставим
      true,          // probe запустить
      false,         // promptDangerous №1: продолжить на свой риск? — нет
    ],
    envFile: { ADAPTER_FAMILY: "ember", Z2M_IMAGE_TAG: "1.42.0" },
  });
  state.makeStdoutByTarget = {
    "detect-device": JSON.stringify([DEVICE]),
    "detect-firmware": JSON.stringify({
      family: "ember",
      firmware: "6.5.0",
      model: "",
      confidence: "probe",
    }),
    "resolve-tag": JSON.stringify({
      ok: false,
      advice: "Прошивка слишком старая — обновите координатор.",
      fallback: "1.42.0",
    }),
  };

  const ok = await wizardSetup();
  assert.equal(ok, false);
  const t = targets();
  assert.ok(!t.includes("up"), "стек не должен запускаться");
  assert.ok(!t.includes("gen-configs"), "конфиги не должны генерироваться");
});

// Баннер make в stdout больше не должен выглядеть как честный ответ «стиков нет».
// Именно так дефект и прятался: JSON.parse падал, catch возвращал null, шаг 2 показывал
// пустой список — и ни одной строки о том, что вывод вообще не разобран.
test("неразобранный ответ make объясняет себя, а не притворяется пустым списком", async () => {
  const logFile = join(tmpdir(), `rocket-tui-test-${process.pid}.log`);
  process.env.ROCKET_LOG_FILE = logFile;
  reset({
    answers: [
      "skip",   // стик: пропустить (список пуст — выбирать не из чего)
      false,    // автоопределение прошивки не запускаем
      "skip",   // семейство вручную: не знаю
      "off",    // облако: без облака
      false,    // node-red
    ],
    envFile: { Z2M_IMAGE_TAG: "1.42.0", Z2M_FRONTEND_PORT: "4000" },
  });
  state.makeStdoutByTarget = {
    "detect-device": "make[1]: Entering directory '/opt/rocket-home'\n[]\n",
  };

  try {
    await wizardSetup();

    const warns = state.logs.filter((l) => l.level === "warn").map((l) => l.msg);
    assert.ok(
      warns.some((m) => m.includes("detect-device") && /не разобран/i.test(m)),
      `ожидалось предупреждение о неразобранном ответе; было: ${warns.join(" | ")}`,
    );
    assert.ok(existsSync(logFile), "сырой вывод сохранён в журнал");
    assert.match(readFileSync(logFile, "utf8"), /Entering directory/);
  } finally {
    delete process.env.ROCKET_LOG_FILE;
    rmSync(logFile, { force: true });
  }
});

// Шаг 9 — отчётный: стек уже поднят. Красный smoke не повод объявлять установку несостоявшейся
// и звать перезапускать мастер (проверено живьём: smoke краснел, пока поднимался z2m 2.6).
test("красный smoke на шаге 9 не делает установку незавершённой", async () => {
  reset({
    answers: [
      DEVICE, true, true, true, "oauth", false,
    ],
    envFile: { ADAPTER_FAMILY: "zstack", Z2M_IMAGE_TAG: "1.42.0", Z2M_FRONTEND_PORT: "4000" },
  });
  state.makeStdoutByTarget = {
    "detect-device": JSON.stringify([DEVICE]),
    "detect-firmware": JSON.stringify({ family: "zstack", firmware: "20240710", model: "", confidence: "probe" }),
    "resolve-tag": JSON.stringify({ ok: true, recommended: "2.6.0", adapter: "zstack", adapter_override: null, fallback: "1.42.0" }),
  };
  state.makeExitByTarget = { smoke: 1 };

  const ok = await wizardSetup();

  assert.equal(ok, true, "установка состоялась: стек поднят");
  const warns = state.logs.filter((l) => l.level === "warn").map((l) => l.msg);
  assert.ok(
    warns.some((m) => m.includes("make smoke")),
    `ожидался совет повторить проверку; было: ${warns.join(" | ")}`,
  );
});
