-- =============================================================================
-- Instituto CG — ATUALIZAR A VERSÃO DE TESTE (tudo de uma vez)
--
-- Arquivo gerado por scripts/gerar-atualizacao-teste.sh — não edite à mão.
--
-- Cole no SQL Editor do projeto de TESTE e clique em "Run".
-- Pode colar mesmo que já tenha aplicado alguma atualização antes: o que já
-- existe é pulado. Os dados que você colocou continuam lá.
-- Inclui tudo desde a primeira versão de teste: agenda, prontuário, campanhas,
-- segurança reforçada, "Criar a minha campanha" e receituário.
-- =============================================================================

-- ---------------------------------------------------------------------------
-- Parte 1: migrations/20261005120000_agenda_financeiro.sql
-- ---------------------------------------------------------------------------
do $parte1$
begin
  if not exists (select 1 from information_schema.columns where table_schema = 'public' and table_name = 'vendas' and column_name = 'agendamento_id') then
    execute $atualizacao1$
-- =============================================================================
-- Migração 13: agenda integrada ao financeiro
--   • Ao agendar, o valor do procedimento (agendamentos.valor_centavos).
--   • Ao marcar "Compareceu", registrar_atendimento(): pago agora, vai pagar depois
--     (data prevista e parcelas) ou sem cobrança — sem preencher nada à parte.
--     O pagamento entra no Financeiro e os lembretes (previsto / atrasado) nascem sozinhos.
--   • Cobrança de avaliação/retorno não fecha a negociação no funil; a de
--     procedimento fecha (como uma venda registrada pelo funil).
-- =============================================================================

alter table public.agendamentos
  add column if not exists valor_centavos bigint check (valor_centavos > 0);

alter table public.vendas
  add column if not exists agendamento_id uuid unique,
  add column if not exists procedimento_id uuid;
alter table public.vendas
  add constraint vendas_agendamento_fk foreign key (clinica_id, agendamento_id) references public.agendamentos (clinica_id, id),
  add constraint vendas_procedimento_fk foreign key (clinica_id, procedimento_id) references public.procedimentos (clinica_id, id);

-- ─── Venda vinda da agenda pode não fechar a negociação ──────────────────────

create or replace function public.ao_registrar_venda()
returns trigger
language plpgsql
as $$
declare
  v_etapa_fechou uuid;
begin
  -- Cobrança de uma consulta (avaliação, retorno…): entra no financeiro sem fechar a negociação.
  if new.tipo = 'venda' and coalesce(current_setting('crm.venda_sem_fechar', true), '') <> 'on' then
    select id into v_etapa_fechou from public.etapas_funil
     where clinica_id = new.clinica_id and resultado = 'fechou' and ativo;
    if v_etapa_fechou is null then
      raise exception 'A clínica não tem etapa ativa para "Fechou".' using errcode = 'P0001';
    end if;

    update public.oportunidades set valor_fechado_centavos = new.valor_final_centavos
     where id = new.oportunidade_id;
    if (select status from public.oportunidades where id = new.oportunidade_id) <> 'ganha' then
      perform public.mover_etapa(new.oportunidade_id, v_etapa_fechou, 'Venda registrada');
    end if;

    if new.orcamento_id is not null then
      update public.orcamentos set status = 'aprovado' where id = new.orcamento_id;
      update public.orcamentos set status = 'substituido'
       where oportunidade_id = new.oportunidade_id and id <> new.orcamento_id
         and status in ('rascunho', 'apresentado', 'em_negociacao');
    end if;

    insert into public.interacoes (clinica_id, pessoa_id, oportunidade_id, tipo, descricao)
    values (new.clinica_id, new.pessoa_id, new.oportunidade_id, 'paciente_fechou',
            'Negociação fechada: ' || public.formatar_brl(new.valor_final_centavos));
  end if;
  return new;
end;
$$;

-- ─── Financeiro: o procedimento da cobrança vem da consulta, quando houver ──

create or replace view public.v_financeiro_parcelas with (security_invoker = true) as
select
  pa.id, pa.clinica_id, pa.venda_id, pa.pessoa_id, pa.numero, pa.vencimento, pa.pago_em,
  pa.valor_centavos, pa.valor_pago_centavos,
  pa.valor_centavos - pa.valor_pago_centavos                       as saldo_centavos,
  pa.observacao_financeira                                         as observacao,
  pe.nome                                                          as pessoa_nome,
  coalesce(pe.whatsapp_e164, pe.telefone_e164)                     as whatsapp,
  pr.nome                                                          as procedimento,
  fp.nome                                                          as forma_pagamento,
  v.quantidade_parcelas,
  public.hoje_clinica(pa.clinica_id) - pa.vencimento               as dias_atraso,
  case
    when pa.status = 'paga' then 'pago'
    when pa.status in ('pendente', 'parcial') and pa.vencimento < public.hoje_clinica(pa.clinica_id) then 'atrasado'
    when pa.status = 'parcial' then 'parcial'
    when pa.status = 'pendente' then 'pendente'
    else pa.status::text
  end                                                              as situacao,
  (select t.id from public.tarefas t where t.parcela_id = pa.id and t.status = 'pendente' limit 1) as tarefa_id,
  coalesce(v.procedimento_id, o.procedimento_id) as procedimento_id
from public.parcelas pa
join public.vendas v on v.id = pa.venda_id
join public.pessoas pe on pe.id = pa.pessoa_id
left join public.oportunidades o on o.id = v.oportunidade_id
left join public.procedimentos pr on pr.id = coalesce(v.procedimento_id, o.procedimento_id)
left join public.formas_pagamento fp on fp.id = pa.forma_pagamento_id
where v.status = 'ativa' and pa.status <> 'cancelada';

create or replace view public.v_financeiro_negociacoes with (security_invoker = true) as
select
  v.id, v.clinica_id, v.pessoa_id, v.tipo, v.fechada_em,
  pe.nome                                       as pessoa_nome,
  coalesce(pr.nome, case when v.tipo = 'saldo_anterior' then 'Saldo anterior' end) as procedimento,
  v.valor_total_centavos, v.desconto_centavos, v.valor_final_centavos,
  v.entrada_centavos, v.quantidade_parcelas, v.valor_parcela_centavos,
  fp.nome                                       as forma_pagamento,
  v.observacao_financeira                       as observacao,
  coalesce(sum(p.valor_pago_centavos), 0)::bigint                                     as pago_centavos,
  coalesce(sum(p.saldo_centavos) filter (where p.situacao <> 'pago'), 0)::bigint      as saldo_centavos,
  coalesce(sum(p.saldo_centavos) filter (where p.situacao = 'atrasado'), 0)::bigint   as atrasado_centavos,
  min(p.vencimento) filter (where p.situacao <> 'pago')                               as proximo_vencimento,
  max(p.pago_em)                                                                      as ultimo_pagamento_em,
  case
    when count(p.id) filter (where p.situacao <> 'pago') = 0 then 'pago'
    when count(p.id) filter (where p.situacao = 'atrasado') > 0 then 'atrasado'
    when coalesce(sum(p.valor_pago_centavos), 0) > 0 then 'parcial'
    else 'pendente'
  end                                           as situacao,
  coalesce(v.procedimento_id, o.procedimento_id) as procedimento_id,
  v.agendamento_id
from public.vendas v
join public.pessoas pe on pe.id = v.pessoa_id
left join public.oportunidades o on o.id = v.oportunidade_id
left join public.procedimentos pr on pr.id = coalesce(v.procedimento_id, o.procedimento_id)
left join public.formas_pagamento fp on fp.id = v.forma_pagamento_id
left join public.v_financeiro_parcelas p on p.venda_id = v.id
where v.status = 'ativa'
group by v.id, pe.nome, pr.nome, fp.nome, o.procedimento_id;

create or replace function public.resumo_financeiro(p_clinica uuid, p_mes date, p_procedimento uuid default null)
returns jsonb
language sql
stable
set search_path = public
as $$
  with lim as (
    select date_trunc('month', p_mes)::date as ini,
           (date_trunc('month', p_mes) + interval '1 month')::date as fim
  ),
  -- Parcelas do filtro (todas, ou só as do procedimento escolhido).
  p as (
    select * from public.v_financeiro_parcelas
     where clinica_id = p_clinica and (p_procedimento is null or procedimento_id = p_procedimento)
  ),
  pg as (
    select pg.* from public.pagamentos pg join p on p.id = pg.parcela_id, lim
     where pg.estornado_em is null and pg.pago_em >= lim.ini and pg.pago_em < lim.fim
  )
  select jsonb_build_object(
    'recebido_mes', coalesce((select sum(valor_centavos) from pg), 0),
    'pagamentos_mes', (select count(*) from pg),
    'previsto_mes', coalesce((select sum(p.saldo_centavos) from p, lim
                               where p.situacao <> 'pago' and p.vencimento >= lim.ini and p.vencimento < lim.fim), 0),
    'pendente', coalesce((select sum(p.saldo_centavos) from p where p.situacao in ('pendente', 'parcial')), 0),
    'atrasado', coalesce((select sum(p.saldo_centavos) from p where p.situacao = 'atrasado'), 0),
    'atrasados', (select count(*) from p where p.situacao = 'atrasado'),
    'vendido_mes', coalesce((select sum(v.valor_final_centavos)
                               from public.vendas v left join public.oportunidades o on o.id = v.oportunidade_id, lim
                              where v.clinica_id = p_clinica and v.status = 'ativa' and v.tipo = 'venda'
                                and (p_procedimento is null or coalesce(v.procedimento_id, o.procedimento_id) = p_procedimento)
                                and v.fechada_em >= lim.ini and v.fechada_em < lim.fim), 0)
  );
$$;

-- ─── Agenda: valor e situação da cobrança ────────────────────────────────────

create or replace view public.v_agenda with (security_invoker = true) as
select
  a.id, a.clinica_id, a.pessoa_id, a.oportunidade_id, a.tipo, a.status, a.inicio, a.duracao_min,
  a.inicio + make_interval(mins => a.duracao_min)            as fim,
  (a.inicio at time zone 'America/Sao_Paulo')::date           as dia,
  to_char(a.inicio at time zone 'America/Sao_Paulo', 'HH24:MI') as horario,
  a.observacoes, a.confirmado_em, a.status_em, a.remarcado_para_id,
  p.nome                                                      as pessoa_nome,
  coalesce(p.whatsapp_e164, p.telefone_e164)                  as whatsapp,
  p.tipo_cadastro,
  a.procedimento_id,
  pr.nome                                                     as procedimento,
  a.profissional_id,
  pf.nome                                                     as profissional,
  pf.cor                                                      as profissional_cor,
  m.nome                                                      as motivo,
  (select x.inicio from public.agendamentos x where x.id = a.remarcado_para_id) as remarcado_para,
  (select r.situacao from public.v_recuperacao r where r.agendamento_id = a.id)   as recuperacao,
  a.valor_centavos,
  -- Cobrança registrada ao marcar "Compareceu" (situação do financeiro).
  (select n.situacao from public.v_financeiro_negociacoes n where n.agendamento_id = a.id) as cobranca,
  -- O paciente já tem uma negociação registrada no financeiro (pelo funil ou pelo Financeiro) nos últimos 6 meses?
  (select n.procedimento || ' — ' || public.formatar_brl(n.valor_final_centavos)
          || case when n.saldo_centavos > 0 then ' (em aberto ' || public.formatar_brl(n.saldo_centavos) || ')' else ' (pago)' end
     from public.v_financeiro_negociacoes n
    where n.pessoa_id = a.pessoa_id and n.agendamento_id is null and n.tipo = 'venda'
      and n.fechada_em >= (a.inicio at time zone 'America/Sao_Paulo')::date - 180
    order by n.fechada_em desc limit 1)                                    as negociacao_registrada
from public.agendamentos a
join public.pessoas p on p.id = a.pessoa_id
left join public.procedimentos pr on pr.id = a.procedimento_id
left join public.profissionais pf on pf.id = a.profissional_id
left join public.motivos m on m.id = a.motivo_id;

-- ─── Agendar e remarcar levam o valor ────────────────────────────────────────

drop function if exists public.agendar(uuid, uuid, public.tipo_agendamento, uuid, timestamptz, int, uuid, boolean, text,
                                       boolean, text, text, public.tipo_cadastro);

create or replace function public.agendar(
  p_clinica       uuid,
  p_pessoa        uuid,
  p_tipo          public.tipo_agendamento,
  p_procedimento  uuid,
  p_inicio        timestamptz,
  p_duracao       int,
  p_profissional  uuid,
  p_confirmado    boolean default false,
  p_observacoes   text default null,
  p_encaixe       boolean default false,
  -- Paciente ainda não cadastrado:
  p_nome          text default null,
  p_whatsapp      text default null,
  p_tipo_cadastro public.tipo_cadastro default 'novo_contato',
  -- Valor do procedimento (cobrado quando a paciente comparecer):
  p_valor_centavos bigint default null
)
returns jsonb
language plpgsql
set search_path = public
as $$
declare
  v_pessoa  uuid := p_pessoa;
  v_nova    boolean := false;
  v_op      public.oportunidades;
  v_ag      uuid;
  v_antes   text := coalesce(current_setting('crm.acao_manual', true), '');
  v_tarefa  jsonb;
  v_prof    uuid;
begin
  if p_clinica not in (select public.minhas_clinicas()) then
    raise exception 'Sem acesso a esta clínica.' using errcode = '42501';
  end if;
  v_prof := public.dentista_escolhida(p_clinica, p_profissional);
  perform public.validar_horario(p_clinica, p_inicio, coalesce(p_duracao, 60), v_prof, p_encaixe);

  -- Paciente: o selecionado, o que já tem este WhatsApp, ou um cadastro novo.
  if v_pessoa is null then
    if nullif(btrim(p_nome), '') is null or p_whatsapp is null then
      raise exception 'Selecione o paciente ou informe nome e WhatsApp.' using errcode = 'P0001';
    end if;
    select id into v_pessoa from public.pessoas
     where clinica_id = p_clinica and (whatsapp_e164 = p_whatsapp or telefone_e164 = p_whatsapp) and arquivado_em is null
     limit 1;
    if v_pessoa is null then
      insert into public.pessoas (clinica_id, tipo_cadastro, nome, whatsapp_e164, responsavel_id, origem_id)
      values (p_clinica, p_tipo_cadastro, btrim(p_nome), p_whatsapp, auth.uid(),
              case when p_tipo_cadastro = 'paciente_antigo'
                   then (select id from public.origens where clinica_id = p_clinica and tipo = 'interno' order by ordem limit 1) end)
      returning id into v_pessoa;
      v_nova := true;
    end if;
  end if;
  if not exists (select 1 from public.pessoas where id = v_pessoa and clinica_id = p_clinica) then
    raise exception 'Paciente não encontrado.' using errcode = 'P0002';
  end if;

  -- Negociação: a que está em andamento; para avaliação, abre uma se não houver.
  select * into v_op from public.oportunidades where pessoa_id = v_pessoa and status in ('aberta', 'pausada');
  if v_op.id is null and p_tipo in ('avaliacao', 'apresentacao_orcamento') then
    perform set_config('crm.acao_manual', 'on', true);
    insert into public.oportunidades (clinica_id, pessoa_id, procedimento_id, origem_id, etapa_id, responsavel_id)
    select p_clinica, v_pessoa, p_procedimento, pe.origem_id,
           (public.etapa_por_marco(p_clinica, 'avaliacao_agendada')).id, coalesce(pe.responsavel_id, auth.uid())
      from public.pessoas pe where pe.id = v_pessoa
    returning * into v_op;
    perform set_config('crm.acao_manual', v_antes, true);
  elsif v_op.status = 'pausada' then
    -- Estava sem resposta e marcou: a negociação volta a andar.
    perform set_config('crm.acao_manual', 'on', true);
    perform public.mover_etapa(v_op.id,
      (public.etapa_por_marco(p_clinica, case when p_tipo = 'avaliacao' then 'avaliacao_agendada' else 'em_contato' end)).id,
      'Voltou a responder e agendou');
    perform set_config('crm.acao_manual', v_antes, true);
  end if;
  if v_op.id is not null and v_op.procedimento_id is null and p_procedimento is not null then
    update public.oportunidades set procedimento_id = p_procedimento where id = v_op.id;
  end if;

  if p_valor_centavos is not null and p_valor_centavos <= 0 then
    raise exception 'O valor do procedimento deve ser maior que zero.' using errcode = 'P0001';
  end if;
  insert into public.agendamentos (clinica_id, pessoa_id, oportunidade_id, profissional_id, tipo, procedimento_id,
                                   inicio, duracao_min, status, confirmado_em, observacoes, valor_centavos)
  values (p_clinica, v_pessoa, v_op.id, v_prof, p_tipo, p_procedimento, p_inicio, coalesce(p_duracao, 60),
          case when p_confirmado then 'confirmado' else 'agendado' end::public.status_agendamento,
          case when p_confirmado then now() end, nullif(btrim(p_observacoes), ''), p_valor_centavos)
  returning id into v_ag;

  select jsonb_build_object('titulo', titulo, 'vence_em', vence_em) into v_tarefa
    from public.tarefas where agendamento_id = v_ag and status = 'pendente' order by vence_em limit 1;
  return jsonb_build_object('id', v_ag, 'pessoa_id', v_pessoa, 'pessoa_nova', v_nova, 'tarefa', v_tarefa);
end;
$$;

create or replace function public.remarcar_consulta(
  p_agendamento  uuid,
  p_inicio       timestamptz,
  p_duracao      int default null,
  p_profissional uuid default null,
  p_encaixe      boolean default false
)
returns jsonb
language plpgsql
set search_path = public
as $$
declare
  a        public.agendamentos;
  v_novo   uuid;
  v_quando text := to_char(p_inicio at time zone 'America/Sao_Paulo', 'DD/MM "às" HH24:MI');
  v_tarefa jsonb;
begin
  select * into a from public.agendamentos where id = p_agendamento for update;
  if a.id is null then
    raise exception 'Consulta não encontrada.' using errcode = 'P0002';
  end if;
  if a.status in ('compareceu', 'remarcado') or a.remarcado_para_id is not null then
    raise exception 'Esta consulta já foi %.', case when a.status = 'compareceu' then 'realizada' else 'remarcada' end
      using errcode = 'P0001';
  end if;
  perform public.validar_horario(a.clinica_id, p_inicio, coalesce(p_duracao, a.duracao_min),
                                 case when p_profissional is null then a.profissional_id
                                      else public.dentista_escolhida(a.clinica_id, p_profissional) end,
                                 p_encaixe, a.id);

  -- Antes de criar a nova consulta — tarefas antigas: a recuperação foi resolvida; a confirmação antiga não vale mais.
  update public.tarefas set status = 'concluida', resultado = 'Remarcou para ' || v_quando
   where pessoa_id = a.pessoa_id and status = 'pendente'
     and (tipo in ('recuperar_desmarcacao', 'recuperar_falta')
          or (agendamento_id = a.id and tipo <> 'confirmar_agendamento'));
  update public.tarefas set status = 'cancelada', cancelada_motivo = 'Consulta remarcada para ' || v_quando
   where agendamento_id = a.id and status = 'pendente';

  insert into public.agendamentos (clinica_id, pessoa_id, oportunidade_id, profissional_id, tipo, procedimento_id,
                                   inicio, duracao_min, observacoes, valor_centavos)
  values (a.clinica_id, a.pessoa_id,
          (select id from public.oportunidades where pessoa_id = a.pessoa_id and status in ('aberta', 'pausada')),
          coalesce(p_profissional, a.profissional_id), a.tipo, a.procedimento_id, p_inicio,
          coalesce(p_duracao, a.duracao_min), a.observacoes, a.valor_centavos)
  returning id into v_novo;

  if a.status in ('agendado', 'confirmado') then
    update public.agendamentos set status = 'remarcado', remarcado_para_id = v_novo where id = a.id;
  else
    -- Desmarcada, faltou ou cancelada e recuperada: o status fica, com o vínculo.
    update public.agendamentos set remarcado_para_id = v_novo where id = a.id;
  end if;


  select jsonb_build_object('titulo', titulo, 'vence_em', vence_em) into v_tarefa
    from public.tarefas where agendamento_id = v_novo and status = 'pendente' order by vence_em limit 1;
  return jsonb_build_object('id', v_novo, 'tarefa', v_tarefa);
end;
$$;

-- Ajustar o valor de uma consulta (antes de registrar a cobrança).
create or replace function public.definir_valor_consulta(p_agendamento uuid, p_valor_centavos bigint)
returns void
language plpgsql
set search_path = public
as $$
begin
  if p_valor_centavos is not null and p_valor_centavos <= 0 then
    raise exception 'O valor do procedimento deve ser maior que zero.' using errcode = 'P0001';
  end if;
  if exists (select 1 from public.vendas where agendamento_id = p_agendamento and status = 'ativa') then
    raise exception 'O pagamento desta consulta já foi registrado. Ajuste pelo Financeiro.' using errcode = 'P0001';
  end if;
  update public.agendamentos set valor_centavos = p_valor_centavos where id = p_agendamento;
  if not found then
    raise exception 'Consulta não encontrada.' using errcode = 'P0002';
  end if;
end;
$$;

-- ─── Compareceu + pagamento, num passo só ────────────────────────────────────
-- p_cobranca:
--   'pago'          → recebido hoje (PIX, dinheiro, transferência ou cartão; cartão parcelado aceita parcelas)
--   'a_pagar'       → vai pagar depois: data prevista (1º vencimento) e parcelas → lembretes no painel
--   'sem_cobranca'  → avaliação gratuita, cortesia…
--   'ja_registrado' → o pagamento já está no Financeiro (fechou pelo funil, por exemplo)
-- Serve também para registrar depois a cobrança de quem já está como "Compareceu".

create or replace function public.registrar_atendimento(
  p_agendamento  uuid,
  p_cobranca     text,
  p_valor        bigint default null,
  p_forma        uuid default null,
  p_vencimento   date default null,
  p_parcelas     int default 1,
  p_observacao   text default null
)
returns jsonb
language plpgsql
set search_path = public
as $$
declare
  a        public.agendamentos;
  f        public.formas_pagamento;
  v_hoje   date;
  v_valor  bigint;
  v_fecha  boolean;
  v_neg    jsonb;
  v_venda  uuid;
  v_antes  text := coalesce(current_setting('crm.venda_sem_fechar', true), '');
  x        record;
begin
  select * into a from public.agendamentos where id = p_agendamento;
  if a.id is null then
    raise exception 'Consulta não encontrada.' using errcode = 'P0002';
  end if;
  if p_cobranca not in ('pago', 'a_pagar', 'sem_cobranca', 'ja_registrado') then
    raise exception 'Escolha como ficou o pagamento.' using errcode = 'P0001';
  end if;
  v_hoje := public.hoje_clinica(a.clinica_id);

  if a.status <> 'compareceu' then
    perform public.mudar_status_consulta(p_agendamento, 'compareceu');
  end if;
  if p_cobranca in ('sem_cobranca', 'ja_registrado') then
    return jsonb_build_object('cobranca', p_cobranca);
  end if;

  if not public.pode_ver_financeiro(a.clinica_id) then
    raise exception 'Seu acesso não inclui o financeiro.' using errcode = '42501';
  end if;
  if exists (select 1 from public.vendas where agendamento_id = a.id and status = 'ativa') then
    raise exception 'O pagamento desta consulta já foi registrado.' using errcode = 'P0001';
  end if;
  v_valor := coalesce(p_valor, a.valor_centavos);
  if coalesce(v_valor, 0) <= 0 then
    raise exception 'Informe o valor.' using errcode = 'P0001';
  end if;
  select * into f from public.formas_pagamento where id = p_forma and clinica_id = a.clinica_id and ativo;
  if f.id is null then
    raise exception 'Escolha a forma de pagamento.' using errcode = 'P0001';
  end if;
  if p_cobranca = 'a_pagar' and not f.recebe_na_hora then
    if p_vencimento is null then
      raise exception 'Informe a data prevista do pagamento.' using errcode = 'P0001';
    end if;
    if p_vencimento < v_hoje then
      raise exception 'A data prevista não pode estar no passado.' using errcode = 'P0001';
    end if;
  end if;
  if p_cobranca = 'pago' and not f.recebe_na_hora and coalesce(p_parcelas, 1) > 1 then
    raise exception 'Pago agora em % é uma parcela só. Para parcelar, escolha "Vai pagar depois".', f.nome
      using errcode = 'P0001';
  end if;

  -- Procedimento fecha a negociação; avaliação, retorno e manutenção não.
  v_fecha := a.tipo = 'procedimento';
  if not v_fecha then perform set_config('crm.venda_sem_fechar', 'on', true); end if;
  v_neg := public.registrar_negociacao(
    a.clinica_id, a.pessoa_id, case when v_fecha then a.procedimento_id end, v_valor, 0, 0, null, null,
    greatest(coalesce(p_parcelas, 1), 1),
    case when p_cobranca = 'a_pagar' then coalesce(p_vencimento, v_hoje) else v_hoje end,
    f.id, coalesce(nullif(btrim(p_observacao), ''), 'Consulta de ' || to_char(a.inicio at time zone 'America/Sao_Paulo', 'DD/MM/YYYY')));
  perform set_config('crm.venda_sem_fechar', v_antes, true);
  v_venda := (v_neg ->> 'venda_id')::uuid;
  update public.vendas set agendamento_id = a.id, procedimento_id = a.procedimento_id where id = v_venda;

  -- Pago agora (PIX, dinheiro, transferência): quita na hora. Cartão já entra quitado.
  if p_cobranca = 'pago' then
    for x in select id from public.parcelas where venda_id = v_venda and status in ('pendente', 'parcial') loop
      perform public.registrar_pagamento(x.id, null, v_hoje, f.id, null);
    end loop;
  end if;

  return jsonb_build_object('cobranca', p_cobranca, 'venda_id', v_venda,
    'situacao', (select situacao from public.v_financeiro_negociacoes where id = v_venda),
    'parcelas', (select count(*) from public.parcelas where venda_id = v_venda),
    'proximo_vencimento', (select proximo_vencimento from public.v_financeiro_negociacoes where id = v_venda));
end;
$$;

revoke execute on function public.registrar_atendimento(uuid, text, bigint, uuid, date, int, text) from anon;
revoke execute on function public.definir_valor_consulta(uuid, bigint) from anon;
revoke execute on function public.agendar(uuid, uuid, public.tipo_agendamento, uuid, timestamptz, int, uuid, boolean, text,
  boolean, text, text, public.tipo_cadastro, bigint) from anon;
$atualizacao1$;
    raise notice 'Parte 1 aplicada.';
  else
    raise notice 'Parte 1 já estava aplicada — pulada.';
  end if;
end $parte1$;

-- ---------------------------------------------------------------------------
-- Parte 2: migrations/20261006120000_prontuario.sql
-- ---------------------------------------------------------------------------
do $parte2$
begin
  if to_regclass('public.prontuarios') is null then
    execute $atualizacao2$
-- =============================================================================
-- Migração 14: prontuário
--   • Um prontuário por paciente (prontuarios.pessoa_id), criado automaticamente.
--   • Consultas do prontuário (atendimentos): uma por atendimento, sem apagar as
--     anteriores. Cada uma guarda a ficha (seleções + campos curtos) e o
--     ODONTOGRAMA daquele momento (cópia do anterior ao abrir a próxima).
--   • Plano de tratamento = orçamento (origem 'prontuario') com itens que têm
--     status (orçado, aceito, pendente, realizado, não realizado, cancelado).
--     Realizar um item registra a cobrança no Financeiro existente (vendas,
--     parcelas, pagamentos) — o mesmo pagamento aparece nos dois lugares.
--   • Agenda: o atendimento nasce do agendamento (data, horário, dentista,
--     procedimento/motivo).
--   • Acesso: dados de saúde (LGPD, dado sensível) — administradora, dentistas
--     e quem tiver membros.pode_ver_prontuario. Tudo auditado; nada é apagado.
-- =============================================================================

-- ─── Acesso ──────────────────────────────────────────────────────────────────

alter table public.membros add column if not exists pode_ver_prontuario boolean not null default false;

create or replace function public.pode_ver_prontuario(p_clinica uuid)
returns boolean
language sql
stable
security definer
set search_path = public
as $$
  select exists (
    select 1 from public.membros m
    join public.usuarios u on u.id = m.usuario_id
    where m.usuario_id = auth.uid() and m.clinica_id = p_clinica and m.ativo and u.ativo
      and (m.papel in ('admin', 'dentista') or m.pode_ver_prontuario)
  );
$$;

-- ─── Prontuário: um por paciente ─────────────────────────────────────────────

create table public.prontuarios (
  id          uuid primary key default gen_random_uuid(),
  clinica_id  uuid not null references public.clinicas (id),
  pessoa_id   uuid not null unique,
  criado_em   timestamptz not null default now(),
  unique (clinica_id, id),
  foreign key (clinica_id, pessoa_id) references public.pessoas (clinica_id, id)
);

create or replace function public.criar_prontuario()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  insert into public.prontuarios (clinica_id, pessoa_id) values (new.clinica_id, new.id)
  on conflict (pessoa_id) do nothing;
  return null;
end;
$$;

create trigger criar_prontuario
  after insert on public.pessoas
  for each row execute function public.criar_prontuario();

-- Pacientes já cadastrados ganham o prontuário agora.
insert into public.prontuarios (clinica_id, pessoa_id)
select clinica_id, id from public.pessoas
on conflict (pessoa_id) do nothing;

-- ─── Consultas do prontuário (atendimentos) ──────────────────────────────────

create type public.status_atendimento as enum ('em_andamento', 'finalizado');

create table public.atendimentos (
  id               uuid primary key default gen_random_uuid(),
  clinica_id       uuid not null references public.clinicas (id),
  prontuario_id    uuid not null,
  pessoa_id        uuid not null,
  numero           int not null default 0,                 -- Consulta 01, 02… (gatilho)
  agendamento_id   uuid unique,                            -- a consulta da agenda que originou
  profissional_id  uuid,
  data             date not null,
  horario          time,
  tipo             public.tipo_agendamento,
  procedimento_id  uuid,                                   -- procedimento/motivo do agendamento
  motivo           text[] not null default '{}',
  motivo_obs       text check (length(motivo_obs) <= 500),
  anamnese         text[] not null default '{}',
  anamnese_obs     text check (length(anamnese_obs) <= 2000),
  diagnostico      text[] not null default '{}',
  diagnostico_obs  text check (length(diagnostico_obs) <= 2000),
  evolucao         text check (length(evolucao) <= 4000),  -- evolução / conduta
  orientacoes      text[] not null default '{}',
  orientacoes_obs  text check (length(orientacoes_obs) <= 1000),
  retorno_em       date,
  retorno_obs      text check (length(retorno_obs) <= 300),
  -- Estado do odontograma NESTA consulta: {"16": {"c": "carie", "f": ["O"], "s": "a_tratar", "o": "…"}}
  odontograma      jsonb not null default '{}'::jsonb check (jsonb_typeof(odontograma) = 'object'),
  status           public.status_atendimento not null default 'em_andamento',
  finalizado_em    timestamptz,
  finalizado_por   uuid,
  criado_por       uuid default auth.uid(),
  criado_em        timestamptz not null default now(),
  atualizado_em    timestamptz not null default now(),
  unique (clinica_id, id),
  unique (prontuario_id, numero),
  foreign key (clinica_id, prontuario_id) references public.prontuarios (clinica_id, id),
  foreign key (clinica_id, pessoa_id) references public.pessoas (clinica_id, id),
  foreign key (clinica_id, agendamento_id) references public.agendamentos (clinica_id, id),
  foreign key (clinica_id, profissional_id) references public.profissionais (clinica_id, id),
  foreign key (clinica_id, procedimento_id) references public.procedimentos (clinica_id, id)
);

create index atendimentos_pessoa on public.atendimentos (pessoa_id, data desc, numero desc);

create or replace function public.numerar_atendimento()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  if new.numero = 0 then
    perform pg_advisory_xact_lock(hashtext('atendimento:' || new.prontuario_id));
    select coalesce(max(numero), 0) + 1 into new.numero from public.atendimentos where prontuario_id = new.prontuario_id;
  end if;
  return new;
end;
$$;

create trigger numerar_atendimento
  before insert on public.atendimentos
  for each row execute function public.numerar_atendimento();

-- Consulta finalizada não muda (o histórico é preservado).
create or replace function public.proteger_atendimento()
returns trigger
language plpgsql
as $$
begin
  if tg_op = 'DELETE' then
    raise exception 'Consultas do prontuário não são apagadas.' using errcode = 'P0001';
  end if;
  if old.status = 'finalizado' then
    raise exception 'Esta consulta foi finalizada e não pode ser alterada.' using errcode = 'P0001';
  end if;
  return coalesce(new, old);
end;
$$;

create trigger proteger_atendimento
  before update or delete on public.atendimentos
  for each row execute function public.proteger_atendimento();

create trigger definir_atualizado_em before update on public.atendimentos
  for each row execute function public.definir_atualizado_em();

-- ─── Plano de tratamento = orçamento do prontuário ───────────────────────────

create type public.status_item_plano as enum ('orcado', 'aceito', 'pendente', 'realizado', 'nao_realizado', 'cancelado');

-- O plano é um orçamento comum, marcado como vindo do prontuário. Não precisa de
-- negociação (paciente antigo, manutenção…) e não mexe no funil.
alter table public.orcamentos
  add column if not exists origem text not null default 'comercial' check (origem in ('comercial', 'prontuario'));
alter table public.orcamentos alter column oportunidade_id drop not null;

alter table public.orcamento_itens
  add column if not exists status public.status_item_plano not null default 'orcado',
  add column if not exists dente text check (length(dente) <= 60),
  add column if not exists atendimento_id uuid,             -- consulta em que foi planejado
  add column if not exists realizado_atendimento_id uuid,   -- consulta em que foi realizado
  add column if not exists realizado_em date,
  add column if not exists venda_id uuid,                   -- cobrança no Financeiro
  add column if not exists atualizado_em timestamptz not null default now();
alter table public.orcamento_itens
  add constraint orcamento_itens_atendimento_fk foreign key (clinica_id, atendimento_id) references public.atendimentos (clinica_id, id),
  add constraint orcamento_itens_realizado_fk foreign key (clinica_id, realizado_atendimento_id) references public.atendimentos (clinica_id, id),
  add constraint orcamento_itens_venda_fk foreign key (clinica_id, venda_id) references public.vendas (clinica_id, id),
  add constraint orcamento_itens_realizado_ck check ((status = 'realizado') = (realizado_atendimento_id is not null));

create trigger definir_atualizado_em before update on public.orcamento_itens
  for each row execute function public.definir_atualizado_em();

create or replace function public.motor_orcamento_apresentado()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  -- O plano de tratamento do prontuário não é um orçamento comercial: não mexe no funil nem cria follow-up.
  if new.origem = 'prontuario' or new.oportunidade_id is null then
    return null;
  end if;
  if new.status <> 'apresentado' or (tg_op = 'UPDATE' and old.status = 'apresentado') then
    return null;
  end if;
  -- O orçamento é apresentado na consulta: a negociação fica em "Consulta realizada".
  perform public.avancar_para_marco(new.oportunidade_id, 'avaliacao_realizada', 'Orçamento apresentado na consulta');
  if not public.tem_proxima_acao(new.oportunidade_id) then
    perform public.criar_por_regra('pos_consulta', new.pessoa_id, new.oportunidade_id, 'op:' || new.oportunidade_id,
      p_base => coalesce(new.apresentado_em, public.hoje_clinica(new.clinica_id)), p_descricao => 'Recebeu o orçamento na consulta');
  end if;
  return null;
end;
$$;

-- Total do orçamento: sem os itens cancelados ou não realizados.
create or replace function public.recalcular_orcamento()
returns trigger
language plpgsql
as $$
declare
  v_orcamento uuid := coalesce(new.orcamento_id, old.orcamento_id);
begin
  update public.orcamentos o
     set valor_total_centavos = coalesce((
           select sum(i.quantidade * i.valor_unitario_centavos - i.desconto_centavos)
             from public.orcamento_itens i
            where i.orcamento_id = v_orcamento and i.status not in ('cancelado', 'nao_realizado')), 0)
   where o.id = v_orcamento;
  return null;
end;
$$;

-- ─── Acesso (RLS) e auditoria ────────────────────────────────────────────────

alter table public.prontuarios enable row level security;
alter table public.atendimentos enable row level security;

create policy prontuario_ler on public.prontuarios for select to authenticated
  using (public.pode_ver_prontuario(clinica_id));
create policy prontuario_ler on public.atendimentos for select to authenticated
  using (public.pode_ver_prontuario(clinica_id));
create policy prontuario_inserir on public.atendimentos for insert to authenticated
  with check (public.pode_ver_prontuario(clinica_id));
create policy prontuario_alterar on public.atendimentos for update to authenticated
  using (public.pode_ver_prontuario(clinica_id)) with check (public.pode_ver_prontuario(clinica_id));
-- Quem atende vê o plano de tratamento mesmo sem acesso ao financeiro.
create policy prontuario_ler on public.orcamentos for select to authenticated
  using (origem = 'prontuario' and public.pode_ver_prontuario(clinica_id));
create policy prontuario_ler on public.orcamento_itens for select to authenticated
  using (public.pode_ver_prontuario(clinica_id)
         and exists (select 1 from public.orcamentos o where o.id = orcamento_id and o.origem = 'prontuario'));

create trigger auditoria after insert or update or delete on public.atendimentos
  for each row execute function public.registrar_auditoria();
create trigger auditoria after insert or update or delete on public.prontuarios
  for each row execute function public.registrar_auditoria();

-- ─── Visões ──────────────────────────────────────────────────────────────────

create view public.v_atendimentos with (security_invoker = true) as
select
  a.id, a.clinica_id, a.prontuario_id, a.pessoa_id, a.numero, a.agendamento_id, a.data,
  to_char(a.horario, 'HH24:MI')                                 as horario,
  a.tipo, a.procedimento_id, pr.nome                            as procedimento,
  a.profissional_id, pf.nome                                    as profissional, pf.cor as profissional_cor,
  a.status, a.finalizado_em, a.motivo, a.anamnese, a.diagnostico, a.retorno_em,
  (select count(*) from public.orcamento_itens i where i.realizado_atendimento_id = a.id)::int as realizados,
  (select string_agg(p2.nome, ', ' order by i.realizado_em, p2.nome)
     from public.orcamento_itens i join public.procedimentos p2 on p2.id = i.procedimento_id
    where i.realizado_atendimento_id = a.id)                    as procedimentos_realizados
from public.atendimentos a
left join public.procedimentos pr on pr.id = a.procedimento_id
left join public.profissionais pf on pf.id = a.profissional_id;

create view public.v_plano_tratamento with (security_invoker = true) as
select
  i.id, i.clinica_id, o.pessoa_id, i.orcamento_id, o.numero as orcamento_numero,
  i.procedimento_id, pr.nome as procedimento, i.dente, i.status,
  (i.quantidade * i.valor_unitario_centavos - i.desconto_centavos)  as valor_centavos,
  i.atendimento_id, ap.numero as atendimento_numero,
  i.realizado_atendimento_id, ar.numero as realizado_atendimento_numero, i.realizado_em,
  i.venda_id, n.situacao as financeiro, n.saldo_centavos, n.pago_centavos, n.proximo_vencimento,
  i.criado_em
from public.orcamento_itens i
join public.orcamentos o on o.id = i.orcamento_id
join public.procedimentos pr on pr.id = i.procedimento_id
left join public.atendimentos ap on ap.id = i.atendimento_id
left join public.atendimentos ar on ar.id = i.realizado_atendimento_id
left join public.v_financeiro_negociacoes n on n.id = i.venda_id
where o.origem = 'prontuario';

-- ─── Abrir consultas ─────────────────────────────────────────────────────────

-- Cria a consulta no prontuário; o odontograma começa como o da consulta anterior.
create or replace function public.criar_atendimento(
  p_pessoa uuid, p_data date, p_horario time default null, p_profissional uuid default null,
  p_tipo public.tipo_agendamento default null, p_procedimento uuid default null, p_agendamento uuid default null
)
returns uuid
language plpgsql
set search_path = public
as $$
declare
  pr     public.prontuarios;
  v_id   uuid;
  v_mot  text[];
begin
  select * into pr from public.prontuarios where pessoa_id = p_pessoa;
  if pr.id is null or not public.pode_ver_prontuario(pr.clinica_id) then
    raise exception 'Sem acesso ao prontuário.' using errcode = '42501';
  end if;
  v_mot := case p_tipo when 'avaliacao' then array['Avaliação'] when 'retorno' then array['Retorno']
                       when 'manutencao' then array['Manutenção / limpeza'] when 'procedimento' then array['Continuidade do tratamento']
                       else '{}' end;
  insert into public.atendimentos (clinica_id, prontuario_id, pessoa_id, agendamento_id, profissional_id, data, horario,
                                   tipo, procedimento_id, motivo, odontograma)
  values (pr.clinica_id, pr.id, p_pessoa, p_agendamento, p_profissional, coalesce(p_data, public.hoje_clinica(pr.clinica_id)),
          p_horario, p_tipo, p_procedimento, v_mot,
          coalesce((select a.odontograma from public.atendimentos a where a.prontuario_id = pr.id
                     order by a.data desc, a.numero desc limit 1), '{}'::jsonb))
  returning id into v_id;
  return v_id;
end;
$$;

-- Agenda → prontuário: abre (ou cria) a consulta daquele agendamento.
create or replace function public.abrir_atendimento(p_agendamento uuid)
returns uuid
language plpgsql
set search_path = public
as $$
declare
  a     public.agendamentos;
  v_id  uuid;
begin
  select * into a from public.agendamentos where id = p_agendamento;
  if a.id is null then
    raise exception 'Consulta não encontrada.' using errcode = 'P0002';
  end if;
  if not public.pode_ver_prontuario(a.clinica_id) then
    raise exception 'Sem acesso ao prontuário.' using errcode = '42501';
  end if;
  select id into v_id from public.atendimentos where agendamento_id = a.id;
  if v_id is not null then
    return v_id;
  end if;
  if a.status in ('desmarcado', 'remarcado', 'cancelado_clinica', 'faltou') then
    raise exception 'Esta consulta não aconteceu (está como %).', replace(a.status::text, '_', ' ') using errcode = 'P0001';
  end if;
  if (a.inicio at time zone 'America/Sao_Paulo')::date > public.hoje_clinica(a.clinica_id) then
    raise exception 'A consulta é em %. A ficha do atendimento abre no dia.',
      to_char(a.inicio at time zone 'America/Sao_Paulo', 'DD/MM') using errcode = 'P0001';
  end if;
  return public.criar_atendimento(a.pessoa_id, (a.inicio at time zone 'America/Sao_Paulo')::date,
    (a.inicio at time zone 'America/Sao_Paulo')::time, a.profissional_id, a.tipo, a.procedimento_id, a.id);
end;
$$;

-- Consulta sem agendamento (encaixe, urgência…).
create or replace function public.novo_atendimento(p_pessoa uuid, p_profissional uuid default null)
returns uuid
language plpgsql
set search_path = public
as $$
declare
  v_clinica uuid := (select clinica_id from public.pessoas where id = p_pessoa);
  v_hoje    date;
  v_ag      uuid;
begin
  if v_clinica is null or not public.pode_ver_prontuario(v_clinica) then
    raise exception 'Sem acesso ao prontuário.' using errcode = '42501';
  end if;
  v_hoje := public.hoje_clinica(v_clinica);
  -- Tem consulta hoje na agenda ainda sem ficha? Usa ela.
  select ag.id into v_ag from public.agendamentos ag
   where ag.pessoa_id = p_pessoa and (ag.inicio at time zone 'America/Sao_Paulo')::date = v_hoje
     and ag.status in ('agendado', 'confirmado', 'compareceu')
     and not exists (select 1 from public.atendimentos x where x.agendamento_id = ag.id)
   order by ag.inicio limit 1;
  if v_ag is not null then
    return public.abrir_atendimento(v_ag);
  end if;
  -- Dentista: a escolhida, ou quem está logada (se for dentista da agenda); senão, escolhe-se na ficha.
  return public.criar_atendimento(p_pessoa, v_hoje, (now() at time zone 'America/Sao_Paulo')::time(0),
    coalesce(p_profissional, (select id from public.profissionais where clinica_id = v_clinica and usuario_id = auth.uid() and ativo limit 1)));
end;
$$;

-- ─── Ficha da consulta ───────────────────────────────────────────────────────

create or replace function public.salvar_atendimento(p_atendimento uuid, p jsonb, p_finalizar boolean default false)
returns void
language plpgsql
set search_path = public
as $$
declare
  a public.atendimentos;
  arr text := '{}';
begin
  select * into a from public.atendimentos where id = p_atendimento for update;
  if a.id is null or not public.pode_ver_prontuario(a.clinica_id) then
    raise exception 'Consulta não encontrada.' using errcode = 'P0002';
  end if;
  update public.atendimentos set
    profissional_id = coalesce(nullif(p ->> 'profissional_id', '')::uuid, profissional_id),
    motivo          = coalesce((select array_agg(x) from jsonb_array_elements_text(p -> 'motivo') x), arr::text[]),
    motivo_obs      = nullif(btrim(p ->> 'motivo_obs'), ''),
    anamnese        = coalesce((select array_agg(x) from jsonb_array_elements_text(p -> 'anamnese') x), arr::text[]),
    anamnese_obs    = nullif(btrim(p ->> 'anamnese_obs'), ''),
    diagnostico     = coalesce((select array_agg(x) from jsonb_array_elements_text(p -> 'diagnostico') x), arr::text[]),
    diagnostico_obs = nullif(btrim(p ->> 'diagnostico_obs'), ''),
    evolucao        = nullif(btrim(p ->> 'evolucao'), ''),
    orientacoes     = coalesce((select array_agg(x) from jsonb_array_elements_text(p -> 'orientacoes') x), arr::text[]),
    orientacoes_obs = nullif(btrim(p ->> 'orientacoes_obs'), ''),
    retorno_em      = nullif(p ->> 'retorno_em', '')::date,
    retorno_obs     = nullif(btrim(p ->> 'retorno_obs'), ''),
    odontograma     = coalesce(p -> 'odontograma', odontograma),
    status          = case when p_finalizar then 'finalizado'::public.status_atendimento else status end,
    finalizado_em   = case when p_finalizar then now() else finalizado_em end,
    finalizado_por  = case when p_finalizar then auth.uid() else finalizado_por end
  where id = p_atendimento;
end;
$$;

-- ─── Plano de tratamento ─────────────────────────────────────────────────────

-- Adiciona um procedimento ao plano do paciente (cria o plano se ainda não houver).
create or replace function public.adicionar_item_plano(
  p_pessoa uuid, p_procedimento uuid, p_valor bigint, p_dente text default null,
  p_atendimento uuid default null, p_status public.status_item_plano default 'orcado'
)
returns uuid
language plpgsql
set search_path = public
as $$
declare
  v_clinica uuid := (select clinica_id from public.pessoas where id = p_pessoa);
  v_orc     uuid;
  v_item    uuid;
begin
  if v_clinica is null or not public.pode_ver_prontuario(v_clinica) then
    raise exception 'Sem acesso ao prontuário.' using errcode = '42501';
  end if;
  if p_status = 'realizado' then
    raise exception 'Para marcar como realizado, use "Realizar" dentro da consulta.' using errcode = 'P0001';
  end if;
  if coalesce(p_valor, -1) < 0 then
    raise exception 'Informe o valor do procedimento.' using errcode = 'P0001';
  end if;
  if not exists (select 1 from public.procedimentos where id = p_procedimento and clinica_id = v_clinica) then
    raise exception 'Escolha o procedimento.' using errcode = 'P0001';
  end if;
  select id into v_orc from public.orcamentos
   where pessoa_id = p_pessoa and origem = 'prontuario' and status not in ('recusado', 'expirado', 'substituido')
   order by criado_em desc limit 1;
  if v_orc is null then
    insert into public.orcamentos (clinica_id, pessoa_id, origem, status, apresentado_em, apresentado_por)
    values (v_clinica, p_pessoa, 'prontuario', 'apresentado', public.hoje_clinica(v_clinica),
            (select profissional_id from public.atendimentos where id = p_atendimento))
    returning id into v_orc;
  end if;
  insert into public.orcamento_itens (clinica_id, orcamento_id, procedimento_id, valor_unitario_centavos, dente,
                                      atendimento_id, status)
  values (v_clinica, v_orc, p_procedimento, p_valor, nullif(btrim(p_dente), ''), p_atendimento, p_status)
  returning id into v_item;
  return v_item;
end;
$$;

create or replace function public.mudar_status_item(p_item uuid, p_status public.status_item_plano)
returns void
language plpgsql
set search_path = public
as $$
declare
  i public.orcamento_itens;
begin
  select * into i from public.orcamento_itens where id = p_item for update;
  if i.id is null or not public.pode_ver_prontuario(i.clinica_id) then
    raise exception 'Procedimento não encontrado.' using errcode = 'P0002';
  end if;
  if p_status = 'realizado' then
    raise exception 'Para marcar como realizado, use "Realizar" dentro da consulta.' using errcode = 'P0001';
  end if;
  if i.status = 'realizado' then
    raise exception 'Este procedimento já foi realizado (consulta registrada).' using errcode = 'P0001';
  end if;
  update public.orcamento_itens set status = p_status where id = p_item;
end;
$$;

-- Realizado nesta consulta + como ficou o pagamento (no Financeiro existente).
-- p_cobranca: 'pago' | 'parcial' (p_pago_agora + o resto na data prevista) | 'a_pagar'
--             | 'ja_registrado' (p_venda: negociação que já está no Financeiro) | 'sem_cobranca'
create or replace function public.realizar_item(
  p_item        uuid,
  p_atendimento uuid,
  p_cobranca    text,
  p_valor       bigint default null,
  p_forma       uuid default null,
  p_pago_agora  bigint default null,
  p_vencimento  date default null,
  p_parcelas    int default 1,
  p_venda       uuid default null,
  p_observacao  text default null
)
returns jsonb
language plpgsql
set search_path = public
as $$
declare
  i        public.orcamento_itens;
  a        public.atendimentos;
  f        public.formas_pagamento;
  v_pessoa uuid;
  v_hoje   date;
  v_valor  bigint;
  v_neg    jsonb;
  v_venda  uuid;
  x        record;
begin
  select * into i from public.orcamento_itens where id = p_item for update;
  select * into a from public.atendimentos where id = p_atendimento;
  if i.id is null or a.id is null or not public.pode_ver_prontuario(i.clinica_id) then
    raise exception 'Procedimento ou consulta não encontrados.' using errcode = 'P0002';
  end if;
  select pessoa_id into v_pessoa from public.orcamentos where id = i.orcamento_id;
  if v_pessoa <> a.pessoa_id then
    raise exception 'O procedimento não é deste paciente.' using errcode = 'P0001';
  end if;
  if a.status = 'finalizado' then
    raise exception 'Esta consulta foi finalizada e não pode ser alterada.' using errcode = 'P0001';
  end if;
  if i.status = 'realizado' then
    raise exception 'Este procedimento já foi realizado.' using errcode = 'P0001';
  end if;
  if i.status in ('cancelado', 'nao_realizado') then
    raise exception 'Este procedimento está como %. Volte para pendente antes de realizar.',
      case i.status when 'cancelado' then 'cancelado' else 'não realizado' end using errcode = 'P0001';
  end if;
  if p_cobranca not in ('pago', 'parcial', 'a_pagar', 'ja_registrado', 'sem_cobranca') then
    raise exception 'Escolha como ficou o pagamento.' using errcode = 'P0001';
  end if;
  v_hoje := public.hoje_clinica(i.clinica_id);
  v_valor := coalesce(p_valor, i.quantidade * i.valor_unitario_centavos - i.desconto_centavos);

  if p_cobranca = 'ja_registrado' then
    if not exists (select 1 from public.vendas where id = p_venda and pessoa_id = v_pessoa and status = 'ativa') then
      raise exception 'Escolha a negociação do Financeiro.' using errcode = 'P0001';
    end if;
    v_venda := p_venda;
  elsif p_cobranca <> 'sem_cobranca' then
    if not public.pode_ver_financeiro(i.clinica_id) then
      raise exception 'Seu acesso não inclui o financeiro.' using errcode = '42501';
    end if;
    if coalesce(v_valor, 0) <= 0 then
      raise exception 'Informe o valor.' using errcode = 'P0001';
    end if;
    select * into f from public.formas_pagamento where id = p_forma and clinica_id = i.clinica_id and ativo;
    if f.id is null then
      raise exception 'Escolha a forma de pagamento.' using errcode = 'P0001';
    end if;
    if p_cobranca = 'parcial' and not f.recebe_na_hora
       and (coalesce(p_pago_agora, 0) <= 0 or p_pago_agora >= v_valor) then
      raise exception 'Informe quanto foi pago agora (menos que o valor total).' using errcode = 'P0001';
    end if;
    if p_cobranca in ('parcial', 'a_pagar') and not f.recebe_na_hora then
      if p_vencimento is null then
        raise exception 'Informe a data prevista do pagamento.' using errcode = 'P0001';
      end if;
      if p_vencimento < v_hoje then
        raise exception 'A data prevista não pode estar no passado.' using errcode = 'P0001';
      end if;
    end if;
    if p_cobranca = 'pago' and not f.recebe_na_hora and coalesce(p_parcelas, 1) > 1 then
      raise exception 'Pago agora em % é uma parcela só. Para parcelar, escolha "Não pago" ou "Pagamento parcial".', f.nome
        using errcode = 'P0001';
    end if;

    v_neg := public.registrar_negociacao(
      i.clinica_id, v_pessoa, i.procedimento_id, v_valor, 0,
      case when p_cobranca = 'parcial' and not f.recebe_na_hora then p_pago_agora else 0 end,
      v_hoje, f.id,
      greatest(coalesce(p_parcelas, 1), 1),
      case when p_cobranca in ('parcial', 'a_pagar') then coalesce(p_vencimento, v_hoje) else v_hoje end,
      f.id,
      coalesce(nullif(btrim(p_observacao), ''), 'Prontuário: consulta ' || lpad(a.numero::text, 2, '0') || ' de '
                                                  || to_char(a.data, 'DD/MM/YYYY')));
    v_venda := (v_neg ->> 'venda_id')::uuid;
    update public.vendas set procedimento_id = i.procedimento_id where id = v_venda;
    -- Pago agora: quita tudo; parcial: quita a parte paga hoje (a "entrada").
    for x in select id from public.parcelas
              where venda_id = v_venda and status in ('pendente', 'parcial')
                and (p_cobranca = 'pago' or (p_cobranca = 'parcial' and numero = 0))
    loop
      perform public.registrar_pagamento(x.id, null, v_hoje, f.id, null);
    end loop;
  end if;

  update public.orcamento_itens
     set status = 'realizado', realizado_atendimento_id = a.id, realizado_em = a.data, venda_id = v_venda,
         valor_unitario_centavos = case when p_valor is not null and quantidade = 1 and desconto_centavos = 0
                                        then p_valor else valor_unitario_centavos end
   where id = p_item;

  return jsonb_build_object('venda_id', v_venda,
    'situacao', (select situacao from public.v_financeiro_negociacoes where id = v_venda));
end;
$$;

-- Negociações do paciente no Financeiro (para ligar um procedimento a um pagamento já registrado).
create or replace function public.negociacoes_do_paciente(p_pessoa uuid)
returns table (id uuid, descricao text, situacao text)
language sql
stable
set search_path = public
as $$
  select n.id,
         coalesce(n.procedimento, 'Sem procedimento') || ' — ' || public.formatar_brl(n.valor_final_centavos)
           || ' · ' || to_char(n.fechada_em, 'DD/MM/YYYY'),
         n.situacao
    from public.v_financeiro_negociacoes n
   where n.pessoa_id = p_pessoa and n.tipo = 'venda'
   order by n.fechada_em desc
   limit 20;
$$;

revoke execute on function public.criar_prontuario() from public, anon, authenticated;
revoke execute on function public.numerar_atendimento() from public, anon, authenticated;
revoke execute on function public.criar_atendimento(uuid, date, time, uuid, public.tipo_agendamento, uuid, uuid) from anon;
revoke execute on function public.abrir_atendimento(uuid) from anon;
revoke execute on function public.novo_atendimento(uuid, uuid) from anon;
revoke execute on function public.salvar_atendimento(uuid, jsonb, boolean) from anon;
revoke execute on function public.adicionar_item_plano(uuid, uuid, bigint, text, uuid, public.status_item_plano) from anon;
revoke execute on function public.mudar_status_item(uuid, public.status_item_plano) from anon;
revoke execute on function public.realizar_item(uuid, uuid, text, bigint, uuid, bigint, date, int, uuid, text) from anon;
revoke execute on function public.negociacoes_do_paciente(uuid) from anon;
$atualizacao2$;
    raise notice 'Parte 2 aplicada.';
  else
    raise notice 'Parte 2 já estava aplicada — pulada.';
  end if;
end $parte2$;

-- ---------------------------------------------------------------------------
-- Parte 3: migrations/20261007120000_prontuario_simples.sql
-- ---------------------------------------------------------------------------
do $parte3$
begin
  if to_regprocedure('public.procedimento_por_nome(uuid,text)') is null then
    execute $atualizacao3$
-- =============================================================================
-- Migração 15: prontuário simplificado + procedimento livre + pagamento do plano
--   • Consulta: motivo, queixa principal e anamnese em texto livre + odontograma.
--   • Procedimento é sempre digitável: procedimento_por_nome() acha (sem acento,
--     sem maiúsculas) ou cria no catálogo. A lista vira sugestão, nunca trava.
--   • Plano de tratamento: cada procedimento com "feito hoje" (marcar_feito);
--     pendentes aparecem nas próximas consultas.
--   • Pagamento ≠ realização: o pagamento é do PLANO (vendas.plano_id), não do
--     procedimento. registrar_pagamento_plano(): integral, parcial ou não pago,
--     com forma, data, valor, restante, data prevista e parcelas — nas mesmas
--     vendas/parcelas do Financeiro (lembretes "previsto"/"atrasado" no painel).
-- Nada é apagado: colunas e funções anteriores continuam existindo.
-- =============================================================================

-- ─── Procedimento livre ──────────────────────────────────────────────────────

create or replace function public.procedimento_por_nome(p_clinica uuid, p_nome text)
returns uuid
language plpgsql
security definer
set search_path = public
as $$
declare
  v_nome text := regexp_replace(btrim(coalesce(p_nome, '')), '\s+', ' ', 'g');
  v_id   uuid;
begin
  if p_clinica not in (select public.minhas_clinicas()) then
    raise exception 'Sem acesso a esta clínica.' using errcode = '42501';
  end if;
  if v_nome = '' then
    return null;
  end if;
  if length(v_nome) < 2 or length(v_nome) > 120 then
    raise exception 'Procedimento: de 2 a 120 caracteres.' using errcode = 'P0001';
  end if;
  select id into v_id from public.procedimentos
   where clinica_id = p_clinica and public.sem_acento(nome) = public.sem_acento(v_nome)
   order by ativo desc, ordem limit 1;
  if v_id is not null then
    update public.procedimentos set ativo = true where id = v_id and not ativo;
    return v_id;
  end if;
  insert into public.procedimentos (clinica_id, nome, ordem)
  values (p_clinica, v_nome, 900)
  on conflict (clinica_id, nome) do update set ativo = true
  returning id into v_id;
  return v_id;
end;
$$;

-- ─── Consulta simplificada ───────────────────────────────────────────────────

alter table public.atendimentos add column if not exists queixa text check (length(queixa) <= 1000);

create or replace function public.criar_atendimento(
  p_pessoa uuid, p_data date, p_horario time default null, p_profissional uuid default null,
  p_tipo public.tipo_agendamento default null, p_procedimento uuid default null, p_agendamento uuid default null
)
returns uuid
language plpgsql
set search_path = public
as $$
declare
  pr     public.prontuarios;
  v_id   uuid;
  v_mot  text;
begin
  select * into pr from public.prontuarios where pessoa_id = p_pessoa;
  if pr.id is null or not public.pode_ver_prontuario(pr.clinica_id) then
    raise exception 'Sem acesso ao prontuário.' using errcode = '42501';
  end if;
  -- Motivo (texto livre), já preenchido com o que foi agendado.
  v_mot := coalesce((select nome from public.procedimentos where id = p_procedimento),
                    case p_tipo when 'avaliacao' then 'Avaliação' when 'retorno' then 'Retorno'
                                when 'manutencao' then 'Manutenção' when 'apresentacao_orcamento' then 'Retorno para decisão' end);
  insert into public.atendimentos (clinica_id, prontuario_id, pessoa_id, agendamento_id, profissional_id, data, horario,
                                   tipo, procedimento_id, motivo_obs, odontograma)
  values (pr.clinica_id, pr.id, p_pessoa, p_agendamento, p_profissional, coalesce(p_data, public.hoje_clinica(pr.clinica_id)),
          p_horario, p_tipo, p_procedimento, v_mot,
          coalesce((select a.odontograma from public.atendimentos a where a.prontuario_id = pr.id
                     order by a.data desc, a.numero desc limit 1), '{}'::jsonb))
  returning id into v_id;
  return v_id;
end;
$$;

-- Lista de consultas: com os textos livres.
create or replace view public.v_atendimentos with (security_invoker = true) as
select
  a.id, a.clinica_id, a.prontuario_id, a.pessoa_id, a.numero, a.agendamento_id, a.data,
  to_char(a.horario, 'HH24:MI')                                 as horario,
  a.tipo, a.procedimento_id, pr.nome                            as procedimento,
  a.profissional_id, pf.nome                                    as profissional, pf.cor as profissional_cor,
  a.status, a.finalizado_em, a.motivo, a.anamnese, a.diagnostico, a.retorno_em,
  (select count(*) from public.orcamento_itens i where i.realizado_atendimento_id = a.id)::int as realizados,
  (select string_agg(p2.nome, ', ' order by i.realizado_em, p2.nome)
     from public.orcamento_itens i join public.procedimentos p2 on p2.id = i.procedimento_id
    where i.realizado_atendimento_id = a.id)                    as procedimentos_realizados,
  a.motivo_obs, a.queixa, a.anamnese_obs
from public.atendimentos a
left join public.procedimentos pr on pr.id = a.procedimento_id
left join public.profissionais pf on pf.id = a.profissional_id;

-- Salva só os campos enviados (o que não vier fica como estava).
create or replace function public.salvar_atendimento(p_atendimento uuid, p jsonb, p_finalizar boolean default false)
returns void
language plpgsql
set search_path = public
as $$
declare
  a public.atendimentos;
  lista text[];
begin
  select * into a from public.atendimentos where id = p_atendimento for update;
  if a.id is null or not public.pode_ver_prontuario(a.clinica_id) then
    raise exception 'Consulta não encontrada.' using errcode = 'P0002';
  end if;
  update public.atendimentos set
    profissional_id = case when p ? 'profissional_id' then coalesce(nullif(p ->> 'profissional_id', '')::uuid, profissional_id) else profissional_id end,
    motivo          = case when p ? 'motivo' then coalesce((select array_agg(x) from jsonb_array_elements_text(p -> 'motivo') x), '{}') else motivo end,
    motivo_obs      = case when p ? 'motivo_obs' then nullif(btrim(p ->> 'motivo_obs'), '') else motivo_obs end,
    queixa          = case when p ? 'queixa' then nullif(btrim(p ->> 'queixa'), '') else queixa end,
    anamnese        = case when p ? 'anamnese' then coalesce((select array_agg(x) from jsonb_array_elements_text(p -> 'anamnese') x), '{}') else anamnese end,
    anamnese_obs    = case when p ? 'anamnese_obs' then nullif(btrim(p ->> 'anamnese_obs'), '') else anamnese_obs end,
    diagnostico     = case when p ? 'diagnostico' then coalesce((select array_agg(x) from jsonb_array_elements_text(p -> 'diagnostico') x), '{}') else diagnostico end,
    diagnostico_obs = case when p ? 'diagnostico_obs' then nullif(btrim(p ->> 'diagnostico_obs'), '') else diagnostico_obs end,
    evolucao        = case when p ? 'evolucao' then nullif(btrim(p ->> 'evolucao'), '') else evolucao end,
    orientacoes     = case when p ? 'orientacoes' then coalesce((select array_agg(x) from jsonb_array_elements_text(p -> 'orientacoes') x), '{}') else orientacoes end,
    orientacoes_obs = case when p ? 'orientacoes_obs' then nullif(btrim(p ->> 'orientacoes_obs'), '') else orientacoes_obs end,
    retorno_em      = case when p ? 'retorno_em' then nullif(p ->> 'retorno_em', '')::date else retorno_em end,
    retorno_obs     = case when p ? 'retorno_obs' then nullif(btrim(p ->> 'retorno_obs'), '') else retorno_obs end,
    odontograma     = case when p ? 'odontograma' then p -> 'odontograma' else odontograma end,
    status          = case when p_finalizar then 'finalizado'::public.status_atendimento else status end,
    finalizado_em   = case when p_finalizar then now() else finalizado_em end,
    finalizado_por  = case when p_finalizar then auth.uid() else finalizado_por end
  where id = p_atendimento;
end;
$$;

-- ─── Plano: procedimento digitado + "feito hoje" ─────────────────────────────

create or replace function public.adicionar_procedimento_plano(
  p_pessoa uuid, p_nome text, p_valor bigint, p_atendimento uuid default null, p_feito boolean default false
)
returns uuid
language plpgsql
set search_path = public
as $$
declare
  v_clinica uuid := (select clinica_id from public.pessoas where id = p_pessoa);
  v_proc    uuid;
  v_item    uuid;
begin
  if v_clinica is null or not public.pode_ver_prontuario(v_clinica) then
    raise exception 'Sem acesso ao prontuário.' using errcode = '42501';
  end if;
  v_proc := public.procedimento_por_nome(v_clinica, p_nome);
  if v_proc is null then
    raise exception 'Escreva o procedimento.' using errcode = 'P0001';
  end if;
  v_item := public.adicionar_item_plano(p_pessoa, v_proc, coalesce(p_valor, 0), null, p_atendimento, 'pendente');
  if p_feito then
    if p_atendimento is null then
      raise exception 'Para marcar como feito, abra a consulta.' using errcode = 'P0001';
    end if;
    perform public.marcar_feito(v_item, p_atendimento, true);
  end if;
  return v_item;
end;
$$;

-- Feito nesta consulta (ou desfaz, enquanto a consulta não foi finalizada).
-- Não mexe em pagamento: pagamento é do plano, não do procedimento.
create or replace function public.marcar_feito(p_item uuid, p_atendimento uuid, p_feito boolean)
returns void
language plpgsql
set search_path = public
as $$
declare
  i public.orcamento_itens;
  a public.atendimentos;
begin
  select * into i from public.orcamento_itens where id = p_item for update;
  select * into a from public.atendimentos where id = p_atendimento;
  if i.id is null or a.id is null or not public.pode_ver_prontuario(i.clinica_id) then
    raise exception 'Procedimento ou consulta não encontrados.' using errcode = 'P0002';
  end if;
  if (select pessoa_id from public.orcamentos where id = i.orcamento_id) <> a.pessoa_id then
    raise exception 'O procedimento não é deste paciente.' using errcode = 'P0001';
  end if;
  if a.status = 'finalizado' then
    raise exception 'Esta consulta foi finalizada e não pode ser alterada.' using errcode = 'P0001';
  end if;
  if p_feito then
    if i.status = 'realizado' and i.realizado_atendimento_id <> a.id then
      raise exception 'Este procedimento já foi feito em outra consulta.' using errcode = 'P0001';
    end if;
    update public.orcamento_itens set status = 'realizado', realizado_atendimento_id = a.id, realizado_em = a.data
     where id = p_item;
  else
    if i.status = 'realizado' and i.realizado_atendimento_id <> a.id then
      raise exception 'Este procedimento foi feito em outra consulta.' using errcode = 'P0001';
    end if;
    update public.orcamento_itens set status = 'pendente', realizado_atendimento_id = null, realizado_em = null
     where id = p_item and status = 'realizado';
  end if;
end;
$$;

create or replace function public.remover_item_plano(p_item uuid)
returns void
language plpgsql
set search_path = public
as $$
declare
  i public.orcamento_itens;
begin
  select * into i from public.orcamento_itens where id = p_item for update;
  if i.id is null or not public.pode_ver_prontuario(i.clinica_id) then
    raise exception 'Procedimento não encontrado.' using errcode = 'P0002';
  end if;
  if i.status = 'realizado' then
    raise exception 'Procedimento já feito não sai do plano (fica no histórico).' using errcode = 'P0001';
  end if;
  update public.orcamento_itens set status = 'cancelado' where id = p_item;
end;
$$;

-- ─── Pagamento do plano (não do procedimento) ────────────────────────────────

alter table public.vendas add column if not exists plano_id uuid;
alter table public.vendas
  add constraint vendas_plano_fk foreign key (clinica_id, plano_id) references public.orcamentos (clinica_id, id);

create or replace view public.v_financeiro_parcelas with (security_invoker = true) as
select
  pa.id, pa.clinica_id, pa.venda_id, pa.pessoa_id, pa.numero, pa.vencimento, pa.pago_em,
  pa.valor_centavos, pa.valor_pago_centavos,
  pa.valor_centavos - pa.valor_pago_centavos                       as saldo_centavos,
  pa.observacao_financeira                                         as observacao,
  pe.nome                                                          as pessoa_nome,
  coalesce(pe.whatsapp_e164, pe.telefone_e164)                     as whatsapp,
  coalesce(pr.nome, case when v.plano_id is not null then 'Plano de tratamento' end) as procedimento,
  fp.nome                                                          as forma_pagamento,
  v.quantidade_parcelas,
  public.hoje_clinica(pa.clinica_id) - pa.vencimento               as dias_atraso,
  case
    when pa.status = 'paga' then 'pago'
    when pa.status in ('pendente', 'parcial') and pa.vencimento < public.hoje_clinica(pa.clinica_id) then 'atrasado'
    when pa.status = 'parcial' then 'parcial'
    when pa.status = 'pendente' then 'pendente'
    else pa.status::text
  end                                                              as situacao,
  (select t.id from public.tarefas t where t.parcela_id = pa.id and t.status = 'pendente' limit 1) as tarefa_id,
  coalesce(v.procedimento_id, o.procedimento_id) as procedimento_id,
  v.plano_id
from public.parcelas pa
join public.vendas v on v.id = pa.venda_id
join public.pessoas pe on pe.id = pa.pessoa_id
left join public.oportunidades o on o.id = v.oportunidade_id
left join public.procedimentos pr on pr.id = coalesce(v.procedimento_id, o.procedimento_id)
left join public.formas_pagamento fp on fp.id = pa.forma_pagamento_id
where v.status = 'ativa' and pa.status <> 'cancelada';

create or replace view public.v_financeiro_negociacoes with (security_invoker = true) as
select
  v.id, v.clinica_id, v.pessoa_id, v.tipo, v.fechada_em,
  pe.nome                                       as pessoa_nome,
  coalesce(pr.nome, case when v.tipo = 'saldo_anterior' then 'Saldo anterior' when v.plano_id is not null then 'Plano de tratamento' end) as procedimento,
  v.valor_total_centavos, v.desconto_centavos, v.valor_final_centavos,
  v.entrada_centavos, v.quantidade_parcelas, v.valor_parcela_centavos,
  fp.nome                                       as forma_pagamento,
  v.observacao_financeira                       as observacao,
  coalesce(sum(p.valor_pago_centavos), 0)::bigint                                     as pago_centavos,
  coalesce(sum(p.saldo_centavos) filter (where p.situacao <> 'pago'), 0)::bigint      as saldo_centavos,
  coalesce(sum(p.saldo_centavos) filter (where p.situacao = 'atrasado'), 0)::bigint   as atrasado_centavos,
  min(p.vencimento) filter (where p.situacao <> 'pago')                               as proximo_vencimento,
  max(p.pago_em)                                                                      as ultimo_pagamento_em,
  case
    when count(p.id) filter (where p.situacao <> 'pago') = 0 then 'pago'
    when count(p.id) filter (where p.situacao = 'atrasado') > 0 then 'atrasado'
    when coalesce(sum(p.valor_pago_centavos), 0) > 0 then 'parcial'
    else 'pendente'
  end                                           as situacao,
  coalesce(v.procedimento_id, o.procedimento_id) as procedimento_id,
  v.agendamento_id,
  v.plano_id
from public.vendas v
join public.pessoas pe on pe.id = v.pessoa_id
left join public.oportunidades o on o.id = v.oportunidade_id
left join public.procedimentos pr on pr.id = coalesce(v.procedimento_id, o.procedimento_id)
left join public.formas_pagamento fp on fp.id = v.forma_pagamento_id
left join public.v_financeiro_parcelas p on p.venda_id = v.id
where v.status = 'ativa'
group by v.id, pe.nome, pr.nome, fp.nome, o.procedimento_id;

create or replace function public.plano_atual(p_pessoa uuid)
returns uuid
language sql
stable
set search_path = public
as $$
  select id from public.orcamentos
   where pessoa_id = p_pessoa and origem = 'prontuario' and status not in ('recusado', 'expirado', 'substituido')
   order by criado_em desc limit 1;
$$;

-- Total, pago e pendente do plano (o pagamento pode vir antes, junto ou depois dos procedimentos).
create or replace function public.situacao_plano(p_plano uuid)
returns jsonb
language sql
stable
set search_path = public
as $$
  with v as (
    select n.* from public.v_financeiro_negociacoes n
     where n.plano_id = p_plano
        or n.id in (select i.venda_id from public.orcamento_itens i where i.orcamento_id = p_plano and i.venda_id is not null)
  ),
  t as (select coalesce(sum(quantidade * valor_unitario_centavos - desconto_centavos), 0)::bigint as total
          from public.orcamento_itens where orcamento_id = p_plano and status not in ('cancelado', 'nao_realizado'))
  select jsonb_build_object(
    'total', t.total,
    'registrado', coalesce((select sum(valor_final_centavos) from v), 0),
    'pago', coalesce((select sum(pago_centavos) from v), 0),
    'pendente', greatest(t.total - coalesce((select sum(pago_centavos) from v), 0), 0),
    'a_registrar', greatest(t.total - coalesce((select sum(valor_final_centavos) from v), 0), 0),
    'atrasado', coalesce((select sum(atrasado_centavos) from v), 0),
    'proximo_vencimento', (select min(proximo_vencimento) from v))
  from t;
$$;

-- p_como: 'integral' (pagou tudo o que falta registrar) | 'parcial' (p_valor_pago agora; o resto
-- na data prevista, em p_parcelas) | 'nao_pago' (tudo na data prevista, em p_parcelas).
create or replace function public.registrar_pagamento_plano(
  p_plano          uuid,
  p_como           text,
  p_forma          uuid,
  p_valor_pago     bigint default null,
  p_data_pagamento date default null,
  p_vencimento     date default null,
  p_parcelas       int default 1,
  p_observacao     text default null
)
returns jsonb
language plpgsql
set search_path = public
as $$
declare
  o       public.orcamentos;
  f       public.formas_pagamento;
  v_hoje  date;
  v_data  date;
  v_base  bigint;
  v_neg   jsonb;
  v_venda uuid;
  v_itens text;
  x       record;
begin
  select * into o from public.orcamentos where id = p_plano and origem = 'prontuario';
  if o.id is null then
    raise exception 'Plano de tratamento não encontrado.' using errcode = 'P0002';
  end if;
  if not public.pode_ver_financeiro(o.clinica_id) then
    raise exception 'Seu acesso não inclui o financeiro.' using errcode = '42501';
  end if;
  if p_como not in ('integral', 'parcial', 'nao_pago') then
    raise exception 'Escolha como foi o pagamento.' using errcode = 'P0001';
  end if;
  v_hoje := public.hoje_clinica(o.clinica_id);
  v_data := coalesce(p_data_pagamento, v_hoje);
  if v_data > v_hoje then
    raise exception 'A data do pagamento não pode ser futura.' using errcode = 'P0001';
  end if;
  v_base := (public.situacao_plano(p_plano) ->> 'a_registrar')::bigint;
  if v_base <= 0 then
    raise exception 'O valor do plano já está todo no Financeiro. Para receber o que falta, use "Marcar como pago" nos pagamentos em aberto.'
      using errcode = 'P0001';
  end if;
  select * into f from public.formas_pagamento where id = p_forma and clinica_id = o.clinica_id and ativo;
  if f.id is null then
    raise exception 'Escolha a forma de pagamento.' using errcode = 'P0001';
  end if;
  if p_como = 'parcial' and not f.recebe_na_hora and (coalesce(p_valor_pago, 0) <= 0 or p_valor_pago >= v_base) then
    raise exception 'Informe o valor pago (menor que o total a registrar, %).', public.formatar_brl(v_base) using errcode = 'P0001';
  end if;
  if p_como in ('parcial', 'nao_pago') and not f.recebe_na_hora then
    if p_vencimento is null then
      raise exception 'Informe a data prevista para o pagamento do restante.' using errcode = 'P0001';
    end if;
    if p_vencimento < v_hoje then
      raise exception 'A data prevista não pode estar no passado.' using errcode = 'P0001';
    end if;
  end if;
  if p_como = 'integral' and not f.recebe_na_hora and coalesce(p_parcelas, 1) > 1 then
    raise exception 'Pago integralmente em % é uma parcela só. Para parcelar, escolha "Não pago" ou "Parcialmente pago".', f.nome
      using errcode = 'P0001';
  end if;

  select string_agg(p.nome, ', ' order by i.criado_em) into v_itens
    from public.orcamento_itens i join public.procedimentos p on p.id = i.procedimento_id
   where i.orcamento_id = p_plano and i.status not in ('cancelado', 'nao_realizado');

  v_neg := public.registrar_negociacao(
    o.clinica_id, o.pessoa_id, null, v_base, 0,
    case when p_como = 'parcial' and not f.recebe_na_hora then p_valor_pago else 0 end,
    v_data, f.id,
    greatest(coalesce(p_parcelas, 1), 1),
    case when p_como = 'integral' or f.recebe_na_hora then v_hoje else p_vencimento end,
    f.id,
    coalesce(nullif(btrim(p_observacao), ''), left('Plano de tratamento: ' || coalesce(v_itens, ''), 1000)));
  v_venda := (v_neg ->> 'venda_id')::uuid;
  update public.vendas set plano_id = p_plano where id = v_venda;

  -- O que foi pago agora: tudo (integral) ou só a parte paga (a "entrada").
  for x in select id from public.parcelas
            where venda_id = v_venda and status in ('pendente', 'parcial')
              and (p_como = 'integral' or (p_como = 'parcial' and numero = 0))
  loop
    perform public.registrar_pagamento(x.id, null, v_data, f.id, null);
  end loop;

  return public.situacao_plano(p_plano) || jsonb_build_object('venda_id', v_venda);
end;
$$;

revoke execute on function public.procedimento_por_nome(uuid, text) from public, anon;
grant execute on function public.procedimento_por_nome(uuid, text) to authenticated;
revoke execute on function public.adicionar_procedimento_plano(uuid, text, bigint, uuid, boolean) from anon;
revoke execute on function public.marcar_feito(uuid, uuid, boolean) from anon;
revoke execute on function public.remover_item_plano(uuid) from anon;
revoke execute on function public.registrar_pagamento_plano(uuid, text, uuid, bigint, date, date, int, text) from anon;
$atualizacao3$;
    raise notice 'Parte 3 aplicada.';
  else
    raise notice 'Parte 3 já estava aplicada — pulada.';
  end if;
end $parte3$;

-- ---------------------------------------------------------------------------
-- Parte 4: migrations/20261008120000_mais_campanhas.sql
-- ---------------------------------------------------------------------------
do $parte4$
begin
  if to_regprocedure('public.campanha_de_relacionamento(text)') is null then
    execute $atualizacao4$
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
alter table public.campanhas drop constraint if exists campanhas_procedimento_check;
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
$atualizacao4$;
    raise notice 'Parte 4 aplicada.';
  else
    raise notice 'Parte 4 já estava aplicada — pulada.';
  end if;
end $parte4$;

-- ---------------------------------------------------------------------------
-- Parte 5: migrations/20261009120000_seguranca_producao.sql
-- ---------------------------------------------------------------------------
do $parte5$
begin
  if true then
    execute $atualizacao5$
-- =============================================================================
-- Migração 17: endurecimento para produção
--   A chave pública do Supabase (anon) fica no navegador. Quem não fez login não
--   deve conseguir chamar nenhuma função nem ler nenhuma tabela — nem as que já
--   checam acesso por dentro. O sistema conversa com o banco pelo servidor, sempre
--   como usuária logada ("authenticated"), então nada aqui muda para quem usa.
--   Funções internas que já eram fechadas para "authenticated" continuam fechadas.
-- =============================================================================

revoke execute on all functions in schema public from public, anon;
alter default privileges in schema public revoke execute on functions from public, anon;

revoke all on all tables in schema public from anon;
revoke all on all sequences in schema public from anon;
alter default privileges in schema public revoke all on tables from anon;
alter default privileges in schema public revoke all on sequences from anon;
$atualizacao5$;
    raise notice 'Parte 5 aplicada.';
  else
    raise notice 'Parte 5 já estava aplicada — pulada.';
  end if;
end $parte5$;

-- ---------------------------------------------------------------------------
-- Parte 6: migrations/20261010120000_campanha_personalizada.sql
-- ---------------------------------------------------------------------------
do $parte6$
begin
  if true then
    execute $atualizacao6$
-- =============================================================================
-- Migração 18: campanha personalizada
--   Além dos tipos prontos, a administradora monta a própria campanha: escolhe
--   o público (pacientes, contatos ou todos), procedimento (que fez ou se
--   interessou), tempo sem vir, idade, bairro/cidade e como conheceu. Decide se
--   a campanha abre negociação no funil ou só cria o contato do dia.
--   As regras de sempre continuam: aceita contato, sem negociação em andamento,
--   sem outra campanha nos últimos 30 dias, sem contato recente, sem atraso.
-- =============================================================================

alter table public.campanhas add column if not exists filtros jsonb;
alter table public.campanhas drop constraint if exists campanhas_segmento_check;
alter table public.campanhas add constraint campanhas_segmento_check check (segmento in (
  'inativos', 'procedimento', 'nao_fecharam',
  'tratamento_pendente', 'avaliacao_nao_agendada', 'aniversario', 'pos_tratamento', 'interesse', 'desmarcou', 'especiais',
  'personalizada'));

drop function if exists public.prever_campanha(uuid, text, int, uuid, boolean);
drop function if exists public.criar_campanha(uuid, text, text, int, uuid, boolean, text, int, date, uuid[]);

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
  if p_segmento in ('procedimento', 'interesse') and p_procedimento is null then
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
  p_pessoas            uuid[] default null,
  p_filtros            jsonb default null
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
  -- Personalizada: só abre negociação no funil se ela escolher.
  v_rel    boolean := public.campanha_de_relacionamento(p_segmento)
                      or (p_segmento = 'personalizada' and not coalesce((p_filtros->>'negociacao')::boolean, false));
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
                                limite_dia, inicia_em, filtros)
  values (p_clinica, btrim(p_nome), p_segmento, p_meses, p_procedimento, p_somente_marketing, p_mensagem,
          p_limite_dia, p_inicia_em, case when p_segmento = 'personalizada' then coalesce(p_filtros, '{}') end)
  returning id into v_id;

  v_dia := public.proximo_dia_util(p_clinica, p_inicia_em);
  for x in
    select * from public.prever_campanha(p_clinica, p_segmento, p_meses, p_procedimento, p_somente_marketing, p_filtros) c
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
          when 'personalizada' then 'Contato com ' || v_nome || ' — ' || btrim(p_nome)
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

revoke execute on function public.prever_campanha(uuid, text, int, uuid, boolean, jsonb) from public, anon;
revoke execute on function public.criar_campanha(uuid, text, text, int, uuid, boolean, text, int, date, uuid[], jsonb) from public, anon;
grant execute on function public.prever_campanha(uuid, text, int, uuid, boolean, jsonb) to authenticated;
grant execute on function public.criar_campanha(uuid, text, text, int, uuid, boolean, text, int, date, uuid[], jsonb) to authenticated;
$atualizacao6$;
    raise notice 'Parte 6 aplicada.';
  else
    raise notice 'Parte 6 já estava aplicada — pulada.';
  end if;
end $parte6$;

-- ---------------------------------------------------------------------------
-- Parte 7: migrations/20261012120000_campanhas_enxutas.sql
-- ---------------------------------------------------------------------------
do $parte7$
begin
  if true then
    execute $atualizacao7$
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
$atualizacao7$;
    raise notice 'Parte 7 aplicada.';
  else
    raise notice 'Parte 7 já estava aplicada — pulada.';
  end if;
end $parte7$;

-- ---------------------------------------------------------------------------
-- Parte 8: migrations/20261013120000_receituario.sql
-- ---------------------------------------------------------------------------
do $parte8$
begin
  if to_regclass('public.receitas') is null then
    execute $atualizacao8$
-- =============================================================================
-- Migração 20: receituário
--   • Receitas dentro do prontuário de cada paciente (simples ou de controle
--     especial, em 1 ou 2 vias), assinadas por uma dentista (nome e CRO).
--   • Receita emitida não muda nem é apagada (pode ser reimpressa ou repetida).
--   • Modelos de receita da clínica (ex.: "Pós-extração") para não digitar tudo.
--   • Dados do cabeçalho/rodapé em clinicas.configuracoes->'receituario'
--     (endereço, telefone, cidade, rodapé) e o CRO em profissionais.cro.
--   • Acesso: o mesmo do prontuário (dado de saúde). Tudo auditado.
-- =============================================================================

alter table public.profissionais add column if not exists cro text check (length(cro) <= 30);
alter table public.profissionais add column if not exists especialidade text check (length(especialidade) <= 80);

create table public.receitas (
  id               uuid primary key default gen_random_uuid(),
  clinica_id       uuid not null references public.clinicas (id),
  pessoa_id        uuid not null,
  prontuario_id    uuid not null,
  atendimento_id   uuid references public.atendimentos (id),
  profissional_id  uuid,
  tipo             text not null default 'simples' check (tipo in ('simples', 'controle_especial')),
  vias             int not null default 1 check (vias in (1, 2)),
  data             date not null,
  -- [{ "medicamento": "Amoxicilina 500 mg", "quantidade": "21 cápsulas", "uso": "oral", "posologia": "..." }]
  itens            jsonb not null check (jsonb_typeof(itens) = 'array' and jsonb_array_length(itens) between 1 and 20),
  orientacoes      text check (length(orientacoes) <= 2000),
  criado_por       uuid default auth.uid(),
  criado_em        timestamptz not null default now(),
  unique (clinica_id, id),
  foreign key (clinica_id, pessoa_id) references public.pessoas (clinica_id, id),
  foreign key (clinica_id, prontuario_id) references public.prontuarios (clinica_id, id),
  foreign key (clinica_id, profissional_id) references public.profissionais (clinica_id, id),
  check (tipo = 'simples' or vias = 2)
);
create index receitas_pessoa on public.receitas (pessoa_id, data desc, criado_em desc);

create table public.receita_modelos (
  id             uuid primary key default gen_random_uuid(),
  clinica_id     uuid not null references public.clinicas (id),
  nome           text not null check (length(btrim(nome)) between 2 and 60),
  tipo           text not null default 'simples' check (tipo in ('simples', 'controle_especial')),
  itens          jsonb not null check (jsonb_typeof(itens) = 'array' and jsonb_array_length(itens) between 1 and 20),
  orientacoes    text check (length(orientacoes) <= 2000),
  criado_por     uuid default auth.uid(),
  criado_em      timestamptz not null default now(),
  atualizado_em  timestamptz not null default now(),
  unique (clinica_id, nome)
);

-- Itens válidos: medicamento obrigatório; textos curtos.
create or replace function public.itens_receita_validos(p_itens jsonb)
returns jsonb
language plpgsql
immutable
as $$
declare
  x   jsonb;
  out jsonb := '[]';
begin
  if p_itens is null or jsonb_typeof(p_itens) <> 'array' then
    raise exception 'Inclua ao menos um medicamento.' using errcode = 'P0001';
  end if;
  for x in select * from jsonb_array_elements(p_itens) loop
    if coalesce(btrim(x->>'medicamento'), '') = '' then
      continue;
    end if;
    if length(x->>'medicamento') > 120 or length(coalesce(x->>'quantidade', '')) > 60
       or length(coalesce(x->>'posologia', '')) > 500 then
      raise exception 'Texto muito longo em um dos medicamentos.' using errcode = 'P0001';
    end if;
    out := out || jsonb_build_array(jsonb_build_object(
      'medicamento', btrim(x->>'medicamento'),
      'quantidade', coalesce(btrim(x->>'quantidade'), ''),
      'uso', case when x->>'uso' in ('oral', 'topico', 'sublingual', 'externo') then x->>'uso' else 'oral' end,
      'posologia', coalesce(btrim(x->>'posologia'), '')));
  end loop;
  if jsonb_array_length(out) = 0 then
    raise exception 'Inclua ao menos um medicamento.' using errcode = 'P0001';
  end if;
  if jsonb_array_length(out) > 20 then
    raise exception 'No máximo 20 medicamentos por receita.' using errcode = 'P0001';
  end if;
  return out;
end;
$$;

-- Emite a receita (quem tem acesso ao prontuário). Opcionalmente guarda como modelo.
create or replace function public.criar_receita(
  p_pessoa        uuid,
  p_profissional  uuid,
  p_tipo          text,
  p_vias          int,
  p_data          date,
  p_itens         jsonb,
  p_orientacoes   text default null,
  p_atendimento   uuid default null,
  p_salvar_modelo text default null
)
returns uuid
language plpgsql
set search_path = public
as $$
declare
  pr      public.prontuarios;
  v_itens jsonb := public.itens_receita_validos(p_itens);
  v_id    uuid;
  v_orient text := nullif(btrim(coalesce(p_orientacoes, '')), '');
begin
  select * into pr from public.prontuarios where pessoa_id = p_pessoa;
  if pr.id is null or not public.pode_ver_prontuario(pr.clinica_id) then
    raise exception 'Seu acesso não inclui o prontuário.' using errcode = '42501';
  end if;
  if p_profissional is null or not exists (select 1 from public.profissionais
                                            where id = p_profissional and clinica_id = pr.clinica_id) then
    raise exception 'Escolha a dentista que assina a receita.' using errcode = 'P0001';
  end if;
  if p_tipo not in ('simples', 'controle_especial') then
    raise exception 'Tipo de receita inválido.' using errcode = 'P0001';
  end if;
  if p_data is null or p_data > public.hoje_clinica(pr.clinica_id) + 30 or p_data < public.hoje_clinica(pr.clinica_id) - 365 then
    raise exception 'Confira a data da receita.' using errcode = 'P0001';
  end if;
  if p_atendimento is not null and not exists (select 1 from public.atendimentos where id = p_atendimento and pessoa_id = p_pessoa) then
    raise exception 'Consulta inválida.' using errcode = 'P0001';
  end if;

  insert into public.receitas (clinica_id, pessoa_id, prontuario_id, atendimento_id, profissional_id, tipo, vias, data,
                               itens, orientacoes)
  values (pr.clinica_id, p_pessoa, pr.id, p_atendimento, p_profissional, p_tipo,
          case when p_tipo = 'controle_especial' then 2 else greatest(1, least(coalesce(p_vias, 1), 2)) end,
          p_data, v_itens, v_orient)
  returning id into v_id;

  if nullif(btrim(coalesce(p_salvar_modelo, '')), '') is not null then
    insert into public.receita_modelos (clinica_id, nome, tipo, itens, orientacoes)
    values (pr.clinica_id, btrim(p_salvar_modelo), p_tipo, v_itens, v_orient)
    on conflict (clinica_id, nome) do update
      set tipo = excluded.tipo, itens = excluded.itens, orientacoes = excluded.orientacoes, atualizado_em = now();
  end if;
  return v_id;
end;
$$;

-- Receita emitida não muda nem é apagada.
create or replace function public.proteger_receita()
returns trigger
language plpgsql
as $$
begin
  raise exception 'Receitas emitidas não são alteradas nem apagadas. Emita uma nova, se precisar.' using errcode = 'P0001';
end;
$$;

create trigger proteger_receita before update or delete on public.receitas
  for each row execute function public.proteger_receita();
create trigger definir_atualizado_em before update on public.receita_modelos
  for each row execute function public.definir_atualizado_em();

alter table public.receitas enable row level security;
alter table public.receita_modelos enable row level security;

create policy receita_ler on public.receitas for select to authenticated
  using (public.pode_ver_prontuario(clinica_id));
create policy receita_inserir on public.receitas for insert to authenticated
  with check (public.pode_ver_prontuario(clinica_id));
create policy modelo_ler on public.receita_modelos for select to authenticated
  using (public.pode_ver_prontuario(clinica_id));
create policy modelo_inserir on public.receita_modelos for insert to authenticated
  with check (public.pode_ver_prontuario(clinica_id));
create policy modelo_alterar on public.receita_modelos for update to authenticated
  using (public.pode_ver_prontuario(clinica_id)) with check (public.pode_ver_prontuario(clinica_id));
create policy modelo_apagar on public.receita_modelos for delete to authenticated
  using (public.pode_ver_prontuario(clinica_id));

grant select, insert on public.receitas to authenticated;
grant select, insert, update, delete on public.receita_modelos to authenticated;

create trigger auditoria after insert or update or delete on public.receitas
  for each row execute function public.registrar_auditoria();
create trigger auditoria after insert or update or delete on public.receita_modelos
  for each row execute function public.registrar_auditoria();

-- Leitura para a lista e a impressão.
create view public.v_receitas with (security_invoker = true) as
select
  r.id, r.clinica_id, r.pessoa_id, r.atendimento_id, a.numero as atendimento_numero,
  r.profissional_id, pf.nome as profissional, pf.cro as profissional_cro, pf.especialidade as profissional_especialidade,
  r.tipo, r.vias, r.data, r.itens, r.orientacoes, r.criado_em
from public.receitas r
left join public.atendimentos a on a.id = r.atendimento_id
left join public.profissionais pf on pf.id = r.profissional_id;

-- Dados do receituário (cabeçalho e rodapé). Somente a administradora.
create or replace function public.salvar_dados_receituario(p_clinica uuid, p_dados jsonb)
returns void
language plpgsql
security definer
set search_path = public
as $$
begin
  if not public.eh_admin(p_clinica) then
    raise exception 'Somente a administradora altera os dados do receituário.' using errcode = '42501';
  end if;
  update public.clinicas
     set configuracoes = configuracoes || jsonb_build_object('receituario', jsonb_build_object(
           'endereco', left(nullif(btrim(p_dados->>'endereco'), ''), 200),
           'telefone', left(nullif(btrim(p_dados->>'telefone'), ''), 60),
           'cidade',   left(nullif(btrim(p_dados->>'cidade'), ''), 80),
           'rodape',   left(nullif(btrim(p_dados->>'rodape'), ''), 200)))
   where id = p_clinica;
end;
$$;

revoke execute on function public.criar_receita(uuid, uuid, text, int, date, jsonb, text, uuid, text) from public, anon;
revoke execute on function public.salvar_dados_receituario(uuid, jsonb) from public, anon;
revoke execute on function public.itens_receita_validos(jsonb) from public, anon;
grant execute on function public.criar_receita(uuid, uuid, text, int, date, jsonb, text, uuid, text) to authenticated;
grant execute on function public.salvar_dados_receituario(uuid, jsonb) to authenticated;
grant execute on function public.itens_receita_validos(jsonb) to authenticated;

-- Ninguém sem login chama funções nem lê tabelas (como na migração de segurança).
revoke execute on all functions in schema public from public, anon;
revoke all on public.receitas, public.receita_modelos, public.v_receitas from anon;
$atualizacao8$;
    raise notice 'Parte 8 aplicada.';
  else
    raise notice 'Parte 8 já estava aplicada — pulada.';
  end if;
end $parte8$;

-- ---------------------------------------------------------------------------
-- Parte 9: seed.sql
-- ---------------------------------------------------------------------------
do $parte9$
begin
  if true then
    execute $atualizacao9$
-- =============================================================================
-- Dados FICTÍCIOS para desenvolvimento, demonstração e a VERSÃO DE TESTE.
-- Nunca executar em produção. Nomes e telefones inventados.
--
-- Cria o esquema "teste": a existência dele é o que liga o modo de teste no
-- sistema (faixa "Versão de teste", botão "Recomeçar com dados de exemplo").
--
-- As situações são criadas como na vida real (novo contato, orçamento,
-- desmarcação, venda…) e o MOTOR cria as tarefas sozinho. No fim, algumas datas
-- são deslocadas para o passado para simular atrasos.
-- =============================================================================

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
  update public.profissionais set nome = 'Dra. Cristina', cro = 'CRO-SP 00000', especialidade = 'Cirurgiã-dentista' where id = prof;
  -- Receituário (fictício): cabeçalho/rodapé e um modelo pronto.
  update public.clinicas set configuracoes = configuracoes || jsonb_build_object('receituario', jsonb_build_object(
    'endereco', 'Rua Exemplo, 100 — sala 12 — Jardins', 'telefone', '(11) 0000-0000',
    'cidade', 'São Paulo - SP', 'rodape', '@institutocg')) where id = c;
  insert into public.receita_modelos (clinica_id, nome, tipo, itens, orientacoes) values
    (c, 'Pós-extração (exemplo)', 'simples',
     '[{"medicamento": "Dipirona 500 mg", "quantidade": "10 comprimidos", "uso": "oral", "posologia": "Tomar 1 comprimido de 6 em 6 horas, se houver dor."},
       {"medicamento": "Digluconato de clorexidina 0,12%", "quantidade": "1 frasco", "uso": "topico", "posologia": "Bochechar 15 ml por 1 minuto, de 12 em 12 horas, por 7 dias, a partir do dia seguinte."}]',
     'Exemplo da versão de teste — confira e ajuste antes de usar. Evitar alimentos quentes e esforço físico nas primeiras 24 horas.');
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

$atualizacao9$;
    raise notice 'Parte 9 aplicada.';
  else
    raise notice 'Parte 9 já estava aplicada — pulada.';
  end if;
end $parte9$;

-- Ninguém sem login chama funções (vale também para o que foi criado acima).
revoke execute on all functions in schema public from public, anon;

select 'Versão de teste atualizada. No site: Configurações → Versão de teste → "Recomeçar com dados de exemplo" para ver os exemplos novos.' as resultado;
