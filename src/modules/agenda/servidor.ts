import "server-only";
import type { PoolClient } from "pg";
import { somarDias, type DataCivil } from "@/lib/datas";
import type { Consulta, Recuperacao } from "./agenda";

type Db = PoolClient;

export interface Opcao {
  id: string;
  nome: string;
}

export interface DentistaAgenda extends Opcao {
  cor: string;
}

export interface DadosAgenda {
  hoje: DataCivil;
  consultas: Consulta[];
  recuperacao: Recuperacao[];
  recuperadas30: { total: number; recuperadas: number };
  profissionais: DentistaAgenda[];
  procedimentos: Opcao[];
  motivos: Opcao[];
}

// Uma consulta de cada vez: a conexão (transação) é compartilhada.
export async function carregarAgenda(db: Db, clinicaId: string, segunda: DataCivil): Promise<DadosAgenda> {
  const hoje = (await db.query<{ hoje: string }>("select public.hoje_clinica($1) as hoje", [clinicaId])).rows[0].hoje;
  const consultas = await db.query<Consulta>(
    `select id, pessoa_id, pessoa_nome, whatsapp, tipo, status, dia, horario, duracao_min, procedimento_id, procedimento,
            profissional_id, profissional, profissional_cor, motivo, observacoes, remarcado_para, recuperacao
       from public.v_agenda
      where clinica_id = $1 and dia between $2::date and $3::date
      order by dia, horario, pessoa_nome`,
    [clinicaId, segunda, somarDias(segunda, 6)],
  );
  const recuperacao = await db.query<Recuperacao>(
    `select agendamento_id, pessoa_id, pessoa_nome, whatsapp, tipo, status, inicio, duracao_min, profissional_id,
            procedimento, motivo, observacoes,
            tarefa_id, tarefa_titulo, tarefa_vence_em, mensagem_sugerida, proxima_acao, proxima_acao_em, desfecho,
            situacao, remarcado_para
       from public.v_recuperacao
      where clinica_id = $1 and situacao in ('sem_acao', 'a_recuperar', 'acompanhando')
      order by case situacao when 'sem_acao' then 0 when 'a_recuperar' then 1 else 2 end,
               coalesce(tarefa_vence_em, proxima_acao_em), inicio`,
    [clinicaId],
  );
  const taxa = await db.query<{ total: number; recuperadas: number }>(
    `select count(*)::int as total, count(*) filter (where situacao = 'recuperado')::int as recuperadas
       from public.v_recuperacao where clinica_id = $1 and status_em >= now() - interval '30 days'`,
    [clinicaId],
  );
  const profissionais = await db.query<DentistaAgenda>(
    "select id, nome, cor from public.profissionais where clinica_id = $1 and ativo order by criado_em",
    [clinicaId],
  );
  const procedimentos = await db.query<Opcao>(
    "select id, nome from public.procedimentos where clinica_id = $1 and ativo order by ordem, nome",
    [clinicaId],
  );
  const motivos = await db.query<Opcao>(
    "select id, nome from public.motivos where clinica_id = $1 and aplica_a = 'desmarcou' and ativo order by ordem",
    [clinicaId],
  );
  return {
    hoje,
    consultas: consultas.rows,
    recuperacao: recuperacao.rows,
    recuperadas30: taxa.rows[0],
    profissionais: profissionais.rows,
    procedimentos: procedimentos.rows,
    motivos: motivos.rows,
  };
}

/** Quantas desmarcações/faltas esperam recuperação (para o menu). */
export async function contarARecuperar(db: Db, clinicaId: string): Promise<number> {
  const { rows } = await db.query<{ n: number }>(
    "select count(*)::int as n from public.v_recuperacao where clinica_id = $1 and situacao in ('a_recuperar', 'sem_acao')",
    [clinicaId],
  );
  return rows[0].n;
}
