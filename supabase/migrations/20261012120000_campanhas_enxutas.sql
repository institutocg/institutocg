-- =============================================================================
-- Migração 19: campanhas mais enxutas
--   A tela passa a oferecer só: interesse que não realizou/fechou, pacientes sem
--   atendimento, quem fez um procedimento, aniversário, avaliação no Google e
--   indicação, pacientes especiais (e a campanha criada por ela).
--   "Interesse" agora aceita procedimento opcional (todos os procedimentos) e
--   inclui quem negociou e não fechou. Os outros tipos continuam no banco para
--   as campanhas antigas aparecerem no histórico.
-- =============================================================================

alter table public.campanhas drop constraint if exists campanhas_procedimento_check;
alter table public.campanhas add constraint campanhas_procedimento_check
  check (segmento <> 'procedimento' or procedimento_id is not null);

-- Quem entra numa campanha. Regras de sempre: aceita contato, sem negociação em
-- andamento, sem outra campanha nos últimos 30 dias, sem contato recente e sem
-- pagamento em atraso. Aniversário é exceção (parabéns não é insistência).
create or replace function public.prever_campanha(
  p_clinica            uuid,
  p_segmento           text,
  p_meses              int,
  p_procedimento       uuid default null,
  p_somente_marketing  boolean default false,
  p_filtros            jsonb default null
)
returns table (pessoa_id uuid, nome text, detalhe text, referencia date, procedimento text)
language plpgsql
stable
security definer
set search_path = public
as $$
#variable_conflict use_column
declare
  v_hoje      date;
  v_corte     date;
  v_intervalo int;
  v_aniv      boolean := p_segmento = 'aniversario';
  -- Campanha personalizada: filtros escolhidos pela administradora.
  v_publico   text := coalesce(nullif(p_filtros->>'publico', ''), 'todos');
  v_relacao   text := coalesce(nullif(p_filtros->>'relacao', ''), 'qualquer');
  v_sem_vir   int  := nullif(p_filtros->>'sem_vir_meses', '')::int;
  v_idade_min int  := nullif(p_filtros->>'idade_min', '')::int;
  v_idade_max int  := nullif(p_filtros->>'idade_max', '')::int;
  v_local     text := nullif(btrim(p_filtros->>'local'), '');
  v_origem    uuid := nullif(p_filtros->>'origem_id', '')::uuid;
begin
  if auth.uid() is not null and p_clinica not in (select public.minhas_clinicas()) then
    raise exception 'Sem acesso a esta clínica.' using errcode = '42501';
  end if;
  if p_segmento = 'procedimento' and p_procedimento is null then
    raise exception 'Escolha o procedimento.' using errcode = 'P0001';
  end if;
  if p_segmento = 'personalizada' then
    if v_publico not in ('todos', 'pacientes', 'contatos') or v_relacao not in ('qualquer', 'fez', 'interesse') then
      raise exception 'Filtro inválido.' using errcode = 'P0001';
    end if;
    if v_idade_min is not null and v_idade_max is not null and v_idade_min > v_idade_max then
      raise exception 'A idade mínima é maior que a máxima.' using errcode = 'P0001';
    end if;
  end if;
  v_hoje := public.hoje_clinica(p_clinica);
  v_corte := (v_hoje - make_interval(months => greatest(coalesce(p_meses, 6), 1)))::date;
  v_intervalo := public.cfg_int(p_clinica, 'intervalo_min_contato_dias', 3);

  return query
  with candidatos as (
    -- Pacientes sem atendimento há X meses
    (select c.id, c.nome, c.ultimo_atendimento_em as ref,
           case when c.ultimo_atendimento_em is not null
                then 'Último atendimento em ' || to_char(c.ultimo_atendimento_em, 'MM/YYYY')
                else 'Paciente antigo, sem data de atendimento' end as det, null::text as proc
      from public.v_contatos c
     where p_segmento = 'inativos' and c.clinica_id = p_clinica
       and c.relacionamento <> 'lead' and not c.em_tratamento
       and (c.ultimo_atendimento_em is null or c.ultimo_atendimento_em <= v_corte))
    union all
    -- Quem fez o procedimento há X meses (ex.: clareamento há 12 meses)
    (select distinct on (x.pid) x.pid, p.nome, x.dia, x.det, null::text
      from (
        select ta.pessoa_id as pid, ta.realizado_em as dia,
               pr.nome || coalesce(' em ' || to_char(ta.realizado_em, 'MM/YYYY'), '') as det
          from public.tratamentos_anteriores ta join public.procedimentos pr on pr.id = ta.procedimento_id
         where ta.clinica_id = p_clinica and ta.procedimento_id = p_procedimento
           and (ta.realizado_em is null or ta.realizado_em <= v_corte)
        union all
        select o.pessoa_id, o.fechada_em::date,
               pr.nome || ' (fechou em ' || to_char(o.fechada_em, 'MM/YYYY') || ')'
          from public.oportunidades o join public.procedimentos pr on pr.id = o.procedimento_id
         where o.clinica_id = p_clinica and o.status = 'ganha' and o.procedimento_id = p_procedimento
           and o.fechada_em::date <= v_corte
        union all
        select oc.pessoa_id, i.realizado_em, pr.nome || ' em ' || to_char(i.realizado_em, 'MM/YYYY')
          from public.orcamento_itens i join public.orcamentos oc on oc.id = i.orcamento_id
          join public.procedimentos pr on pr.id = i.procedimento_id
         where i.clinica_id = p_clinica and i.status = 'realizado' and i.procedimento_id = p_procedimento
           and i.realizado_em <= v_corte
      ) x
      join public.pessoas p on p.id = x.pid
     where p_segmento = 'procedimento' and not p.em_tratamento
     order by x.pid, x.dia desc nulls last)
    union all
    -- Quem não fechou há X meses
    (select distinct on (o.pessoa_id) o.pessoa_id, p.nome, o.fechada_em::date,
           case when o.resultado = 'desistiu' then 'Desistiu' else 'Não fechou' end
             || coalesce(' (' || lower(m.nome) || ')', '') || coalesce(' — ' || lower(pr.nome), '')
             || ' em ' || to_char(o.fechada_em, 'MM/YYYY'), null::text
      from public.oportunidades o
      join public.pessoas p on p.id = o.pessoa_id
      left join public.motivos m on m.id = o.motivo_id
      left join public.procedimentos pr on pr.id = o.procedimento_id
     where p_segmento = 'nao_fecharam' and o.clinica_id = p_clinica and o.status = 'perdida'
       and o.fechada_em::date <= v_corte
       and (p_procedimento is null or o.procedimento_id = p_procedimento)
     order by o.pessoa_id, o.fechada_em desc)
    union all
    -- Tratamento pendente: procedimentos do plano ainda a fazer, sem consulta marcada.
    (select oc.pessoa_id, p.nome, max(coalesce(i.atualizado_em, i.criado_em))::date,
            'Pendente no plano: ' || string_agg(pr.nome, ', ' order by i.criado_em),
            string_agg(lower(pr.nome), ', ' order by i.criado_em)
       from public.orcamento_itens i
       join public.orcamentos oc on oc.id = i.orcamento_id and oc.origem = 'prontuario'
       join public.procedimentos pr on pr.id = i.procedimento_id
       join public.pessoas p on p.id = oc.pessoa_id
      where p_segmento = 'tratamento_pendente' and i.clinica_id = p_clinica
        and i.status in ('orcado', 'aceito', 'pendente')
        and not exists (select 1 from public.agendamentos a where a.pessoa_id = oc.pessoa_id
                         and a.status in ('agendado', 'confirmado') and a.inicio >= now())
      group by oc.pessoa_id, p.nome
     having max(coalesce(i.atualizado_em, i.criado_em))::date <= v_corte
         and (p_procedimento is null or bool_or(i.procedimento_id = p_procedimento)))
    union all
    -- Interesse que nunca virou avaliação (negociação encerrada sem nenhuma consulta).
    (select distinct on (o.pessoa_id) o.pessoa_id, p.nome, o.criado_em::date,
            'Interesse' || coalesce(' em ' || lower(pr.nome), '') || ' desde ' || to_char(o.criado_em, 'MM/YYYY')
              || ', sem avaliação', null::text
       from public.oportunidades o
       join public.pessoas p on p.id = o.pessoa_id
       left join public.procedimentos pr on pr.id = o.procedimento_id
      where p_segmento = 'avaliacao_nao_agendada' and o.clinica_id = p_clinica and o.status = 'perdida'
        and o.criado_em::date <= v_corte
        and (p_procedimento is null or o.procedimento_id = p_procedimento)
        and not exists (select 1 from public.agendamentos a where a.pessoa_id = o.pessoa_id)
        and not exists (select 1 from public.oportunidades g where g.pessoa_id = o.pessoa_id and g.status = 'ganha')
      order by o.pessoa_id, o.criado_em desc)
    union all
    -- Aniversário nos próximos X meses (a tarefa fica para o dia).
    (select p.id, p.nome, x.dia, 'Aniversário em ' || to_char(x.dia, 'DD/MM'), null::text
       from public.pessoas p,
            lateral (select case when (p.data_nascimento + make_interval(years => extract(year from age(v_hoje, p.data_nascimento))::int))::date >= v_hoje
                                 then (p.data_nascimento + make_interval(years => extract(year from age(v_hoje, p.data_nascimento))::int))::date
                                 else (p.data_nascimento + make_interval(years => extract(year from age(v_hoje, p.data_nascimento))::int + 1))::date
                            end as dia) x
      where v_aniv and p.clinica_id = p_clinica and p.data_nascimento is not null
        and x.dia < (v_hoje + make_interval(months => greatest(coalesce(p_meses, 1), 1)))::date
        and not exists (select 1 from public.campanha_destinatarios d join public.campanhas c on c.id = d.campanha_id
                         where d.pessoa_id = p.id and c.segmento = 'aniversario' and d.contato_em = (case when public.eh_dia_util(p_clinica, x.dia) then x.dia else public.dia_util_anterior(p_clinica, x.dia) end)))
    union all
    -- Pós-tratamento: realizou algo entre 1 e 3 meses atrás (padrão) e nunca recebeu este pedido.
    (select y.pid, p.nome, y.dia, 'Fez ' || y.proc || ' em ' || to_char(y.dia, 'DD/MM/YYYY'), lower(y.proc)
       from (
         select distinct on (z.pid) z.pid, z.dia, z.proc from (
           select oc.pessoa_id as pid, i.realizado_em as dia, pr.nome as proc
             from public.orcamento_itens i join public.orcamentos oc on oc.id = i.orcamento_id
             join public.procedimentos pr on pr.id = i.procedimento_id
            where i.clinica_id = p_clinica and i.status = 'realizado'
           union all
           select o.pessoa_id, o.fechada_em::date, coalesce(pr.nome, 'tratamento')
             from public.oportunidades o left join public.procedimentos pr on pr.id = o.procedimento_id
            where o.clinica_id = p_clinica and o.status = 'ganha'
         ) z order by z.pid, z.dia desc
       ) y
       join public.pessoas p on p.id = y.pid
      where p_segmento = 'pos_tratamento' and y.dia <= v_corte and y.dia > v_corte - 60
        and not exists (select 1 from public.campanha_destinatarios d join public.campanhas c on c.id = d.campanha_id
                         where d.pessoa_id = p.id and c.segmento = 'pos_tratamento'))
    union all
    -- Demonstrou interesse num procedimento (negociação, interesse anotado ou
    -- orçamento) nos últimos X meses e não realizou nem fechou. Procedimento opcional.
    (select distinct on (z.pid) z.pid, p.nome, z.dia,
            'Interesse em ' || coalesce(lower(pr.nome), 'tratamento') || ' (' || to_char(z.dia, 'MM/YYYY') || ')'
              || case when z.perdida then ', não fechou' else ', não realizou' end,
            lower(pr.nome)
       from (
         select o.pessoa_id as pid, o.criado_em::date as dia, o.procedimento_id as proc, o.status = 'perdida' as perdida
           from public.oportunidades o
          where o.clinica_id = p_clinica and o.status <> 'ganha'
         union all
         select o.pessoa_id, oi.criado_em::date, oi.procedimento_id, o.status = 'perdida'
           from public.oportunidade_interesses oi join public.oportunidades o on o.id = oi.oportunidade_id
          where oi.clinica_id = p_clinica
         union all
         select oc.pessoa_id, i.criado_em::date, i.procedimento_id, false
           from public.orcamento_itens i join public.orcamentos oc on oc.id = i.orcamento_id
          where i.clinica_id = p_clinica and i.status in ('orcado', 'aceito', 'pendente')
       ) z
       join public.pessoas p on p.id = z.pid
       left join public.procedimentos pr on pr.id = z.proc
      where p_segmento = 'interesse' and z.dia >= v_corte
        and (p_procedimento is null or z.proc = p_procedimento)
        and not exists (select 1 from public.tratamentos_anteriores ta where ta.pessoa_id = z.pid and ta.procedimento_id = z.proc)
        and not exists (select 1 from public.orcamento_itens i join public.orcamentos oc on oc.id = i.orcamento_id
                         where oc.pessoa_id = z.pid and i.procedimento_id = z.proc and i.status = 'realizado')
        and not exists (select 1 from public.oportunidades g where g.pessoa_id = z.pid and g.status = 'ganha'
                         and (g.procedimento_id = z.proc or z.proc is null))
      order by z.pid, z.dia desc, z.proc nulls last)
    union all
    -- Desmarcou ou faltou há mais de X meses e nunca remarcou.
    (select distinct on (a.pessoa_id) a.pessoa_id, p.nome, a.status_em::date,
            case a.status when 'faltou' then 'Faltou' when 'cancelado_clinica' then 'Consulta cancelada pela clínica' else 'Desmarcou' end
              || ' em ' || to_char(a.inicio at time zone 'America/Sao_Paulo', 'DD/MM/YYYY') || ', sem remarcar', null::text
       from public.agendamentos a join public.pessoas p on p.id = a.pessoa_id
      where p_segmento = 'desmarcou' and a.clinica_id = p_clinica
        and a.status in ('desmarcado', 'faltou', 'cancelado_clinica') and a.remarcado_para_id is null
        and a.status_em::date <= v_corte
        and not exists (select 1 from public.agendamentos b where b.pessoa_id = a.pessoa_id and b.inicio > a.inicio
                         and b.status in ('agendado', 'confirmado', 'compareceu'))
      order by a.pessoa_id, a.inicio desc)
    union all
    -- Pacientes especiais: os de maior histórico (30% com mais negociações fechadas e valor).
    (select t.pid, p.nome, t.desde,
            'Paciente desde ' || to_char(t.desde, 'YYYY') || ' · ' || t.n || ' ' || case when t.n = 1 then 'tratamento fechado' else 'tratamentos fechados' end,
            null::text
       from (
         select v.pessoa_id as pid, count(*)::int as n, sum(v.valor_final_centavos) as total, min(v.fechada_em) as desde,
                percent_rank() over (order by sum(v.valor_final_centavos)) as pr
           from public.vendas v
          where v.clinica_id = p_clinica and v.status = 'ativa' and v.tipo = 'venda'
          group by v.pessoa_id
       ) t
       join public.pessoas p on p.id = t.pid
      where p_segmento = 'especiais' and t.pr >= 0.7)
    union all
    -- Personalizada: a administradora monta o público com os filtros.
    (select c.id, c.nome, c.ultimo_atendimento_em,
            concat_ws(' · ',
              case when c.relacionamento = 'lead' then 'Contato, ainda não veio' else 'Paciente' end,
              case when c.ultimo_atendimento_em is not null then 'último atendimento ' || to_char(c.ultimo_atendimento_em, 'MM/YYYY') end,
              case when c.data_nascimento is not null then extract(year from age(v_hoje, c.data_nascimento))::int || ' anos' end,
              nullif(concat_ws(', ', nullif(c.bairro, ''), nullif(c.cidade, '')), ''),
              case when p_procedimento is not null then
                (select case when v_relacao = 'interesse' then 'interesse em ' else '' end || lower(pr.nome)
                   from public.procedimentos pr where pr.id = p_procedimento) end),
            null::text
       from public.v_contatos c
      where p_segmento = 'personalizada' and c.clinica_id = p_clinica
        and (v_publico = 'todos' or (v_publico = 'pacientes') = (c.relacionamento <> 'lead'))
        and (v_sem_vir is null or (c.relacionamento <> 'lead' and not c.em_tratamento
             and (c.ultimo_atendimento_em is null
                  or c.ultimo_atendimento_em <= (v_hoje - make_interval(months => v_sem_vir))::date)))
        and (v_idade_min is null or (c.data_nascimento is not null and extract(year from age(v_hoje, c.data_nascimento)) >= v_idade_min))
        and (v_idade_max is null or (c.data_nascimento is not null and extract(year from age(v_hoje, c.data_nascimento)) <= v_idade_max))
        and (v_local is null or position(lower(v_local) in lower(concat_ws(' ', c.bairro, c.cidade))) > 0)
        and (v_origem is null or c.origem_id = v_origem)
        and (p_procedimento is null
             or (v_relacao in ('qualquer', 'fez') and (
                   exists (select 1 from public.tratamentos_anteriores ta where ta.pessoa_id = c.id and ta.procedimento_id = p_procedimento)
                or exists (select 1 from public.oportunidades o where o.pessoa_id = c.id and o.procedimento_id = p_procedimento and o.status = 'ganha')
                or exists (select 1 from public.orcamento_itens i join public.orcamentos oc on oc.id = i.orcamento_id
                            where oc.pessoa_id = c.id and i.procedimento_id = p_procedimento and i.status = 'realizado')))
             or (v_relacao in ('qualquer', 'interesse') and (
                   exists (select 1 from public.oportunidades o where o.pessoa_id = c.id and o.procedimento_id = p_procedimento and o.status <> 'ganha')
                or exists (select 1 from public.oportunidade_interesses oi join public.oportunidades o on o.id = oi.oportunidade_id
                            where o.pessoa_id = c.id and oi.procedimento_id = p_procedimento)
                or exists (select 1 from public.orcamento_itens i join public.orcamentos oc on oc.id = i.orcamento_id
                            where oc.pessoa_id = c.id and i.procedimento_id = p_procedimento and i.status in ('orcado', 'aceito', 'pendente'))))))
  )
  select k.id, k.nome, k.det, k.ref, k.proc
    from candidatos k
    join public.pessoas p on p.id = k.id
   where p.arquivado_em is null and not p.nao_contatar and p.consentimento_contato
     and (not p_somente_marketing or p.consentimento_marketing)
     and (v_aniv or p.ultimo_contato_em is null or p.ultimo_contato_em < now() - make_interval(days => v_intervalo))
     and not exists (select 1 from public.oportunidades o where o.pessoa_id = p.id and o.status in ('aberta', 'pausada'))
     and (v_aniv or not exists (select 1 from public.campanha_destinatarios d join public.campanhas c on c.id = d.campanha_id
                                 where d.pessoa_id = p.id and c.segmento <> 'aniversario'
                                   and d.criado_em > now() - interval '30 days'))
     -- Quem está com pagamento em atraso é tratado pelo financeiro, não por campanha.
     and (v_aniv or not exists (select 1 from public.parcelas pa where pa.pessoa_id = p.id
                                 and pa.status in ('pendente', 'parcial') and pa.vencimento < v_hoje))
   order by k.ref nulls first, k.nome;
end;
$$;


-- Quantas vezes a pessoa veio à clínica (consultas com "compareceu" na agenda ou
-- consultas registradas no prontuário; o mesmo dia conta uma vez). Ajuda a
-- administradora a escolher o público da campanha criada por ela.
create or replace function public.vindas(p_pessoa uuid)
returns int
language sql
stable
security invoker
set search_path = public
as $$
  select count(*)::int from (
    select (a.inicio at time zone 'America/Sao_Paulo')::date from public.agendamentos a
     where a.pessoa_id = p_pessoa and a.status = 'compareceu'
    union
    select t.data from public.atendimentos t where t.pessoa_id = p_pessoa
  ) x;
$$;

revoke execute on function public.vindas(uuid) from public, anon;
grant execute on function public.vindas(uuid) to authenticated;
