-- =============================================================================
-- Migração 2/4: núcleo comercial
--   pessoas (leads e pacientes), oportunidades (funil) + histórico de etapas,
--   interesses, tratamentos anteriores, agenda, follow-ups (interações) e tarefas.
--
-- Integridade entre clínicas: as chaves estrangeiras incluem clinica_id
-- (ex.: (clinica_id, pessoa_id) → pessoas(clinica_id, id)), de modo que é
-- impossível ligar registros de clínicas diferentes, mesmo por engano.
-- =============================================================================

-- ─── Tipos ───────────────────────────────────────────────────────────────────

create type public.tipo_cadastro as enum ('novo_contato', 'paciente_antigo');
create type public.temperatura as enum ('fria', 'morna', 'quente');
create type public.status_oportunidade as enum ('aberta', 'pausada', 'ganha', 'perdida');
create type public.tipo_agendamento as enum (
  'avaliacao', 'apresentacao_orcamento', 'procedimento', 'retorno', 'manutencao', 'ligacao_agendada'
);
create type public.status_agendamento as enum (
  'agendado', 'confirmado', 'compareceu', 'faltou', 'desmarcado', 'cancelado_clinica', 'remarcado'
);
create type public.tipo_interacao as enum (
  'whatsapp', 'ligacao', 'email', 'instagram', 'atendimento', 'orcamento_enviado',
  'retorno_solicitado', 'paciente_respondeu', 'paciente_nao_respondeu', 'paciente_desmarcou',
  'paciente_faltou', 'paciente_fechou', 'paciente_recusou', 'pagamento_recebido', 'nota', 'outro'
);
create type public.canal_contato as enum ('whatsapp', 'ligacao', 'presencial', 'email', 'instagram', 'outro');
create type public.direcao_contato as enum ('saida', 'entrada');
create type public.tipo_tarefa as enum (
  'primeiro_contato', 'follow_up', 'follow_up_orcamento', 'confirmar_agendamento',
  'recuperar_desmarcacao', 'recuperar_falta', 'reabrir_sem_resposta', 'retorno_por_motivo',
  'reativacao', 'manutencao', 'confirmar_pagamento', 'apresentar_orcamento',
  'agendar_tratamento', 'definir_proxima_acao', 'personalizada'
);
create type public.categoria_tarefa as enum ('vendas', 'agenda', 'recuperacao', 'reativacao', 'financeiro', 'outra');
create type public.prioridade_tarefa as enum ('baixa', 'normal', 'alta', 'urgente');
create type public.status_tarefa as enum ('pendente', 'concluida', 'cancelada');
create type public.origem_tarefa as enum ('manual', 'automatica');

-- ─── Pessoas: leads e pacientes (mesmo cadastro em momentos diferentes) ──────

create table public.pessoas (
  id                            uuid primary key default gen_random_uuid(),
  clinica_id                    uuid not null references public.clinicas (id),
  tipo_cadastro                 public.tipo_cadastro not null default 'novo_contato',

  -- Identificação e contato
  nome                          text not null check (length(btrim(nome)) between 2 and 200),
  apelido_tratamento            text check (length(apelido_tratamento) <= 60),
  data_nascimento               date check (data_nascimento >= date '1900-01-01'),
  telefone_e164                 text check (telefone_e164 ~ '^\+[1-9][0-9]{7,14}$'),
  whatsapp_e164                 text check (whatsapp_e164 ~ '^\+[1-9][0-9]{7,14}$'),
  email                         text check (email ~* '^[^@\s]+@[^@\s]+\.[^@\s]+$'),

  -- Endereço
  cep                           text check (cep ~ '^[0-9]{8}$'),
  logradouro                    text,
  numero                        text,
  complemento                   text,
  bairro                        text,
  cidade                        text,
  uf                            text check (uf ~ '^[A-Z]{2}$'),

  -- Comercial
  origem_id                     uuid,                -- "como conheceu a clínica"
  origem_detalhe                text,                -- ex.: nome do perfil que indicou
  indicado_por_pessoa_id        uuid,
  responsavel_id                uuid,                -- responsável pelo atendimento
  temperatura                   public.temperatura,
  observacoes_comerciais        text check (length(observacoes_comerciais) <= 1000),

  -- LGPD
  consentimento_contato         boolean not null default true,
  consentimento_marketing       boolean not null default false,
  nao_contatar                  boolean not null default false,
  nao_contatar_motivo           text,

  -- Paciente antigo (informado no recadastro)
  paciente_desde                date,
  ultimo_atendimento_informado  date,
  em_tratamento                 boolean not null default false,

  -- Datas de relacionamento
  primeiro_contato_em           date not null default current_date,
  ultimo_contato_em             timestamptz,         -- atualizado pelos follow-ups

  arquivado_em                  timestamptz,
  arquivado_motivo              text,
  criado_por                    uuid default auth.uid(),
  criado_em                     timestamptz not null default now(),
  atualizado_em                 timestamptz not null default now(),

  unique (clinica_id, id),
  foreign key (clinica_id, origem_id) references public.origens (clinica_id, id),
  foreign key (clinica_id, indicado_por_pessoa_id) references public.pessoas (clinica_id, id),
  foreign key (clinica_id, responsavel_id) references public.membros (clinica_id, usuario_id),
  -- É preciso ter ao menos uma forma de contato (exceto cadastros arquivados/anonimizados).
  check (arquivado_em is not null or telefone_e164 is not null or whatsapp_e164 is not null or email is not null),
  check (not nao_contatar or nao_contatar_motivo is not null),
  check (arquivado_em is null or arquivado_motivo is not null),
  check (indicado_por_pessoa_id is distinct from id)
);

-- Evita cadastro duplicado pelo mesmo número.
create unique index pessoas_telefone_unico on public.pessoas (clinica_id, telefone_e164)
  where telefone_e164 is not null;
create unique index pessoas_whatsapp_unico on public.pessoas (clinica_id, whatsapp_e164)
  where whatsapp_e164 is not null;
create index pessoas_nome on public.pessoas (clinica_id, lower(nome));
create index pessoas_responsavel on public.pessoas (clinica_id, responsavel_id);

-- ─── Oportunidades: o "cartão" do funil ──────────────────────────────────────
-- Cada pessoa tem NO MÁXIMO UMA oportunidade em andamento (aberta ou pausada),
-- portanto uma única etapa atual. Oportunidades encerradas ficam como histórico.

create table public.oportunidades (
  id                        uuid primary key default gen_random_uuid(),
  clinica_id                uuid not null references public.clinicas (id),
  pessoa_id                 uuid not null,
  procedimento_id           uuid,                    -- procedimento de interesse principal
  titulo                    text check (length(titulo) <= 120),
  origem_id                 uuid,                    -- atribuição desta negociação
  etapa_id                  uuid not null,
  etapa_desde               timestamptz not null default now(),
  -- status e resultado são derivados da etapa (gatilho sincronizar_oportunidade)
  status                    public.status_oportunidade not null default 'aberta',
  resultado                 public.resultado_oportunidade,
  motivo_id                 uuid,
  motivo_detalhe            text check (length(motivo_detalhe) <= 500),
  valor_estimado_centavos   bigint check (valor_estimado_centavos >= 0),
  valor_fechado_centavos    bigint check (valor_fechado_centavos >= 0),
  responsavel_id            uuid,
  reabre_em                 date,                    -- data combinada para retomar
  aberta_em                 timestamptz not null default now(),
  fechada_em                timestamptz,
  oportunidade_origem_id    uuid,                    -- quando nasce de uma reativação
  criado_por                uuid default auth.uid(),
  criado_em                 timestamptz not null default now(),
  atualizado_em             timestamptz not null default now(),

  unique (clinica_id, id),
  foreign key (clinica_id, pessoa_id) references public.pessoas (clinica_id, id),
  foreign key (clinica_id, procedimento_id) references public.procedimentos (clinica_id, id),
  foreign key (clinica_id, origem_id) references public.origens (clinica_id, id),
  foreign key (clinica_id, etapa_id) references public.etapas_funil (clinica_id, id),
  foreign key (clinica_id, motivo_id) references public.motivos (clinica_id, id),
  foreign key (clinica_id, responsavel_id) references public.membros (clinica_id, usuario_id),
  foreign key (clinica_id, oportunidade_origem_id) references public.oportunidades (clinica_id, id),
  check (
    (status = 'aberta' and resultado is null)
    or (status = 'ganha' and resultado = 'fechou')
    or (status = 'perdida' and resultado in ('nao_fechou', 'desistiu'))
    or (status = 'pausada' and resultado = 'sem_resposta')
  ),
  check ((status in ('ganha', 'perdida')) = (fechada_em is not null)),
  check (resultado is distinct from 'nao_fechou' or motivo_id is not null),
  check (resultado is distinct from 'desistiu' or motivo_id is not null)
);

create unique index oportunidades_uma_em_andamento on public.oportunidades (pessoa_id)
  where status in ('aberta', 'pausada');
create index oportunidades_funil on public.oportunidades (clinica_id, status, etapa_id);

-- Procedimentos de interesse adicionais da mesma negociação.
create table public.oportunidade_interesses (
  clinica_id       uuid not null references public.clinicas (id),
  oportunidade_id  uuid not null,
  procedimento_id  uuid not null,
  criado_em        timestamptz not null default now(),
  primary key (oportunidade_id, procedimento_id),
  foreign key (clinica_id, oportunidade_id) references public.oportunidades (clinica_id, id) on delete cascade,
  foreign key (clinica_id, procedimento_id) references public.procedimentos (clinica_id, id)
);

-- Histórico de etapas: etapa anterior, nova etapa, data, usuário e observação.
create table public.historico_etapas (
  id                 bigint generated always as identity primary key,
  clinica_id         uuid not null references public.clinicas (id),
  oportunidade_id    uuid not null,
  pessoa_id          uuid not null,
  etapa_anterior_id  uuid,
  etapa_nova_id      uuid not null,
  mudou_em           timestamptz not null default now(),
  usuario_id         uuid,
  observacao         text check (length(observacao) <= 1000),
  foreign key (clinica_id, oportunidade_id) references public.oportunidades (clinica_id, id),
  foreign key (clinica_id, pessoa_id) references public.pessoas (clinica_id, id),
  foreign key (clinica_id, etapa_anterior_id) references public.etapas_funil (clinica_id, id),
  foreign key (clinica_id, etapa_nova_id) references public.etapas_funil (clinica_id, id)
);

create index historico_etapas_oportunidade on public.historico_etapas (oportunidade_id, mudou_em);

-- O que o paciente antigo já fez na clínica (somente nome comercial e data).
create table public.tratamentos_anteriores (
  id                         uuid primary key default gen_random_uuid(),
  clinica_id                 uuid not null references public.clinicas (id),
  pessoa_id                  uuid not null,
  procedimento_id            uuid not null,
  realizado_em               date,
  valor_aproximado_centavos  bigint check (valor_aproximado_centavos >= 0),
  criado_por                 uuid default auth.uid(),
  criado_em                  timestamptz not null default now(),
  atualizado_em              timestamptz not null default now(),
  foreign key (clinica_id, pessoa_id) references public.pessoas (clinica_id, id),
  foreign key (clinica_id, procedimento_id) references public.procedimentos (clinica_id, id)
);

-- ─── Agenda comercial ────────────────────────────────────────────────────────

create table public.agendamentos (
  id                  uuid primary key default gen_random_uuid(),
  clinica_id          uuid not null references public.clinicas (id),
  pessoa_id           uuid not null,
  oportunidade_id     uuid,
  profissional_id     uuid,
  tipo                public.tipo_agendamento not null,
  procedimento_id     uuid,
  inicio              timestamptz not null,
  duracao_min         int not null default 60 check (duracao_min between 5 and 600),
  status              public.status_agendamento not null default 'agendado',
  motivo_id           uuid,                                   -- motivo da desmarcação
  remarcado_para_id   uuid,
  confirmado_em       timestamptz,
  observacoes         text check (length(observacoes) <= 500),  -- administrativas
  criado_por          uuid default auth.uid(),
  criado_em           timestamptz not null default now(),
  atualizado_em       timestamptz not null default now(),
  unique (clinica_id, id),
  foreign key (clinica_id, pessoa_id) references public.pessoas (clinica_id, id),
  foreign key (clinica_id, oportunidade_id) references public.oportunidades (clinica_id, id),
  foreign key (clinica_id, profissional_id) references public.profissionais (clinica_id, id),
  foreign key (clinica_id, procedimento_id) references public.procedimentos (clinica_id, id),
  foreign key (clinica_id, motivo_id) references public.motivos (clinica_id, id),
  foreign key (clinica_id, remarcado_para_id) references public.agendamentos (clinica_id, id),
  check (remarcado_para_id is distinct from id),
  check (status <> 'remarcado' or remarcado_para_id is not null)
);

create index agendamentos_periodo on public.agendamentos (clinica_id, inicio);
create index agendamentos_pessoa on public.agendamentos (pessoa_id, inicio desc);

-- ─── Follow-ups: cada ação de relacionamento (histórico permanente) ──────────

create table public.interacoes (
  id               uuid primary key default gen_random_uuid(),
  clinica_id       uuid not null references public.clinicas (id),
  pessoa_id        uuid not null,
  oportunidade_id  uuid,
  tarefa_id        uuid,
  agendamento_id   uuid,
  tipo             public.tipo_interacao not null,
  canal            public.canal_contato,
  direcao          public.direcao_contato,
  descricao        text check (length(descricao) <= 2000),
  retorno_em       date,                     -- quando o paciente pediu retorno
  ocorreu_em       timestamptz not null default now(),
  usuario_id       uuid default auth.uid(),
  -- Um follow-up nunca é apagado; se foi registrado por engano, é anulado.
  anulada_em       timestamptz,
  anulada_por      uuid,
  anulada_motivo   text,
  criado_em        timestamptz not null default now(),
  unique (clinica_id, id),
  foreign key (clinica_id, pessoa_id) references public.pessoas (clinica_id, id),
  foreign key (clinica_id, oportunidade_id) references public.oportunidades (clinica_id, id),
  foreign key (clinica_id, agendamento_id) references public.agendamentos (clinica_id, id),
  check (tipo <> 'retorno_solicitado' or retorno_em is not null),
  check ((anulada_em is null) = (anulada_motivo is null))
);

create index interacoes_pessoa on public.interacoes (pessoa_id, ocorreu_em desc);

-- ─── Tarefas: próximas ações e lembretes ─────────────────────────────────────

create table public.tarefas (
  id                  uuid primary key default gen_random_uuid(),
  clinica_id          uuid not null references public.clinicas (id),
  pessoa_id           uuid not null,                 -- paciente/lead relacionado
  oportunidade_id     uuid,
  agendamento_id      uuid,
  parcela_id          uuid,                          -- FK criada na migração do financeiro
  tipo                public.tipo_tarefa not null default 'personalizada',
  categoria           public.categoria_tarefa not null default 'outra',
  titulo              text not null check (length(btrim(titulo)) between 2 and 200),
  descricao           text check (length(descricao) <= 2000),
  vence_em            date not null,                 -- data
  horario             time,                          -- horário opcional
  prioridade          public.prioridade_tarefa not null default 'normal',
  status              public.status_tarefa not null default 'pendente',
  responsavel_id      uuid,
  origem              public.origem_tarefa not null default 'manual',
  regra               text,                          -- regra que criou (tarefas automáticas)
  mensagem_sugerida   text check (length(mensagem_sugerida) <= 2000),
  modelo_mensagem_id  uuid,
  resultado           text,
  passo               int not null default 1 check (passo >= 1),   -- tentativa da cadência
  adiamentos          int not null default 0 check (adiamentos >= 0),
  chave_dedupe        text,
  concluida_em        timestamptz,
  concluida_por       uuid,
  cancelada_em        timestamptz,
  cancelada_motivo    text,
  criado_por          uuid default auth.uid(),
  criado_em           timestamptz not null default now(),
  atualizado_em       timestamptz not null default now(),
  unique (clinica_id, id),
  foreign key (clinica_id, pessoa_id) references public.pessoas (clinica_id, id),
  foreign key (clinica_id, oportunidade_id) references public.oportunidades (clinica_id, id),
  foreign key (clinica_id, agendamento_id) references public.agendamentos (clinica_id, id),
  foreign key (clinica_id, responsavel_id) references public.membros (clinica_id, usuario_id),
  foreign key (clinica_id, modelo_mensagem_id) references public.modelos_mensagem (clinica_id, id),
  check ((status = 'concluida') = (concluida_em is not null)),
  check ((status = 'cancelada') = (cancelada_em is not null)),
  check (origem = 'manual' or regra is not null)
);

-- Impossível duplicar o mesmo lembrete automático enquanto ele estiver pendente.
create unique index tarefas_sem_duplicidade on public.tarefas (clinica_id, chave_dedupe)
  where status = 'pendente' and chave_dedupe is not null;
create index tarefas_painel on public.tarefas (clinica_id, status, vence_em);
create index tarefas_pessoa on public.tarefas (pessoa_id, status);

alter table public.interacoes
  add foreign key (clinica_id, tarefa_id) references public.tarefas (clinica_id, id);

-- =============================================================================
-- Gatilhos de regra de negócio
-- =============================================================================

-- Status/resultado da oportunidade derivam da etapa. Assim, mover a etapa é a
-- única forma de mudar o estado, e os dois nunca ficam inconsistentes.
create or replace function public.sincronizar_oportunidade()
returns trigger
language plpgsql
as $$
declare
  v_resultado public.resultado_oportunidade;
begin
  select e.resultado into v_resultado
    from public.etapas_funil e
   where e.id = new.etapa_id and e.clinica_id = new.clinica_id;

  new.resultado := v_resultado;
  new.status := case v_resultado
    when 'fechou' then 'ganha'
    when 'nao_fechou' then 'perdida'
    when 'desistiu' then 'perdida'
    when 'sem_resposta' then 'pausada'
    else 'aberta'
  end::public.status_oportunidade;

  if new.status in ('ganha', 'perdida') then
    new.fechada_em := coalesce(new.fechada_em, now());
  else
    new.fechada_em := null;
  end if;

  if tg_op = 'UPDATE' and new.etapa_id is distinct from old.etapa_id then
    new.etapa_desde := now();
  end if;
  return new;
end;
$$;

create trigger sincronizar_oportunidade
  before insert or update of etapa_id on public.oportunidades
  for each row execute function public.sincronizar_oportunidade();

-- Registra cada mudança de etapa no histórico (com observação opcional, passada
-- pela função mover_etapa).
create or replace function public.registrar_historico_etapa()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  if tg_op = 'INSERT' or new.etapa_id is distinct from old.etapa_id then
    insert into public.historico_etapas
      (clinica_id, oportunidade_id, pessoa_id, etapa_anterior_id, etapa_nova_id, usuario_id, observacao)
    values (
      new.clinica_id, new.id, new.pessoa_id,
      case when tg_op = 'UPDATE' then old.etapa_id end,
      new.etapa_id, auth.uid(),
      nullif(current_setting('crm.observacao_etapa', true), '')
    );
  end if;
  return new;
end;
$$;

create trigger registrar_historico_etapa
  after insert or update of etapa_id on public.oportunidades
  for each row execute function public.registrar_historico_etapa();

-- Ao encerrar uma negociação, cancela os lembretes de venda pendentes dela.
create or replace function public.encerrar_tarefas_da_oportunidade()
returns trigger
language plpgsql
as $$
begin
  if new.status in ('ganha', 'perdida', 'pausada') and new.status is distinct from old.status then
    update public.tarefas
       set status = 'cancelada', cancelada_em = now(),
           cancelada_motivo = 'Negociação encerrada (' || new.resultado || ')'
     where oportunidade_id = new.id and status = 'pendente' and categoria <> 'financeiro';
  end if;
  return new;
end;
$$;

-- Sem "of status": o status é alterado pelo gatilho da etapa, não pelo UPDATE em si.
create trigger encerrar_tarefas_da_oportunidade
  after update on public.oportunidades
  for each row execute function public.encerrar_tarefas_da_oportunidade();

-- Mover etapa com observação e motivo (usado pela aplicação).
create or replace function public.mover_etapa(
  p_oportunidade uuid,
  p_etapa uuid,
  p_observacao text default null,
  p_motivo uuid default null,
  p_motivo_detalhe text default null
)
returns public.oportunidades
language plpgsql
as $$
declare
  v_resultado public.oportunidades;
begin
  perform set_config('crm.observacao_etapa', coalesce(p_observacao, ''), true);
  update public.oportunidades
     set etapa_id = p_etapa,
         motivo_id = coalesce(p_motivo, motivo_id),
         motivo_detalhe = coalesce(p_motivo_detalhe, motivo_detalhe)
   where id = p_oportunidade
  returning * into v_resultado;
  perform set_config('crm.observacao_etapa', '', true);

  if v_resultado.id is null then
    raise exception 'Oportunidade não encontrada ou sem permissão' using errcode = 'P0002';
  end if;
  return v_resultado;
end;
$$;

-- Follow-ups são permanentes: só é permitido anular (com motivo), nunca editar o conteúdo.
create or replace function public.proteger_interacao()
returns trigger
language plpgsql
as $$
begin
  -- Única exceção: anonimização LGPD apaga o texto livre (função anonimizar_pessoa).
  if current_setting('crm.anonimizando', true) = 'on' then
    return new;
  end if;
  if (to_jsonb(new) - array['anulada_em', 'anulada_por', 'anulada_motivo'])
     is distinct from (to_jsonb(old) - array['anulada_em', 'anulada_por', 'anulada_motivo']) then
    raise exception 'Follow-ups não podem ser editados; anule e registre novamente.'
      using errcode = 'P0001';
  end if;
  if old.anulada_em is not null then
    raise exception 'Este follow-up já foi anulado.' using errcode = 'P0001';
  end if;
  new.anulada_por := coalesce(new.anulada_por, auth.uid());
  return new;
end;
$$;

create trigger proteger_interacao
  before update on public.interacoes
  for each row execute function public.proteger_interacao();

-- Mantém a data do último contato da pessoa.
create or replace function public.atualizar_ultimo_contato()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  if new.tipo not in ('nota', 'pagamento_recebido') then
    update public.pessoas
       set ultimo_contato_em = greatest(coalesce(ultimo_contato_em, new.ocorreu_em), new.ocorreu_em)
     where id = new.pessoa_id and clinica_id = new.clinica_id;
  end if;
  return new;
end;
$$;

create trigger atualizar_ultimo_contato
  after insert on public.interacoes
  for each row execute function public.atualizar_ultimo_contato();

-- Mudanças de status na agenda viram follow-ups no histórico da pessoa.
create or replace function public.registrar_status_agendamento()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare
  v_tipo public.tipo_interacao;
begin
  if new.status is distinct from old.status then
    v_tipo := case new.status
      when 'compareceu' then 'atendimento'
      when 'desmarcado' then 'paciente_desmarcou'
      when 'faltou' then 'paciente_faltou'
    end;
    if v_tipo is not null then
      insert into public.interacoes
        (clinica_id, pessoa_id, oportunidade_id, agendamento_id, tipo, canal, descricao)
      values (
        new.clinica_id, new.pessoa_id, new.oportunidade_id, new.id, v_tipo,
        case when new.status = 'compareceu' then 'presencial'::public.canal_contato end,
        'Agendamento de ' || to_char(new.inicio at time zone 'America/Sao_Paulo', 'DD/MM/YYYY HH24:MI')
      );
    end if;
    if new.status = 'confirmado' and new.confirmado_em is null then
      new.confirmado_em := now();
    end if;
  end if;
  return new;
end;
$$;

create trigger registrar_status_agendamento
  before update of status on public.agendamentos
  for each row execute function public.registrar_status_agendamento();

-- Carimbos de conclusão/cancelamento de tarefas.
create or replace function public.carimbar_tarefa()
returns trigger
language plpgsql
as $$
begin
  if new.status = 'concluida' and (tg_op = 'INSERT' or old.status <> 'concluida') then
    new.concluida_em := coalesce(new.concluida_em, now());
    new.concluida_por := coalesce(new.concluida_por, auth.uid());
  elsif new.status <> 'concluida' then
    new.concluida_em := null;
    new.concluida_por := null;
  end if;

  if new.status = 'cancelada' and (tg_op = 'INSERT' or old.status <> 'cancelada') then
    new.cancelada_em := coalesce(new.cancelada_em, now());
  elsif new.status <> 'cancelada' then
    new.cancelada_em := null;
  end if;

  if tg_op = 'UPDATE' and new.status = 'pendente' and new.vence_em > old.vence_em then
    new.adiamentos := old.adiamentos + 1;
  end if;
  return new;
end;
$$;

create trigger carimbar_tarefa
  before insert or update on public.tarefas
  for each row execute function public.carimbar_tarefa();

-- ─── Gatilhos comuns (atualizado_em + auditoria) ─────────────────────────────

do $$
declare
  t text;
begin
  foreach t in array array[
    'pessoas', 'oportunidades', 'tratamentos_anteriores', 'agendamentos', 'tarefas'
  ] loop
    execute format(
      'create trigger definir_atualizado_em before update on public.%I
         for each row execute function public.definir_atualizado_em()', t);
  end loop;
  foreach t in array array[
    'pessoas', 'oportunidades', 'tratamentos_anteriores', 'agendamentos', 'tarefas', 'interacoes'
  ] loop
    execute format(
      'create trigger auditoria after insert or update or delete on public.%I
         for each row execute function public.registrar_auditoria()', t);
  end loop;
end;
$$;

-- ─── RLS ─────────────────────────────────────────────────────────────────────
-- Membros da clínica leem, criam e alteram. Não há DELETE para usuários:
-- pessoas são arquivadas, tarefas canceladas, follow-ups anulados.

do $$
declare
  t text;
begin
  foreach t in array array[
    'pessoas', 'oportunidades', 'oportunidade_interesses', 'tratamentos_anteriores',
    'agendamentos', 'interacoes', 'tarefas'
  ] loop
    execute format('alter table public.%I enable row level security', t);
    execute format(
      'create policy membro_ler on public.%I for select to authenticated
         using (clinica_id in (select public.minhas_clinicas()))', t);
    execute format(
      'create policy membro_inserir on public.%I for insert to authenticated
         with check (clinica_id in (select public.minhas_clinicas()))', t);
    execute format(
      'create policy membro_alterar on public.%I for update to authenticated
         using (clinica_id in (select public.minhas_clinicas()))
         with check (clinica_id in (select public.minhas_clinicas()))', t);
  end loop;
end;
$$;

-- Interesses secundários podem ser removidos da negociação.
create policy membro_remover on public.oportunidade_interesses for delete to authenticated
  using (clinica_id in (select public.minhas_clinicas()));

-- Histórico de etapas: somente leitura (escrito pelo gatilho).
alter table public.historico_etapas enable row level security;
create policy membro_ler on public.historico_etapas for select to authenticated
  using (clinica_id in (select public.minhas_clinicas()));

-- ─── LGPD: anonimização a pedido do titular (somente administradora) ─────────

create or replace function public.anonimizar_pessoa(p_pessoa uuid, p_motivo text)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  v_clinica uuid;
begin
  select clinica_id into v_clinica from public.pessoas where id = p_pessoa;
  if v_clinica is null or not public.eh_admin(v_clinica) then
    raise exception 'Somente a administradora pode anonimizar cadastros.' using errcode = '42501';
  end if;
  if coalesce(btrim(p_motivo), '') = '' then
    raise exception 'Informe o motivo da anonimização.' using errcode = 'P0001';
  end if;

  update public.pessoas set
    nome = 'Pessoa anonimizada', apelido_tratamento = null, data_nascimento = null,
    telefone_e164 = null, whatsapp_e164 = null, email = null,
    cep = null, logradouro = null, numero = null, complemento = null, bairro = null,
    observacoes_comerciais = null, origem_detalhe = null, indicado_por_pessoa_id = null,
    consentimento_contato = false, consentimento_marketing = false,
    nao_contatar = true, nao_contatar_motivo = 'Anonimizado (LGPD)',
    arquivado_em = coalesce(arquivado_em, now()), arquivado_motivo = 'Anonimizado (LGPD)'
  where id = p_pessoa;

  perform set_config('crm.anonimizando', 'on', true);
  update public.interacoes set descricao = null where pessoa_id = p_pessoa and descricao is not null;
  perform set_config('crm.anonimizando', '', true);

  update public.tarefas set status = 'cancelada', cancelada_motivo = 'Cadastro anonimizado'
   where pessoa_id = p_pessoa and status = 'pendente';
  update public.tarefas set descricao = null, mensagem_sugerida = null, titulo = 'Tarefa de cadastro anonimizado'
   where pessoa_id = p_pessoa;

  -- Remove os dados pessoais também das cópias guardadas na auditoria.
  update public.auditoria set antes = null, depois = null
   where registro_id = p_pessoa
      or registro_id in (select i.id from public.interacoes i where i.pessoa_id = p_pessoa)
      or registro_id in (select t.id from public.tarefas t where t.pessoa_id = p_pessoa);

  insert into public.auditoria (clinica_id, tabela, registro_id, acao, depois, usuario_id)
  values (v_clinica, 'pessoas', p_pessoa, 'anonimizacao', jsonb_build_object('motivo', p_motivo), auth.uid());
end;
$$;

revoke execute on function public.anonimizar_pessoa(uuid, text) from public, anon;
