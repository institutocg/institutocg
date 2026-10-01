"use server";

import { revalidatePath } from "next/cache";
import { z } from "zod";
import { comoUsuaria, mensagemDeErro } from "@/lib/db";
import { formatarMoeda, paraCentavos } from "@/lib/moeda";
import { esquemaFicha, normalizarOdontograma, STATUS_MANUAIS, type Ficha, type StatusItem } from "@/modules/prontuario/prontuario";
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

const esquemaItem = z.object({
  pessoaId: uuid,
  procedimentoId: uuid,
  valor: z.string().trim().min(1, "Informe o valor.").max(20),
  dente: z.string().trim().max(60).optional(),
  atendimentoId: z.union([z.literal(""), uuid]).optional(),
  status: z.enum(["orcado", "aceito", "pendente"]).default("orcado"),
});

export async function adicionarAoPlano(dados: z.input<typeof esquemaItem>): Promise<Retorno> {
  const sessao = await sessaoProntuario();
  if (!sessao) return { ok: false, erro: SEM_ACESSO };
  const lido = esquemaItem.safeParse(dados);
  if (!lido.success) return { ok: false, erro: lido.error.issues[0].message };
  const v = lido.data;
  const centavos = paraCentavos(v.valor);
  if (centavos === null) return { ok: false, erro: "Valor inválido. Ex.: 1.200,00" };
  try {
    await comoUsuaria(sessao.usuarioId, (db) =>
      db.query("select public.adicionar_item_plano($1, $2, $3, $4, $5::uuid, $6::public.status_item_plano)", [
        v.pessoaId, v.procedimentoId, centavos, v.dente || null, v.atendimentoId || null, v.status,
      ]),
    );
    revalidatePath("/prontuario", "layout");
    return { ok: true, mensagem: `Adicionado ao plano de tratamento (${formatarMoeda(centavos)}).` };
  } catch (erro) {
    return { ok: false, erro: mensagemDeErro(erro) };
  }
}

export async function mudarStatusDoItem(itemId: string, status: StatusItem): Promise<Retorno> {
  const sessao = await sessaoProntuario();
  if (!sessao) return { ok: false, erro: SEM_ACESSO };
  if (!uuid.safeParse(itemId).success || !STATUS_MANUAIS.includes(status)) return { ok: false, erro: "Status inválido." };
  try {
    await comoUsuaria(sessao.usuarioId, (db) =>
      db.query("select public.mudar_status_item($1, $2::public.status_item_plano)", [itemId, status]),
    );
    revalidatePath("/prontuario", "layout");
    return { ok: true, mensagem: "Status atualizado." };
  } catch (erro) {
    return { ok: false, erro: mensagemDeErro(erro) };
  }
}

const esquemaRealizar = z
  .object({
    itemId: uuid,
    atendimentoId: uuid,
    como: z.enum(["pago", "parcial", "a_pagar", "ja_registrado", "sem_cobranca"]),
    valor: z.string().trim().max(20).optional(),
    formaId: z.union([z.literal(""), uuid]).optional(),
    pagoAgora: z.string().trim().max(20).optional(),
    vencimento: z.union([z.literal(""), z.string().regex(/^\d{4}-\d{2}-\d{2}$/, "Data inválida.")]).optional(),
    parcelas: z.coerce.number().int().min(1, "Parcelas: de 1 a 60.").max(60, "Parcelas: de 1 a 60.").default(1),
    vendaId: z.union([z.literal(""), uuid]).optional(),
  })
  .superRefine((v, ctx) => {
    if (v.como === "ja_registrado" && !v.vendaId) ctx.addIssue({ code: "custom", message: "Escolha o pagamento que já está no Financeiro." });
    if (v.como === "pago" || v.como === "parcial" || v.como === "a_pagar") {
      if (!v.valor || !paraCentavos(v.valor)) ctx.addIssue({ code: "custom", message: "Informe o valor. Ex.: 1.200,00" });
      else if (!v.formaId) ctx.addIssue({ code: "custom", message: "Escolha a forma de pagamento." });
      else if (v.como === "parcial" && (!v.pagoAgora || !paraCentavos(v.pagoAgora)))
        ctx.addIssue({ code: "custom", message: "Informe quanto foi pago agora." });
    }
  });

const MENSAGEM_REALIZAR = {
  pago: "Realizado e pago. O pagamento já está no Financeiro.",
  parcial: "Realizado. A parte paga e o saldo (com lembrete) estão no Financeiro.",
  a_pagar: "Realizado. O pagamento ficou no Financeiro, com lembrete na data prevista.",
  ja_registrado: "Realizado e ligado ao pagamento que já estava no Financeiro.",
  sem_cobranca: "Realizado, sem cobrança.",
} as const;

/** Procedimento realizado nesta consulta + como ficou o pagamento (Financeiro existente). */
export async function realizarProcedimento(dados: z.input<typeof esquemaRealizar>): Promise<Retorno> {
  const sessao = await sessaoProntuario();
  if (!sessao) return { ok: false, erro: SEM_ACESSO };
  const lido = esquemaRealizar.safeParse(dados);
  if (!lido.success) return { ok: false, erro: lido.error.issues[0].message };
  const v = lido.data;
  const cobra = v.como === "pago" || v.como === "parcial" || v.como === "a_pagar";
  try {
    const r = await comoUsuaria(sessao.usuarioId, async (db) => {
      const { rows } = await db.query<{ r: { situacao: string | null } }>(
        `select public.realizar_item($1, $2, $3, $4::bigint, $5::uuid, $6::bigint, $7::date, $8, $9::uuid) as r`,
        [
          v.itemId, v.atendimentoId, v.como, cobra ? paraCentavos(v.valor ?? "") : null, cobra ? v.formaId || null : null,
          v.como === "parcial" ? paraCentavos(v.pagoAgora ?? "") : null,
          v.como === "parcial" || v.como === "a_pagar" ? v.vencimento || null : null, v.parcelas,
          v.como === "ja_registrado" ? v.vendaId || null : null,
        ],
      );
      return rows[0].r;
    });
    revalidatePath("/", "layout");
    const mensagem = cobra && r.situacao === "pago" && v.como !== "pago" ? "Realizado. Cartão: recebido na hora." : MENSAGEM_REALIZAR[v.como];
    return { ok: true, mensagem };
  } catch (erro) {
    return { ok: false, erro: mensagemDeErro(erro) };
  }
}

export interface NegociacaoPaciente {
  id: string;
  descricao: string;
  situacao: string;
}

export async function negociacoesDoPaciente(pessoaId: string): Promise<NegociacaoPaciente[]> {
  const sessao = await sessaoProntuario();
  if (!sessao || !sessao.podeVerFinanceiro || !uuid.safeParse(pessoaId).success) return [];
  return comoUsuaria(sessao.usuarioId, async (db) => {
    const { rows } = await db.query<NegociacaoPaciente>("select * from public.negociacoes_do_paciente($1)", [pessoaId]);
    return rows;
  });
}
