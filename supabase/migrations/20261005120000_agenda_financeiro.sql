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
