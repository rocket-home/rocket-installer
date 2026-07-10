// Все модули TUI импортируются без ошибок (ловит битые import/синтаксис).
import { test } from "node:test";
import assert from "node:assert/strict";

const modules = [
  "../main.mjs",
  "../io.mjs",
  "../prompts.mjs",
  "../lib/make.mjs",
  "../lib/env.mjs",
  "../lib/repo.mjs",
  "../wizards/setup.mjs",
  "../actions/day2.mjs",
  "../settings/settings.mjs",
];

for (const m of modules) {
  test(`import ${m}`, async () => {
    const mod = await import(m);
    assert.ok(mod, `${m} должен экспортировать модуль`);
  });
}
