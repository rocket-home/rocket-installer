import { fileURLToPath } from "node:url";
import { dirname, resolve } from "node:path";

// scripts/rocket-control/lib/ → корень репозитория
export const REPO_ROOT = resolve(
  dirname(fileURLToPath(import.meta.url)),
  "../../..",
);
