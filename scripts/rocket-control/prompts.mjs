// Общие промпт-хелперы (паттерн infra/prompts.mjs).
import { isCancel, confirm, log } from "./io.mjs";
import { formatMakeCommand, runMake } from "./lib/make.mjs";

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
