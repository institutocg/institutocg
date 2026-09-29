import { execFileSync } from "node:child_process";

/** Recria o banco local com os dados fictícios (cada arquivo de teste começa do zero). */
export function recriarBanco() {
  execFileSync("./scripts/banco-local.sh", ["recriar"], { stdio: "ignore" });
}
