"use server";

import { revalidatePath } from "next/cache";
import { redirect } from "next/navigation";
import { z } from "zod";
import { comoUsuaria, mensagemDeErro } from "@/lib/db";
import { errosPorCampo, lerFormulario, type ErrosCadastro } from "@/modules/contatos/cadastro";
import { abrirNegociacao, atualizar, buscarDuplicado, cadastrar } from "@/modules/contatos/servidor";
import { resolverProcedimento } from "@/modules/procedimentos/servidor";
import { exigirSessao } from "@/modules/sessao/sessao";
import type { Retorno } from "../hoje/acoes";

export type EstadoCadastro = {
  versao: number;
  erros?: ErrosCadastro;
  duplicado?: { id: string; nome: string };
  valores?: Record<string, string | string[]>;
};

function valoresDo(form: FormData): Record<string, string | string[]> {
  const v: Record<string, string | string[]> = {};
  for (const chave of new Set(form.keys())) {
    const todos = form.getAll(chave).map(String);
    v[chave] = chave === "tratamentos" ? todos : todos[0];
  }
  return v;
}

/** Novo cadastro. Depois de salvar abre a ficha, ou volta ao formulário ("cadastrar o próximo"). */
export async function salvarCadastro(anterior: EstadoCadastro, form: FormData): Promise<EstadoCadastro> {
  const sessao = await exigirSessao();
  const versao = anterior.versao + 1;
  const lido = lerFormulario(form);
  if (!lido.success) return { versao, erros: errosPorCampo(lido.error), valores: valoresDo(form) };

  let id: string;
  try {
    const r = await comoUsuaria(sessao.usuarioId, async (db) => {
      const duplicado = await buscarDuplicado(db, lido.data);
      if (duplicado) return { duplicado };
      return { id: await cadastrar(db, sessao, lido.data) };
    });
    if ("duplicado" in r && r.duplicado) return { versao, duplicado: r.duplicado, valores: valoresDo(form) };
    id = r.id!;
  } catch (erro) {
    return { versao, erros: { geral: mensagemDeErro(erro) }, valores: valoresDo(form) };
  }

  revalidatePath("/", "layout");
  if (form.get("depois") === "proximo") {
    redirect(`/contatos/novo?tipo=${lido.data.tipo}&salvo=${encodeURIComponent(lido.data.nome)}&id=${id}`);
  }
  redirect(`/contatos/${id}?novo=1`);
}

export async function salvarEdicao(pessoaId: string, anterior: EstadoCadastro, form: FormData): Promise<EstadoCadastro> {
  const sessao = await exigirSessao();
  const versao = anterior.versao + 1;
  if (!z.uuid().safeParse(pessoaId).success) return { versao, erros: { geral: "Cadastro inválido." } };
  const lido = lerFormulario(form);
  if (!lido.success) return { versao, erros: errosPorCampo(lido.error), valores: valoresDo(form) };

  try {
    const duplicado = await comoUsuaria(sessao.usuarioId, async (db) => {
      const dup = await buscarDuplicado(db, lido.data, pessoaId);
      if (dup) return dup;
      await atualizar(db, sessao, pessoaId, lido.data);
      return null;
    });
    if (duplicado) return { versao, duplicado, valores: valoresDo(form) };
  } catch (erro) {
    return { versao, erros: { geral: mensagemDeErro(erro) }, valores: valoresDo(form) };
  }
  revalidatePath("/", "layout");
  redirect(`/contatos/${pessoaId}?salvo=1`);
}

/** Cria na hora a tarefa de resgate (manutenção ou reativação) de um paciente antigo. */
export async function criarResgate(pessoaId: string): Promise<Retorno> {
  const sessao = await exigirSessao();
  if (!z.uuid().safeParse(pessoaId).success) return { ok: false, erro: "Cadastro inválido." };
  try {
    const titulo = await comoUsuaria(sessao.usuarioId, async (db) => {
      // Dois comandos: uma consulta não enxerga linhas criadas por uma função chamada no mesmo comando.
      const { rows } = await db.query<{ id: string | null }>("select public.criar_resgate($1) as id", [pessoaId]);
      if (!rows[0]?.id) return null;
      const tarefa = await db.query<{ titulo: string }>("select titulo from public.tarefas where id = $1", [rows[0].id]);
      return tarefa.rows[0]?.titulo ?? null;
    });
    revalidatePath("/", "layout");
    return titulo
      ? { ok: true, mensagem: `Tarefa criada para hoje: ${titulo}.` }
      : { ok: false, erro: "Não foi possível criar a tarefa (verifique se a pessoa aceita contato)." };
  } catch (erro) {
    return { ok: false, erro: mensagemDeErro(erro) };
  }
}

/** Abre uma negociação para quem não tem nenhuma em andamento. */
export async function abrirNegociacaoAcao(pessoaId: string, procedimento: string | null): Promise<Retorno> {
  const sessao = await exigirSessao();
  if (!z.uuid().safeParse(pessoaId).success) return { ok: false, erro: "Cadastro inválido." };
  if (procedimento && procedimento.trim().length > 120) return { ok: false, erro: "Procedimento: no máximo 120 caracteres." };
  try {
    await comoUsuaria(sessao.usuarioId, async (db) => {
      const { rows } = await db.query<{ origem_id: string | null; tipo_cadastro: string; responsavel_id: string | null }>(
        "select origem_id, tipo_cadastro, responsavel_id from public.pessoas where id = $1",
        [pessoaId],
      );
      if (!rows[0]) throw Object.assign(new Error("Cadastro não encontrado."), { code: "P0002" });
      const procedimentoId = await resolverProcedimento(db, sessao.clinicaId, procedimento);
      await abrirNegociacao(db, sessao.clinicaId, pessoaId, procedimentoId, "em_contato", rows[0].origem_id,
        rows[0].responsavel_id ?? sessao.usuarioId);
    });
    revalidatePath("/", "layout");
    return { ok: true, mensagem: "Negociação aberta. A próxima ação já está na lista de hoje." };
  } catch (erro) {
    return { ok: false, erro: mensagemDeErro(erro) };
  }
}

/** Tratamento concluído: registra o último atendimento e agenda o convite de retorno. */
export async function concluirTratamento(pessoaId: string, retorno: string | null): Promise<Retorno> {
  const sessao = await exigirSessao();
  if (!z.uuid().safeParse(pessoaId).success) return { ok: false, erro: "Cadastro inválido." };
  if (retorno && !/^\d{4}-\d{2}-\d{2}$/.test(retorno)) return { ok: false, erro: "Data inválida." };
  try {
    const data = await comoUsuaria(sessao.usuarioId, async (db) => {
      const { rows } = await db.query<{ retorno: string | null }>(
        "select public.concluir_tratamento($1, $2::date) as retorno",
        [pessoaId, retorno || null],
      );
      return rows[0].retorno;
    });
    revalidatePath("/", "layout");
    return {
      ok: true,
      mensagem: data
        ? `Tratamento concluído. O convite para a revisão fica programado para ${data.split("-").reverse().join("/")}.`
        : "Tratamento concluído.",
    };
  } catch (erro) {
    return { ok: false, erro: mensagemDeErro(erro) };
  }
}
