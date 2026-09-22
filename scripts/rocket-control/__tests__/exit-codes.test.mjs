// Отмена пользователя и технический отказ должны различаться СНАРУЖИ.
//
// install.sh решает по коду возврата, что сказать человеку. Пока всё схлопывалось в 1 (а через
// make — в 2), установщик печатал «docker недоступен» и на отменённый Ctrl+C, и на упавший шаг.
import { test, beforeEach, afterEach } from "node:test";
import assert from "node:assert/strict";
import { installMocks, reset, state, CANCEL } from "./_harness.mjs";

installMocks();
const { runRocket } = await import("../main.mjs");

beforeEach(() => reset());
afterEach(() => {
  process.exitCode = 0;
});

test("Ctrl+C в мастере → код 130 (отменено пользователем)", async () => {
  reset({ answers: [CANCEL] });
  state.makeStdoutByTarget = { "detect-device": "[]" };

  await runRocket(["--wizard"]);

  assert.equal(process.exitCode, 130);
});

test("упавший шаг → код 1 (технический отказ)", async () => {
  reset({ answers: [] });
  state.makeExitByTarget = { "check-tools": 1 };

  await runRocket(["--wizard"]);

  assert.equal(process.exitCode, 1);
  assert.ok(
    state.logs.some((l) => l.level === "error" && /инструмент/i.test(l.msg)),
    "пользователь видит, какой именно шаг не выполнен",
  );
});
