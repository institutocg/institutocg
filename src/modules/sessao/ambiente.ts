import "server-only";
import { cache } from "react";
import { pool } from "@/lib/db";

/**
 * Versão de teste: liga quando o banco tem os dados fictícios (esquema "teste").
 * Em produção é sempre falso — lá os dados fictícios nunca são carregados.
 */
export const ambienteTeste = cache(async (): Promise<boolean> => {
  try {
    const r = await pool().query<{ teste: boolean }>("select public.ambiente_teste() as teste");
    return r.rows[0]?.teste === true;
  } catch {
    return false;
  }
});
