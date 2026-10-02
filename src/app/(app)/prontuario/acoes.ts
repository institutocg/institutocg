"use server";

import { revalidatePath } from "next/cache";
import { z } from "zod";
import { comoUsuaria, mensagemDeErro } from "@/lib/db";
import { formatarMoeda, paraCentavos } from "@/lib/moeda";
import { esquemaFicha, normalizarOdontograma, type Ficha } from "@/modules/prontuario/prontuario";
import { exigirSessao } from "@/modules/sessao/sessao";
import type { Retorno } from "../hoje/acoes";

export type RetornoUrl = { ok: true; url: string } | { ok: false; erro: string };

const uuid = z.uuid();
const SEM_ACESSO = "Seu acesso não inclui o prontuário. Fale com a administradora.";

async function sessaoProntuario() {
  const sessao = await exigirSessao();
  return sessao.podeVerProntuario ? sessao : null;
}

/** Agenda → prontuário: abre a ficha da consulta do dia (cria se preciso). Consulta futura: abre o prontuário. */
export async function abrirProntuarioDaConsulta(agendamentoId: string): Promise<RetornoUrl> {
  const sessao = await sessaoProntuario();
  if (!sessao) return { ok: false, erro: SEM_ACESSO };
  if (!uuid.safeParse(agendamentoId).success) return { ok: false, erro: "Consulta inválida." };
  try {
    return await comoUsuaria(sessao.usuarioId, async (db) => {
      const { rows } = await db.query<{ pessoa_id: string; futura: boolean; encerrada: boolean }>(
        `select pessoa_id, (inicio at time zone 'America/Sao_Paulo')::date > public.hoje_clinica(clinica_id) as futura,
                status in ('desmarcado', 'remarcado', 'cancelado_clinica', 'faltou') as encerrada
           from public.agendamentos where id = $1`,
        [agendamentoId],
      );
      const a = rows[0];
      if (!a) return { ok: false, erro: "Consulta não encontrada." } as const;
      const ja = await db.query<{ id: string }>("select id from public.atendimentos where agendamento_id = $1", [agendamentoId]);
      if (!ja.rows[0] && (a.futura || a.encerrada)) return { ok: true, url: `/prontuario/${a.pessoa_id}` } as const;
      const r = await db.query<{ id: string }>("select public.abrir_atendimento($1) as id", [agendamentoId]);
      return { ok: true, url: `/prontuario/${a.pessoa_id}/consulta/${r.rows[0].id}` } as const;
    });
  } catch (erro) {
    return { ok: false, erro: mensagemDeErro(erro) };
  }
}

/** Nova consulta no prontuário (usa a consulta de hoje da agenda, se houver). */
export async function novaConsulta(pessoaId: string): Promise<RetornoUrl> {
  const sessao = await sessaoProntuario();
  if (!sessao) return { ok: false, erro: SEM_ACESSO };
  if (!uuid.safeParse(pessoaId).success) return { ok: false, erro: "Paciente inválido." };
  try {
    const id = await comoUsuaria(sessao.usuarioId, async (db) => {
      const { rows } = await db.query<{ id: string }>("select public.novo_atendimento($1) as id", [pessoaId]);
      return rows[0].id;
    });
    revalidatePath(`/prontuario/${pessoaId}`);
    return { ok: true, url: `/prontuario/${pessoaId}/consulta/${id}` };
  } catch (erro) {
    return { ok: false, erro: mensagemDeErro(erro) };
  }
}

/** Salva a ficha (e, se pedido, finaliza: a consulta não muda mais). */
export async function salvarConsulta(atendimentoId: string, dados: Ficha, finalizar = false): Promise<Retorno> {
  const sessao = await sessaoProntuario();
  if (!sessao) return { ok: false, erro: SEM_ACESSO };
  if (!uuid.safeParse(atendimentoId).success) return { ok: false, erro: "Consulta inválida." };
  const lido = esquemaFicha.safeParse(dados);
  if (!lido.success) return { ok: false, erro: lido.error.issues[0].message };
  const ficha = { ...lido.data, odontograma: normalizarOdontograma(lido.data.odontograma) };
  try {
    await comoUsuaria(sessao.usuarioId, (db) =>
      db.query("select public.salvar_atendimento($1, $2::jsonb, $3)", [atendimentoId, JSON.stringify(ficha), finalizar]),
    );
    revalidatePath("/prontuario", "layout");
    return { ok: true, mensagem: finalizar ? "Consulta finalizada. O registro fica guardado no histórico." : "Ficha salva." };
  } catch (erro) {
    return { ok: false, erro: mensagemDeErro(erro) };
  }
}

const esquemaProcedimento = z.object({
  pessoaId: uuid,
  nome: z.string().trim().min(2, "Escreva o procedimento.").max(120, "Procedimento: no máximo 120 caracteres."),
  valor: z.string().trim().max(20).default(""),
  atendimentoId: z.union([z.literal(""), uuid]).optional(),
  feito: z.boolean().default(false),
});

/** Procedimento escrito livremente + valor; pode já entrar como feito nesta consulta. */
export async function adicionarProcedimento(dados: z.input<typeof esquemaProcedimento>): Promise<Retorno> {
  const sessao = await sessaoProntuario();
  if (!sessao) return { ok: false, erro: SEM_ACESSO };
  const lido = esquemaProcedimento.safeParse(dados);
  if (!lido.success) return { ok: false, erro: lido.error.issues[0].message };
  const v = lido.data;
  const centavos = v.valor ? paraCentavos(v.valor) : 0;
  if (centavos === null) return { ok: false, erro: "Valor inválido. Ex.: 1.200,00" };
  try {
    await comoUsuaria(sessao.usuarioId, (db) =>
      db.query("select public.adicionar_procedimento_plano($1, $2, $3, $4::uuid, $5)", [
        v.pessoaId, v.nome, centavos, v.atendimentoId || null, v.feito,
      ]),
    );
    revalidatePath("/prontuario", "layout");
    return { ok: true, mensagem: `${v.nome} — ${formatarMoeda(centavos)} no plano${v.feito ? ", feito hoje" : ""}.` };
  } catch (erro) {
    return { ok: false, erro: mensagemDeErro(erro) };
  }
}

/** Feito (ou não) nesta consulta. Não mexe em pagamento. */
export async function marcarFeito(itemId: string, atendimentoId: string, feito: boolean): Promise<Retorno> {
  const sessao = await sessaoProntuario();
  if (!sessao) return { ok: false, erro: SEM_ACESSO };
  if (!uuid.safeParse(itemId).success || !uuid.safeParse(atendimentoId).success) return { ok: false, erro: "Dados inválidos." };
  try {
    await comoUsuaria(sessao.usuarioId, (db) => db.query("select public.marcar_feito($1, $2, $3)", [itemId, atendimentoId, feito]));
    revalidatePath("/prontuario", "layout");
    return { ok: true, mensagem: feito ? "Marcado como feito nesta consulta." : "Voltou para pendente." };
  } catch (erro) {
    return { ok: false, erro: mensagemDeErro(erro) };
  }
}

export async function removerDoPlano(itemId: string): Promise<Retorno> {
  const sessao = await sessaoProntuario();
  if (!sessao) return { ok: false, erro: SEM_ACESSO };
  if (!uuid.safeParse(itemId).success) return { ok: false, erro: "Dados inválidos." };
  try {
    await comoUsuaria(sessao.usuarioId, (db) => db.query("select public.remover_item_plano($1)", [itemId]));
    revalidatePath("/prontuario", "layout");
    return { ok: true, mensagem: "Removido do plano." };
  } catch (erro) {
    return { ok: false, erro: mensagemDeErro(erro) };
  }
}

const data = z.union([z.literal(""), z.string().regex(/^\d{4}-\d{2}-\d{2}$/, "Data inválida.")]);
const esquemaPagamento = z
  .object({
    planoId: uuid,
    como: z.enum(["integral", "parcial", "nao_pago"]),
    formaId: z.union([z.literal(""), uuid]),
    valorPago: z.string().trim().max(20).default(""),
    dataPagamento: data.default(""),
    vencimento: data.default(""),
    parcelas: z.coerce.number().int().min(1, "Parcelas: de 1 a 60.").max(60, "Parcelas: de 1 a 60.").default(1),
    observacao: z.string().trim().max(300).default(""),
  })
  .superRefine((v, ctx) => {
    if (!v.formaId) ctx.addIssue({ code: "custom", message: "Escolha a forma de pagamento." });
    else if (v.como === "parcial" && !paraCentavos(v.valorPago)) ctx.addIssue({ code: "custom", message: "Informe o valor pago." });
  });

/** Pagamento do PLANO (não do procedimento): integral, parcial ou não pago — no Financeiro existente. */
export async function registrarPagamentoDoPlano(dados: z.input<typeof esquemaPagamento>): Promise<Retorno> {
  const sessao = await sessaoProntuario();
  if (!sessao) return { ok: false, erro: SEM_ACESSO };
  if (!sessao.podeVerFinanceiro) return { ok: false, erro: "Seu acesso não inclui o financeiro." };
  const lido = esquemaPagamento.safeParse(dados);
  if (!lido.success) return { ok: false, erro: lido.error.issues[0].message };
  const v = lido.data;
  try {
    const r = await comoUsuaria(sessao.usuarioId, async (db) => {
      const { rows } = await db.query<{ r: { pago: number; pendente: number } }>(
        "select public.registrar_pagamento_plano($1, $2, $3, $4::bigint, $5::date, $6::date, $7, $8) as r",
        [
          v.planoId, v.como, v.formaId, v.como === "parcial" ? paraCentavos(v.valorPago) : null, v.dataPagamento || null,
          v.como === "integral" ? null : v.vencimento || null, v.como === "integral" ? 1 : v.parcelas, v.observacao || null,
        ],
      );
      return rows[0].r;
    });
    revalidatePath("/", "layout");
    return {
      ok: true,
      mensagem: `Pagamento registrado. Pago ${formatarMoeda(Number(r.pago))} · pendente ${formatarMoeda(Number(r.pendente))}.`,
    };
  } catch (erro) {
    return { ok: false, erro: mensagemDeErro(erro) };
  }
}
