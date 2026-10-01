"use server";

import { revalidatePath } from "next/cache";
import { z } from "zod";
import { comoUsuaria, mensagemDeErro } from "@/lib/db";
import { esquemaModelo, type DadosModelo, type Sugestao } from "@/modules/mensagens/mensagens";
import { exigirSessao } from "@/modules/sessao/sessao";
import type { Retorno } from "../hoje/acoes";

/** Cria ou edita uma mensagem da biblioteca (toda a equipe pode). */
export async function salvarModelo(dados: DadosModelo): Promise<Retorno> {
  const lido = esquemaModelo.safeParse(dados);
  if (!lido.success) return { ok: false, erro: lido.error.issues[0].message };
  const v = lido.data;
  const sessao = await exigirSessao();
  try {
    await comoUsuaria(sessao.usuarioId, async (db) => {
      if (!v.id) {
        await db.query(
          `insert into public.modelos_mensagem (clinica_id, categoria, procedimento_id, titulo, texto, padrao, ativo)
           values ($1, $2, $3::uuid, $4, $5, $6, true)`,
          [sessao.clinicaId, v.categoria, v.procedimentoId || null, v.titulo, v.texto, v.padrao],
        );
        return;
      }
      const r = await db.query(
        `update public.modelos_mensagem
            set categoria = $2, procedimento_id = $3::uuid, titulo = $4, texto = $5, padrao = $6 and $7, ativo = $7,
                atualizado_em = now()
          where id = $1 and clinica_id = $8`,
        [v.id, v.categoria, v.procedimentoId || null, v.titulo, v.texto, v.padrao, v.ativo, sessao.clinicaId],
      );
      if (!r.rowCount) throw Object.assign(new Error("Mensagem não encontrada."), { code: "P0002" });
    });
    revalidatePath("/", "layout");
    return { ok: true, mensagem: v.id ? (v.ativo ? "Mensagem atualizada." : "Mensagem arquivada.") : "Mensagem criada." };
  } catch (erro) {
    return { ok: false, erro: mensagemDeErro(erro) };
  }
}

/** A biblioteca preenchida para a tarefa, com a recomendada primeiro. */
export async function sugestoesDaTarefa(tarefaId: string): Promise<Sugestao[]> {
  if (!z.uuid().safeParse(tarefaId).success) return [];
  const sessao = await exigirSessao();
  return comoUsuaria(sessao.usuarioId, async (db) => {
    const { rows } = await db.query<Sugestao>("select * from public.sugestoes_mensagem($1)", [tarefaId]);
    return rows;
  });
}

/** Textos preenchidos para um paciente: { id do modelo: texto }. */
export async function preencherParaPaciente(pessoaId: string): Promise<Record<string, string>> {
  if (!z.uuid().safeParse(pessoaId).success) return {};
  const sessao = await exigirSessao();
  return comoUsuaria(sessao.usuarioId, async (db) => {
    const { rows } = await db.query<{ modelo_id: string; texto: string }>(
      "select * from public.mensagens_para_pessoa($1)",
      [pessoaId],
    );
    return Object.fromEntries(rows.map((r) => [r.modelo_id, r.texto]));
  });
}
