-- =============================================================================
-- Instituto CG — ATUALIZAÇÃO da versão de teste: novas campanhas
-- (tratamento pendente, avaliação que não aconteceu, aniversário, avaliação no
-- Google e indicação, interesse/época, desmarcou e pacientes especiais).
--
-- Para quem já aplicou atualizar-prontuario-simples.sql.
-- Cole no SQL Editor do projeto de TESTE e clique em "Run" (uma vez só).
-- Depois, no sistema: Configurações → Versão de teste → "Recomeçar com dados de exemplo".
-- =============================================================================

begin;

-- =============================================================================
-- Migração 16: mais tipos de campanha
--   • tratamento_pendente — procedimentos pendentes no plano, sem consulta marcada
--   • avaliacao_nao_agendada — interesse que nunca virou avaliação
--   • aniversario — parabéns no dia (sem oferta)
--   • pos_tratamento — pedir avaliação no Google e indicação
--   • interesse — quem se interessou por um procedimento (campanhas de época)
--   • desmarcou — desmarcou/faltou e nunca remarcou
--   • especiais — pacientes com maior histórico na clínica
-- Campanhas de vendas (inativos, procedimento, não fecharam, avaliação, interesse,
-- desmarcou) abrem a negociação em "Reativação", como antes. As de relacionamento
-- (tratamento pendente, aniversário, pós-tratamento, especiais) só criam a tarefa
-- com a mensagem — não mexem no funil.
-- =============================================================================

alter table public.campanhas drop constraint if exists campanhas_segmento_check;
alter table public.campanhas add constraint campanhas_segmento_check check (segmento in (
  'inativos', 'procedimento', 'nao_fecharam',
  'tratamento_pendente', 'avaliacao_nao_agendada', 'aniversario', 'pos_tratamento', 'interesse', 'desmarcou', 'especiais'));
alter table public.campanhas drop constraint if exists campanhas_check;
alter table public.campanhas add constraint campanhas_procedimento_check
  check (segmento not in ('procedimento', 'interesse') or procedimento_id is not null);

-- Campanha que só cria a tarefa (relacionamento), sem abrir negociação no funil.
create or replace function public.campanha_de_relacionamento(p_segmento text)
returns boolean
language sql
immutable
as $$
  select p_segmento in ('tratamento_pendente', 'aniversario', 'pos_tratamento', 'especiais');
$$;

drop function if exists public.prever_campanha(uuid, text, int, uuid, boolean);

-- Quem entra numa campanha. Regras de sempre: aceita contato, sem negociação em
-- andamento, sem outra campanha nos últimos 30 dias, sem contato recente e sem
-- pagamento em atraso. Aniversário é exceção (parabéns não é insistência).
create or replace function public.prever_campanha(
  p_clinica            uuid,
  p_segmento           text,
  p_meses              int,
  p_procedimento       uuid default null,
  p_somente_marketing  boolean default false
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
begin
  if auth.uid() is not null and p_clinica not in (select public.minhas_clinicas()) then
    raise exception 'Sem acesso a esta clínica.' using errcode = '42501';
  end if;
  if p_segmento in ('procedimento', 'interesse') and p_procedimento is null then
    raise exception 'Escolha o procedimento.' using errcode = 'P0001';
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
    -- Interesse num procedimento (campanhas de época): demonstrou interesse nos últimos X meses e não fez.
    (select distinct on (z.pid) z.pid, p.nome, z.dia, 'Interesse em ' || lower(pr.nome) || ' (' || to_char(z.dia, 'MM/YYYY') || ')', null::text
       from (
         select o.pessoa_id as pid, o.criado_em::date as dia from public.oportunidades o
          where o.clinica_id = p_clinica and o.procedimento_id = p_procedimento and o.status <> 'ganha'
         union all
         select o.pessoa_id, oi.criado_em::date from public.oportunidade_interesses oi
           join public.oportunidades o on o.id = oi.oportunidade_id
          where oi.clinica_id = p_clinica and oi.procedimento_id = p_procedimento
         union all
         select oc.pessoa_id, i.criado_em::date from public.orcamento_itens i join public.orcamentos oc on oc.id = i.orcamento_id
          where i.clinica_id = p_clinica and i.procedimento_id = p_procedimento and i.status in ('orcado', 'aceito', 'pendente')
       ) z
       join public.pessoas p on p.id = z.pid
       join public.procedimentos pr on pr.id = p_procedimento
      where p_segmento = 'interesse' and z.dia >= v_corte
        and not exists (select 1 from public.tratamentos_anteriores ta where ta.pessoa_id = z.pid and ta.procedimento_id = p_procedimento)
        and not exists (select 1 from public.orcamento_itens i join public.orcamentos oc on oc.id = i.orcamento_id
                         where oc.pessoa_id = z.pid and i.procedimento_id = p_procedimento and i.status = 'realizado')
        and not exists (select 1 from public.oportunidades g where g.pessoa_id = z.pid and g.procedimento_id = p_procedimento and g.status = 'ganha')
      order by z.pid, z.dia desc)
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

-- Cria a campanha e distribui os contatos (limite por dia útil). Campanhas de
-- vendas abrem a negociação em "Reativação"; as de relacionamento só criam a
-- tarefa. Aniversário: a tarefa fica para o dia (ou o dia útil anterior).
create or replace function public.criar_campanha(
  p_clinica            uuid,
  p_nome               text,
  p_segmento           text,
  p_meses              int,
  p_procedimento       uuid,
  p_somente_marketing  boolean,
  p_mensagem           text,
  p_limite_dia         int,
  p_inicia_em          date,
  p_pessoas            uuid[] default null
)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_id     uuid;
  v_hoje   date;
  v_dia    date;
  v_quando date;
  v_no_dia int := 0;
  v_total  int := 0;
  v_tarefa uuid;
  v_op     uuid;
  v_proc   text;
  v_prim   date;
  v_ult    date;
  v_rel    boolean := public.campanha_de_relacionamento(p_segmento);
  v_nome   text;
  x        record;
begin
  if not public.eh_admin(p_clinica) then
    raise exception 'Somente a administradora cria campanhas.' using errcode = '42501';
  end if;
  v_hoje := public.hoje_clinica(p_clinica);
  if p_inicia_em is null or p_inicia_em < v_hoje then
    raise exception 'A campanha precisa começar hoje ou numa data futura.' using errcode = 'P0001';
  end if;
  select nome into v_proc from public.procedimentos where id = p_procedimento and clinica_id = p_clinica;

  insert into public.campanhas (clinica_id, nome, segmento, meses, procedimento_id, somente_marketing, mensagem,
                                limite_dia, inicia_em)
  values (p_clinica, btrim(p_nome), p_segmento, p_meses, p_procedimento, p_somente_marketing, p_mensagem,
          p_limite_dia, p_inicia_em)
  returning id into v_id;

  v_dia := public.proximo_dia_util(p_clinica, p_inicia_em);
  for x in
    select * from public.prever_campanha(p_clinica, p_segmento, p_meses, p_procedimento, p_somente_marketing) c
     where p_pessoas is null or c.pessoa_id = any (p_pessoas)
  loop
    v_nome := coalesce((select nullif(apelido_tratamento, '') from public.pessoas where id = x.pessoa_id), split_part(x.nome, ' ', 1));
    if p_segmento = 'aniversario' then
      v_quando := case when public.eh_dia_util(p_clinica, x.referencia) then x.referencia
                       else public.dia_util_anterior(p_clinica, x.referencia) end;
      v_quando := greatest(v_quando, v_hoje);
    else
      if v_no_dia >= p_limite_dia then
        v_dia := public.proximo_dia_util(p_clinica, v_dia + 1);
        v_no_dia := 0;
      end if;
      v_quando := v_dia;
    end if;

    if v_rel then
      v_tarefa := public.criar_tarefa_auto(
        x.pessoa_id, null,
        case when p_segmento = 'tratamento_pendente' then 'agendar_tratamento' else 'personalizada' end::public.tipo_tarefa,
        case when p_segmento = 'tratamento_pendente' then 'agenda' else 'outra' end::public.categoria_tarefa,
        case p_segmento
          when 'aniversario' then 'Aniversário de ' || v_nome || ' — ' || to_char(x.referencia, 'DD/MM')
          when 'tratamento_pendente' then 'Convidar ' || v_nome || ' para continuar o tratamento'
          when 'pos_tratamento' then 'Pedir avaliação a ' || v_nome
          else 'Contato especial com ' || v_nome end,
        v_quando, 'normal', 'campanha', 'camp:' || v_id || ':' || x.pessoa_id, 1,
        'Campanha “' || btrim(p_nome) || '”. ' || x.detalhe, null,
        public.renderizar_texto(p_mensagem, x.pessoa_id, coalesce(x.procedimento, lower(v_proc))));
      v_op := null;
    else
      v_tarefa := public.abrir_reativacao(
        x.pessoa_id, null, p_procedimento, 'reativacao',
        'Convidar ' || v_nome || ' — ' || btrim(p_nome),
        'Campanha “' || btrim(p_nome) || '”. ' || x.detalhe,
        v_quando, 'campanha', public.renderizar_texto(p_mensagem, x.pessoa_id, coalesce(x.procedimento, lower(v_proc))), 'normal');
      if v_tarefa is not null then
        select oportunidade_id into v_op from public.tarefas where id = v_tarefa;
      end if;
    end if;

    if v_tarefa is not null then
      select vence_em into v_ult from public.tarefas where id = v_tarefa;
      insert into public.campanha_destinatarios (clinica_id, campanha_id, pessoa_id, oportunidade_id, tarefa_id, contato_em)
      values (p_clinica, v_id, x.pessoa_id, v_op, v_tarefa, v_ult);
      v_prim := least(coalesce(v_prim, v_ult), v_ult);
      v_no_dia := v_no_dia + 1;
      v_total := v_total + 1;
    end if;
  end loop;

  if v_total = 0 then
    raise exception 'Nenhuma pessoa elegível para esta campanha.' using errcode = 'P0001';
  end if;
  select max(contato_em) into v_ult from public.campanha_destinatarios where campanha_id = v_id;
  return jsonb_build_object('id', v_id, 'pessoas', v_total, 'primeiro_dia', v_prim, 'ultimo_dia', v_ult);
end;
$$;

revoke execute on function public.prever_campanha(uuid, text, int, uuid, boolean) from anon;
revoke execute on function public.criar_campanha(uuid, text, text, int, uuid, boolean, text, int, date, uuid[]) from anon;


-- Dados de exemplo atualizados (usados pelo botão "Recomeçar com dados de exemplo").
create schema if not exists teste;
revoke all on schema teste from public;
grant usage on schema teste to authenticated;

-- Cria a clínica "Instituto CG" com as situações de exemplo e devolve o id.
create or replace function teste.carregar_dados_ficticios()
returns uuid
language plpgsql
security definer
set search_path = public
as $$
declare
  c        uuid := public.inicializar_clinica('Instituto CG');
  hoje     date := public.hoje_clinica(c);
  prof     uuid;
  pix      uuid;
  credito  uuid;
  p        uuid;
  o        uuid;
  v        uuid;
  orc      uuid;

begin
  select id into prof from public.profissionais where clinica_id = c limit 1;
  select id into pix from public.formas_pagamento where clinica_id = c and nome = 'PIX';
  select id into credito from public.formas_pagamento where clinica_id = c and nome = 'Cartão parcelado';

  -- 1. Beatriz: novo contato que chegou hoje pelo Instagram → primeiro contato (urgente)
  insert into public.pessoas (clinica_id, nome, whatsapp_e164, cidade, uf, origem_id, temperatura)
  values (c, 'Beatriz Almeida', '+5511900000006', 'São Paulo', 'SP',
          (select id from public.origens where clinica_id = c and nome = 'Instagram'), 'quente')
  returning id into p;
  insert into public.oportunidades (clinica_id, pessoa_id, procedimento_id, etapa_id)
  values (c, p, (select id from public.procedimentos where clinica_id = c and nome = 'Facetas/lentes em resina'),
          (public.etapa_por_marco(c, 'novo_contato')).id);

  -- 2. Maria: recebeu o orçamento de facetas na consulta há 7 dias → contato hoje (importante)
  insert into public.pessoas (clinica_id, nome, whatsapp_e164, email, origem_id, temperatura, primeiro_contato_em)
  values (c, 'Maria Silva', '+5511900000001', 'maria.silva@exemplo.com',
          (select id from public.origens where clinica_id = c and nome = 'Indicação de paciente'), 'morna', hoje - 20)
  returning id into p;
  insert into public.oportunidades (clinica_id, pessoa_id, procedimento_id, etapa_id, valor_estimado_centavos)
  values (c, p, (select id from public.procedimentos where clinica_id = c and nome = 'Facetas de porcelana'),
          (public.etapa_por_marco(c, 'avaliacao_realizada')).id, 1400000)
  returning id into o;
  insert into public.orcamentos (clinica_id, pessoa_id, oportunidade_id, status, valor_total_centavos,
                                 condicao_pagamento, entrada_centavos, quantidade_parcelas, forma_pagamento_id,
                                 apresentado_em, valido_ate, apresentado_por)
  values (c, p, o, 'apresentado', 1400000, 'parcelado', 200000, 10, credito, hoje - 7, hoje + 23, prof);
  -- Consulta há 7 dias: o contato da regra "Saiu da consulta sem fechar" é hoje.
  update public.tarefas set vence_em = hoje where pessoa_id = p and status = 'pendente';

  -- 3. João: lead com quem a conversa começou; a tarefa ficou atrasada 2 dias
  insert into public.pessoas (clinica_id, nome, telefone_e164, whatsapp_e164, origem_id, primeiro_contato_em)
  values (c, 'João Lima', '+5511900000002', '+5511900000002',
          (select id from public.origens where clinica_id = c and nome = 'Google'), hoje - 4)
  returning id into p;
  insert into public.oportunidades (clinica_id, pessoa_id, procedimento_id, etapa_id)
  values (c, p, (select id from public.procedimentos where clinica_id = c and nome = 'Implantes'),
          (public.etapa_por_marco(c, 'em_contato')).id);
  update public.tarefas set vence_em = hoje - 2 where pessoa_id = p and status = 'pendente';

  -- 4. Carla: avaliação amanhã, mas desmarcou ontem → hoje "Entrar em contato para remarcar" (urgente)
  insert into public.pessoas (clinica_id, nome, whatsapp_e164, origem_id, primeiro_contato_em)
  values (c, 'Carla Mendes', '+5511900000003',
          (select id from public.origens where clinica_id = c and nome = 'Site'), hoje - 15)
  returning id into p;
  insert into public.oportunidades (clinica_id, pessoa_id, procedimento_id, etapa_id)
  values (c, p, (select id from public.procedimentos where clinica_id = c and nome = 'Clareamento dental'),
          (public.etapa_por_marco(c, 'em_contato')).id)
  returning id into o;
  insert into public.agendamentos (clinica_id, pessoa_id, oportunidade_id, profissional_id, tipo, inicio)
  values (c, p, o, prof, 'avaliacao', (hoje + 1 + time '10:00') at time zone 'America/Sao_Paulo');
  update public.agendamentos set status = 'desmarcado',
         motivo_id = (select id from public.motivos where clinica_id = c and nome = 'Trabalho')
   where pessoa_id = p;
  -- Regra "Paciente desmarcou": contato no dia seguinte à desmarcação (feita ontem).
  update public.tarefas set vence_em = hoje where pessoa_id = p and status = 'pendente';

  -- 5. Rafael: avaliação no próximo dia útil → confirmação hoje (rotina)
  insert into public.pessoas (clinica_id, nome, whatsapp_e164, origem_id, primeiro_contato_em)
  values (c, 'Rafael Gomes', '+5511900000007',
          (select id from public.origens where clinica_id = c and nome = 'Anúncio Instagram/Facebook'), hoje - 3)
  returning id into p;
  insert into public.oportunidades (clinica_id, pessoa_id, procedimento_id, etapa_id)
  values (c, p, (select id from public.procedimentos where clinica_id = c and nome = 'Estética odontológica'),
          (public.etapa_por_marco(c, 'em_contato')).id)
  returning id into o;
  insert into public.agendamentos (clinica_id, pessoa_id, oportunidade_id, profissional_id, tipo, inicio)
  values (c, p, o, prof, 'avaliacao', (public.proximo_dia_util(c, hoje + 1) + time '14:30') at time zone 'America/Sao_Paulo');
  update public.tarefas set vence_em = hoje where pessoa_id = p and status = 'pendente';

  -- 6. Luiza: passou pela consulta e ficou de pensar → contato em 2 dias (próximos dias)
  insert into public.pessoas (clinica_id, nome, whatsapp_e164, origem_id, primeiro_contato_em)
  values (c, 'Luiza Prado', '+5511900000008',
          (select id from public.origens where clinica_id = c and nome = 'Instagram'), hoje - 30)
  returning id into p;
  insert into public.oportunidades (clinica_id, pessoa_id, procedimento_id, etapa_id, valor_estimado_centavos)
  values (c, p, (select id from public.procedimentos where clinica_id = c and nome = 'Facetas de porcelana'),
          (public.etapa_por_marco(c, 'avaliacao_realizada')).id, 2200000)
  returning id into o;
  perform public.definir_proxima_acao(o, 'acompanhar_decisao', 'Retomar com Luiza depois da consulta',
                                      hoje + 2, 'alta', 'pos_consulta', 1, 'Ficou de pensar');

  -- 7. Marcos: contato pós-consulta que deveria ter sido feito há 3 dias (atrasada)
  insert into public.pessoas (clinica_id, nome, whatsapp_e164, origem_id, primeiro_contato_em)
  values (c, 'Marcos Tavares', '+5511900000009',
          (select id from public.origens where clinica_id = c and nome = 'Indicação de profissional'), hoje - 25)
  returning id into p;
  insert into public.oportunidades (clinica_id, pessoa_id, procedimento_id, etapa_id)
  values (c, p, (select id from public.procedimentos where clinica_id = c and nome = 'Periodontia'),
          (public.etapa_por_marco(c, 'avaliacao_realizada')).id)
  returning id into o;
  insert into public.orcamentos (clinica_id, pessoa_id, oportunidade_id, status, valor_total_centavos, apresentado_em)
  values (c, p, o, 'apresentado', 480000, hoje - 5);
  update public.tarefas set vence_em = hoje - 3 where pessoa_id = p and status = 'pendente';

  -- 8. Paulo: paciente antigo com saldo anterior; parcela atrasada há 5 dias; e reativação
  insert into public.pessoas (clinica_id, tipo_cadastro, nome, whatsapp_e164, origem_id,
                              paciente_desde, ultimo_atendimento_informado, consentimento_marketing)
  values (c, 'paciente_antigo', 'Paulo Ribeiro', '+5511900000004',
          (select id from public.origens where clinica_id = c and nome = 'Paciente antigo'),
          '2018-05-01', hoje - 420, true)
  returning id into p;
  insert into public.tratamentos_anteriores (clinica_id, pessoa_id, procedimento_id, realizado_em)
  values (c, p, (select id from public.procedimentos where clinica_id = c and nome = 'Manutenção e limpeza'), hoje - 420);
  insert into public.vendas (clinica_id, pessoa_id, tipo, valor_total_centavos, condicao_pagamento,
                             quantidade_parcelas, forma_pagamento_id, fechada_em, observacao_financeira)
  values (c, p, 'saldo_anterior', 160000, 'parcelado', 2, pix, hoje - 400, 'Saldo informado no recadastro')
  returning id into v;
  perform public.gerar_parcelas(v, hoje - 5);
  update public.tarefas set vence_em = hoje - 5
   where parcela_id = (select id from public.parcelas where venda_id = v and numero = 1);

  -- 9. Sofia: paciente antiga inativa → reativação hoje (rotina)
  insert into public.pessoas (clinica_id, tipo_cadastro, nome, whatsapp_e164, origem_id, ultimo_atendimento_informado)
  values (c, 'paciente_antigo', 'Sofia Martins', '+5511900000010',
          (select id from public.origens where clinica_id = c and nome = 'Paciente antigo'), hoje - 600)
  returning id into p;
  perform public.abrir_reativacao(p, null, null, 'reativacao', 'Reativar contato com Sofia',
                                  'Último atendimento em ' || to_char(hoje - 600, 'MM/YYYY'), hoje, 'paciente_inativo');
  update public.tarefas set vence_em = hoje where pessoa_id = p and status = 'pendente';

  -- 10. Ana: fechou lentes; entrada paga; parcela 1 vence hoje (importante)
  insert into public.pessoas (clinica_id, nome, whatsapp_e164, origem_id, primeiro_contato_em)
  values (c, 'Ana Costa', '+5511900000005',
          (select id from public.origens where clinica_id = c and nome = 'Instagram'), hoje - 60)
  returning id into p;
  insert into public.oportunidades (clinica_id, pessoa_id, procedimento_id, etapa_id)
  values (c, p, (select id from public.procedimentos where clinica_id = c and nome = 'Facetas/lentes em resina'),
          (public.etapa_por_marco(c, 'avaliacao_realizada')).id)
  returning id into o;
  insert into public.orcamentos (clinica_id, pessoa_id, oportunidade_id, status, valor_total_centavos, desconto_centavos,
                                 condicao_pagamento, entrada_centavos, quantidade_parcelas, forma_pagamento_id, apresentado_em)
  values (c, p, o, 'em_negociacao', 1250000, 50000, 'parcelado', 120000, 4, pix, hoje - 40)
  returning id into orc;
  insert into public.vendas (clinica_id, pessoa_id, oportunidade_id, orcamento_id, valor_total_centavos, desconto_centavos,
                             condicao_pagamento, entrada_centavos, quantidade_parcelas, forma_pagamento_id, fechada_em)
  values (c, p, o, orc, 1250000, 50000, 'parcelado', 120000, 4, pix, hoje - 35)
  returning id into v;
  perform public.gerar_parcelas(v, hoje, hoje - 35);
  insert into public.pagamentos (clinica_id, parcela_id, valor_centavos, pago_em, forma_pagamento_id)
  select c, id, valor_centavos, hoje - 35, pix from public.parcelas where venda_id = v and numero = 0;
  -- O tratamento dela já começou: a tarefa "agendar início" foi feita há tempos.
  update public.tarefas set status = 'concluida', resultado = 'Tratamento agendado'
   where pessoa_id = p and tipo = 'agendar_tratamento';
  update public.tarefas set vence_em = hoje where pessoa_id = p and status = 'pendente' and parcela_id is not null
     and vence_em < hoje + 1;

  -- 11. Fernanda: pediu retorno daqui a 4 dias (próximos dias)
  insert into public.pessoas (clinica_id, nome, whatsapp_e164, origem_id, primeiro_contato_em)
  values (c, 'Fernanda Lopes', '+5511900000011',
          (select id from public.origens where clinica_id = c and nome = 'WhatsApp'), hoje - 6)
  returning id into p;
  insert into public.oportunidades (clinica_id, pessoa_id, procedimento_id, etapa_id)
  values (c, p, (select id from public.procedimentos where clinica_id = c and nome = 'Clareamento dental'),
          (public.etapa_por_marco(c, 'em_contato')).id)
  returning id into o;
  perform public.definir_proxima_acao(o, 'follow_up', 'Retornar para Fernanda (pediu retorno)',
                                      hoje + 4, 'alta', 'pediu_retorno');

  -- 12. Tiago: recebeu orçamento e parou de responder → "Sem resposta" (nova tentativa leve)
  insert into public.pessoas (clinica_id, nome, whatsapp_e164, origem_id, primeiro_contato_em, ultimo_contato_em)
  values (c, 'Tiago Moreira', '+5511900000012',
          (select id from public.origens where clinica_id = c and nome = 'Google'), hoje - 40, now() - interval '12 days')
  returning id into p;
  insert into public.oportunidades (clinica_id, pessoa_id, procedimento_id, etapa_id, valor_estimado_centavos)
  values (c, p, (select id from public.procedimentos where clinica_id = c and nome = 'Implantes'),
          (public.etapa_por_marco(c, 'avaliacao_realizada')).id, 900000)
  returning id into o;
  perform public.mover_etapa(o, public.etapa_por_resultado(c, 'sem_resposta'), 'Parou de responder após o orçamento');
  update public.tarefas set vence_em = hoje + 12 where oportunidade_id = o and status = 'pendente';

  -- 13. Vera: não fechou por valor alto; retomada combinada para daqui a 25 dias
  insert into public.pessoas (clinica_id, nome, whatsapp_e164, origem_id, primeiro_contato_em, ultimo_contato_em)
  values (c, 'Vera Albuquerque', '+5511900000013',
          (select id from public.origens where clinica_id = c and nome = 'Indicação de paciente'), hoje - 21, now() - interval '5 days')
  returning id into p;
  insert into public.oportunidades (clinica_id, pessoa_id, procedimento_id, etapa_id, valor_estimado_centavos)
  values (c, p, (select id from public.procedimentos where clinica_id = c and nome = 'Facetas de porcelana'),
          (public.etapa_por_marco(c, 'avaliacao_realizada')).id, 2400000)
  returning id into o;
  update public.oportunidades set reabre_em = hoje + 25 where id = o;
  perform public.mover_etapa(o, public.etapa_por_resultado(c, 'nao_fechou'), 'Achou o investimento alto neste momento',
                             (select id from public.motivos where clinica_id = c and nome = 'Valor alto'));

  -- Dentistas (fictícias): a dona da clínica e mais duas.
  update public.profissionais set nome = 'Dra. Cristina' where id = prof;
  insert into public.profissionais (clinica_id, nome, cor) values
    (c, 'Dra. Paula Reis', '#5F8A6A'),
    (c, 'Dra. Lívia Moraes', '#7A6FA8');

  -- Agenda da semana: consultas já confirmadas (sem tarefas novas no painel).
  insert into public.agendamentos (clinica_id, pessoa_id, oportunidade_id, profissional_id, tipo, procedimento_id,
                                   inicio, duracao_min, status, confirmado_em)
  select c, pe.id, null, prof, 'procedimento',
         (select id from public.procedimentos where clinica_id = c and nome = 'Facetas/lentes em resina'),
         (public.proximo_dia_util(c, hoje) + time '11:00') at time zone 'America/Sao_Paulo', 90, 'confirmado', now()
    from public.pessoas pe where pe.clinica_id = c and pe.nome = 'Ana Costa';
  insert into public.agendamentos (clinica_id, pessoa_id, oportunidade_id, profissional_id, tipo, procedimento_id,
                                   inicio, duracao_min, status, confirmado_em)
  select c, pe.id, o.id, (select id from public.profissionais where clinica_id = c and nome = 'Dra. Paula Reis'),
         'apresentacao_orcamento', o.procedimento_id,
         (public.proximo_dia_util(c, public.proximo_dia_util(c, hoje) + 1) + time '16:00') at time zone 'America/Sao_Paulo',
         30, 'confirmado', now()
    from public.pessoas pe join public.oportunidades o on o.pessoa_id = pe.id and o.status = 'aberta'
   where pe.clinica_id = c and pe.nome = 'Luiza Prado';

  -- Consulta de hoje: para testar "Compareceu" → "Abrir prontuário".
  insert into public.pessoas (clinica_id, nome, whatsapp_e164, cidade, uf, origem_id)
  values (c, 'Renata Alves', '+5511900000016', 'São Paulo', 'SP',
          (select id from public.origens where clinica_id = c and nome = 'Indicação de paciente'))
  returning id into p;
  insert into public.agendamentos (clinica_id, pessoa_id, profissional_id, tipo, procedimento_id, inicio, duracao_min,
                                   status, confirmado_em)
  values (c, p, (select id from public.profissionais where clinica_id = c and nome = 'Dra. Lívia Moraes'), 'procedimento',
          (select id from public.procedimentos where clinica_id = c and nome = 'Clareamento dental'),
          (hoje + time '08:30') at time zone 'America/Sao_Paulo', 60, 'confirmado', now());

  -- Prontuário da Maria: consulta 01 (avaliação, finalizada) com odontograma e plano de tratamento.
  insert into public.atendimentos (clinica_id, prontuario_id, pessoa_id, profissional_id, data, horario, tipo, procedimento_id,
                                   motivo_obs, queixa, anamnese_obs, odontograma, status, finalizado_em)
  select c, pr.id, pr.pessoa_id, prof, hoje - 14, time '10:00', 'avaliacao',
         (select id from public.procedimentos where clinica_id = c and nome = 'Facetas de porcelana'),
         'Avaliação estética', 'Acha os dentes amarelados e desgastados na frente.',
         'Hipertensa, usa losartana 50 mg. Sem alergias conhecidas. Range os dentes à noite.',
         '{"11": {"c": "faceta", "f": [], "s": "a_tratar"}, "21": {"c": "faceta", "f": [], "s": "a_tratar"},
           "16": {"c": "restauracao", "f": ["O"], "s": "existente"}, "26": {"c": "carie", "f": ["O", "M"], "s": "a_tratar"},
           "36": {"c": "canal", "f": [], "s": "existente"}}'::jsonb,
         'finalizado', now() - interval '14 days'
    from public.prontuarios pr join public.pessoas pe on pe.id = pr.pessoa_id
   where pe.clinica_id = c and pe.nome = 'Maria Silva'
  returning id, pessoa_id into v, p;
  insert into public.orcamentos (clinica_id, pessoa_id, origem, status, apresentado_em, apresentado_por)
  values (c, p, 'prontuario', 'apresentado', hoje - 14, prof)
  returning id into orc;
  insert into public.orcamento_itens (clinica_id, orcamento_id, procedimento_id, valor_unitario_centavos, dente, atendimento_id,
                                      status, realizado_atendimento_id, realizado_em)
  values
    (c, orc, (select id from public.procedimentos where clinica_id = c and nome = 'Manutenção e limpeza'), 35000, null, v,
     'realizado', v, hoje - 14),
    (c, orc, (select id from public.procedimentos where clinica_id = c and nome = 'Clareamento dental'), 120000, null, v,
     'pendente', null, null),
    (c, orc, (select id from public.procedimentos where clinica_id = c and nome = 'Facetas de porcelana'), 1400000, '13 a 23', v,
     'pendente', null, null);

  -- 14 e 15. Pacientes antigos sem atendimento há meses (público de campanhas de reativação)
  insert into public.pessoas (clinica_id, tipo_cadastro, nome, whatsapp_e164, origem_id, ultimo_atendimento_informado,
                              consentimento_marketing)
  values (c, 'paciente_antigo', 'Gabriela Rocha', '+5511900000014',
          (select id from public.origens where clinica_id = c and nome = 'Paciente antigo'), hoje - 430, true)
  returning id into p;
  insert into public.tratamentos_anteriores (clinica_id, pessoa_id, procedimento_id, realizado_em)
  values (c, p, (select id from public.procedimentos where clinica_id = c and nome = 'Clareamento dental'), hoje - 430);
  insert into public.pessoas (clinica_id, tipo_cadastro, nome, whatsapp_e164, origem_id, ultimo_atendimento_informado)
  values (c, 'paciente_antigo', 'Heitor Campos', '+5511900000015',
          (select id from public.origens where clinica_id = c and nome = 'Paciente antigo'), hoje - 280);

  -- Aniversários nos próximos dias (campanha "Aniversário").
  update public.pessoas set data_nascimento = (hoje + 6 - interval '38 years')::date where clinica_id = c and nome = 'Gabriela Rocha';
  update public.pessoas set data_nascimento = (hoje + 20 - interval '45 years')::date where clinica_id = c and nome = 'Heitor Campos';

  -- A rotina de hoje já "rodou" para estes dados.
  insert into public.execucoes_rotina (clinica_id, dia) values (c, hoje);
  return c;
end;
$$;
revoke execute on function teste.carregar_dados_ficticios() from public, anon, authenticated;

-- Login de teste. No Supabase de verdade, cria o login já confirmado e com senha
-- (nenhum e-mail é enviado); se já existir, troca a senha.
create or replace function teste.criar_login(p_email text, p_nome text, p_senha text)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  v_id uuid;
  v_col text;
begin
  select id into v_id from auth.users where lower(email) = lower(p_email);
  if not exists (select 1 from information_schema.columns
                  where table_schema = 'auth' and table_name = 'users' and column_name = 'encrypted_password') then
    -- Banco local (sem Supabase Auth): o login é só o e-mail.
    if v_id is null then
      insert into auth.users (email, raw_user_meta_data) values (p_email, jsonb_build_object('nome', p_nome));
    end if;
    return;
  end if;

  if v_id is not null then
    execute 'update auth.users set encrypted_password = extensions.crypt($2, extensions.gen_salt(''bf'')),
                                   email_confirmed_at = coalesce(email_confirmed_at, now()), updated_at = now()
              where id = $1' using v_id, p_senha;
    return;
  end if;

  v_id := gen_random_uuid();
  execute 'insert into auth.users (instance_id, id, aud, role, email, encrypted_password, email_confirmed_at,
                                   raw_app_meta_data, raw_user_meta_data, created_at, updated_at)
           values (''00000000-0000-0000-0000-000000000000'', $1, ''authenticated'', ''authenticated'', $2,
                   extensions.crypt($3, extensions.gen_salt(''bf'')), now(),
                   ''{"provider": "email", "providers": ["email"]}'', jsonb_build_object(''nome'', $4), now(), now())'
    using v_id, p_email, p_senha, p_nome;
  -- O Supabase Auth não aceita estes campos nulos.
  for v_col in select column_name from information_schema.columns
                where table_schema = 'auth' and table_name = 'users'
                  and column_name in ('confirmation_token', 'recovery_token', 'email_change_token_new',
                                      'email_change_token_current', 'email_change', 'phone_change',
                                      'phone_change_token', 'reauthentication_token') loop
    execute format('update auth.users set %I = coalesce(%I, '''') where id = $1', v_col, v_col) using v_id;
  end loop;
  execute 'insert into auth.identities (id, user_id, provider_id, identity_data, provider, last_sign_in_at, created_at, updated_at)
           values (gen_random_uuid(), $1, $1::text,
                   jsonb_build_object(''sub'', $1::text, ''email'', $2, ''email_verified'', true), ''email'', now(), now(), now())'
    using v_id, p_email;
end;
$$;
revoke execute on function teste.criar_login(text, text, text) from public, anon, authenticated;

-- Logins da versão de teste (dona e secretária), com senhas novas a cada chamada.
-- Para trocar as senhas: select * from teste.criar_logins_de_teste();
create or replace function teste.criar_logins_de_teste()
returns table (perfil text, email text, senha text)
language plpgsql
security definer
set search_path = public
as $$
declare
  v_clinica uuid := (select id from public.clinicas where nome = 'Instituto CG' order by criado_em desc limit 1);
  v_senha text;
begin
  if v_clinica is null then v_clinica := teste.carregar_dados_ficticios(); end if;
  for perfil, email, v_senha in
    select x.perfil, x.email, 'cg-' || substr(md5(random()::text), 1, 4) || '-' || substr(md5(random()::text), 1, 4)
      from (values ('Dona da clínica (administradora)', 'dona@teste.institutocg.com.br', 1),
                   ('Secretária', 'secretaria@teste.institutocg.com.br', 2)) as x (perfil, email, ordem)
     order by x.ordem
  loop
    perform teste.criar_login(email, case when email like 'dona@%' then 'Dra. Cristina (teste)' else 'Secretária (teste)' end, v_senha);
    perform public.adicionar_membro(v_clinica, email, case when email like 'dona@%' then 'admin' else 'comercial' end::public.papel_membro, true);
    senha := v_senha;
    return next;
  end loop;
end;
$$;
revoke execute on function teste.criar_logins_de_teste() from public, anon, authenticated;

-- "Recomeçar com dados de exemplo" (só a administradora, só na versão de teste):
-- apaga tudo o que foi feito nos testes e recria as situações de exemplo, com
-- datas a partir de hoje. Os logins continuam os mesmos.
create or replace function teste.recomecar()
returns uuid
language plpgsql
security definer
set search_path = public
as $$
declare
  v_clinica uuid := (select m.clinica_id from public.membros m where m.usuario_id = auth.uid() and m.ativo
                      order by m.criado_em limit 1);
  v_membros jsonb;
  v_tabelas text;
  v_nova uuid;
  v_m jsonb;
begin
  if v_clinica is null or not public.eh_admin(v_clinica) then
    raise exception 'Só a administradora pode recomeçar a versão de teste.' using errcode = '42501';
  end if;
  select jsonb_agg(jsonb_build_object('email', u.email, 'papel', m.papel, 'fin', m.pode_ver_financeiro))
    into v_membros
    from public.membros m join public.usuarios u on u.id = m.usuario_id
   where m.clinica_id = v_clinica and m.ativo;

  select string_agg(format('public.%I', tablename), ', ') into v_tabelas
    from pg_tables where schemaname = 'public' and tablename <> 'usuarios';
  execute 'truncate table ' || v_tabelas || ' restart identity cascade';

  -- Os dados de exemplo são criados "pelo sistema", não em nome de quem clicou.
  perform set_config('request.jwt.claims', '', true);
  perform set_config('request.jwt.claim.sub', '', true);
  v_nova := teste.carregar_dados_ficticios();
  for v_m in select * from jsonb_array_elements(v_membros) loop
    perform public.adicionar_membro(v_nova, v_m ->> 'email', (v_m ->> 'papel')::public.papel_membro, (v_m ->> 'fin')::boolean);
  end loop;
  return v_nova;
end;
$$;
revoke execute on function teste.recomecar() from public, anon;
grant execute on function teste.recomecar() to authenticated;


commit;
