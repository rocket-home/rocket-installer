// Тестовый харнесс (паттерн infra __tests__/_harness.mjs): мокает io.mjs и
// lib/make.mjs один раз на файл. Ответы промптов задаются очередью answers,
// вызовы make записываются в makeCalls.
import { mock } from "node:test";

export const state = {
  answers: [],
  makeCalls: [],
  notes: [],
  logs: [],
};

export function reset({ answers = [], makeExitCode = 0, makeStdout = "", envFile = {} } = {}) {
  state.answers = [...answers];
  state.makeCalls = [];
  state.notes = [];
  state.logs = [];
  state.makeExitCode = makeExitCode;
  state.makeStdout = makeStdout;
  // makeExitByTarget: {target: code} — уронить конкретную цель, не трогая остальные
  state.makeExitByTarget = {};
  // makeStdoutByTarget: {target: stdout} — разные JSON-ответы на разные цели
  state.makeStdoutByTarget = {};
  // содержимое .env, которое видит TUI через lib/env.mjs
  state.envFile = { ...envFile };
}

function nextAnswer(kind, message) {
  if (!state.answers.length) {
    throw new Error(`нет ответа для ${kind}("${message}") — очередь answers пуста`);
  }
  return state.answers.shift();
}

export function installMocks() {
  const logFn = (level) => (msg) => state.logs.push({ level, msg });
  mock.module(new URL("../io.mjs", import.meta.url).href, {
    namedExports: {
      intro: () => {},
      outro: () => {},
      cancel: () => {},
      select: async ({ message }) => nextAnswer("select", message),
      multiselect: async ({ message }) => nextAnswer("multiselect", message),
      confirm: async ({ message }) => nextAnswer("confirm", message),
      text: async ({ message }) => nextAnswer("text", message),
      note: (msg, title) => state.notes.push({ msg, title }),
      log: {
        step: logFn("step"),
        info: logFn("info"),
        warn: logFn("warn"),
        error: logFn("error"),
        success: logFn("success"),
      },
      spinner: () => ({ start: () => {}, stop: () => {} }),
      isCancel: (v) => v === Symbol.for("clack.cancel"),
    },
  });
  mock.module(new URL("../lib/env.mjs", import.meta.url).href, {
    namedExports: {
      ENV_PATH: "/mocked/.env",
      readEnv: () => ({ ...state.envFile }),
      envExists: () => true,
    },
  });
  mock.module(new URL("../lib/make.mjs", import.meta.url).href, {
    namedExports: {
      runMake: async (target, options = {}) => {
        state.makeCalls.push({ target, ...options });
        return { code: state.makeExitByTarget[target] ?? state.makeExitCode };
      },
      runMakeCapture: async (target, options = {}) => {
        state.makeCalls.push({ target, ...options, captured: true });
        const stdout = state.makeStdoutByTarget[target] ?? state.makeStdout;
        return { code: state.makeExitByTarget[target] ?? state.makeExitCode, stdout };
      },
      formatMakeCommand: (target, extraArgs = []) =>
        ["make", target, ...extraArgs].join(" "),
      reportMakeExit: () => {},
    },
  });
}

export const CANCEL = Symbol.for("clack.cancel");
