"use server";

import { revalidatePath } from "next/cache";
import { z } from "zod";
import { comoUsuaria, mensagemDeErro } from "@/lib/db";
import { rotuloData } from "@/modules/painel/painel";
import { exigirSessao } from "@/modules/sessao/sessao";

export interface Sugestao {
  tipo: string | null;
  titulo: string;
  descricao: string | null;
  vence_em: string | null;
  explicacao: string;
  requer: "agendamento" | "motivo" | "financeiro" | null;
  mensagem: string | null;
}

const uuid = z.uuid();
const data = z.string().regex(/^\d{4}-\d{2}-\d{2}$/);

export async function sugerirAcao(
  oportunidadeId: string,
  etapaId: string,
  motivoId?: string | null,
): Promise<{ ok: true; sugestao: Sugestao } | { ok: false; erro: string }> {
  const sessao = await exigirSessao();
  if (!uuid.safeParse(oportunidadeId).success || !uuid.safeParse(etapaId).success) return { ok: false, erro: "Dados inválidos." };
  try {
    const s = await comoUsuaria(sessao.usuarioId, async (db) => {
      const { rows } = await db.query<{ s: Sugestao | null }>("select public.sugerir_acao($1, $2, $3) as s", [
        oportunidadeId,
        etapaId,
        motivoId && uuid.safeParse(motivoId).success ? motivoId : null,
      ]);
      return rows[0].s;
    });
    return s ? { ok: true, sugestao: s } : { ok: false, erro: "Negociação não encontrada." };
  } catch (erro) {
    return { ok: false, erro: mensagemDeErro(erro) };
  }
}

const centavos = z.number().int().nonnegative();

const esquemaMover = z.object({
  oportunidadeId: uuid,
  etapaId: uuid,
  observacao: z.string().max(1000).optional(),
  motivoId: uuid.optional(),
  criar: z.boolean(),
  titulo: z.string().max(200).optional(),
  venceEm: data.optional(),
  mensagem: z.string().max(2000).optional(),
  agendarEm: z.string().regex(/^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}$/).optional(),
  valorCentavos: centavos.optional(),
  venda: z
    .object({
      valorTotalCentavos: centavos.positive("Informe o valor do tratamento."),
      descontoCentavos: centavos.default(0),
      entradaCentavos: centavos.default(0),
      parcelas: z.number().int().min(1).max(60),
      formaPagamentoId: uuid.optional(),
      primeiroVencimento: data.optional(),
      observacao: z.string().max(500).optional(),
    })
    .refine((v) => v.descontoCentavos < v.valorTotalCentavos, "O desconto não pode ser maior que o valor.")
    .refine((v) => v.entradaCentavos <= v.valorTotalCentavos - v.descontoCentavos, "A entrada não pode ser maior que o valor final.")
    .optional(),
});

export type DadosMover = z.input<typeof esquemaMover>;

export async function moverEtapa(
  dados: DadosMover,
): Promise<{ ok: true; mensagem: string } | { ok: false; erro: string }> {
  const sessao = await exigirSessao();
  const lido = esquemaMover.safeParse(dados);
  if (!lido.success) return { ok: false, erro: lido.error.issues[0].message };
  const v = lido.data;

  const acao: Record<string, unknown> = { criar: v.criar };
  if (v.titulo?.trim()) acao.titulo = v.titulo.trim();
  if (v.venceEm) acao.vence_em = v.venceEm;
  if (v.mensagem?.trim()) acao.mensagem = v.mensagem.trim();
  if (v.agendarEm) acao.agendar_em = v.agendarEm;
  if (v.valorCentavos !== undefined) acao.valor_centavos = v.valorCentavos;
  if (v.venda) {
    acao.venda = {
      valor_total_centavos: v.venda.valorTotalCentavos,
      desconto_centavos: v.venda.descontoCentavos,
      entrada_centavos: v.venda.entradaCentavos,
      parcelas: v.venda.parcelas,
      forma_pagamento_id: v.venda.formaPagamentoId,
      primeiro_vencimento: v.venda.primeiroVencimento,
      observacao: v.venda.observacao,
    };
  }

  try {
    const r = await comoUsuaria(sessao.usuarioId, async (db) => {
      const { rows } = await db.query<{ r: { tarefa: { titulo: string; vence_em: string } | null; venda: string | null } }>(
        "select public.mover_etapa_manual($1, $2, $3, $4, $5::jsonb) as r",
        [v.oportunidadeId, v.etapaId, v.observacao?.trim() || null, v.motivoId ?? null, JSON.stringify(acao)],
      );
      const extra = await db.query<{ nome: string; etapa: string; hoje: string }>(
        `select split_part(p.nome, ' ', 1) as nome, e.nome as etapa, public.hoje_clinica(e.clinica_id) as hoje
           from public.etapas_funil e, public.oportunidades o join public.pessoas p on p.id = o.pessoa_id
          where e.id = $1 and o.id = $2`,
        [v.etapaId, v.oportunidadeId],
      );
      return { ...rows[0].r, ...extra.rows[0] };
    });
    revalidatePath("/", "layout");
    const partes = [`${r.nome} foi para “${r.etapa}”.`];
    if (r.venda) partes.push("Parcelas e lembretes de pagamento criados.");
    partes.push(
      r.tarefa
        ? `Próxima ação: ${r.tarefa.titulo} — ${rotuloData(r.tarefa.vence_em, r.hoje).toLowerCase()}.`
        : "Nenhuma ação programada.",
    );
    return { ok: true, mensagem: partes.join(" ") };
  } catch (erro) {
    return { ok: false, erro: mensagemDeErro(erro) };
  }
}
