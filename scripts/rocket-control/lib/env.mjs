// Чтение .env (источник правды конфигурации). Запись — только через
// make env-set (env-set.sh), чтобы TUI оставался тонкой оболочкой.
import { readFileSync, existsSync } from "node:fs";
import { join } from "node:path";
import { REPO_ROOT } from "./repo.mjs";

export const ENV_PATH = join(REPO_ROOT, ".env");

/** @returns {Record<string, string>} */
export function readEnv() {
  if (!existsSync(ENV_PATH)) return {};
  const out = {};
  for (const line of readFileSync(ENV_PATH, "utf8").split("\n")) {
    const m = line.match(/^([A-Z][A-Z0-9_]*)=(.*)$/);
    if (m) out[m[1]] = m[2];
  }
  return out;
}

export function envExists() {
  return existsSync(ENV_PATH);
}
