// Без терминала мастер обязан сказать это вслух и выйти, а не зависнуть.
//
// Запускаем настоящий процесс: суть дефекта была в том, что промпт @clack на исчерпанном пайпе
// не резолвится никогда, незавершённый top-level await роняет Node с кодом 13 молча, а
// install.sh приписывал это докеру. Мок такого не покажет.
//
// ROCKET_TTY_DEVICE обязателен: без него тест открыл бы терминал разработчика и повис бы
// в настоящем мастере.
import { test } from "node:test";
import assert from "node:assert/strict";
import { spawnSync } from "node:child_process";
import { fileURLToPath } from "node:url";
import { dirname, join } from "node:path";
import { tmpdir } from "node:os";

const ENTRY = join(dirname(fileURLToPath(import.meta.url)), "../../rocket.mjs");

function runWizard(ttyDevice) {
  return spawnSync(process.execPath, [ENTRY, "--wizard"], {
    input: "", // stdin — пайп, как при `curl … | bash`
    encoding: "utf8",
    timeout: 20000,
    env: { ...process.env, ROCKET_TTY_DEVICE: ttyDevice },
  });
}

test("нет /dev/tty → код 3 и внятное сообщение, без зависания", () => {
  const res = runWizard(join(tmpdir(), "rocket-no-such-tty"));

  assert.equal(res.signal, null, "процесс завершился сам, а не по таймауту");
  assert.equal(res.status, 3);
  assert.match(res.stderr, /терминал/i);
  assert.match(res.stderr, /rocket/);
});

test("подложный «терминал» (обычный файл) тоже даёт код 3", () => {
  const res = runWizard("/dev/null");

  assert.equal(res.signal, null);
  assert.equal(res.status, 3);
  assert.match(res.stderr, /не терминал/i);
});
