// Вход TUI. Логика — в rocket-control/ (по образцу infra/scripts/infra.mjs).
import { runRocket } from "./rocket-control/main.mjs";

await runRocket(process.argv.slice(2));
