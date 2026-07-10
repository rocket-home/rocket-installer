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

function spawnMake(target, { env = {}, extraArgs = [], stdio }) {
  const mergedEnv = { ...process.env };
  for (const [k, v] of Object.entries(env)) {
    if (v !== undefined) mergedEnv[k] = String(v);
  }
  return spawn("make", [target, ...extraArgs], {
    cwd: REPO_ROOT,
    stdio,
    env: mergedEnv,
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
