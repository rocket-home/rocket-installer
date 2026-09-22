// Запуск make-целей из TUI (порт infra/scripts/lib/make.mjs).
// TUI — тонкая оболочка: каждый вызов печатает эквивалентную команду,
// чтобы пользователь мог воспроизвести всё без TUI.
import { spawn } from "node:child_process";
import { REPO_ROOT } from "./repo.mjs";

function dropRawMode() {
  /* Clack оставляет stdin в raw mode — вывод make не виден и кажется «зависание». */
  try {
    if (process.stdin.isTTY && typeof process.stdin.setRawMode === "function") {
      process.stdin.setRawMode(false);
    }
  } catch {
    /* ignore */
  }
}

// Переменные, которыми родительский make «заражает» потомков. Главная — MAKELEVEL: увидев её,
// GNU Make считает себя под-make и сам включает -w, то есть печатает `make[1]: Entering
// directory …` в STDOUT — ровно туда, откуда мы читаем JSON целей detect-device/detect-firmware/
// resolve-tag. Мастер запускается целью `make setup`, поэтому под make он оказывается всегда:
// список стиков выходил пустым, прошивка «не определилась», тег откатывался на консервативный —
// и всё это молча, как будто железа просто нет.
//
// Вырезать баннер из вывода нельзя: он локализован (в ru-локали это «Вход в каталог») и в
// принципе неотличим от данных. Чиним источник — не отдаём потомку чужие make-переменные.
const INHERITED_MAKE_VARS = [
  "MAKELEVEL",
  "MAKEFLAGS",
  "MFLAGS",
  "GNUMAKEFLAGS",
  "MAKE_TERMOUT",
  "MAKE_TERMERR",
];

/** Окружение для дочернего make: копия base без унаследованных make-переменных + overrides.
 *  Экспортируется ради теста — spawn изнутри не наблюдаем. */
export function childEnv(base = process.env, overrides = {}) {
  const env = { ...base };
  for (const k of INHERITED_MAKE_VARS) delete env[k];
  for (const [k, v] of Object.entries(overrides)) {
    if (v !== undefined) env[k] = String(v);
  }
  return env;
}

function spawnMake(target, { env = {}, extraArgs = [], stdio }) {
  // --no-print-directory — ремень к подтяжкам: `make -C <dir>` включает -w даже на нулевом
  // уровне, то есть баннер может прийти и без MAKELEVEL в окружении.
  return spawn("make", ["--no-print-directory", target, ...extraArgs], {
    cwd: REPO_ROOT,
    stdio,
    env: childEnv(process.env, env),
  });
}

export function formatMakeCommand(target, extraArgs = []) {
  return ["make", target, ...extraArgs].join(" ");
}

/** Интерактивный запуск (вывод в терминал). @returns {Promise<{code:number}>} */
export function runMake(target, options = {}) {
  const { env = {}, extraArgs = [], handleSigint = true } = options;
  dropRawMode();
  const child = spawnMake(target, { env, extraArgs, stdio: "inherit" });

  return new Promise((resolveP, rejectP) => {
    let killed = false;
    const onSigint = () => {
      if (killed) return;
      killed = true;
      child.kill("SIGINT");
    };
    if (handleSigint) process.on("SIGINT", onSigint);
    child.on("error", (err) => {
      if (handleSigint) process.off("SIGINT", onSigint);
      rejectP(err);
    });
    child.on("exit", (code, signal) => {
      if (handleSigint) process.off("SIGINT", onSigint);
      resolveP({ code: code ?? (signal ? 130 : 1) });
    });
  });
}

/** Запуск с захватом stdout (для JSON-целей: detect-device, resolve-tag). */
export function runMakeCapture(target, options = {}) {
  const { env = {}, extraArgs = [] } = options;
  dropRawMode();
  const child = spawnMake(target, {
    env,
    extraArgs,
    stdio: ["ignore", "pipe", "inherit"],
  });
  let out = "";
  child.stdout.on("data", (d) => {
    out += d;
  });
  return new Promise((resolveP, rejectP) => {
    child.on("error", rejectP);
    child.on("exit", (code) => resolveP({ code: code ?? 1, stdout: out }));
  });
}

export function reportMakeExit(label, code, log) {
  if (code === 0) log.success(`${label}: OK`);
  else log.error(`${label}: exit ${code}`);
}
