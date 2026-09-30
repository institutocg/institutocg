-- =============================================================================
-- Migração 9: agenda comercial
--   A agenda conversa com o CRM: cada consulta é ligada à pessoa e à negociação,
--   e cada mudança de status gera (ou encerra) a ação comercial certa.
--
--   • agendar()            paciente existente ou novo, procedimento, data, horário,
--                          profissional e status; valida horário de funcionamento
--                          e conflitos; liga (ou abre) a negociação.
--   • desmarcar_consulta() registra o evento e o motivo; a tarefa de recuperação
--                          nasce sozinha (regra "Desmarcou ou faltou").
--   • remarcar_consulta()  cria a nova consulta, encerra a recuperação e a
--                          confirmação antigas; a nova confirmação nasce sozinha.
--   • mudar_status_consulta() confirmado, compareceu, faltou e cancelado.
--   • Garantia: nenhuma desmarcação, falta ou cancelamento fica sem ação
--     comercial (gatilho + rotina diária) e agendamentos nunca são apagados.
--   • v_recuperacao: quem precisa ser recuperado, quem já foi e quem está sem ação.
-- =============================================================================

-- ─── Agendamentos não são apagados ───────────────────────────────────────────

create or replace function public.proteger_agendamento()
returns trigger
language plpgsql
as $$
begin
  if tg_op = 'DELETE' then
    raise exception 'Consultas não são apagadas: use Desmarcar, Remarcar ou Cancelar.' using errcode = 'P0001';
  end if;
  -- Uma consulta desmarcada, remarcada ou cancelada não "volta" a ficar agendada:
  -- para marcar de novo, remarque (assim a desmarcação continua no histórico).
  if old.status in ('desmarcado', 'remarcado', 'cancelado_clinica') and new.status in ('agendado', 'confirmado') then
    raise exception 'Esta consulta foi %. Para marcar de novo, use Remarcar.',
      case old.status when 'desmarcado' then 'desmarcada' when 'remarcado' then 'remarcada' else 'cancelada' end
      using errcode = 'P0001';
  end if;
  return coalesce(new, old);
end;
$$;

create trigger proteger_agendamento
  before update of status or delete on public.agendamentos
  for each row execute function public.proteger_agendamento();

-- ─── Garantia: desmarcou, faltou ou foi cancelada → sempre uma ação comercial ─
-- Roda depois do motor ("zz_" = último na ordem alfabética). Se nenhuma regra criou
-- a recuperação (regra desligada, ação recusada no funil…), cria agora.

create or replace function public.garantir_recuperacao()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare
  v_pessoa public.pessoas;
begin
  if new.status not in ('desmarcado', 'faltou', 'cancelado_clinica')
     or old.status not in ('agendado', 'confirmado') then
    return null;
  end if;
  select * into v_pessoa from public.pessoas where id = new.pessoa_id;
  if v_pessoa.nao_contatar or not v_pessoa.consentimento_contato or v_pessoa.arquivado_em is not null then
    return null;
  end if;
  if exists (select 1 from public.tarefas t
              where t.pessoa_id = new.pessoa_id and t.status = 'pendente' and t.categoria <> 'financeiro'
                and (t.agendamento_id = new.id or t.tipo in ('recuperar_desmarcacao', 'recuperar_falta'))) then
    return null;
  end if;
  perform public.criar_tarefa_auto(
    new.pessoa_id, new.oportunidade_id,
    case when new.status = 'faltou' then 'recuperar_falta' else 'recuperar_desmarcacao' end::public.tipo_tarefa,
    'recuperacao',
    'Entrar em contato com ' || coalesce(nullif(v_pessoa.apelido_tratamento, ''), split_part(v_pessoa.nome, ' ', 1))
      || ' para remarcar',
    public.hoje_clinica(new.clinica_id) + 1, 'urgente', 'desmarcou', 'rec:' || new.id, 1,
    case new.status when 'faltou' then 'Faltou à consulta de ' when 'cancelado_clinica' then 'A clínica cancelou a consulta de '
         else 'Desmarcou a consulta de ' end
      || to_char(new.inicio at time zone 'America/Sao_Paulo', 'DD/MM "às" HH24:MI'),
    new.id,
    public.renderizar_mensagem(new.clinica_id,
      case new.status when 'faltou' then 'recuperar_falta' when 'cancelado_clinica' then 'clinica_cancelou'
           else 'recuperar_desmarcacao' end, new.pessoa_id,
      (select nome from public.procedimentos where id = new.procedimento_id),
      jsonb_build_object('consulta', public.rotulo_consulta(new.tipo),
                         'data', to_char(new.inicio at time zone 'America/Sao_Paulo', 'DD/MM'))));
  return null;
end;
$$;

create trigger zz_garantir_recuperacao
  after update of status on public.agendamentos
  for each row execute function public.garantir_recuperacao();

-- ─── Recuperação: quem desmarcou, faltou ou teve a consulta cancelada ─────────
--   recuperado   → remarcou (ou marcou outra consulta depois)
--   a_recuperar  → há tarefa de recuperação pendente
--   acompanhando → sem tarefa de recuperação, mas com outra próxima ação (pediu
--                  retorno, sem resposta, retomada futura…)
--   encerrado    → não quer contato, ou a conversa já teve um desfecho registrado
--   sem_acao     → nenhuma ação: não deveria acontecer (a rotina diária corrige)

create view public.v_recuperacao with (security_invoker = true) as
select
  a.id                                        as agendamento_id,
  a.clinica_id,
  a.pessoa_id,
  p.nome                                      as pessoa_nome,
  coalesce(p.whatsapp_e164, p.telefone_e164)  as whatsapp,
  a.tipo,
  a.status,
  a.inicio,
  a.status_em,
  a.duracao_min,
  a.profissional_id,
  pr.nome                                     as procedimento,
  m.nome                                      as motivo,
  a.observacoes,
  coalesce(novo.inicio, depois.inicio)        as remarcado_para,
  rec.id                                      as tarefa_id,
  rec.titulo                                  as tarefa_titulo,
  rec.vence_em                                as tarefa_vence_em,
  rec.mensagem_sugerida,
  outra.titulo                                as proxima_acao,
  outra.vence_em                              as proxima_acao_em,
  feita.resultado                             as desfecho,
  case
    when novo.id is not null or depois.id is not null then 'recuperado'
    when rec.id is not null then 'a_recuperar'
    when outra.id is not null then 'acompanhando'
    when p.nao_contatar or p.arquivado_em is not null or feita.id is not null then 'encerrado'
    else 'sem_acao'
  end                                         as situacao
from public.agendamentos a
join public.pessoas p on p.id = a.pessoa_id
left join public.procedimentos pr on pr.id = a.procedimento_id
left join public.motivos m on m.id = a.motivo_id
left join public.agendamentos novo on novo.id = a.remarcado_para_id
left join lateral (
  select x.id, x.inicio from public.agendamentos x
   where x.pessoa_id = a.pessoa_id and x.id <> a.id and x.criado_em > a.status_em
     and x.status in ('agendado', 'confirmado', 'compareceu')
   order by x.criado_em limit 1
) depois on true
left join lateral (
  select t.id, t.titulo, t.vence_em, t.mensagem_sugerida from public.tarefas t
   where t.pessoa_id = a.pessoa_id and t.status = 'pendente'
     and (t.agendamento_id = a.id or t.tipo in ('recuperar_desmarcacao', 'recuperar_falta'))
   order by (t.agendamento_id = a.id) desc, t.vence_em limit 1
) rec on true
left join lateral (
  select t.id, t.titulo, t.vence_em from public.tarefas t
   where t.pessoa_id = a.pessoa_id and t.status = 'pendente' and t.categoria <> 'financeiro'
   order by t.vence_em limit 1
) outra on true
left join lateral (
  select t.id, t.resultado from public.tarefas t
   where t.pessoa_id = a.pessoa_id and t.status = 'concluida' and t.concluida_em >= a.status_em
     and (t.agendamento_id = a.id or t.tipo in ('recuperar_desmarcacao', 'recuperar_falta'))
   order by t.concluida_em desc limit 1
) feita on true
where a.status in ('desmarcado', 'faltou', 'cancelado_clinica')
  and a.status_em >= now() - interval '120 days';

-- ─── Visão da agenda ─────────────────────────────────────────────────────────

create view public.v_agenda with (security_invoker = true) as
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
  (select r.situacao from public.v_recuperacao r where r.agendamento_id = a.id)   as recuperacao
from public.agendamentos a
join public.pessoas p on p.id = a.pessoa_id
left join public.procedimentos pr on pr.id = a.procedimento_id
left join public.profissionais pf on pf.id = a.profissional_id
left join public.motivos m on m.id = a.motivo_id;

-- ─── Validações de horário ───────────────────────────────────────────────────

-- Segunda a sexta, 08h–19h (sem feriados); e sem choque com outra consulta do
-- mesmo profissional, a menos que a usuária peça um encaixe.
create or replace function public.validar_horario(
  p_clinica      uuid,
  p_inicio       timestamptz,
  p_duracao      int,
  p_profissional uuid,
  p_encaixe      boolean,
  p_ignorar      uuid default null
)
returns void
language plpgsql
stable
set search_path = public
as $$
declare
  v_local  timestamp := p_inicio at time zone 'America/Sao_Paulo';
  v_fim    timestamp := v_local + make_interval(mins => p_duracao);
  v_choque record;
begin
  if p_inicio is null then
    raise exception 'Informe a data e o horário.' using errcode = 'P0001';
  end if;
  if v_local::date < public.hoje_clinica(p_clinica) then
    raise exception 'A data já passou. Escolha hoje ou uma data futura.' using errcode = 'P0001';
  end if;
  if not public.eh_dia_util(p_clinica, v_local::date) then
    raise exception 'A clínica não atende neste dia (sábado, domingo ou feriado).' using errcode = 'P0001';
  end if;
  if v_local::time < time '08:00' or v_fim > v_local::date + time '19:00' then
    raise exception 'Fora do horário de atendimento (08h às 19h).' using errcode = 'P0001';
  end if;
  if not coalesce(p_encaixe, false) then
    select pe.nome, a.inicio into v_choque
      from public.agendamentos a join public.pessoas pe on pe.id = a.pessoa_id
     where a.clinica_id = p_clinica and a.status in ('agendado', 'confirmado')
       and a.profissional_id is not distinct from p_profissional
       and (p_ignorar is null or a.id <> p_ignorar)
       and a.inicio < p_inicio + make_interval(mins => p_duracao)
       and a.inicio + make_interval(mins => a.duracao_min) > p_inicio
     order by a.inicio limit 1;
    if found then
      raise exception 'Horário ocupado: % às %. Escolha outro horário ou marque como encaixe.',
        v_choque.nome, to_char(v_choque.inicio at time zone 'America/Sao_Paulo', 'HH24:MI')
        using errcode = 'P0001', hint = 'conflito';
    end if;
  end if;
end;
$$;

-- ─── Agendar ─────────────────────────────────────────────────────────────────

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
  p_tipo_cadastro public.tipo_cadastro default 'novo_contato'
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
begin
  if p_clinica not in (select public.minhas_clinicas()) then
    raise exception 'Sem acesso a esta clínica.' using errcode = '42501';
  end if;
  perform public.validar_horario(p_clinica, p_inicio, coalesce(p_duracao, 60), p_profissional, p_encaixe);

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

  insert into public.agendamentos (clinica_id, pessoa_id, oportunidade_id, profissional_id, tipo, procedimento_id,
                                   inicio, duracao_min, status, confirmado_em, observacoes)
  values (p_clinica, v_pessoa, v_op.id, p_profissional, p_tipo, p_procedimento, p_inicio, coalesce(p_duracao, 60),
          case when p_confirmado then 'confirmado' else 'agendado' end::public.status_agendamento,
          case when p_confirmado then now() end, nullif(btrim(p_observacoes), ''))
  returning id into v_ag;

  select jsonb_build_object('titulo', titulo, 'vence_em', vence_em) into v_tarefa
    from public.tarefas where agendamento_id = v_ag and status = 'pendente' order by vence_em limit 1;
  return jsonb_build_object('id', v_ag, 'pessoa_id', v_pessoa, 'pessoa_nova', v_nova, 'tarefa', v_tarefa);
end;
$$;

-- ─── Desmarcar ───────────────────────────────────────────────────────────────
-- Registra o evento (histórico) e o motivo, muda o status; a regra cria a tarefa
-- de recuperação com a mensagem de remarcação. p_contato_em: data combinada para
-- falar de novo (se a paciente pediu), em vez do prazo da regra.

create or replace function public.desmarcar_consulta(
  p_agendamento uuid,
  p_motivo      uuid default null,
  p_observacao  text default null,
  p_contato_em  date default null
)
returns jsonb
language plpgsql
set search_path = public
as $$
declare
  a      public.agendamentos;
  v_res  jsonb;
begin
  select * into a from public.agendamentos where id = p_agendamento for update;
  if a.id is null then
    raise exception 'Consulta não encontrada.' using errcode = 'P0002';
  end if;
  if a.status not in ('agendado', 'confirmado') then
    raise exception 'Só é possível desmarcar uma consulta agendada ou confirmada.' using errcode = 'P0001';
  end if;
  if p_contato_em is not null and p_contato_em < public.hoje_clinica(a.clinica_id) then
    raise exception 'A data do próximo contato precisa ser hoje ou futura.' using errcode = 'P0001';
  end if;

  perform set_config('crm.observacao_agenda', coalesce(p_observacao, ''), true);
  update public.agendamentos
     set status = 'desmarcado', motivo_id = p_motivo,
         observacoes = coalesce(nullif(btrim(p_observacao), ''), observacoes)
   where id = p_agendamento;
  perform set_config('crm.observacao_agenda', '', true);

  if p_contato_em is not null then
    update public.tarefas set vence_em = public.proximo_dia_util(a.clinica_id, p_contato_em)
     where agendamento_id = p_agendamento and status = 'pendente'
       and tipo in ('recuperar_desmarcacao', 'recuperar_falta');
  end if;

  select jsonb_build_object('titulo', titulo, 'vence_em', vence_em, 'mensagem', mensagem_sugerida) into v_res
    from public.tarefas
   where pessoa_id = a.pessoa_id and status = 'pendente' and categoria <> 'financeiro'
   order by (agendamento_id = p_agendamento) desc nulls last, vence_em limit 1;
  return v_res;
end;
$$;

-- ─── Remarcar ────────────────────────────────────────────────────────────────
-- Nova consulta com os mesmos dados; a antiga aponta para ela. A recuperação
-- pendente é concluída ("Remarcou para …") e a confirmação antiga, cancelada;
-- a confirmação da nova consulta é criada pelo motor.

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
                                 coalesce(p_profissional, a.profissional_id), p_encaixe, a.id);

  -- Antes de criar a nova consulta — tarefas antigas: a recuperação foi resolvida; a confirmação antiga não vale mais.
  update public.tarefas set status = 'concluida', resultado = 'Remarcou para ' || v_quando
   where pessoa_id = a.pessoa_id and status = 'pendente'
     and (tipo in ('recuperar_desmarcacao', 'recuperar_falta')
          or (agendamento_id = a.id and tipo <> 'confirmar_agendamento'));
  update public.tarefas set status = 'cancelada', cancelada_motivo = 'Consulta remarcada para ' || v_quando
   where agendamento_id = a.id and status = 'pendente';

  insert into public.agendamentos (clinica_id, pessoa_id, oportunidade_id, profissional_id, tipo, procedimento_id,
                                   inicio, duracao_min, observacoes)
  values (a.clinica_id, a.pessoa_id,
          (select id from public.oportunidades where pessoa_id = a.pessoa_id and status in ('aberta', 'pausada')),
          coalesce(p_profissional, a.profissional_id), a.tipo, a.procedimento_id, p_inicio,
          coalesce(p_duracao, a.duracao_min), a.observacoes)
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

-- ─── Demais status ───────────────────────────────────────────────────────────

create or replace function public.mudar_status_consulta(
  p_agendamento uuid,
  p_status      public.status_agendamento,
  p_observacao  text default null
)
returns jsonb
language plpgsql
set search_path = public
as $$
declare
  a     public.agendamentos;
  v_res jsonb;
begin
  select * into a from public.agendamentos where id = p_agendamento for update;
  if a.id is null then
    raise exception 'Consulta não encontrada.' using errcode = 'P0002';
  end if;
  if p_status not in ('confirmado', 'compareceu', 'faltou', 'cancelado_clinica') then
    raise exception 'Use Desmarcar ou Remarcar para este caso.' using errcode = 'P0001';
  end if;
  if a.status = p_status then
    raise exception 'A consulta já está com este status.' using errcode = 'P0001';
  end if;
  if p_status = 'confirmado' and a.status <> 'agendado' then
    raise exception 'Só é possível confirmar uma consulta agendada.' using errcode = 'P0001';
  end if;
  if p_status in ('compareceu', 'faltou') then
    if a.status not in ('agendado', 'confirmado', 'compareceu', 'faltou') then
      raise exception 'Esta consulta não está marcada.' using errcode = 'P0001';
    end if;
    if (a.inicio at time zone 'America/Sao_Paulo')::date > public.hoje_clinica(a.clinica_id) then
      raise exception 'Presença ou falta só podem ser registradas no dia da consulta ou depois.' using errcode = 'P0001';
    end if;
  end if;
  if p_status = 'cancelado_clinica' then
    if a.status not in ('agendado', 'confirmado') then
      raise exception 'Só é possível cancelar uma consulta agendada ou confirmada.' using errcode = 'P0001';
    end if;
    if nullif(btrim(p_observacao), '') is null then
      raise exception 'Informe o motivo do cancelamento.' using errcode = 'P0001';
    end if;
  end if;

  perform set_config('crm.observacao_agenda', coalesce(p_observacao, ''), true);
  update public.agendamentos
     set status = p_status, observacoes = coalesce(nullif(btrim(p_observacao), ''), observacoes)
   where id = p_agendamento;
  perform set_config('crm.observacao_agenda', '', true);

  -- "Compareceu" corrigindo uma falta registrada por engano: a recuperação perde o sentido.
  if p_status = 'compareceu' and a.status = 'faltou' then
    update public.tarefas set status = 'cancelada', cancelada_motivo = 'Falta corrigida: a pessoa compareceu'
     where pessoa_id = a.pessoa_id and status = 'pendente' and tipo = 'recuperar_falta';
  end if;

  select jsonb_build_object('titulo', titulo, 'vence_em', vence_em) into v_res
    from public.tarefas
   where pessoa_id = a.pessoa_id and status = 'pendente' and categoria <> 'financeiro'
   order by (agendamento_id = p_agendamento) desc nulls last, vence_em limit 1;
  return v_res;
end;
$$;

-- ─── Busca de pacientes para o agendamento ───────────────────────────────────

create or replace function public.buscar_pacientes(p_clinica uuid, p_texto text)
returns table (id uuid, nome text, whatsapp text, tipo_cadastro public.tipo_cadastro,
               procedimento_id uuid, procedimento text, etapa text)
language sql
stable
set search_path = public
as $$
  select c.id, c.nome, coalesce(c.whatsapp_e164, c.telefone_e164), c.tipo_cadastro,
         c.procedimento_interesse_id, c.procedimento_interesse, c.etapa_atual
    from public.v_contatos c
   where c.clinica_id = p_clinica and c.arquivado_em is null
     and (public.sem_acento(c.nome) like '%' || public.sem_acento(btrim(p_texto)) || '%'
          or (length(regexp_replace(p_texto, '\D', '', 'g')) >= 4
              and coalesce(c.whatsapp_e164, c.telefone_e164, '') like '%' || regexp_replace(p_texto, '\D', '', 'g') || '%'))
   order by c.nome
   limit 8;
$$;

revoke execute on function public.garantir_recuperacao() from public, anon, authenticated;
revoke execute on function public.agendar(uuid, uuid, public.tipo_agendamento, uuid, timestamptz, int, uuid, boolean, text,
  boolean, text, text, public.tipo_cadastro) from anon;
revoke execute on function public.desmarcar_consulta(uuid, uuid, text, date) from anon;
revoke execute on function public.remarcar_consulta(uuid, timestamptz, int, uuid, boolean) from anon;
revoke execute on function public.mudar_status_consulta(uuid, public.status_agendamento, text) from anon;
revoke execute on function public.buscar_pacientes(uuid, text) from anon;
