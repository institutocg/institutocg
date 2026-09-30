import "server-only";
import type { PoolClient } from "pg";
import { comoUsuaria } from "@/lib/db";
import type { Sessao } from "@/modules/sessao/sessao";
import { DIAS_PROXIMOS, montarPainel, type Painel, type TarefaAberta } from "./painel";

export interface Motivo {
  id: string;
  nome: string;
  aplica_a: "nao_fechou" | "desistiu";
  retorno_sugerido_dias: number | null;
}

const COLUNAS = `
  id, pessoa_id, oportunidade_id, agendamento_id, parcela_id, tipo, titulo, descricao, vence_em, horario,
  prioridade, passo, regra, mensagem_sugerida, pessoa_nome, whatsapp_e164, telefone_e164, origem_nome,
  primeiro_contato_em, procedimento, etapa_marco, orcamento_apresentado_em, orcamento_valor_centavos,
  agendamento_inicio, agendamento_tipo, parcela_numero, parcela_vencimento, parcela_saldo_centavos, parcela_total, regra_nome`;

export async function carregarPainel(sessao: Sessao): Promise<{ painel: Painel; motivos: Motivo[] }> {
  return comoUsuaria(sessao.usuarioId, async (db) => {
    // Rotina do dia (uma vez por dia): expira orçamentos, garante próximas ações,
    // cria reativações. Se falhar, o painel abre mesmo assim.
    await db.query("savepoint rotina");
    try {
      await db.query("select public.preparar_dia($1)", [sessao.clinicaId]);
      await db.query("release savepoint rotina");
    } catch (erro) {
      await db.query("rollback to savepoint rotina");
      console.error("Rotina do dia falhou", erro);
    }

    const { rows: [{ hoje }] } = await db.query<{ hoje: string }>(
      "select public.hoje_clinica($1) as hoje",
      [sessao.clinicaId],
    );
    const { rows } = await db.query<Omit<TarefaAberta, "agendamento_inicio"> & { agendamento_inicio: Date | string | null }>(
      `select ${COLUNAS} from public.v_tarefas_abertas
        where clinica_id = $1 and vence_em <= $2::date + $3::int
        order by vence_em, horario nulls last`,
      [sessao.clinicaId, hoje, DIAS_PROXIMOS],
    );
    const tarefas = rows.map((r) => ({
      ...r,
      agendamento_inicio: r.agendamento_inicio instanceof Date ? r.agendamento_inicio.toISOString() : r.agendamento_inicio,
    }));
    const motivos = await carregarMotivos(db, sessao.clinicaId);
    return { painel: montarPainel(tarefas, hoje), motivos };
  });
}

export async function carregarMotivos(db: PoolClient, clinicaId: string): Promise<Motivo[]> {
  const { rows } = await db.query<Motivo>(
    `select id, nome, aplica_a, retorno_sugerido_dias from public.motivos
      where clinica_id = $1 and ativo and aplica_a in ('nao_fechou', 'desistiu')
      order by aplica_a, ordem`,
    [clinicaId],
  );
  return rows;
}
