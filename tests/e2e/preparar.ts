import { execFileSync } from "node:child_process";

/** Recria o banco local com os dados fictícios antes dos testes. */
export default function preparar() {
  execFileSync("./scripts/banco-local.sh", ["recriar"], { stdio: "inherit" });
}
