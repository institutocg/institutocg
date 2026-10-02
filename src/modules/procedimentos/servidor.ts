import "server-only";
import type { PoolClient } from "pg";
import { z } from "zod";

/**
 * Procedimento é sempre digitável: recebe o nome escrito (ou o id de um já
 * cadastrado) e devolve o id — acha o existente (sem acento/maiúsculas) ou cria.
 */
export async function resolverProcedimento(db: PoolClient, clinicaId: string, valor: string | null | undefined): Promise<string | null> {
  const texto = (valor ?? "").trim();
  if (!texto) return null;
  if (z.uuid().safeParse(texto).success) return texto;
  const { rows } = await db.query<{ id: string | null }>("select public.procedimento_por_nome($1, $2) as id", [clinicaId, texto]);
  return rows[0].id;
}
