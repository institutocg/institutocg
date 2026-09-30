"use server";

import { revalidatePath } from "next/cache";
import { z } from "zod";
import { comoUsuaria, mensagemDeErro } from "@/lib/db";
import { esquemaRegra, lerIntervalos, type DadosRegra } from "@/modules/regras/regras";
import { exigirSessao } from "@/modules/sessao/sessao";
import type { Retorno } from "../hoje/acoes";

const numero = (v: string | number) => (v === "" ? null : Number(v));

/** Salva uma regra de follow-up e o texto da mensagem sugerida (somente a administradora). */
export async function salvarRegra(dados: DadosRegra): Promise<Retorno> {
  const sessao = await exigirSessao();
  if (sessao.papel !== "admin") return { ok: false, erro: "Somente a administradora altera as regras." };
  const lido = esquemaRegra.safeParse(dados);
  if (!lido.success) return { ok: false, erro: lido.error.issues[0].message };
  const v = lido.data;
  try {
    await comoUsuaria(sessao.usuarioId, async (db) => {
      const { rows } = await db.query<{ mensagem_situacao: string | null; nome: string }>(
        `update public.regras_followup
            set ativa = $2, titulo_modelo = $3, prazo_dias = $4, intervalos = $5, prioridade = $6,
                ao_esgotar = $7, espera_reativacao_dias = $8, periodo_meses = coalesce($9, periodo_meses)
          where id = $1 and clinica_id = $10
        returning mensagem_situacao, nome`,
        [
          v.id, v.ativa, v.titulo_modelo, numero(v.prazo_dias), lerIntervalos(v.intervalos) ?? [], v.prioridade,
          v.ao_esgotar, numero(v.espera_reativacao_dias), numero(v.periodo_meses), sessao.clinicaId,
        ],
      );
      // Sem linha alterada = sem permissão (a política do banco também protege).
      if (!rows[0]) throw Object.assign(new Error("Regra não encontrada ou sem permissão."), { code: "P0002" });
      const situacao = rows[0].mensagem_situacao;
      if (situacao && v.mensagem) {
        const atualizada = await db.query(
          `update public.modelos_mensagem set texto = $3, atualizado_em = now()
            where id = (select id from public.modelos_mensagem
                         where clinica_id = $1 and situacao = $2 and ativo order by criado_em limit 1)`,
          [sessao.clinicaId, situacao, v.mensagem],
        );
        if (!atualizada.rowCount) {
          await db.query(
            "insert into public.modelos_mensagem (clinica_id, situacao, titulo, texto) values ($1, $2, $3, $4)",
            [sessao.clinicaId, situacao, rows[0].nome, v.mensagem],
          );
        }
      }
    });
    revalidatePath("/", "layout");
    return { ok: true, mensagem: "Regra salva. Vale para as próximas tarefas criadas." };
  } catch (erro) {
    return { ok: false, erro: mensagemDeErro(erro) };
  }
}

const esquemaLimites = z.object({
  limiteReativacaoDia: z.coerce.number().int().min(1, "Limite entre 1 e 50.").max(50, "Limite entre 1 e 50."),
  intervaloMinContatoDias: z.coerce.number().int().min(0, "Intervalo entre 0 e 30 dias.").max(30, "Intervalo entre 0 e 30 dias."),
});

/** Limites gerais que evitam contatos em excesso. */
export async function salvarLimites(dados: z.input<typeof esquemaLimites>): Promise<Retorno> {
  const sessao = await exigirSessao();
  if (sessao.papel !== "admin") return { ok: false, erro: "Somente a administradora altera as configurações." };
  const lido = esquemaLimites.safeParse(dados);
  if (!lido.success) return { ok: false, erro: lido.error.issues[0].message };
  try {
    await comoUsuaria(sessao.usuarioId, (db) =>
      db.query(
        `update public.clinicas
            set configuracoes = configuracoes || jsonb_build_object('limite_reativacao_dia', $2::int,
                                                                    'intervalo_min_contato_dias', $3::int)
          where id = $1`,
        [sessao.clinicaId, lido.data.limiteReativacaoDia, lido.data.intervaloMinContatoDias],
      ),
    );
    revalidatePath("/", "layout");
    return { ok: true, mensagem: "Limites salvos." };
  } catch (erro) {
    return { ok: false, erro: mensagemDeErro(erro) };
  }
}

const esquemaDentista = z.object({
  id: z.union([z.literal(""), z.uuid()]),
  nome: z.string().trim().min(3, "Informe o nome da dentista.").max(80),
  cor: z.string().regex(/^#[0-9A-Fa-f]{6}$/, "Cor inválida."),
  ativo: z.boolean(),
});

/** Inclui ou altera uma dentista da agenda (somente a administradora). */
export async function salvarDentista(dados: z.input<typeof esquemaDentista>): Promise<Retorno> {
  const sessao = await exigirSessao();
  if (sessao.papel !== "admin") return { ok: false, erro: "Somente a administradora altera as dentistas." };
  const lido = esquemaDentista.safeParse(dados);
  if (!lido.success) return { ok: false, erro: lido.error.issues[0].message };
  const v = lido.data;
  try {
    await comoUsuaria(sessao.usuarioId, async (db) => {
      if (!v.id) {
        await db.query("insert into public.profissionais (clinica_id, nome, cor) values ($1, $2, $3)", [sessao.clinicaId, v.nome, v.cor]);
        return;
      }
      if (!v.ativo) {
        // Desativar só depois de remarcar as consultas futuras (nenhuma consulta fica sem dentista).
        const { rows } = await db.query<{ n: number }>(
          `select count(*)::int as n from public.agendamentos
            where profissional_id = $1 and status in ('agendado', 'confirmado') and inicio >= now()`,
          [v.id],
        );
        if (rows[0].n > 0) {
          throw Object.assign(
            new Error(`Esta dentista tem ${rows[0].n} ${rows[0].n === 1 ? "consulta futura" : "consultas futuras"}. Remarque antes de desativar.`),
            { code: "P0001" },
          );
        }
      }
      const r = await db.query("update public.profissionais set nome = $2, cor = $3, ativo = $4 where id = $1 and clinica_id = $5", [
        v.id, v.nome, v.cor, v.ativo, sessao.clinicaId,
      ]);
      if (!r.rowCount) throw Object.assign(new Error("Dentista não encontrada ou sem permissão."), { code: "P0002" });
    });
    revalidatePath("/", "layout");
    return { ok: true, mensagem: v.id ? "Dentista atualizada." : "Dentista incluída. Ela já aparece na agenda." };
  } catch (erro) {
    return { ok: false, erro: mensagemDeErro(erro) };
  }
}
