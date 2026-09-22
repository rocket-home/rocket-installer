// Вход TUI. Логика — в rocket-control/ (по образцу infra/scripts/infra.mjs).
import { fileURLToPath } from "node:url";
import { ensureInteractiveStdin } from "./rocket-control/lib/tty.mjs";
import { runRocket } from "./rocket-control/main.mjs";

// Первым делом — терминал: при запуске из `curl … | bash` stdin это пайп, и без настоящего
// fd 0 первый же вопрос мастера повис бы навсегда (см. lib/tty.mjs).
ensureInteractiveStdin(process.argv.slice(2), fileURLToPath(import.meta.url));

await runRocket(process.argv.slice(2));
