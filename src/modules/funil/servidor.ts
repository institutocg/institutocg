import "server-only";
import type { PoolClient } from "pg";
import type { EtapaFunil, NegociacaoFunil } from "./funil";

export interface FiltrosFunil {
  busca: string;
  procedimentoId: string | null;
  responsavelId: string | null;
}

export interface OpcoesFunil {
  procedimentos: { id: string; nome: string }[];
  responsaveis: { id: string; nome: string }[];
  motivos: { id: string; nome: string; aplica_a: "nao_fechou" | "desistiu"; retorno_sugerido_dias: number | null }[];
  formas: { id: string; nome: string; permite_parcelamento: boolean; max_parcelas: number }[];
}

export async function carregarFunil(db: PoolClient, clinicaId: string, filtros: FiltrosFunil) {
  const { rows: cfg } = await db.query<{ hoje: string; dias: number }>(
    `select public.hoje_clinica($1) as hoje,
            coalesce((configuracoes ->> 'dias_encerradas_no_funil')::int, 30) as dias
       from public.clinicas where id = $1`,
    [clinicaId],
  );
  const { hoje, dias } = cfg[0];

  const [etapas, negociacoes, procedimentos, responsaveis, motivos, formas] = await Promise.all([
    db.query<EtapaFunil>(
      `select id, nome, ordem, tipo, resultado, marco, cor, sla_dias from public.etapas_funil
        where clinica_id = $1 and ativo order by ordem`,
      [clinicaId],
    ),
    db.query<Omit<NegociacaoFunil, "ultimo_contato_em"> & { ultimo_contato_em: Date | null }>(
      `select o.id, o.pessoa_id, p.nome, pr.nome as procedimento, o.etapa_id, o.status, o.resultado,
              ($2::date - (o.etapa_desde at time zone 'America/Sao_Paulo')::date) as dias_na_etapa,
              p.primeiro_contato_em, p.ultimo_contato_em,
              prox.titulo as proxima_acao, prox.vence_em as proxima_acao_em,
              coalesce(o.valor_fechado_centavos, orc.valor_final_centavos, o.valor_estimado_centavos) as valor_potencial_centavos,
              m.nome as motivo
         from public.oportunidades o
         join public.pessoas p on p.id = o.pessoa_id
         left join public.procedimentos pr on pr.id = o.procedimento_id
         left join public.motivos m on m.id = o.motivo_id
         left join lateral (
           select valor_final_centavos from public.orcamentos
            where oportunidade_id = o.id and status <> 'rascunho' order by criado_em desc limit 1
         ) orc on true
         left join lateral (
           select titulo, vence_em from public.tarefas
            where oportunidade_id = o.id and status = 'pendente' order by vence_em, criado_em limit 1
         ) prox on true
        where o.clinica_id = $1 and p.arquivado_em is null
          and (o.status in ('aberta', 'pausada') or o.fechada_em >= now() - make_interval(days => $3))
          -- negociação encerrada que já foi retomada aparece só na nova
          and not (o.status in ('ganha', 'perdida')
                   and exists (select 1 from public.oportunidades x where x.oportunidade_origem_id = o.id))
          and ($4::uuid is null or o.procedimento_id = $4)
          and ($5::uuid is null or o.responsavel_id = $5)
          and ($6 = '' or public.sem_acento(p.nome) like '%' || public.sem_acento($6) || '%')
        order by o.etapa_desde`,
      [clinicaId, hoje, dias, filtros.procedimentoId, filtros.responsavelId, filtros.busca.trim()],
    ),
    db.query("select id, nome from public.procedimentos where clinica_id = $1 and ativo order by ordem, nome", [clinicaId]),
    db.query(
      `select u.id, u.nome from public.membros m join public.usuarios u on u.id = m.usuario_id
        where m.clinica_id = $1 and m.ativo order by u.nome`,
      [clinicaId],
    ),
    db.query(
      `select id, nome, aplica_a, retorno_sugerido_dias from public.motivos
        where clinica_id = $1 and ativo and aplica_a in ('nao_fechou', 'desistiu') order by aplica_a desc, ordem`,
      [clinicaId],
    ),
    db.query(
      `select id, nome, permite_parcelamento, max_parcelas from public.formas_pagamento
        where clinica_id = $1 and ativo order by ordem`,
      [clinicaId],
    ),
  ]);

  return {
    hoje,
    diasEncerradas: dias,
    etapas: etapas.rows,
    negociacoes: negociacoes.rows.map((r) => ({ ...r, ultimo_contato_em: r.ultimo_contato_em?.toISOString() ?? null })),
    opcoes: {
      procedimentos: procedimentos.rows,
      responsaveis: responsaveis.rows,
      motivos: motivos.rows,
      formas: formas.rows,
    } as OpcoesFunil,
  };
}
