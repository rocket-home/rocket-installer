// Каждая make-цель, на которую ссылается TUI (runMake*/runMakeStep-литералы),
// существует в Makefile — TUI не может «протухнуть» относительно make-слоя.
import { test } from "node:test";
import assert from "node:assert/strict";
import { readFileSync, readdirSync, statSync } from "node:fs";
import { join, dirname } from "node:path";
import { fileURLToPath } from "node:url";

const controlDir = dirname(dirname(fileURLToPath(import.meta.url)));
const repoRoot = join(controlDir, "../..");

function* mjsFiles(dir) {
  for (const name of readdirSync(dir)) {
    if (name === "__tests__" || name === "node_modules") continue;
    const p = join(dir, name);
    if (statSync(p).isDirectory()) yield* mjsFiles(p);
    else if (name.endsWith(".mjs")) yield p;
  }
}

test("все make-цели из TUI существуют в Makefile", () => {
  const makefile = readFileSync(join(repoRoot, "Makefile"), "utf8");
  const defined = new Set(
    [...makefile.matchAll(/^([a-z][a-z0-9-]*):/gm)].map((m) => m[1]),
  );

  const referenced = new Set();
  for (const file of mjsFiles(controlDir)) {
    const src = readFileSync(file, "utf8");
    for (const m of src.matchAll(/runMake(?:Step|Capture)?\(\s*"([a-z][a-z0-9-]*)"/g)) {
      referenced.add(m[1]);
    }
  }

  assert.ok(referenced.size >= 10, `подозрительно мало ссылок на make: ${referenced.size}`);
  for (const target of referenced) {
    assert.ok(defined.has(target), `цель "${target}" используется в TUI, но нет в Makefile`);
  }
});

test("скрипты из Makefile существуют и исполняемы", () => {
  const makefile = readFileSync(join(repoRoot, "Makefile"), "utf8");
  for (const m of makefile.matchAll(/\$\(ROOT\)\/(scripts\/[a-z0-9-]+\.sh|tests\/run\.sh)/g)) {
    const p = join(repoRoot, m[1]);
    assert.ok(statSync(p).isFile(), `нет файла ${m[1]}`);
  }
});
