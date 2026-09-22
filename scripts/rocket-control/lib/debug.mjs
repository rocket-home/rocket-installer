// Журнал для того, что нельзя показать в TUI целиком.
//
// ЗАЧЕМ. Вывод make, который не разобрался как JSON, — главная улика при разборе «мастер не
// видит координатор». Вывалить его в stdout нельзя: там рисует clack, и чужие строки ломают
// вёрстку. Значит на экран — одна строка с объяснением, а сырьё — в файл.
import { appendFileSync } from "node:fs";
import { join } from "node:path";
import { tmpdir } from "node:os";
import { REPO_ROOT } from "./repo.mjs";

const MAX_PAYLOAD = 4096;

export function debugLogPath() {
  return process.env.ROCKET_LOG_FILE || join(REPO_ROOT, "data", "rocket-tui.log");
}

/**
 * Дописать запись в журнал. Никогда не бросает: data/ после контейнеров может принадлежать
 * root, и диагностика не имеет права ронять TUI — в этом случае уходим в системный temp.
 * @returns {string|null} путь файла, куда легла запись (null — записать не удалось никуда)
 */
export function writeDebug(label, payload) {
  const text = String(payload ?? "");
  const entry =
    `\n[${new Date().toISOString()}] ${label}\n` +
    (text.length > MAX_PAYLOAD ? `${text.slice(0, MAX_PAYLOAD)}\n…(обрезано)\n` : `${text}\n`);

  for (const path of [debugLogPath(), join(tmpdir(), "rocket-tui.log")]) {
    try {
      appendFileSync(path, entry);
      return path;
    } catch {
      /* пробуем следующий */
    }
  }
  return null;
}
