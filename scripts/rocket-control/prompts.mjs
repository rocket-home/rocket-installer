// Общие промпт-хелперы (паттерн infra/prompts.mjs).
import { isCancel, confirm, log } from "./io.mjs";
import { formatMakeCommand, runMake, runMakeCapture } from "./lib/make.mjs";
import { writeDebug } from "./lib/debug.mjs";

/** Отмена промпта (Escape/Ctrl+C) — возврат в меню через исключение. */
export class Cancelled extends Error {
  constructor() {
    super("cancelled");
  }
}

/** Разворачивает результат clack-промпта; на отмене кидает Cancelled. */
export function ensure(value) {
  if (isCancel(value)) throw new Cancelled();
  return value;
}

/**
 * Двойной confirm для деструктива; SKIP_CONFIRM=1 — обход для автоматизации.
 * @returns {Promise<boolean>}
 */
export async function promptDangerous(message) {
  if (process.env.SKIP_CONFIRM === "1") return true;
  const first = ensure(await confirm({ message }));
  if (!first) return false;
  const second = ensure(
    await confirm({ message: "Точно? Действие необратимо.", initialValue: false }),
  );
  return second;
}

/** Запуск make-цели с печатью эквивалентной команды (TUI обучает CLI). */
export async function runMakeStep(target, options = {}) {
  const { extraArgs = [], env = {} } = options;
  log.step(`→ ${formatMakeCommand(target, extraArgs)}`);
  return runMake(target, { extraArgs, env });
}

/**
 * Единственная точка разбора JSON от make (detect-device, detect-firmware, resolve-tag).
 *
 * Прежний вариант жил в визарде и глотал ЛЮБУЮ неудачу молча (`catch { return null }`).
 * Поэтому сломанный вывод make выглядел как честный ответ «стиков нет, прошивка неизвестна»,
 * и дефект прожил до живого прогона в чистой ВМ. Теперь каждая неудача называет себя: одна
 * строка на экран (внутри вёрстки clack), сырьё — в журнал.
 *
 * @returns {Promise<any|null>} разобранный JSON либо null
 */
export async function captureJsonStep(target, options = {}) {
  const { extraArgs = [] } = options;
  log.step(`→ ${formatMakeCommand(target, extraArgs)}`);
  const { code, stdout } = await runMakeCapture(target, options);

  if (code !== 0) {
    log.warn(`make ${target}: выход с кодом ${code} — подробности в выводе выше.`);
    return null;
  }
  if (stdout.trim() === "") {
    log.warn(`make ${target}: пустой ответ (ожидался JSON).`);
    return null;
  }
  try {
    return JSON.parse(stdout);
  } catch {
    const head = stdout.trim().replace(/\s+/g, " ").slice(0, 100);
    const path = writeDebug(`make ${target}: ответ не разобран как JSON`, stdout);
    log.warn(
      `make ${target}: ответ не разобран — «${head}»` +
        (path ? `; полный вывод: ${path}` : ""),
    );
    if (process.env.ROCKET_DEBUG === "1") process.stderr.write(stdout);
    return null;
  }
}
