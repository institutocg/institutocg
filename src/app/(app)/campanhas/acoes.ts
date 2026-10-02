"use server";

import { revalidatePath } from "next/cache";
import { z } from "zod";
import { comoUsuaria, mensagemDeErro } from "@/lib/db";
import type { Destinatario } from "@/modules/campanhas/campanhas";
import { exigirSessao } from "@/modules/sessao/sessao";
import type { Retorno } from "../hoje/acoes";

const esquemaFiltro = z.object({
  segmento: z.enum([
    "inativos", "procedimento", "nao_fecharam", "tratamento_pendente", "avaliacao_nao_agendada", "aniversario",
    "pos_tratamento", "interesse", "desmarcou", "especiais",
  ]),
  meses: z.coerce.number({ error: "Informe os meses." }).int().min(1, "Meses entre 1 e 120.").max(120, "Meses entre 1 e 120."),
  procedimentoId: z.union([z.literal(""), z.uuid()]),
  somenteMarketing: z.boolean(),
});

export type Filtro = z.input<typeof esquemaFiltro>;

/** Prévia: quem entraria na campanha (já sem quem não aceita contato ou está negociando). */
export async function preverCampanha(filtro: Filtro): Promise<{ ok: true; pessoas: Destinatario[] } | { ok: false; erro: string }> {
  const sessao = await exigirSessao();
  const lido = esquemaFiltro.safeParse(filtro);
  if (!lido.success) return { ok: false, erro: lido.error.issues[0].message };
  const f = lido.data;
  if ((f.segmento === "procedimento" || f.segmento === "interesse") && !f.procedimentoId) return { ok: false, erro: "Escolha o procedimento." };
  try {
    const pessoas = await comoUsuaria(sessao.usuarioId, async (db) => {
      const { rows } = await db.query<Destinatario>(
        "select pessoa_id, nome, detalhe, referencia from public.prever_campanha($1, $2, $3, $4::uuid, $5) limit 500",
        [sessao.clinicaId, f.segmento, f.meses, f.procedimentoId || null, f.somenteMarketing],
      );
      return rows;
    });
    return { ok: true, pessoas };
  } catch (erro) {
    return { ok: false, erro: mensagemDeErro(erro) };
  }
}

const esquemaCampanha = esquemaFiltro.extend({
  nome: z.string().trim().min(2, "Dê um nome à campanha.").max(80),
  mensagem: z.string().trim().min(10, "Escreva a mensagem sugerida.").max(2000),
  limiteDia: z.coerce.number().int().min(1, "Limite entre 1 e 50 por dia.").max(50, "Limite entre 1 e 50 por dia."),
  iniciaEm: z.string().regex(/^\d{4}-\d{2}-\d{2}$/, "Escolha a data de início."),
  pessoas: z.array(z.uuid()).min(1, "Selecione ao menos uma pessoa."),
});

export type DadosCampanha = z.input<typeof esquemaCampanha>;

export async function criarCampanha(dados: DadosCampanha): Promise<Retorno> {
  const sessao = await exigirSessao();
  if (sessao.papel !== "admin") return { ok: false, erro: "Somente a administradora cria campanhas." };
  const lido = esquemaCampanha.safeParse(dados);
  if (!lido.success) return { ok: false, erro: lido.error.issues[0].message };
  const v = lido.data;
  try {
    const r = await comoUsuaria(sessao.usuarioId, async (db) => {
      const { rows } = await db.query<{ r: { pessoas: number; primeiro_dia: string; ultimo_dia: string } }>(
        "select public.criar_campanha($1, $2, $3, $4, $5::uuid, $6, $7, $8, $9::date, $10::uuid[]) as r",
        [sessao.clinicaId, v.nome, v.segmento, v.meses, v.procedimentoId || null, v.somenteMarketing, v.mensagem,
         v.limiteDia, v.iniciaEm, v.pessoas],
      );
      return rows[0].r;
    });
    revalidatePath("/", "layout");
    const br = (d: string) => d.split("-").reverse().join("/");
    const periodo = r.primeiro_dia === r.ultimo_dia ? `em ${br(r.primeiro_dia)}` : `de ${br(r.primeiro_dia)} a ${br(r.ultimo_dia)}`;
    return {
      ok: true,
      mensagem: `Campanha criada: ${r.pessoas} ${r.pessoas === 1 ? "contato programado" : "contatos programados"} ${periodo}. Os contatos aparecem em “Hoje” na data programada.`,
    };
  } catch (erro) {
    return { ok: false, erro: mensagemDeErro(erro) };
  }
}

export async function encerrarCampanha(id: string): Promise<Retorno> {
  const sessao = await exigirSessao();
  if (!z.uuid().safeParse(id).success) return { ok: false, erro: "Campanha inválida." };
  try {
    const n = await comoUsuaria(sessao.usuarioId, async (db) => {
      const { rows } = await db.query<{ n: number }>("select public.encerrar_campanha($1) as n", [id]);
      return rows[0].n;
    });
    revalidatePath("/", "layout");
    return { ok: true, mensagem: `Campanha encerrada. ${n} ${n === 1 ? "contato ainda não feito foi cancelado" : "contatos ainda não feitos foram cancelados"}.` };
  } catch (erro) {
    return { ok: false, erro: mensagemDeErro(erro) };
  }
}
