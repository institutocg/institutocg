"use server";

import { revalidatePath } from "next/cache";
import { z } from "zod";
import { comoUsuaria, mensagemDeErro } from "@/lib/db";
import { rotuloData } from "@/modules/painel/painel";
import { exigirSessao } from "@/modules/sessao/sessao";

export type Retorno = { ok: true; mensagem: string } | { ok: false; erro: string };

const uuid = z.uuid();
const data = z.string().regex(/^\d{4}-\d{2}-\d{2}$/, "Data inválida.");

const RESULTADOS = [
  "respondeu_interesse", "agendou", "vai_pensar", "pediu_retorno", "nao_respondeu", "fechou",
  "nao_fechou", "desistiu", "nao_contatar", "numero_invalido", "confirmou", "desmarcou", "prometeu_pagar",
] as const;

const esquemaRegistro = z
  .object({
    tarefaId: uuid,
    resultado: z.enum(RESULTADOS),
    canal: z.enum(["whatsapp", "ligacao", "presencial", "email", "instagram", "outro"]).optional(),
    observacao: z.string().max(1000).optional(),
    data: data.optional(),
    motivoId: uuid.optional(),
    agendarEm: z.string().regex(/^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}$/, "Informe data e horário.").optional(),
  })
  .superRefine((v, ctx) => {
    if (v.resultado === "agendou" && !v.agendarEm)
      ctx.addIssue({ code: "custom", message: "Informe a data e o horário do agendamento." });
    if ((v.resultado === "pediu_retorno" || v.resultado === "prometeu_pagar") && !v.data)
      ctx.addIssue({ code: "custom", message: "Informe a data combinada." });
    if ((v.resultado === "nao_fechou" || v.resultado === "desistiu") && !v.motivoId)
      ctx.addIssue({ code: "custom", message: "Escolha o motivo." });
  });

export type DadosRegistro = z.input<typeof esquemaRegistro>;

type Proxima = { titulo: string; vence_em: string } | null;

async function executar(
  acao: (db: Parameters<Parameters<typeof comoUsuaria>[1]>[0], clinicaId: string) => Promise<Proxima>,
  sucesso: string,
): Promise<Retorno> {
  const sessao = await exigirSessao();
  try {
    const { proxima, hoje } = await comoUsuaria(sessao.usuarioId, async (db) => {
      const proxima = await acao(db, sessao.clinicaId);
      const { rows } = await db.query<{ hoje: string }>("select public.hoje_clinica($1) as hoje", [sessao.clinicaId]);
      return { proxima, hoje: rows[0].hoje };
    });
    revalidatePath("/", "layout");
    const complemento = proxima
      ? ` Próxima ação: ${proxima.titulo} — ${rotuloData(proxima.vence_em, hoje).toLowerCase()}.`
      : "";
    return { ok: true, mensagem: `${sucesso}${complemento}` };
  } catch (erro) {
    return { ok: false, erro: mensagemDeErro(erro) };
  }
}

/** "Concluir": a ação foi feita; o sistema agenda a próxima conforme a cadência. */
export async function concluirTarefa(tarefaId: string): Promise<Retorno> {
  if (!uuid.safeParse(tarefaId).success) return { ok: false, erro: "Tarefa inválida." };
  return executar(async (db) => {
    const { rows } = await db.query<{ proxima: Proxima }>(
      "select public.registrar_acao($1, 'feito') as proxima",
      [tarefaId],
    );
    return rows[0].proxima;
  }, "Tarefa concluída.");
}

export async function registrarContato(dados: DadosRegistro): Promise<Retorno> {
  const lido = esquemaRegistro.safeParse(dados);
  if (!lido.success) return { ok: false, erro: lido.error.issues[0].message };
  const v = lido.data;
  return executar(async (db) => {
    const { rows } = await db.query<{ proxima: Proxima }>(
      `select public.registrar_acao(
         $1, $2, $3::public.canal_contato, $4, $5::date, $6::uuid,
         case when $7::text is null then null else ($7::timestamp at time zone 'America/Sao_Paulo') end
       ) as proxima`,
      [v.tarefaId, v.resultado, v.canal ?? null, v.observacao?.trim() || null, v.data ?? null, v.motivoId ?? null, v.agendarEm ?? null],
    );
    return rows[0].proxima;
  }, "Contato registrado.");
}

export async function marcarComoPago(parcelaId: string): Promise<Retorno> {
  if (!uuid.safeParse(parcelaId).success) return { ok: false, erro: "Parcela inválida." };
  return executar(async (db) => {
    await db.query("select public.marcar_parcela_paga($1)", [parcelaId]);
    return null;
  }, "Pagamento registrado.");
}

const esquemaEdicao = z.object({
  tarefaId: uuid,
  titulo: z.string().trim().min(2, "Escreva o que precisa ser feito.").max(200),
  venceEm: data.optional(),
  horario: z.union([z.literal(""), z.string().regex(/^\d{2}:\d{2}$/, "Horário inválido.")]).optional(),
  mensagem: z.string().max(2000).optional(),
});

export type DadosEdicao = z.input<typeof esquemaEdicao>;

/** Toda ação (automática ou não) pode ser ajustada: título, data, horário e mensagem. */
export async function editarTarefa(dados: DadosEdicao): Promise<Retorno> {
  const lido = esquemaEdicao.safeParse(dados);
  if (!lido.success) return { ok: false, erro: lido.error.issues[0].message };
  const v = lido.data;
  const sessao = await exigirSessao();
  try {
    const r = await comoUsuaria(sessao.usuarioId, async (db) => {
      const { rows } = await db.query<{ tipo: string; status: string; hoje: string }>(
        "select tipo, status, public.hoje_clinica(clinica_id) as hoje from public.tarefas where id = $1",
        [v.tarefaId],
      );
      const t = rows[0];
      if (!t) throw Object.assign(new Error("Tarefa não encontrada."), { code: "P0002" });
      if (t.status !== "pendente") throw Object.assign(new Error("Esta tarefa não está mais pendente."), { code: "P0001" });
      // A data do lembrete de pagamento acompanha o vencimento da parcela.
      const mudaData = t.tipo !== "confirmar_pagamento" && v.venceEm;
      if (mudaData && v.venceEm! < t.hoje) throw Object.assign(new Error("Escolha hoje ou uma data futura."), { code: "P0001" });
      await db.query(
        `update public.tarefas set titulo = $2, vence_em = coalesce($3::date, vence_em), horario = $4::time,
                mensagem_sugerida = $5
          where id = $1`,
        [v.tarefaId, v.titulo, mudaData ? v.venceEm : null, v.horario || null, v.mensagem?.trim() || null],
      );
      return t;
    });
    revalidatePath("/", "layout");
    return { ok: true, mensagem: r.tipo === "confirmar_pagamento" && v.venceEm ? "Ação atualizada (a data segue o vencimento da parcela)." : "Ação atualizada." };
  } catch (erro) {
    return { ok: false, erro: mensagemDeErro(erro) };
  }
}

/** "Não fazer esta ação": cancela a tarefa, registrando o motivo. */
export async function cancelarTarefa(tarefaId: string, motivo: string): Promise<Retorno> {
  if (!uuid.safeParse(tarefaId).success) return { ok: false, erro: "Tarefa inválida." };
  const sessao = await exigirSessao();
  try {
    await comoUsuaria(sessao.usuarioId, async (db) => {
      const { rows } = await db.query<{ tipo: string; status: string }>("select tipo, status from public.tarefas where id = $1", [tarefaId]);
      if (!rows[0]) throw Object.assign(new Error("Tarefa não encontrada."), { code: "P0002" });
      if (rows[0].status !== "pendente") throw Object.assign(new Error("Esta tarefa não está mais pendente."), { code: "P0001" });
      if (rows[0].tipo === "confirmar_pagamento") {
        throw Object.assign(new Error("Lembretes de pagamento saem sozinhos quando o pagamento é registrado."), { code: "P0001" });
      }
      await db.query(
        "update public.tarefas set status = 'cancelada', cancelada_motivo = $2 where id = $1",
        [tarefaId, `Cancelada pela usuária${motivo.trim() ? `: ${motivo.trim().slice(0, 300)}` : ""}`],
      );
    });
    revalidatePath("/", "layout");
    return { ok: true, mensagem: "Ação cancelada. Ela fica registrada no histórico de tarefas." };
  } catch (erro) {
    return { ok: false, erro: mensagemDeErro(erro) };
  }
}
