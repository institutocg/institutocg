import "server-only";
import type { PoolClient } from "pg";
import type { Regra } from "./regras";

type Db = PoolClient;

export interface Limites {
  limiteReativacaoDia: number;
  intervaloMinContatoDias: number;
}

export async function carregarRegras(
  db: Db,
  clinicaId: string,
): Promise<{ regras: Regra[]; limites: Limites }> {
  // Uma consulta de cada vez: a conexão (transação) é compartilhada.
  const regras = await db.query<Regra>(
    `select r.id, r.situacao, r.nome, r.quando, r.ativa, r.titulo_modelo, r.prazo_dias, r.intervalos, r.prioridade,
              r.ao_esgotar, r.espera_reativacao_dias, r.periodo_meses, r.mensagem_situacao,
              (select m.texto from public.modelos_mensagem m
                where m.clinica_id = r.clinica_id and m.situacao = r.mensagem_situacao and m.ativo
                order by m.criado_em limit 1) as mensagem
         from public.regras_followup r
        where r.clinica_id = $1`,
    [clinicaId],
  );
  const cfg = await db.query<{ configuracoes: Record<string, unknown> }>(
    "select configuracoes from public.clinicas where id = $1",
    [clinicaId],
  );
  const c = cfg.rows[0]?.configuracoes ?? {};
  return {
    regras: regras.rows,
    limites: {
      limiteReativacaoDia: Number(c.limite_reativacao_dia ?? 10),
      intervaloMinContatoDias: Number(c.intervalo_min_contato_dias ?? 3),
    },
  };
}
