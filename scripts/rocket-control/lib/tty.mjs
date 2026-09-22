// Терминал для TUI, когда stdin достался нам пайпом.
//
// ЗАЧЕМ. Заглавная команда установки — `curl -fsSL …/install.sh | bash`. У такого процесса
// stdin — это пайп от curl, а не терминал. @clack рисует первый вопрос и ждёт нажатия клавиши,
// которого никогда не будет: на EOF он не подписан, промпт не резолвится, а незавершённый
// top-level await в scripts/rocket.mjs роняет Node молча с кодом 13. Снаружи это выглядело как
// «установщик умер, ничего не сказав».
//
// ПОЧЕМУ НЕ ОТДАТЬ ПОТОК САМОМУ CLACK. @clack/prompts 0.7 опции промптов перечисляет поимённо,
// слов input/output в пакете нет вовсе (появились в 0.9+), а @clack/core снимает process.stdin
// в момент импорта — подменять его после импорта бесполезно. Поднимать мажор UI-библиотеки ради
// одного дескриптора дороже, чем добыть настоящий fd 0.
//
// ПОЧЕМУ НЕ РЕДИРЕКТ В install.sh. `exec </dev/tty` там запрещён: bash дочитывает текст самого
// скрипта из fd 0, и остаток установщика был бы прочитан с клавиатуры пользователя. Чинить
// дескриптор должен тот, кому он нужен, — Node.
import { openSync, closeSync } from "node:fs";
import { spawnSync } from "node:child_process";
import { isatty } from "node:tty";
import { EXIT } from "./exit-codes.mjs";

/** Устройство терминала. ROCKET_TTY_DEVICE — шов для тестов, не пользовательская настройка:
 *  без него тест отказного пути захватил бы терминал разработчика и повис бы в мастере. */
function ttyDevice() {
  return process.env.ROCKET_TTY_DEVICE || "/dev/tty";
}

function failNoTty(reason) {
  // Терминала нет — значит и рисовать clack'ом некому: пишем простым текстом в stderr.
  process.stderr.write(
    `\nНет терминала: мастеру нужен интерактивный ввод, а stdin — не терминал` +
      `${reason ? ` (${reason})` : ""}.\n` +
      `Запустите мастер в терминале:  rocket\n` +
      `Либо поставьте без мастера:    curl -fsSL https://rocket-home.ru/install.sh | bash -s -- --headless\n`,
  );
  process.exit(EXIT.NO_TTY);
}

/**
 * Дать процессу настоящий терминал на fd 0, перезапустив себя, если stdin — пайп.
 * Когда stdin уже терминал (запуск `rocket` из консоли, `make setup` из консоли) —
 * не делает ничего, поведение прежнее байт в байт.
 *
 * @param {string[]} argv аргументы после пути скрипта (process.argv.slice(2))
 * @param {string} entryPath абсолютный путь точки входа, который передаём себе же
 */
export function ensureInteractiveStdin(argv, entryPath) {
  if (process.stdin.isTTY) return;

  // Защита от рекурсии: если терминал не помог, второй перезапуск ничего не изменит.
  if (process.env.ROCKET_NO_REEXEC === "1") {
    failNoTty("повторный запуск с /dev/tty не дал терминала");
    return;
  }

  let fd;
  try {
    fd = openSync(ttyDevice(), "r");
  } catch (e) {
    // ENXIO — у процесса нет управляющего терминала: cron, systemd-юнит, ssh без -t.
    failNoTty(`${ttyDevice()} недоступен: ${e?.code || e?.message || e}`);
    return;
  }

  if (!isatty(fd)) {
    closeSync(fd);
    failNoTty(`${ttyDevice()} — не терминал`);
    return;
  }

  // Ctrl+C должен достаться ребёнку, который рисует промпт и умеет сказать «отменено».
  // Без этого обработчика родитель, стоящий в spawnSync, умрёт первым и потеряет код 130.
  process.on("SIGINT", () => {});

  const res = spawnSync(process.execPath, [entryPath, ...argv], {
    stdio: [fd, "inherit", "inherit"],
    env: { ...process.env, ROCKET_NO_REEXEC: "1" },
  });
  closeSync(fd);

  process.exit(res.status ?? (res.signal ? EXIT.CANCELLED : EXIT.FAILED));
}
