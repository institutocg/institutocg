"use server";

import { revalidatePath } from "next/cache";
import { z } from "zod";
import { comoUsuaria, mensagemDeErro } from "@/lib/db";
import { formatarMoeda } from "@/lib/moeda";
import { exigirSessao } from "@/modules/sessao/sessao";
import type { Retorno } from "../hoje/acoes";

const uuid = z.uuid();
const data = z.string().regex(/^\d{4}-\d{2}-\d{2}$/, "Data inválida.");

export interface FormaPagamento {
  id: string;
  nome: string;
  permite_parcelamento: boolean;
  max_parcelas: number;
  recebe_na_hora: boolean;
}

export async function listarFormas(): Promise<FormaPagamento[]> {
  const sessao = await exigirSessao();
  return comoUsuaria(sessao.usuarioId, async (db) => {
    const { rows } = await db.query<FormaPagamento>(
      `select id, nome, permite_parcelamento, max_parcelas, recebe_na_hora
         from public.formas_pagamento where clinica_id = $1 and ativo order by ordem`,
      [sessao.clinicaId],
    );
    return rows;
  });
}

const esquemaPagamento = z.object({
  parcelaId: uuid,
  valorCentavos: z.number().int().positive("Informe o valor recebido.").optional(),
  data: data.optional(),
  formaId: z.union([z.literal(""), uuid]).optional(),
  observacao: z.string().trim().max(300).optional(),
});

/** Pagamento total ou parcial, com data e forma. */
export async function registrarPagamento(dados: z.input<typeof esquemaPagamento>): Promise<Retorno> {
  const lido = esquemaPagamento.safeParse(dados);
  if (!lido.success) return { ok: false, erro: lido.error.issues[0].message };
  const v = lido.data;
  const sessao = await exigirSessao();
  try {
    const r = await comoUsuaria(sessao.usuarioId, async (db) => {
      const { rows } = await db.query<{ r: { status: string; saldo_centavos: number } }>(
        "select public.registrar_pagamento($1, $2, $3::date, $4::uuid, $5) as r",
        [v.parcelaId, v.valorCentavos ?? null, v.data ?? null, v.formaId || null, v.observacao || null],
      );
      return rows[0].r;
    });
    revalidatePath("/", "layout");
    return {
      ok: true,
      mensagem:
        r.status === "paga"
          ? "Pagamento registrado."
          : `Pagamento parcial registrado. Saldo de ${formatarMoeda(Number(r.saldo_centavos))} continua no lembrete.`,
    };
  } catch (erro) {
    return { ok: false, erro: mensagemDeErro(erro) };
  }
}

export async function mudarVencimento(parcelaId: string, novaData: string, observacao: string): Promise<Retorno> {
  if (!uuid.safeParse(parcelaId).success || !data.safeParse(novaData).success) return { ok: false, erro: "Escolha a nova data." };
  const sessao = await exigirSessao();
  try {
    await comoUsuaria(sessao.usuarioId, (db) =>
      db.query("select public.mudar_vencimento($1, $2::date, $3)", [parcelaId, novaData, observacao.trim() || null]),
    );
    revalidatePath("/", "layout");
    return { ok: true, mensagem: `Nova data: ${novaData.split("-").reverse().join("/")}. O lembrete acompanha.` };
  } catch (erro) {
    return { ok: false, erro: mensagemDeErro(erro) };
  }
}

const centavos = z.number().int().min(0);
const esquemaNegociacao = z.object({
  pessoaId: uuid,
  procedimentoId: z.union([z.literal(""), uuid]),
  valorCentavos: centavos.positive("Informe o valor."),
  descontoCentavos: centavos.default(0),
  entradaCentavos: centavos.default(0),
  entradaEm: z.union([z.literal(""), data]),
  entradaFormaId: z.union([z.literal(""), uuid]),
  parcelas: z.number().int().min(1).max(60),
  primeiroVencimento: z.union([z.literal(""), data]),
  formaId: uuid.or(z.literal("")).refine((v) => v !== "", "Escolha a forma de pagamento."),
  observacao: z.string().trim().max(1000).optional(),
});

export type DadosNegociacao = z.input<typeof esquemaNegociacao>;

/** Registra a negociação (venda) com entrada, parcelas e lembretes automáticos. */
export async function registrarNegociacao(dados: DadosNegociacao): Promise<Retorno> {
  const lido = esquemaNegociacao.safeParse(dados);
  if (!lido.success) return { ok: false, erro: lido.error.issues[0].message };
  const v = lido.data;
  const sessao = await exigirSessao();
  try {
    const r = await comoUsuaria(sessao.usuarioId, async (db) => {
      const { rows } = await db.query<{ r: { parcelas: number; lembretes: number } }>(
        `select public.registrar_negociacao($1, $2, $3::uuid, $4, $5, $6, $7::date, $8::uuid, $9, $10::date, $11::uuid, $12) as r`,
        [
          sessao.clinicaId, v.pessoaId, v.procedimentoId || null, v.valorCentavos, v.descontoCentavos, v.entradaCentavos,
          v.entradaEm || null, v.entradaFormaId || null, v.parcelas, v.primeiroVencimento || null, v.formaId, v.observacao || null,
        ],
      );
      return rows[0].r;
    });
    revalidatePath("/", "layout");
    return {
      ok: true,
      mensagem:
        r.lembretes > 0
          ? `Negociação registrada: ${r.parcelas} ${r.parcelas === 1 ? "pagamento" : "pagamentos"} e ${r.lembretes} ${r.lembretes === 1 ? "lembrete" : "lembretes"} no painel.`
          : "Negociação registrada e quitada.",
    };
  } catch (erro) {
    return { ok: false, erro: mensagemDeErro(erro) };
  }
}
