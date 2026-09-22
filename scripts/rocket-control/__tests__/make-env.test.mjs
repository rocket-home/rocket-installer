// Дочерний make не должен наследовать make-переменные родителя.
//
// Без харнесса: здесь нужен НАСТОЯЩИЙ spawn. Именно этот класс дефектов моки поймать не могут —
// харнесс подменяет lib/make.mjs целиком и всегда отдаёт идеально чистый JSON, поэтому
// «мастер слеп из-под make» прожил до живого прогона в чистой ВМ.
import { test } from "node:test";
import assert from "node:assert/strict";
import { mkdtempSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { execFileSync } from "node:child_process";
import { childEnv, runMakeCapture } from "../lib/make.mjs";

function haveCmd(cmd) {
  try {
    execFileSync("sh", ["-c", `command -v ${cmd}`], { stdio: "ignore" });
    return true;
  } catch {
    return false;
  }
}

test("childEnv вычищает унаследованные make-переменные и применяет overrides", () => {
  const env = childEnv(
    { MAKELEVEL: "1", MAKEFLAGS: "w", MFLAGS: "-w", GNUMAKEFLAGS: "x", FOO: "bar" },
    { BAR: "1" },
  );
  assert.equal(env.MAKELEVEL, undefined);
  assert.equal(env.MAKEFLAGS, undefined);
  assert.equal(env.MFLAGS, undefined);
  assert.equal(env.GNUMAKEFLAGS, undefined);
  assert.equal(env.FOO, "bar", "чужие переменные остаются нетронутыми");
  assert.equal(env.BAR, "1");
});

test(
  "под MAKELEVEL=1 вывод make всё равно разбирается как JSON",
  { timeout: 60000 },
  (t) => {
    if (!haveCmd("make") || !haveCmd("jq")) {
      t.skip("нужны make и jq");
      return;
    }
    // Пустой каталог вместо /dev — detect-device отдаёт пустой список кандидатов.
    const dev = mkdtempSync(join(tmpdir(), "rocket-dev-"));
    const saved = { ...process.env };
    try {
      process.env.MAKELEVEL = "1";
      process.env.MAKEFLAGS = "w";
      return runMakeCapture("detect-device", { env: { ROCKET_DEV_ROOT: dev } }).then(
        ({ code, stdout }) => {
          assert.equal(code, 0);
          // Ассерт положительный: «JSON разобран». Проверять отсутствие строки
          // `Entering directory` нельзя — она локализуется вместе с локалью системы.
          assert.deepEqual(JSON.parse(stdout), []);
        },
      );
    } finally {
      process.env.MAKELEVEL = saved.MAKELEVEL ?? "";
      if (saved.MAKELEVEL === undefined) delete process.env.MAKELEVEL;
      if (saved.MAKEFLAGS === undefined) delete process.env.MAKEFLAGS;
      rmSync(dev, { recursive: true, force: true });
    }
  },
);
