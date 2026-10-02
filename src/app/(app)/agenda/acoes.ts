"use server";

import { revalidatePath } from "next/cache";
import { z } from "zod";
import { comoUsuaria, mensagemDeErro } from "@/lib/db";
import { normalizarTelefone } from "@/lib/telefone";
import { rotuloData } from "@/modules/painel/painel";
import { resolverProcedimento } from "@/modules/procedimentos/servidor";
import { exigirSessao } from "@/modules/sessao/sessao";
import type { Retorno } from "../hoje/acoes";

/** Resultado com aviso de conflito de horário (a usuária pode confirmar o encaixe). */
export type RetornoAgenda = Retorno | { ok: false; erro: string; conflito: true };

export interface PacienteEncontrado {
  id: string;
  nome: string;
  whatsapp: string | null;
  tipo_cadastro: "novo_contato" | "paciente_antigo";
  procedimento_id: string | null;
  procedimento: string | null;
  etapa: string | null;
}

const uuid = z.uuid();
const dataHora = z.string().regex(/^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}$/, "Informe a data e o horário.");
type Proxima = { titulo: string; vence_em: string } | null;

function comConflito(erro: unknown): RetornoAgenda {
  const texto = mensagemDeErro(erro);
  return texto.startsWith("Horário ocupado") ? { ok: false, erro: texto, conflito: true } : { ok: false, erro: texto };
}

async function hojeDa(db: Parameters<Parameters<typeof comoUsuaria>[1]>[0], clinicaId: string) {
  return (await db.query<{ hoje: string }>("select public.hoje_clinica($1) as hoje", [clinicaId])).rows[0].hoje;
}

function frase(p: Proxima, hoje: string) {
  return p ? ` Próxima ação: ${p.titulo} — ${rotuloData(p.vence_em, hoje).toLowerCase()}.` : "";
}

/** Pacientes já cadastrados (nome sem acento ou parte do telefone). */
export async function buscarPacientes(texto: string): Promise<PacienteEncontrado[]> {
  const sessao = await exigirSessao();
  const t = texto.trim();
  if (t.length < 2) return [];
  return comoUsuaria(sessao.usuarioId, async (db) => {
    const { rows } = await db.query<PacienteEncontrado>(
      "select * from public.buscar_pacientes($1, $2)",
      [sessao.clinicaId, t.slice(0, 60)],
    );
    return rows;
  });
}

const esquemaAgendar = z
  .object({
    pessoaId: z.union([z.literal(""), uuid]),
    nome: z.string().trim().max(120).optional(),
    whatsapp: z.string().trim().max(30).optional(),
    tipoCadastro: z.enum(["novo_contato", "paciente_antigo"]).default("novo_contato"),
    tipo: z.enum(["avaliacao", "apresentacao_orcamento", "procedimento", "retorno", "manutencao"]),
    procedimento: z.string().trim().max(120).default(""),
    inicio: dataHora,
    duracao: z.coerce.number().int().min(15).max(240),
    profissionalId: z.union([z.literal(""), uuid]),
    status: z.enum(["agendado", "confirmado"]),
    observacoes: z.string().trim().max(500).optional(),
    encaixe: z.boolean().default(false),
  })
  .superRefine((v, ctx) => {
    if (!v.pessoaId) {
      if (!v.nome || v.nome.length < 3) ctx.addIssue({ code: "custom", message: "Selecione o paciente ou informe o nome completo." });
      else if (!v.whatsapp || !normalizarTelefone(v.whatsapp)) ctx.addIssue({ code: "custom", message: "Informe um WhatsApp válido, com DDD." });
    }
  });

export type DadosAgendar = z.input<typeof esquemaAgendar>;

export async function agendarConsulta(dados: DadosAgendar): Promise<RetornoAgenda> {
  const lido = esquemaAgendar.safeParse(dados);
  if (!lido.success) return { ok: false, erro: lido.error.issues[0].message };
  const v = lido.data;
  const sessao = await exigirSessao();
  try {
    const r = await comoUsuaria(sessao.usuarioId, async (db) => {
      const procedimentoId = await resolverProcedimento(db, sessao.clinicaId, v.procedimento);
      const { rows } = await db.query<{ r: { pessoa_nova: boolean; tarefa: Proxima } }>(
        `select public.agendar($1, $2::uuid, $3::public.tipo_agendamento, $4::uuid,
                ($5::timestamp at time zone 'America/Sao_Paulo'), $6, $7::uuid, $8, $9, $10, $11, $12,
                $13::public.tipo_cadastro) as r`,
        [
          sessao.clinicaId, v.pessoaId || null, v.tipo, procedimentoId, v.inicio, v.duracao,
          v.profissionalId || null, v.status === "confirmado", v.observacoes || null, v.encaixe,
          v.pessoaId ? null : v.nome, v.pessoaId ? null : normalizarTelefone(v.whatsapp ?? ""), v.tipoCadastro,
        ],
      );
      return { ...rows[0].r, hoje: await hojeDa(db, sessao.clinicaId) };
    });
    revalidatePath("/", "layout");
    const quando = `${v.inicio.slice(8, 10)}/${v.inicio.slice(5, 7)} às ${v.inicio.slice(11)}`;
    return {
      ok: true,
      mensagem: `Consulta marcada para ${quando}.${r.pessoa_nova ? " Paciente cadastrado." : ""}${frase(r.tarefa, r.hoje)}`,
    };
  } catch (erro) {
    return comConflito(erro);
  }
}

const esquemaDesmarcar = z.object({
  agendamentoId: uuid,
  motivoId: z.union([z.literal(""), uuid]),
  observacao: z.string().trim().max(300).optional(),
  contatoEm: z.union([z.literal(""), z.string().regex(/^\d{4}-\d{2}-\d{2}$/, "Data inválida.")]),
});

/** Desmarcou: registra o evento, muda o status e a recuperação nasce sozinha. */
export async function desmarcarConsulta(dados: z.input<typeof esquemaDesmarcar>): Promise<Retorno> {
  const lido = esquemaDesmarcar.safeParse(dados);
  if (!lido.success) return { ok: false, erro: lido.error.issues[0].message };
  const v = lido.data;
  const sessao = await exigirSessao();
  try {
    const r = await comoUsuaria(sessao.usuarioId, async (db) => {
      const { rows } = await db.query<{ r: Proxima }>(
        "select public.desmarcar_consulta($1, $2::uuid, $3, $4::date) as r",
        [v.agendamentoId, v.motivoId || null, v.observacao || null, v.contatoEm || null],
      );
      return { tarefa: rows[0].r, hoje: await hojeDa(db, sessao.clinicaId) };
    });
    revalidatePath("/", "layout");
    return {
      ok: true,
      mensagem: r.tarefa
        ? `Desmarcação registrada. Recuperação: ${r.tarefa.titulo} — ${rotuloData(r.tarefa.vence_em, r.hoje).toLowerCase()}.`
        : "Desmarcação registrada. Esta pessoa não aceita contatos, então não há tarefa de recuperação.",
    };
  } catch (erro) {
    return { ok: false, erro: mensagemDeErro(erro) };
  }
}

const esquemaRemarcar = z.object({
  agendamentoId: uuid,
  inicio: dataHora,
  duracao: z.coerce.number().int().min(15).max(240),
  profissionalId: z.union([z.literal(""), uuid]),
  encaixe: z.boolean().default(false),
});

export async function remarcarConsulta(dados: z.input<typeof esquemaRemarcar>): Promise<RetornoAgenda> {
  const lido = esquemaRemarcar.safeParse(dados);
  if (!lido.success) return { ok: false, erro: lido.error.issues[0].message };
  const v = lido.data;
  const sessao = await exigirSessao();
  try {
    const r = await comoUsuaria(sessao.usuarioId, async (db) => {
      const { rows } = await db.query<{ r: { tarefa: Proxima } }>(
        `select public.remarcar_consulta($1, ($2::timestamp at time zone 'America/Sao_Paulo'), $3, $4::uuid, $5) as r`,
        [v.agendamentoId, v.inicio, v.duracao, v.profissionalId || null, v.encaixe],
      );
      return { ...rows[0].r, hoje: await hojeDa(db, sessao.clinicaId) };
    });
    revalidatePath("/", "layout");
    const quando = `${v.inicio.slice(8, 10)}/${v.inicio.slice(5, 7)} às ${v.inicio.slice(11)}`;
    return { ok: true, mensagem: `Remarcado para ${quando}. A tarefa antiga foi encerrada.${frase(r.tarefa, r.hoje)}` };
  } catch (erro) {
    return comConflito(erro);
  }
}

const esquemaStatus = z.object({
  agendamentoId: uuid,
  status: z.enum(["confirmado", "compareceu", "faltou", "cancelado_clinica"]),
  observacao: z.string().trim().max(300).optional(),
});

const SUCESSO: Record<z.infer<typeof esquemaStatus>["status"], string> = {
  confirmado: "Presença confirmada.",
  compareceu: "Comparecimento registrado.",
  faltou: "Falta registrada.",
  cancelado_clinica: "Consulta cancelada.",
};

export async function mudarStatusConsulta(dados: z.input<typeof esquemaStatus>): Promise<Retorno> {
  const lido = esquemaStatus.safeParse(dados);
  if (!lido.success) return { ok: false, erro: lido.error.issues[0].message };
  const v = lido.data;
  const sessao = await exigirSessao();
  try {
    const r = await comoUsuaria(sessao.usuarioId, async (db) => {
      const { rows } = await db.query<{ r: Proxima }>(
        "select public.mudar_status_consulta($1, $2::public.status_agendamento, $3) as r",
        [v.agendamentoId, v.status, v.observacao || null],
      );
      return { tarefa: rows[0].r, hoje: await hojeDa(db, sessao.clinicaId) };
    });
    revalidatePath("/", "layout");
    return { ok: true, mensagem: `${SUCESSO[v.status]}${frase(r.tarefa, r.hoje)}` };
  } catch (erro) {
    return { ok: false, erro: mensagemDeErro(erro) };
  }
}
