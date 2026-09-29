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
