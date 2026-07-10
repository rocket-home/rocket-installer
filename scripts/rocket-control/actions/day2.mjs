// Действия день-2: тонкие обёртки над make-целями.
import { select, text, log } from "../io.mjs";
import { ensure, promptDangerous, runMakeStep } from "../prompts.mjs";
import { reportMakeExit } from "../lib/make.mjs";

export async function actionStatus() {
  const { code } = await runMakeStep("status");
  reportMakeExit("status", code, log);
}

export async function actionLogs() {
  const service = ensure(
    await select({
      message: "Логи какого сервиса?",
      options: [
        { value: "mqtt", label: "mqtt (брокер + мост + token-agent)" },
        { value: "zigbee2mqtt", label: "zigbee2mqtt" },
        { value: "nodered", label: "nodered" },
        { value: "", label: "все" },
      ],
    }),
  );
  const follow = ensure(
    await select({
      message: "Режим:",
      options: [
        { value: "0", label: "снимок (последние 100 строк)" },
        { value: "1", label: "поток (Ctrl+C — выход)" },
      ],
    }),
  );
  await runMakeStep("logs", {
    extraArgs: [`SERVICE=${service}`, `FOLLOW=${follow}`],
  });
}

export async function actionPermitJoin() {
  const mode = ensure(
    await select({
      message: "Zigbee-сеть:",
      options: [
        { value: "on", label: "Открыть для подключения устройств", hint: "автозакрытие по таймеру" },
        { value: "off", label: "Закрыть" },
      ],
    }),
  );
  if (mode === "on") {
    const time = ensure(
      await text({
        message: "На сколько секунд открыть?",
        defaultValue: "254",
        validate: (v) => (!v || /^\d+$/.test(v) ? undefined : "число секунд"),
      }),
    );
    const { code } = await runMakeStep("permit-join-on", {
      extraArgs: [`TIME=${time || "254"}`],
    });
    reportMakeExit("permit-join", code, log);
  } else {
    const { code } = await runMakeStep("permit-join-off");
    reportMakeExit("permit-join", code, log);
  }
}

export async function actionUpdate() {
  log.info("Обновление: стоп z2m → детект прошивки → матрица → бэкап → новый тег → smoke.");
  const { code } = await runMakeStep("update");
  reportMakeExit("update", code, log);
}

export async function actionRelink() {
  const { code } = await runMakeStep("relink");
  reportMakeExit("relink", code, log);
}

export async function actionDoctor() {
  const { code } = await runMakeStep("doctor");
  reportMakeExit("doctor", code, log);
}

export async function actionBackup() {
  const what = ensure(
    await select({
      message: "Бэкапы:",
      options: [
        { value: "backup", label: "Сделать бэкап (data + secrets + .env)" },
        { value: "restore", label: "Восстановить из архива" },
      ],
    }),
  );
  if (what === "backup") {
    const { code } = await runMakeStep("backup");
    reportMakeExit("backup", code, log);
    return;
  }
  const archive = ensure(
    await text({
      message: "Путь к архиву (backups/rocket-backup-….tar.gz):",
      validate: (v) => (v ? undefined : "обязательное поле"),
    }),
  );
  if (!(await promptDangerous("Восстановление перезапишет data/, secrets/ и .env. Продолжить?"))) return;
  const { code } = await runMakeStep("restore", {
    extraArgs: [`ARCHIVE=${archive}`, "CONFIRM=1"],
  });
  reportMakeExit("restore", code, log);
}
