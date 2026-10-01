import "server-only";
import { Pool, types, type PoolClient } from "pg";

// Datas de calendário chegam como texto "AAAA-MM-DD" (sem conversão de fuso) e
// valores bigint (centavos) como número.
types.setTypeParser(1082, (valor) => valor);
types.setTypeParser(20, (valor) => Number(valor));

/**
 * Conexão direta com o PostgreSQL (Supabase).
 *
 * Toda consulta feita em nome de uma usuária roda dentro de uma transação com o
 * papel "authenticated" e o id dela nas claims — exatamente como o Supabase faz.
 * Assim as regras de acesso (RLS) do banco valem também aqui no servidor.
 */
const global = globalThis as unknown as { crmPool?: Pool };

function criarPool() {
  const url = process.env.DATABASE_URL;
  if (!url) throw new Error("DATABASE_URL não configurada (veja .env.example).");
  // Fora do computador (Supabase), a conexão é sempre criptografada.
  const local = /@(localhost|127\.0\.0\.1)[:/]/.test(url);
  const novo = new Pool({
    connectionString: url,
    max: 5,
    idleTimeoutMillis: 10_000,
    ssl: local || /sslmode=/.test(url) ? undefined : { rejectUnauthorized: false },
  });
  // Conexão ociosa derrubada (reinício do banco, rede): registra e segue; o pool abre outra.
  novo.on("error", (erro) => console.error("Conexão com o banco encerrada", erro.message));
  return novo;
}

export function pool(): Pool {
  global.crmPool ??= criarPool();
  return global.crmPool;
}

export type Consulta = PoolClient["query"];

/** Executa `fn` como a usuária informada (RLS ativo). */
export async function comoUsuaria<T>(usuarioId: string, fn: (db: PoolClient) => Promise<T>): Promise<T> {
  const cliente = await pool().connect();
  try {
    await cliente.query("begin");
    await cliente.query(
      "select set_config('request.jwt.claims', $1, true), set_config('request.jwt.claim.sub', $2, true)",
      [JSON.stringify({ sub: usuarioId, role: "authenticated" }), usuarioId],
    );
    await cliente.query("set local role authenticated");
    const resultado = await fn(cliente);
    await cliente.query("commit");
    return resultado;
  } catch (erro) {
    await cliente.query("rollback").catch(() => {});
    throw erro;
  } finally {
    cliente.release();
  }
}

/** Mensagem amigável para erros vindos do banco. */
export function mensagemDeErro(erro: unknown): string {
  const e = erro as { code?: string; message?: string };
  // Erros de regra de negócio (P0001/P0002/42501) já são escritos em português.
  if (e?.code && ["P0001", "P0002", "42501"].includes(e.code) && e.message) return e.message;
  if (e?.code === "23505") return "Este registro já existe.";
  if (e?.code === "23514" || e?.code === "23503") return "Não foi possível salvar: algum dado está inconsistente.";
  console.error(erro);
  return "Não foi possível concluir agora. Tente novamente em instantes.";
}
