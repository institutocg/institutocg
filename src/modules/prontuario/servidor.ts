import "server-only";
import type { PoolClient } from "pg";
import type { ParcelaFin } from "@/modules/financeiro/financeiro";
import type { DataCivil } from "@/lib/datas";
import type { ItemPlano, ResumoConsulta } from "./prontuario";

type Db = PoolClient;

export interface PacienteProntuario {
  id: string;
  nome: string;
  data_nascimento: DataCivil | null;
  whatsapp: string | null;
  tipo_cadastro: "novo_contato" | "paciente_antigo";
  prontuario_id: string;
}

export interface ProximaConsulta {
  id: string;
  dia: DataCivil;
  horario: string;
  tipo: string;
  procedimento: string | null;
  profissional: string | null;
  status: string;
}

export interface Financeiro {
  em_aberto: number;
  atrasado: number;
  pago: number;
  parcelas: ParcelaFin[];
}

// Uma consulta de cada vez: a conexão (transação) é compartilhada.
export async function carregarPaciente(db: Db, pessoaId: string): Promise<PacienteProntuario | null> {
  const { rows } = await db.query<PacienteProntuario>(
    `select p.id, p.nome, p.data_nascimento, coalesce(p.whatsapp_e164, p.telefone_e164) as whatsapp, p.tipo_cadastro,
            pr.id as prontuario_id
       from public.prontuarios pr join public.pessoas p on p.id = pr.pessoa_id
      where pr.pessoa_id = $1`,
    [pessoaId],
  );
  return rows[0] ?? null;
}

export async function carregarConsultas(db: Db, pessoaId: string): Promise<ResumoConsulta[]> {
  const { rows } = await db.query<ResumoConsulta>(
    `select id, numero, data, horario, tipo, procedimento, profissional, profissional_cor, status, motivo, anamnese,
            diagnostico, retorno_em, realizados, procedimentos_realizados
       from public.v_atendimentos where pessoa_id = $1 order by data desc, numero desc`,
    [pessoaId],
  );
  return rows;
}

export async function carregarPlano(db: Db, pessoaId: string): Promise<ItemPlano[]> {
  const { rows } = await db.query<ItemPlano>(
    `select id, procedimento_id, procedimento, dente, status, valor_centavos, atendimento_numero, realizado_atendimento_id,
            realizado_atendimento_numero, realizado_em, venda_id, financeiro, saldo_centavos, proximo_vencimento
       from public.v_plano_tratamento where pessoa_id = $1
      order by case status when 'realizado' then 1 when 'cancelado' then 3 when 'nao_realizado' then 2 else 0 end,
               realizado_em desc nulls last, criado_em`,
    [pessoaId],
  );
  return rows;
}

export async function carregarProximas(db: Db, pessoaId: string): Promise<ProximaConsulta[]> {
  const { rows } = await db.query<ProximaConsulta>(
    `select id, dia, horario, tipo, procedimento, profissional, status from public.v_agenda
      where pessoa_id = $1 and status in ('agendado', 'confirmado') and fim >= now()
      order by inicio limit 3`,
    [pessoaId],
  );
  return rows;
}

/** Situação financeira do paciente (as mesmas parcelas do módulo Financeiro). */
export async function carregarFinanceiro(db: Db, pessoaId: string): Promise<Financeiro> {
  const resumo = await db.query<{ em_aberto: number; atrasado: number; pago: number }>(
    `select coalesce(sum(saldo_centavos) filter (where situacao <> 'pago'), 0)::bigint as em_aberto,
            coalesce(sum(saldo_centavos) filter (where situacao = 'atrasado'), 0)::bigint as atrasado,
            coalesce(sum(valor_pago_centavos), 0)::bigint as pago
       from public.v_financeiro_parcelas where pessoa_id = $1`,
    [pessoaId],
  );
  const parcelas = await db.query<ParcelaFin>(
    `select * from public.v_financeiro_parcelas where pessoa_id = $1 and situacao <> 'pago' order by vencimento limit 20`,
    [pessoaId],
  );
  return { ...resumo.rows[0], parcelas: parcelas.rows };
}

export async function carregarCatalogo(db: Db, clinicaId: string) {
  const procedimentos = await db.query<{ id: string; nome: string; ticket_medio_centavos: number | null }>(
    "select id, nome, ticket_medio_centavos from public.procedimentos where clinica_id = $1 and ativo order by ordem, nome",
    [clinicaId],
  );
  const formas = await db.query<{ id: string; nome: string; max_parcelas: number; recebe_na_hora: boolean }>(
    "select id, nome, max_parcelas, recebe_na_hora from public.formas_pagamento where clinica_id = $1 and ativo order by ordem",
    [clinicaId],
  );
  const profissionais = await db.query<{ id: string; nome: string }>(
    "select id, nome from public.profissionais where clinica_id = $1 and ativo order by criado_em",
    [clinicaId],
  );
  return { procedimentos: procedimentos.rows, formas: formas.rows, profissionais: profissionais.rows };
}
