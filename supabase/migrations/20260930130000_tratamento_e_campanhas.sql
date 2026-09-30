-- =============================================================================
-- Migração 8: acompanhamento do tratamento e campanhas de reativação
--   • Fechou → a pessoa sai do funil de vendas e fica "em tratamento".
--   • concluir_tratamento(): registra o fim do tratamento e agenda o retorno
--     (regra "Retorno após o tratamento", 6 meses por padrão).
--   • Campanhas: a administradora escolhe um grupo (pacientes inativos, quem fez
--     um procedimento, quem não fechou), revisa a lista e o sistema distribui os
--     contatos em dias úteis, com limite por dia. Nada é enviado sozinho: cada
--     contato vira uma tarefa com a mensagem sugerida.
-- =============================================================================

-- ─── Fechou → em tratamento ──────────────────────────────────────────────────

create or replace function public.iniciar_tratamento()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  if new.status = 'ganha' and old.status is distinct from 'ganha' then
    update public.pessoas set em_tratamento = true, retorno_previsto_em = null where id = new.pessoa_id;
  end if;
  return null;
end;
$$;

create trigger iniciar_tratamento
  after update on public.oportunidades
  for each row execute function public.iniciar_tratamento();

-- Tratamento concluído: último atendimento = hoje e retorno previsto pela regra.
create or replace function public.concluir_tratamento(p_pessoa uuid, p_retorno date default null)
returns date
language plpgsql
security definer
set search_path = public
as $$
declare
  v_pessoa  public.pessoas;
  v_hoje    date;
  r         public.regras_followup;
  v_retorno date;
begin
  select * into v_pessoa from public.pessoas where id = p_pessoa for update;
  if v_pessoa.id is null or (auth.uid() is not null and v_pessoa.clinica_id not in (select public.minhas_clinicas())) then
    raise exception 'Cadastro não encontrado.' using errcode = 'P0002';
  end if;
  v_hoje := public.hoje_clinica(v_pessoa.clinica_id);
  r := public.regra(v_pessoa.clinica_id, 'pos_tratamento');
  if p_retorno is not null and p_retorno <= v_hoje then
    raise exception 'A data do retorno precisa ser futura.' using errcode = 'P0001';
  end if;
  v_retorno := coalesce(p_retorno,
                        case when r.ativa then (v_hoje + make_interval(months => coalesce(r.periodo_meses, 6)))::date end);

  update public.pessoas
     set em_tratamento = false,
         ultimo_atendimento_informado = v_hoje,
         ultimo_atendimento_faixa = null,
         retorno_previsto_em = v_retorno
   where id = p_pessoa;

  update public.tarefas set status = 'concluida', resultado = 'Tratamento concluído'
   where pessoa_id = p_pessoa and status = 'pendente' and tipo = 'agendar_tratamento';

  insert into public.interacoes (clinica_id, pessoa_id, tipo, descricao)
  values (v_pessoa.clinica_id, p_pessoa, 'nota',
          'Tratamento concluído' || coalesce('. Retorno previsto para ' || to_char(v_retorno, 'DD/MM/YYYY'), ''));
  return v_retorno;
end;
$$;

revoke execute on function public.concluir_tratamento(uuid, date) from anon;

-- ─── Campanhas ───────────────────────────────────────────────────────────────

create table public.campanhas (
  id                  uuid primary key default gen_random_uuid(),
  clinica_id          uuid not null references public.clinicas (id),
  nome                text not null check (length(btrim(nome)) between 1 and 80),
  segmento            text not null check (segmento in ('inativos', 'procedimento', 'nao_fecharam')),
  meses               int not null check (meses between 1 and 120),
  procedimento_id     uuid,
  somente_marketing   boolean not null default false,
  mensagem            text not null check (length(mensagem) between 1 and 2000),
  limite_dia          int not null check (limite_dia between 1 and 50),
  inicia_em           date not null,
  encerrada_em        timestamptz,
  criada_por          uuid default auth.uid(),
  criado_em           timestamptz not null default now(),
  atualizado_em       timestamptz not null default now(),
  unique (clinica_id, id),
  foreign key (clinica_id, procedimento_id) references public.procedimentos (clinica_id, id),
  check (segmento <> 'procedimento' or procedimento_id is not null)
);

create table public.campanha_destinatarios (
  id               uuid primary key default gen_random_uuid(),
  clinica_id       uuid not null references public.clinicas (id),
  campanha_id      uuid not null,
  pessoa_id        uuid not null,
  oportunidade_id  uuid,
  tarefa_id        uuid,
  contato_em       date not null,
  criado_em        timestamptz not null default now(),
  unique (campanha_id, pessoa_id),
  foreign key (clinica_id, campanha_id) references public.campanhas (clinica_id, id),
  foreign key (clinica_id, pessoa_id) references public.pessoas (clinica_id, id),
  foreign key (clinica_id, oportunidade_id) references public.oportunidades (clinica_id, id)
);
create index campanha_destinatarios_pessoa on public.campanha_destinatarios (pessoa_id, criado_em desc);

create trigger definir_atualizado_em before update on public.campanhas
  for each row execute function public.definir_atualizado_em();
create trigger auditoria after insert or update or delete on public.campanhas
  for each row execute function public.registrar_auditoria();

-- Todos veem as campanhas; somente a administradora cria ou encerra (pelas funções abaixo).
alter table public.campanhas enable row level security;
create policy membro_ler on public.campanhas for select to authenticated
  using (clinica_id in (select public.minhas_clinicas()));
alter table public.campanha_destinatarios enable row level security;
create policy membro_ler on public.campanha_destinatarios for select to authenticated
  using (clinica_id in (select public.minhas_clinicas()));

-- Quem entra numa campanha. Só pessoas que aceitam contato, sem negociação em
-- andamento, sem outra campanha nos últimos 30 dias, sem contato recente e sem
-- pagamento em atraso.
create or replace function public.prever_campanha(
  p_clinica            uuid,
  p_segmento           text,
  p_meses              int,
  p_procedimento       uuid default null,
  p_somente_marketing  boolean default false
)
returns table (pessoa_id uuid, nome text, detalhe text, referencia date)
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
begin
  if auth.uid() is not null and p_clinica not in (select public.minhas_clinicas()) then
    raise exception 'Sem acesso a esta clínica.' using errcode = '42501';
  end if;
  if p_segmento = 'procedimento' and p_procedimento is null then
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
                else 'Paciente antigo, sem data de atendimento' end as det
      from public.v_contatos c
     where p_segmento = 'inativos' and c.clinica_id = p_clinica
       and c.relacionamento <> 'lead' and not c.em_tratamento
       and (c.ultimo_atendimento_em is null or c.ultimo_atendimento_em <= v_corte))
    union all
    -- Quem fez o procedimento há X meses (ex.: clareamento há 12 meses)
    (select distinct on (x.pid) x.pid, p.nome, x.dia, x.det
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
      ) x
      join public.pessoas p on p.id = x.pid
     where p_segmento = 'procedimento' and not p.em_tratamento
     order by x.pid, x.dia desc nulls last)
    union all
    -- Quem não fechou há X meses
    (select distinct on (o.pessoa_id) o.pessoa_id, p.nome, o.fechada_em::date,
           case when o.resultado = 'desistiu' then 'Desistiu' else 'Não fechou' end
             || coalesce(' (' || lower(m.nome) || ')', '') || coalesce(' — ' || lower(pr.nome), '')
             || ' em ' || to_char(o.fechada_em, 'MM/YYYY')
      from public.oportunidades o
      join public.pessoas p on p.id = o.pessoa_id
      left join public.motivos m on m.id = o.motivo_id
      left join public.procedimentos pr on pr.id = o.procedimento_id
     where p_segmento = 'nao_fecharam' and o.clinica_id = p_clinica and o.status = 'perdida'
       and o.fechada_em::date <= v_corte
       and (p_procedimento is null or o.procedimento_id = p_procedimento)
     order by o.pessoa_id, o.fechada_em desc)
  )
  select k.id, k.nome, k.det, k.ref
    from candidatos k
    join public.pessoas p on p.id = k.id
   where p.arquivado_em is null and not p.nao_contatar and p.consentimento_contato
     and (not p_somente_marketing or p.consentimento_marketing)
     and (p.ultimo_contato_em is null or p.ultimo_contato_em < now() - make_interval(days => v_intervalo))
     and not exists (select 1 from public.oportunidades o where o.pessoa_id = p.id and o.status in ('aberta', 'pausada'))
     and not exists (select 1 from public.campanha_destinatarios d where d.pessoa_id = p.id
                      and d.criado_em > now() - interval '30 days')
     -- Quem está com pagamento em atraso é tratado pelo financeiro, não por campanha.
     and not exists (select 1 from public.parcelas pa where pa.pessoa_id = p.id
                      and pa.status in ('pendente', 'parcial') and pa.vencimento < v_hoje)
   order by k.ref nulls first, k.nome;
end;
$$;

-- Cria a campanha e distribui os contatos: `limite_dia` pessoas por dia útil a
-- partir de `inicia_em`. Cada pessoa vai para a coluna "Reativação" do funil com
-- uma tarefa e a mensagem personalizada. p_pessoas permite tirar nomes da lista.
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
  v_no_dia int := 0;
  v_total  int := 0;
  v_tarefa uuid;
  v_op     uuid;
  v_proc   text;
  v_prim   date;
  v_ult    date;
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
    if v_no_dia >= p_limite_dia then
      v_dia := public.proximo_dia_util(p_clinica, v_dia + 1);
      v_no_dia := 0;
    end if;
    v_tarefa := public.abrir_reativacao(
      x.pessoa_id, null, p_procedimento, 'reativacao',
      'Convidar ' || coalesce((select nullif(apelido_tratamento, '') from public.pessoas where id = x.pessoa_id),
                              split_part(x.nome, ' ', 1)) || ' — ' || btrim(p_nome),
      'Campanha “' || btrim(p_nome) || '”. ' || x.detalhe,
      v_dia, 'campanha', public.renderizar_texto(p_mensagem, x.pessoa_id, v_proc), 'normal');
    if v_tarefa is not null then
      select oportunidade_id, vence_em into v_op, v_ult from public.tarefas where id = v_tarefa;
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

-- Encerrar: contatos ainda não feitos são cancelados (quem já respondeu segue no funil).
create or replace function public.encerrar_campanha(p_campanha uuid)
returns int
language plpgsql
security definer
set search_path = public
as $$
declare
  c public.campanhas;
  n int;
begin
  select * into c from public.campanhas where id = p_campanha;
  if c.id is null or not public.eh_admin(c.clinica_id) then
    raise exception 'Campanha não encontrada.' using errcode = 'P0002';
  end if;
  if c.encerrada_em is not null then
    raise exception 'Esta campanha já foi encerrada.' using errcode = 'P0001';
  end if;
  update public.campanhas set encerrada_em = now() where id = p_campanha;

  -- Negociações ainda paradas no primeiro contato da campanha saem do funil junto com a tarefa.
  with canceladas as (
    update public.tarefas t set status = 'cancelada', cancelada_motivo = 'Campanha encerrada'
      from public.campanha_destinatarios d
     where d.campanha_id = p_campanha and t.id = d.tarefa_id and t.status = 'pendente'
    returning t.oportunidade_id
  )
  select count(*) into n from canceladas;
  perform set_config('crm.acao_manual', 'on', true);
  update public.oportunidades o
     set etapa_id = (public.etapa_por_resultado(o.clinica_id, 'desistiu')),
         motivo_id = (select id from public.motivos where clinica_id = o.clinica_id and aplica_a = 'desistiu' and ativo
                       order by (nome = 'Sem interesse no momento') desc, ordem limit 1)
    from public.campanha_destinatarios d
   where d.campanha_id = p_campanha and o.id = d.oportunidade_id and o.status = 'aberta'
     and not exists (select 1 from public.tarefas t where t.oportunidade_id = o.id and t.status = 'pendente')
     and not exists (select 1 from public.interacoes i where i.oportunidade_id = o.id);
  perform set_config('crm.acao_manual', '', true);
  return n;
end;
$$;

-- Resultado de cada campanha (contatados, responderam, agendaram, fecharam).
create view public.v_campanhas with (security_invoker = true) as
select
  c.*,
  pr.nome as procedimento,
  u.nome  as criada_por_nome,
  count(d.id)                                                             as pessoas,
  count(d.id) filter (where t.status = 'concluida')                       as contatadas,
  count(d.id) filter (where t.status = 'pendente')                        as a_contatar,
  count(d.id) filter (where t.status = 'pendente' and t.vence_em <= public.hoje_clinica(c.clinica_id)) as para_hoje,
  count(d.id) filter (where o.status = 'ganha' or (o.status = 'aberta' and e.marco is distinct from 'reativacao')
                      or exists (select 1 from public.interacoes i where i.oportunidade_id = d.oportunidade_id
                                   and i.tipo in ('paciente_respondeu', 'retorno_solicitado', 'paciente_fechou')))
                                                                           as responderam,
  count(d.id) filter (where exists (select 1 from public.agendamentos a where a.oportunidade_id = d.oportunidade_id))
                                                                           as agendaram,
  count(d.id) filter (where o.status = 'ganha')                           as fecharam,
  min(d.contato_em) as primeiro_contato,
  max(d.contato_em) as ultimo_contato
from public.campanhas c
left join public.procedimentos pr on pr.id = c.procedimento_id
left join public.usuarios u on u.id = c.criada_por
left join public.campanha_destinatarios d on d.campanha_id = c.id
left join public.tarefas t on t.id = d.tarefa_id
left join public.oportunidades o on o.id = d.oportunidade_id
left join public.etapas_funil e on e.id = o.etapa_id
group by c.id, pr.nome, u.nome;

revoke execute on function public.prever_campanha(uuid, text, int, uuid, boolean) from anon;
revoke execute on function public.criar_campanha(uuid, text, text, int, uuid, boolean, text, int, date, uuid[]) from anon;
revoke execute on function public.encerrar_campanha(uuid) from anon;
revoke execute on function public.iniciar_tratamento() from public, anon, authenticated;
