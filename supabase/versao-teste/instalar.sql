-- =============================================================================
-- Instituto CG — VERSÃO DE TESTE (dados fictícios)
--
-- Arquivo gerado por scripts/gerar-versao-teste.sh — não edite à mão.
--
-- Como usar: num projeto Supabase NOVO, só para testes, abra o SQL Editor,
-- cole este arquivo inteiro e clique em "Run". No fim aparecem os e-mails e as
-- senhas dos logins de teste (anote).
--
-- NUNCA rode este arquivo no projeto de produção: ele cria pacientes fictícios
-- e liga o modo de teste.
-- =============================================================================

begin;


-- ---------------------------------------------------------------------------
-- 20260929120000_fundacao.sql
-- ---------------------------------------------------------------------------

-- =============================================================================
-- Instituto CG — CRM comercial
-- Migração 1/4: fundação
--   clínica (inquilino), usuários, membros, profissionais, catálogos
--   configuráveis, auditoria e funções de apoio às regras de acesso (RLS).
--
-- Convenções:
--   • Toda tabela de negócio tem clinica_id (preparado para várias unidades).
--   • Dinheiro em centavos (bigint). Nunca float.
--   • Nada é apagado silenciosamente: registros são desativados/arquivados e
--     as alterações importantes vão para a tabela auditoria.
--   • NENHUM campo clínico (prontuário, diagnóstico, anamnese etc.).
-- =============================================================================

-- ─── Tipos ───────────────────────────────────────────────────────────────────

create type public.papel_membro as enum ('admin', 'gestor', 'comercial', 'dentista');
create type public.tipo_origem as enum ('pago', 'organico', 'indicacao', 'interno');
create type public.tipo_etapa as enum ('aberta', 'ganho', 'perda');
create type public.resultado_oportunidade as enum ('fechou', 'nao_fechou', 'desistiu', 'sem_resposta');
create type public.aplica_motivo as enum ('nao_fechou', 'desistiu', 'desmarcou', 'encerramento');

-- ─── Funções utilitárias ─────────────────────────────────────────────────────

create or replace function public.definir_atualizado_em()
returns trigger
language plpgsql
as $$
begin
  new.atualizado_em := now();
  return new;
end;
$$;

-- "R$ 1.234,56" a partir de centavos (usado em títulos de tarefas automáticas).
create or replace function public.formatar_brl(p_centavos bigint)
returns text
language sql
immutable
as $$
  select 'R$ ' || replace(replace(replace(
           to_char(p_centavos / 100.0, 'FM999G999G999G990D00'),
           ',', '#'), '.', ','), '#', '.');
$$;

-- ─── Clínica, usuários e membros ─────────────────────────────────────────────

create table public.clinicas (
  id             uuid primary key default gen_random_uuid(),
  nome           text not null check (length(btrim(nome)) >= 2),
  fuso           text not null default 'America/Sao_Paulo',
  -- Parâmetros (horário, prazos, limites). Formato em src/modules/configuracoes/padroes.ts
  configuracoes  jsonb not null default '{}'::jsonb,
  criado_em      timestamptz not null default now(),
  atualizado_em  timestamptz not null default now()
);

-- Perfil de quem faz login (1:1 com auth.users).
create table public.usuarios (
  id             uuid primary key references auth.users (id) on delete cascade,
  nome           text not null,
  email          text not null,
  telefone       text,
  ativo          boolean not null default true,
  criado_em      timestamptz not null default now(),
  atualizado_em  timestamptz not null default now()
);

-- Usuário × clínica × papel.
create table public.membros (
  id                   uuid primary key default gen_random_uuid(),
  clinica_id           uuid not null references public.clinicas (id),
  usuario_id           uuid not null references public.usuarios (id),
  papel                public.papel_membro not null,
  pode_ver_financeiro  boolean not null default true,
  ativo                boolean not null default true,
  criado_em            timestamptz not null default now(),
  atualizado_em        timestamptz not null default now(),
  unique (clinica_id, usuario_id)
);

-- Quem atende na agenda (pode não ter login).
create table public.profissionais (
  id             uuid primary key default gen_random_uuid(),
  clinica_id     uuid not null references public.clinicas (id),
  nome           text not null check (length(btrim(nome)) >= 2),
  cor            text not null default '#B08D57' check (cor ~ '^#[0-9A-Fa-f]{6}$'),
  usuario_id     uuid references public.usuarios (id),
  ativo          boolean not null default true,
  criado_em      timestamptz not null default now(),
  atualizado_em  timestamptz not null default now(),
  unique (clinica_id, id)
);

-- Cria o perfil automaticamente quando um login é criado no Supabase Auth.
create or replace function public.criar_perfil_usuario()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  insert into public.usuarios (id, nome, email)
  values (
    new.id,
    coalesce(nullif(new.raw_user_meta_data ->> 'nome', ''), split_part(new.email, '@', 1)),
    new.email
  )
  on conflict (id) do nothing;
  return new;
end;
$$;

create trigger ao_criar_login
  after insert on auth.users
  for each row execute function public.criar_perfil_usuario();

-- ─── Funções de acesso (usadas pelas políticas RLS) ──────────────────────────
-- SECURITY DEFINER para consultar membros sem recursão nas próprias políticas.

create or replace function public.minhas_clinicas()
returns setof uuid
language sql
stable
security definer
set search_path = public
as $$
  select m.clinica_id
  from public.membros m
  join public.usuarios u on u.id = m.usuario_id
  where m.usuario_id = auth.uid() and m.ativo and u.ativo;
$$;

create or replace function public.eh_admin(p_clinica uuid)
returns boolean
language sql
stable
security definer
set search_path = public
as $$
  select exists (
    select 1 from public.membros m
    join public.usuarios u on u.id = m.usuario_id
    where m.usuario_id = auth.uid() and m.clinica_id = p_clinica
      and m.ativo and u.ativo and m.papel = 'admin'
  );
$$;

-- Versão de teste: o esquema "teste" só existe onde os dados fictícios foram
-- carregados (seed.sql / versao-teste/instalar.sql) — nunca em produção.
create or replace function public.ambiente_teste()
returns boolean
language sql
stable
as $$
  select to_regnamespace('teste') is not null;
$$;

create or replace function public.pode_ver_financeiro(p_clinica uuid)
returns boolean
language sql
stable
security definer
set search_path = public
as $$
  select exists (
    select 1 from public.membros m
    join public.usuarios u on u.id = m.usuario_id
    where m.usuario_id = auth.uid() and m.clinica_id = p_clinica
      and m.ativo and u.ativo
      and (m.papel in ('admin', 'gestor') or m.pode_ver_financeiro)
  );
$$;

-- ─── Catálogos configuráveis (editáveis pela administradora) ─────────────────

-- Procedimentos/serviços comercializados pela clínica (nome comercial apenas).
create table public.procedimentos (
  id                     uuid primary key default gen_random_uuid(),
  clinica_id             uuid not null references public.clinicas (id),
  nome                   text not null check (length(btrim(nome)) >= 2),
  categoria              text,
  descricao_comercial    text check (length(descricao_comercial) <= 500),
  ticket_medio_centavos  bigint check (ticket_medio_centavos >= 0),
  -- Sugestão de retorno/manutenção (ex.: limpeza = 6 meses). Usado na reativação.
  ciclo_retorno_meses    int check (ciclo_retorno_meses between 1 and 120),
  ordem                  int not null default 0,
  ativo                  boolean not null default true,
  criado_em              timestamptz not null default now(),
  atualizado_em          timestamptz not null default now(),
  unique (clinica_id, id),
  unique (clinica_id, nome)
);

-- "Como conheceu a clínica".
create table public.origens (
  id             uuid primary key default gen_random_uuid(),
  clinica_id     uuid not null references public.clinicas (id),
  nome           text not null check (length(btrim(nome)) >= 2),
  tipo           public.tipo_origem not null default 'organico',
  -- Canal usado nos indicadores (agrupa anúncios e orgânico do mesmo lugar).
  canal          text not null default 'outro'
                 check (canal in ('instagram', 'indicacao', 'google', 'whatsapp', 'paciente_antigo', 'outro')),
  ordem          int not null default 0,
  ativo          boolean not null default true,
  criado_em      timestamptz not null default now(),
  atualizado_em  timestamptz not null default now(),
  unique (clinica_id, id),
  unique (clinica_id, nome)
);

-- Etapas do funil (flexíveis). Etapas finais indicam o resultado correspondente.
create table public.etapas_funil (
  id             uuid primary key default gen_random_uuid(),
  clinica_id     uuid not null references public.clinicas (id),
  nome           text not null check (length(btrim(nome)) >= 2),
  ordem          int not null,
  tipo           public.tipo_etapa not null default 'aberta',
  resultado      public.resultado_oportunidade,
  -- Papel da etapa nas automações (o nome pode ser mudado à vontade).
  -- desmarcou e reativacao são etapas "fora do fluxo": dali a pessoa pode voltar
  -- para qualquer etapa (ex.: reagendou → Avaliação agendada).
  marco          text check (marco in (
                   'novo_contato', 'em_contato', 'avaliacao_agendada', 'avaliacao_realizada',
                   'orcamento_apresentado', 'em_negociacao', 'desmarcou', 'reativacao')),
  sla_dias       int check (sla_dias >= 0),
  cor            text not null default '#B08D57' check (cor ~ '^#[0-9A-Fa-f]{6}$'),
  ativo          boolean not null default true,
  criado_em      timestamptz not null default now(),
  atualizado_em  timestamptz not null default now(),
  unique (clinica_id, id),
  unique (clinica_id, nome),
  unique (clinica_id, marco),
  check (marco is null or tipo = 'aberta'),
  -- Etapa aberta não tem resultado; ganho = fechou; perda = um dos resultados negativos.
  check (
    (tipo = 'aberta' and resultado is null)
    or (tipo = 'ganho' and resultado = 'fechou')
    or (tipo = 'perda' and resultado in ('nao_fechou', 'desistiu', 'sem_resposta'))
  )
);

-- Só pode existir uma etapa ativa por resultado (o sistema precisa saber para onde mover).
create unique index etapas_funil_um_resultado
  on public.etapas_funil (clinica_id, resultado)
  where resultado is not null and ativo;

-- Motivos (não fechou, desistiu, desmarcou, encerramento).
create table public.motivos (
  id                      uuid primary key default gen_random_uuid(),
  clinica_id              uuid not null references public.clinicas (id),
  nome                    text not null check (length(btrim(nome)) >= 2),
  aplica_a                public.aplica_motivo not null,
  retorno_sugerido_dias   int check (retorno_sugerido_dias >= 0),
  -- Grupo do motivo nos indicadores de perda.
  grupo_perda             text check (grupo_perda in ('preco', 'desistiu', 'nao_respondeu', 'outro_local', 'adiou', 'outro')),
  ordem                   int not null default 0,
  ativo                   boolean not null default true,
  criado_em               timestamptz not null default now(),
  atualizado_em           timestamptz not null default now(),
  unique (clinica_id, id),
  unique (clinica_id, aplica_a, nome)
);

-- Formas de pagamento (configuráveis).
create table public.formas_pagamento (
  id                    uuid primary key default gen_random_uuid(),
  clinica_id            uuid not null references public.clinicas (id),
  nome                  text not null check (length(btrim(nome)) >= 2),
  permite_parcelamento  boolean not null default false,
  max_parcelas          int not null default 1 check (max_parcelas between 1 and 60),
  -- Recebido no ato (ex.: cartão): o paciente não fica devendo à clínica, então não há lembretes.
  recebe_na_hora        boolean not null default false,
  ordem                 int not null default 0,
  ativo                 boolean not null default true,
  criado_em             timestamptz not null default now(),
  atualizado_em         timestamptz not null default now(),
  unique (clinica_id, id),
  unique (clinica_id, nome),
  check (permite_parcelamento or max_parcelas = 1)
);

-- Biblioteca de mensagens prontas, organizada por categoria (situação).
-- Variáveis preenchidas pelo CRM: {{nome}}, {{nome_completo}}, {{procedimento}}, {{consulta}},
-- {{data}}, {{horario}}, {{dentista}}, {{valor}}, {{vencimento}}, {{clinica}}.
-- Nada é enviado automaticamente: a mensagem é sugerida para a usuária copiar e adaptar.
create table public.modelos_mensagem (
  id               uuid primary key default gen_random_uuid(),
  clinica_id       uuid not null references public.clinicas (id),
  categoria        text not null check (categoria in (
                     'primeiro_contato', 'pos_consulta', 'nao_fechou', 'sem_resposta', 'desmarcou',
                     'confirmacao', 'remarcacao', 'reativacao', 'pos_atendimento', 'cobranca_amigavel',
                     'pagamento_pendente', 'pagamento_previsto', 'paciente_antigo')),
  -- Tarefa/regra que usa este modelo de preferência (opcional; ex.: 'recuperar_falta').
  situacao         text,
  -- Modelo específico de um procedimento (opcional): tem preferência para quem negocia esse procedimento.
  procedimento_id  uuid,
  titulo           text not null check (length(btrim(titulo)) between 2 and 80),
  texto            text not null check (length(texto) between 1 and 2000),
  -- O modelo sugerido na categoria (um por categoria e procedimento).
  padrao           boolean not null default false,
  canal            text not null default 'whatsapp',
  ativo            boolean not null default true,
  criado_por       uuid default auth.uid(),
  criado_em        timestamptz not null default now(),
  atualizado_em    timestamptz not null default now(),
  unique (clinica_id, id),
  foreign key (clinica_id, procedimento_id) references public.procedimentos (clinica_id, id)
);
create unique index modelos_mensagem_padrao on public.modelos_mensagem
  (clinica_id, categoria, coalesce(procedimento_id, '00000000-0000-0000-0000-000000000000'::uuid))
  where padrao and ativo;

-- ─── Auditoria ───────────────────────────────────────────────────────────────

create table public.auditoria (
  id           bigint generated always as identity primary key,
  clinica_id   uuid,
  tabela       text not null,
  registro_id  uuid,
  acao         text not null check (acao in ('insert', 'update', 'delete', 'exportacao', 'anonimizacao')),
  antes        jsonb,
  depois       jsonb,
  usuario_id   uuid,
  quando       timestamptz not null default now()
);

create index auditoria_registro on public.auditoria (tabela, registro_id, quando desc);
create index auditoria_clinica on public.auditoria (clinica_id, quando desc);

-- Registra criação, alteração (somente os campos que mudaram) e exclusão.
create or replace function public.registrar_auditoria()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare
  v_antes   jsonb := case when tg_op in ('UPDATE', 'DELETE') then to_jsonb(old) end;
  v_depois  jsonb := case when tg_op in ('INSERT', 'UPDATE') then to_jsonb(new) end;
  v_id      uuid;
  v_clinica uuid;
begin
  if tg_op = 'UPDATE' then
    select jsonb_object_agg(d.key, d.value) into v_depois
      from jsonb_each(to_jsonb(new)) d
     where d.key <> 'atualizado_em' and (to_jsonb(old) -> d.key) is distinct from d.value;
    if v_depois is null then
      return new; -- nada relevante mudou
    end if;
    select jsonb_object_agg(a.key, a.value) into v_antes
      from jsonb_each(to_jsonb(old)) a
     where v_depois ? a.key;
  end if;

  v_id := coalesce(to_jsonb(new) ->> 'id', to_jsonb(old) ->> 'id')::uuid;
  v_clinica := case
    when tg_table_name = 'clinicas' then v_id
    else coalesce(to_jsonb(new) ->> 'clinica_id', to_jsonb(old) ->> 'clinica_id')::uuid
  end;

  insert into public.auditoria (clinica_id, tabela, registro_id, acao, antes, depois, usuario_id)
  values (v_clinica, tg_table_name, v_id, lower(tg_op), v_antes, v_depois, auth.uid());

  return coalesce(new, old);
end;
$$;

-- ─── Gatilhos comuns ─────────────────────────────────────────────────────────

do $$
declare
  t text;
begin
  foreach t in array array[
    'clinicas', 'usuarios', 'membros', 'profissionais', 'procedimentos', 'origens',
    'etapas_funil', 'motivos', 'formas_pagamento', 'modelos_mensagem'
  ] loop
    execute format(
      'create trigger definir_atualizado_em before update on public.%I
         for each row execute function public.definir_atualizado_em()', t);
    execute format(
      'create trigger auditoria after insert or update or delete on public.%I
         for each row execute function public.registrar_auditoria()', t);
  end loop;
end;
$$;

-- ─── Regras de acesso (RLS) ──────────────────────────────────────────────────

alter table public.clinicas enable row level security;
alter table public.usuarios enable row level security;
alter table public.membros enable row level security;
alter table public.profissionais enable row level security;
alter table public.procedimentos enable row level security;
alter table public.origens enable row level security;
alter table public.etapas_funil enable row level security;
alter table public.motivos enable row level security;
alter table public.formas_pagamento enable row level security;
alter table public.modelos_mensagem enable row level security;
alter table public.auditoria enable row level security;

-- Clínica: membros veem; só a administradora altera. Criação apenas pelo servidor.
create policy clinica_ler on public.clinicas for select to authenticated
  using (id in (select public.minhas_clinicas()));
create policy clinica_alterar on public.clinicas for update to authenticated
  using (public.eh_admin(id)) with check (public.eh_admin(id));

-- Usuários: cada um vê a si e aos colegas de clínica; edita apenas o próprio perfil
-- (a administradora pode desativar colegas).
create policy usuario_ler on public.usuarios for select to authenticated
  using (
    id = auth.uid()
    or id in (select m.usuario_id from public.membros m
              where m.clinica_id in (select public.minhas_clinicas()))
  );
create policy usuario_alterar_proprio on public.usuarios for update to authenticated
  using (id = auth.uid()) with check (id = auth.uid());
create policy usuario_alterar_admin on public.usuarios for update to authenticated
  using (exists (select 1 from public.membros m where m.usuario_id = usuarios.id and public.eh_admin(m.clinica_id)));

-- Um usuário não pode mudar o próprio papel nem se reativar.
create policy membro_ler on public.membros for select to authenticated
  using (clinica_id in (select public.minhas_clinicas()));
create policy membro_inserir on public.membros for insert to authenticated
  with check (public.eh_admin(clinica_id));
create policy membro_alterar on public.membros for update to authenticated
  using (public.eh_admin(clinica_id)) with check (public.eh_admin(clinica_id));

-- Catálogos: todos os membros leem; somente a administradora cria/edita.
-- Não há política de DELETE: itens são desativados (ativo = false), preservando o histórico.
do $$
declare
  t text;
begin
  foreach t in array array[
    'profissionais', 'procedimentos', 'origens', 'etapas_funil', 'motivos',
    'formas_pagamento'
  ] loop
    execute format(
      'create policy catalogo_ler on public.%I for select to authenticated
         using (clinica_id in (select public.minhas_clinicas()))', t);
    execute format(
      'create policy catalogo_inserir on public.%I for insert to authenticated
         with check (public.eh_admin(clinica_id))', t);
    execute format(
      'create policy catalogo_alterar on public.%I for update to authenticated
         using (public.eh_admin(clinica_id)) with check (public.eh_admin(clinica_id))', t);
  end loop;
end;
$$;

-- Mensagens prontas: toda a equipe usa, cria e edita (não há exclusão: desativa-se).
create policy membro_ler on public.modelos_mensagem for select to authenticated
  using (clinica_id in (select public.minhas_clinicas()));
create policy membro_inserir on public.modelos_mensagem for insert to authenticated
  with check (clinica_id in (select public.minhas_clinicas()));
create policy membro_alterar on public.modelos_mensagem for update to authenticated
  using (clinica_id in (select public.minhas_clinicas()))
  with check (clinica_id in (select public.minhas_clinicas()));

-- Auditoria: somente leitura, somente administradora. Escrita apenas via gatilho.
create policy auditoria_ler on public.auditoria for select to authenticated
  using (public.eh_admin(clinica_id));

-- ---------------------------------------------------------------------------
-- 20260929120100_crm.sql
-- ---------------------------------------------------------------------------

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
  'reativacao', 'manutencao', 'confirmar_pagamento', 'apresentar_orcamento', 'acompanhar_decisao',
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
  ultimo_atendimento_informado  date,          -- mês informado, ou data aproximada da faixa
  -- Quando a pessoa não lembra o mês: faixa aproximada (exibida como texto).
  ultimo_atendimento_faixa      text check (ultimo_atendimento_faixa in (
                                  'menos_6_meses', '6_a_12_meses', '1_a_2_anos', 'mais_2_anos', 'nao_lembra')),
  em_tratamento                 boolean not null default false,
  -- Data em que o paciente deve ser convidado a voltar (ex.: 6 meses após concluir o tratamento).
  retorno_previsto_em           date,

  -- Datas de relacionamento
  primeiro_contato_em           date not null default (now() at time zone 'America/Sao_Paulo')::date,
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
  status_em           timestamptz not null default now(),     -- quando o status mudou pela última vez
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

-- ─── Regras de follow-up (editáveis pela administradora) ─────────────────────
-- Uma regra por situação comercial: o que fazer, quando, quantas tentativas,
-- o que acontece se a pessoa continuar sem responder e qual mensagem sugerir.

create table public.regras_followup (
  id                      uuid primary key default gen_random_uuid(),
  clinica_id              uuid not null references public.clinicas (id),
  situacao                text not null check (situacao in (
                            'novo_contato', 'em_contato', 'confirmacao', 'pos_consulta', 'desmarcou',
                            'sem_resposta', 'nao_fechou', 'fechou',
                            'reativacao', 'paciente_inativo', 'manutencao', 'pos_tratamento')),
  nome                    text not null,
  quando                  text not null,            -- explicação do gatilho, para a tela
  ativa                   boolean not null default true,
  tipo_tarefa             public.tipo_tarefa not null,
  titulo_modelo           text not null check (length(btrim(titulo_modelo)) >= 3),
  -- Primeira ação: N dias após o evento (0 = no mesmo dia). Datas caem sempre em dia útil.
  prazo_dias              int check (prazo_dias between 0 and 730),
  -- Novas tentativas se não houver resposta: dias após a tentativa anterior.
  intervalos              int[] not null default '{}' check (array_position(intervalos, null) is null),
  prioridade              public.prioridade_tarefa not null default 'normal',
  -- Se continuar sem resposta depois da última tentativa:
  ao_esgotar              text not null default 'decidir' check (ao_esgotar in ('decidir', 'sem_resposta', 'reativacao', 'encerrar')),
  espera_reativacao_dias  int check (espera_reativacao_dias between 0 and 730),
  -- Regras por período (paciente inativo, pós-tratamento): meses desde o último atendimento.
  periodo_meses           int check (periodo_meses between 1 and 60),
  mensagem_situacao       text,                     -- modelo em modelos_mensagem
  criado_em               timestamptz not null default now(),
  atualizado_em           timestamptz not null default now(),
  unique (clinica_id, id),
  unique (clinica_id, situacao),
  check (cardinality(intervalos) <= 5),
  check (0 < all (intervalos))
);

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
      when 'cancelado_clinica' then 'nota'
      when 'remarcado' then 'nota'
    end;
    if v_tipo is not null then
      insert into public.interacoes
        (clinica_id, pessoa_id, oportunidade_id, agendamento_id, tipo, canal, descricao)
      values (
        new.clinica_id, new.pessoa_id, new.oportunidade_id, new.id, v_tipo,
        case when new.status = 'compareceu' then 'presencial'::public.canal_contato end,
        case new.status
          when 'compareceu' then 'Compareceu à consulta de '
          when 'desmarcado' then 'Desmarcou a consulta de '
          when 'faltou' then 'Faltou à consulta de '
          when 'cancelado_clinica' then 'A clínica cancelou a consulta de '
          else 'Remarcou a consulta de '
        end || to_char(new.inicio at time zone 'America/Sao_Paulo', 'DD/MM/YYYY "às" HH24:MI')
          || coalesce(' — motivo: ' || lower((select nome from public.motivos where id = new.motivo_id)), '')
          || coalesce(' — ' || nullif(btrim(current_setting('crm.observacao_agenda', true)), ''), '')
      );
    end if;
    if new.status = 'confirmado' and new.confirmado_em is null then
      new.confirmado_em := now();
    end if;
    new.status_em := now();
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
    'pessoas', 'oportunidades', 'tratamentos_anteriores', 'agendamentos', 'tarefas', 'regras_followup'
  ] loop
    execute format(
      'create trigger definir_atualizado_em before update on public.%I
         for each row execute function public.definir_atualizado_em()', t);
  end loop;
  foreach t in array array[
    'pessoas', 'oportunidades', 'tratamentos_anteriores', 'agendamentos', 'tarefas', 'interacoes', 'regras_followup'
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

-- Regras: todos leem; somente a administradora altera.
alter table public.regras_followup enable row level security;
create policy catalogo_ler on public.regras_followup for select to authenticated
  using (clinica_id in (select public.minhas_clinicas()));
create policy catalogo_inserir on public.regras_followup for insert to authenticated
  with check (public.eh_admin(clinica_id));
create policy catalogo_alterar on public.regras_followup for update to authenticated
  using (public.eh_admin(clinica_id)) with check (public.eh_admin(clinica_id));

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

-- ---------------------------------------------------------------------------
-- 20260929120200_financeiro.sql
-- ---------------------------------------------------------------------------

-- =============================================================================
-- Migração 3/4: financeiro simples (somente contas a receber)
--   orçamentos (+ itens), vendas (negociação fechada), parcelas, pagamentos
--   e os lembretes financeiros automáticos.
--
--   Orçamento ──aprovado──► Venda ──► Parcelas ──► Pagamentos
--                          (vendido)  (a receber)   (recebido)
-- =============================================================================

create type public.condicao_pagamento as enum ('a_vista', 'parcelado');
create type public.status_orcamento as enum (
  'rascunho', 'apresentado', 'em_negociacao', 'aprovado', 'recusado', 'expirado', 'substituido'
);
create type public.tipo_venda as enum ('venda', 'saldo_anterior');
create type public.status_venda as enum ('ativa', 'cancelada');
create type public.status_parcela as enum ('pendente', 'parcial', 'paga', 'cancelada', 'renegociada');

-- ─── Orçamentos ──────────────────────────────────────────────────────────────

create table public.orcamentos (
  id                      uuid primary key default gen_random_uuid(),
  clinica_id              uuid not null references public.clinicas (id),
  pessoa_id               uuid not null,
  oportunidade_id         uuid not null,
  numero                  int not null default 0,         -- definido pelo gatilho
  versao                  int not null default 1 check (versao >= 1),
  status                  public.status_orcamento not null default 'rascunho',
  valor_total_centavos    bigint not null default 0 check (valor_total_centavos >= 0),
  desconto_centavos       bigint not null default 0 check (desconto_centavos >= 0),
  valor_final_centavos    bigint generated always as (valor_total_centavos - desconto_centavos) stored,
  forma_pagamento_id      uuid,
  condicao_pagamento      public.condicao_pagamento not null default 'a_vista',
  entrada_centavos        bigint not null default 0 check (entrada_centavos >= 0),
  quantidade_parcelas     int not null default 1 check (quantidade_parcelas between 1 and 60),
  valor_parcela_centavos  bigint generated always as (
    (valor_total_centavos - desconto_centavos - entrada_centavos) / quantidade_parcelas
  ) stored,
  observacao_financeira   text check (length(observacao_financeira) <= 1000),
  apresentado_em          date,
  valido_ate              date,
  apresentado_por         uuid,                              -- profissional
  criado_por              uuid default auth.uid(),
  criado_em               timestamptz not null default now(),
  atualizado_em           timestamptz not null default now(),
  unique (clinica_id, id),
  unique (clinica_id, numero, versao),
  foreign key (clinica_id, pessoa_id) references public.pessoas (clinica_id, id),
  foreign key (clinica_id, oportunidade_id) references public.oportunidades (clinica_id, id),
  foreign key (clinica_id, forma_pagamento_id) references public.formas_pagamento (clinica_id, id),
  foreign key (clinica_id, apresentado_por) references public.profissionais (clinica_id, id),
  check (desconto_centavos <= valor_total_centavos),
  check (entrada_centavos <= valor_total_centavos - desconto_centavos),
  check ((condicao_pagamento = 'a_vista') = (quantidade_parcelas = 1 and entrada_centavos = 0)),
  check (valido_ate is null or apresentado_em is null or valido_ate >= apresentado_em)
);

-- Um único orçamento aprovado por negociação.
create unique index orcamentos_um_aprovado on public.orcamentos (oportunidade_id) where status = 'aprovado';

-- Itens: procedimento + descrição comercial (nada de plano clínico).
create table public.orcamento_itens (
  id                        uuid primary key default gen_random_uuid(),
  clinica_id                uuid not null references public.clinicas (id),
  orcamento_id              uuid not null,
  procedimento_id           uuid not null,
  descricao_comercial       text check (length(descricao_comercial) <= 200),
  quantidade                int not null default 1 check (quantidade between 1 and 100),
  valor_unitario_centavos   bigint not null check (valor_unitario_centavos >= 0),
  desconto_centavos         bigint not null default 0 check (desconto_centavos >= 0),
  criado_em                 timestamptz not null default now(),
  foreign key (clinica_id, orcamento_id) references public.orcamentos (clinica_id, id) on delete cascade,
  foreign key (clinica_id, procedimento_id) references public.procedimentos (clinica_id, id),
  check (desconto_centavos <= quantidade * valor_unitario_centavos)
);

-- ─── Vendas (negociação fechada) ─────────────────────────────────────────────

create table public.vendas (
  id                      uuid primary key default gen_random_uuid(),
  clinica_id              uuid not null references public.clinicas (id),
  pessoa_id               uuid not null,
  oportunidade_id         uuid,
  orcamento_id            uuid unique,
  tipo                    public.tipo_venda not null default 'venda',
  status                  public.status_venda not null default 'ativa',
  fechada_em              date not null default (now() at time zone 'America/Sao_Paulo')::date,
  valor_total_centavos    bigint not null check (valor_total_centavos > 0),
  desconto_centavos       bigint not null default 0 check (desconto_centavos >= 0),
  valor_final_centavos    bigint generated always as (valor_total_centavos - desconto_centavos) stored,
  forma_pagamento_id      uuid,
  condicao_pagamento      public.condicao_pagamento not null default 'a_vista',
  entrada_centavos        bigint not null default 0 check (entrada_centavos >= 0),
  quantidade_parcelas     int not null default 1 check (quantidade_parcelas between 1 and 60),
  valor_parcela_centavos  bigint generated always as (
    (valor_total_centavos - desconto_centavos - entrada_centavos) / quantidade_parcelas
  ) stored,
  observacao_financeira   text check (length(observacao_financeira) <= 1000),
  cancelada_em            timestamptz,
  cancelada_motivo        text,
  criado_por              uuid default auth.uid(),
  criado_em               timestamptz not null default now(),
  atualizado_em           timestamptz not null default now(),
  unique (clinica_id, id),
  foreign key (clinica_id, pessoa_id) references public.pessoas (clinica_id, id),
  foreign key (clinica_id, oportunidade_id) references public.oportunidades (clinica_id, id),
  foreign key (clinica_id, orcamento_id) references public.orcamentos (clinica_id, id),
  foreign key (clinica_id, forma_pagamento_id) references public.formas_pagamento (clinica_id, id),
  check (desconto_centavos < valor_total_centavos),
  check (entrada_centavos <= valor_total_centavos - desconto_centavos),
  check ((condicao_pagamento = 'a_vista') = (quantidade_parcelas = 1 and entrada_centavos = 0)),
  -- Venda nova nasce de uma negociação; "saldo anterior" é só para o recadastro.
  check (tipo = 'saldo_anterior' or oportunidade_id is not null),
  check ((status = 'cancelada') = (cancelada_em is not null and cancelada_motivo is not null))
);

-- ─── Parcelas (contas a receber) ─────────────────────────────────────────────

create table public.parcelas (
  id                      uuid primary key default gen_random_uuid(),
  clinica_id              uuid not null references public.clinicas (id),
  venda_id                uuid not null,
  pessoa_id               uuid not null,
  numero                  int not null check (numero >= 0),   -- 0 = entrada
  valor_centavos          bigint not null check (valor_centavos > 0),
  vencimento              date not null,                      -- data prevista
  forma_pagamento_id      uuid,
  status                  public.status_parcela not null default 'pendente',
  valor_pago_centavos     bigint not null default 0 check (valor_pago_centavos >= 0),
  pago_em                 date,                               -- data efetiva
  observacao_financeira   text check (length(observacao_financeira) <= 500),
  criado_em               timestamptz not null default now(),
  atualizado_em           timestamptz not null default now(),
  unique (clinica_id, id),
  unique (venda_id, numero),
  foreign key (clinica_id, venda_id) references public.vendas (clinica_id, id),
  foreign key (clinica_id, pessoa_id) references public.pessoas (clinica_id, id),
  foreign key (clinica_id, forma_pagamento_id) references public.formas_pagamento (clinica_id, id),
  check (status <> 'paga' or (valor_pago_centavos >= valor_centavos and pago_em is not null))
);

create index parcelas_vencimento on public.parcelas (clinica_id, status, vencimento);
create index parcelas_pessoa on public.parcelas (pessoa_id);

alter table public.tarefas
  add foreign key (clinica_id, parcela_id) references public.parcelas (clinica_id, id);
create unique index tarefas_uma_por_parcela on public.tarefas (parcela_id)
  where status = 'pendente' and parcela_id is not null;

-- ─── Pagamentos (o que efetivamente entrou) ──────────────────────────────────

create table public.pagamentos (
  id                  uuid primary key default gen_random_uuid(),
  clinica_id          uuid not null references public.clinicas (id),
  parcela_id          uuid not null,
  valor_centavos      bigint not null check (valor_centavos > 0),
  pago_em             date not null default (now() at time zone 'America/Sao_Paulo')::date,
  forma_pagamento_id  uuid,
  observacao          text check (length(observacao) <= 500),
  registrado_por      uuid default auth.uid(),
  -- Pagamento lançado por engano é estornado, nunca apagado.
  estornado_em        timestamptz,
  estorno_motivo      text,
  criado_em           timestamptz not null default now(),
  foreign key (clinica_id, parcela_id) references public.parcelas (clinica_id, id),
  foreign key (clinica_id, forma_pagamento_id) references public.formas_pagamento (clinica_id, id),
  check ((estornado_em is null) = (estorno_motivo is null))
);

create index pagamentos_parcela on public.pagamentos (parcela_id);
create index pagamentos_data on public.pagamentos (clinica_id, pago_em);

-- =============================================================================
-- Gatilhos e funções
-- =============================================================================

-- Numeração sequencial de orçamentos por clínica (nova versão mantém o número).
create or replace function public.numerar_orcamento()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  if new.numero = 0 then
    perform pg_advisory_xact_lock(hashtext('orcamento:' || new.clinica_id));
    select coalesce(max(numero), 0) + 1 into new.numero
      from public.orcamentos where clinica_id = new.clinica_id;
  end if;
  return new;
end;
$$;

create trigger numerar_orcamento
  before insert on public.orcamentos
  for each row execute function public.numerar_orcamento();

-- Valor total do orçamento = soma dos itens (quando há itens).
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
             from public.orcamento_itens i where i.orcamento_id = v_orcamento), 0)
   where o.id = v_orcamento;
  return null;
end;
$$;

create trigger recalcular_orcamento
  after insert or update or delete on public.orcamento_itens
  for each row execute function public.recalcular_orcamento();

-- Registrar uma venda fecha a negociação: move para a etapa "Fechou", grava o
-- valor fechado e marca o orçamento como aprovado.
create or replace function public.ao_registrar_venda()
returns trigger
language plpgsql
as $$
declare
  v_etapa_fechou uuid;
begin
  if new.tipo = 'venda' then
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

create trigger ao_registrar_venda
  after insert on public.vendas
  for each row execute function public.ao_registrar_venda();

-- Cancelar uma venda exige a administradora e cancela as parcelas em aberto.
create or replace function public.ao_cancelar_venda()
returns trigger
language plpgsql
as $$
begin
  if new.status = 'cancelada' and old.status <> 'cancelada' then
    if auth.uid() is not null and not public.eh_admin(new.clinica_id) then
      raise exception 'Somente a administradora pode cancelar uma venda.' using errcode = '42501';
    end if;
    update public.parcelas set status = 'cancelada'
     where venda_id = new.id and status in ('pendente', 'parcial');
  end if;
  return new;
end;
$$;

create trigger ao_cancelar_venda
  after update of status on public.vendas
  for each row execute function public.ao_cancelar_venda();

-- Gera entrada + parcelas mensais. A diferença de centavos vai para a última.
create or replace function public.gerar_parcelas(
  p_venda uuid,
  p_primeiro_vencimento date,
  p_vencimento_entrada date default null
)
returns int
language plpgsql
as $$
declare
  v public.vendas;
  v_restante bigint;
  v_valor bigint;
  i int;
begin
  select * into v from public.vendas where id = p_venda;
  if v.id is null then
    raise exception 'Venda não encontrada ou sem permissão' using errcode = 'P0002';
  end if;
  if exists (select 1 from public.parcelas where venda_id = p_venda) then
    raise exception 'As parcelas desta venda já foram geradas.' using errcode = 'P0001';
  end if;

  if v.entrada_centavos > 0 then
    insert into public.parcelas (clinica_id, venda_id, pessoa_id, numero, valor_centavos, vencimento, forma_pagamento_id)
    values (v.clinica_id, v.id, v.pessoa_id, 0, v.entrada_centavos,
            coalesce(p_vencimento_entrada, v.fechada_em), v.forma_pagamento_id);
  end if;

  v_restante := v.valor_final_centavos - v.entrada_centavos;
  if v_restante > 0 then
    for i in 1 .. v.quantidade_parcelas loop
      v_valor := case when i = v.quantidade_parcelas
                      then v_restante - v.valor_parcela_centavos * (v.quantidade_parcelas - 1)
                      else v.valor_parcela_centavos end;
      insert into public.parcelas (clinica_id, venda_id, pessoa_id, numero, valor_centavos, vencimento, forma_pagamento_id)
      values (v.clinica_id, v.id, v.pessoa_id, i, v_valor,
              (p_primeiro_vencimento + make_interval(months => i - 1))::date, v.forma_pagamento_id);
    end loop;
  end if;

  return (select count(*) from public.parcelas where venda_id = p_venda);
end;
$$;

-- Pagamentos só podem ser estornados (com motivo), nunca editados.
create or replace function public.proteger_pagamento()
returns trigger
language plpgsql
as $$
begin
  if (to_jsonb(new) - array['estornado_em', 'estorno_motivo'])
     is distinct from (to_jsonb(old) - array['estornado_em', 'estorno_motivo']) then
    raise exception 'Pagamentos não podem ser editados; estorne e registre novamente.'
      using errcode = 'P0001';
  end if;
  if old.estornado_em is not null then
    raise exception 'Este pagamento já foi estornado.' using errcode = 'P0001';
  end if;
  return new;
end;
$$;

create trigger proteger_pagamento
  before update on public.pagamentos
  for each row execute function public.proteger_pagamento();

-- Recalcula valor pago, data efetiva e status da parcela a partir dos pagamentos.
create or replace function public.recalcular_parcela()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare
  v_pago bigint;
  v_data date;
begin
  select coalesce(sum(valor_centavos), 0), max(pago_em) into v_pago, v_data
    from public.pagamentos where parcela_id = new.parcela_id and estornado_em is null;

  update public.parcelas p set
    valor_pago_centavos = v_pago,
    pago_em = case when v_pago > 0 then v_data end,
    status = case
      when p.status in ('cancelada', 'renegociada') then p.status
      when v_pago >= p.valor_centavos then 'paga'
      when v_pago > 0 then 'parcial'
      else 'pendente'
    end::public.status_parcela
  where p.id = new.parcela_id;

  if tg_op = 'INSERT' then
    insert into public.interacoes (clinica_id, pessoa_id, tipo, descricao, usuario_id)
    select pa.clinica_id, pa.pessoa_id, 'pagamento_recebido',
           'Pagamento de ' || public.formatar_brl(new.valor_centavos) || ' recebido em '
             || to_char(new.pago_em, 'DD/MM/YYYY'),
           new.registrado_por
      from public.parcelas pa where pa.id = new.parcela_id;
  end if;
  return null;
end;
$$;

create trigger recalcular_parcela
  after insert or update on public.pagamentos
  for each row execute function public.recalcular_parcela();

-- LEMBRETE FINANCEIRO AUTOMÁTICO
-- Toda parcela em aberto tem uma tarefa "confirmar pagamento" na data prevista.
-- Muda a data → a tarefa acompanha. Pagou → tarefa concluída. Cancelou → cancelada.
-- Se passar da data sem pagamento, a tarefa continua pendente e aparece no painel
-- como "Pagamento em atraso".
create or replace function public.sincronizar_tarefa_parcela()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare
  v_pessoa     public.pessoas;
  v_venda      public.vendas;
  v_forma      text;
  v_saldo      bigint := new.valor_centavos - new.valor_pago_centavos;
  v_chave      text := 'pagamento:' || new.id;
  v_titulo     text;
  v_descricao  text;
  v_mensagem   text;
begin
  select * into v_pessoa from public.pessoas where id = new.pessoa_id;
  select * into v_venda from public.vendas where id = new.venda_id;
  select nome into v_forma from public.formas_pagamento where id = new.forma_pagamento_id;

  if new.status in ('pendente', 'parcial') then
    v_titulo := 'Pagamento previsto — ' || v_pessoa.nome || ' — ' || public.formatar_brl(v_saldo);
    v_descricao := case when new.numero = 0 then 'Entrada'
                        else 'Parcela ' || new.numero || ' de ' || v_venda.quantidade_parcelas end
                   || ' · vencimento ' || to_char(new.vencimento, 'DD/MM/YYYY')
                   || coalesce(' · ' || v_forma, '')
                   || case when new.valor_pago_centavos > 0
                           then ' · já pago ' || public.formatar_brl(new.valor_pago_centavos) else '' end;
    -- Mensagem da biblioteca ("Pagamento previsto"); o painel troca por cobrança amigável
    -- ou pagamento pendente conforme o atraso.
    v_mensagem := public.renderizar_mensagem(new.clinica_id, 'confirmar_pagamento', new.pessoa_id, null,
                    jsonb_build_object('valor', public.formatar_brl(v_saldo),
                                       'vencimento', to_char(new.vencimento, 'DD/MM')));

    update public.tarefas
       set titulo = v_titulo, descricao = v_descricao, vence_em = new.vencimento,
           mensagem_sugerida = v_mensagem
     where parcela_id = new.id and status = 'pendente';

    if not found then
      insert into public.tarefas (
        clinica_id, pessoa_id, oportunidade_id, parcela_id, tipo, categoria, titulo, descricao,
        vence_em, prioridade, responsavel_id, origem, regra, mensagem_sugerida, chave_dedupe
      ) values (
        new.clinica_id, new.pessoa_id, v_venda.oportunidade_id, new.id, 'confirmar_pagamento',
        'financeiro', v_titulo, v_descricao, new.vencimento, 'alta', v_pessoa.responsavel_id,
        'automatica', 'R-FIN-01', v_mensagem, v_chave
      );
    end if;

  elsif new.status = 'paga' then
    update public.tarefas
       set status = 'concluida', resultado = 'Pagamento registrado'
     where parcela_id = new.id and status = 'pendente';

  else -- cancelada / renegociada
    update public.tarefas
       set status = 'cancelada', cancelada_motivo = 'Parcela ' || new.status::text
     where parcela_id = new.id and status = 'pendente';
  end if;

  return null;
end;
$$;

create trigger sincronizar_tarefa_parcela
  after insert or update of status, vencimento, valor_centavos, valor_pago_centavos on public.parcelas
  for each row execute function public.sincronizar_tarefa_parcela();

-- ─── Gatilhos comuns e RLS ───────────────────────────────────────────────────

do $$
declare
  t text;
begin
  foreach t in array array['orcamentos', 'vendas', 'parcelas'] loop
    execute format(
      'create trigger definir_atualizado_em before update on public.%I
         for each row execute function public.definir_atualizado_em()', t);
  end loop;
  foreach t in array array['orcamentos', 'orcamento_itens', 'vendas', 'parcelas', 'pagamentos'] loop
    execute format(
      'create trigger auditoria after insert or update or delete on public.%I
         for each row execute function public.registrar_auditoria()', t);
    execute format('alter table public.%I enable row level security', t);
    -- Ver valores exige permissão financeira; registrar (ex.: pagamento) basta ser membro.
    execute format(
      'create policy financeiro_ler on public.%I for select to authenticated
         using (public.pode_ver_financeiro(clinica_id))', t);
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

-- Itens de orçamento podem ser removidos enquanto o orçamento é rascunho.
create policy item_remover on public.orcamento_itens for delete to authenticated
  using (
    clinica_id in (select public.minhas_clinicas())
    and exists (select 1 from public.orcamentos o where o.id = orcamento_id and o.status = 'rascunho')
  );

-- ---------------------------------------------------------------------------
-- 20260929120300_visoes_e_inicializacao.sql
-- ---------------------------------------------------------------------------

-- =============================================================================
-- Migração 4/4: visões de leitura e inicialização da clínica
--   v_contatos            → cada contato com status, etapa atual, procedimento
--                            de interesse e próxima ação (data incluída)
--   v_parcelas            → parcelas com situação (a vencer, vence hoje, atrasada…)
--   v_painel_tarefas      → o que fazer hoje (inclui atrasadas), com o texto do painel
--   v_pendencias_financeiras, v_resumo_financeiro_mensal, v_funil
--   inicializar_clinica() → cria a clínica com catálogos e parâmetros padrão
--
-- Todas as visões usam security_invoker: respeitam o RLS de quem consulta.
-- =============================================================================

-- ─── Contatos ────────────────────────────────────────────────────────────────

create view public.v_contatos with (security_invoker = true) as
with base as (
  select
    p.*,
    (now() at time zone c.fuso)::date as hoje,
    coalesce((select r.periodo_meses from public.regras_followup r
               where r.clinica_id = p.clinica_id and r.situacao = 'paciente_inativo'), 6) as meses_inativo,
    greatest(
      p.ultimo_atendimento_informado,
      (select max((a.inicio at time zone c.fuso)::date)
         from public.agendamentos a
        where a.pessoa_id = p.id and a.status = 'compareceu')
    ) as ultimo_atendimento_em,
    (select max(o.fechada_em)::date from public.oportunidades o
      where o.pessoa_id = p.id and o.status = 'ganha') as ultima_venda_em
  from public.pessoas p
  join public.clinicas c on c.id = p.clinica_id
)
select
  b.id,
  b.clinica_id,
  b.tipo_cadastro,
  b.nome,
  b.apelido_tratamento,
  b.data_nascimento,
  b.telefone_e164,
  b.whatsapp_e164,
  b.email,
  b.cep, b.logradouro, b.numero, b.complemento, b.bairro, b.cidade, b.uf,
  b.origem_id,
  orig.nome                                 as origem,
  b.responsavel_id,
  resp.nome                                 as responsavel,
  b.temperatura,
  b.observacoes_comerciais,
  b.primeiro_contato_em,
  b.ultimo_contato_em,
  b.ultimo_atendimento_em,
  b.ultimo_atendimento_informado,
  b.ultimo_atendimento_faixa,
  b.paciente_desde,
  b.em_tratamento,
  b.retorno_previsto_em,
  b.nao_contatar_motivo,
  b.criado_em,
  b.consentimento_contato,
  b.consentimento_marketing,
  b.nao_contatar,
  b.arquivado_em,
  -- Relacionamento com a clínica
  case
    when b.tipo_cadastro = 'novo_contato' and b.ultima_venda_em is null then 'lead'
    when b.em_tratamento
      or greatest(b.ultimo_atendimento_em, b.ultima_venda_em)
         >= b.hoje - make_interval(months => b.meses_inativo) then 'paciente_ativo'
    else 'paciente_inativo'
  end                                       as relacionamento,
  -- Status atual
  case
    when b.arquivado_em is not null then 'arquivado'
    when b.nao_contatar then 'nao_contatar'
    when op.status = 'aberta' then 'em_negociacao'
    when op.status = 'pausada' then 'sem_resposta'
    when b.em_tratamento then 'em_tratamento'
    else 'sem_negociacao'
  end                                       as status_atual,
  -- Funil (uma única negociação em andamento por pessoa)
  op.id                                     as oportunidade_id,
  op.procedimento_id                        as procedimento_interesse_id,
  proc.nome                                 as procedimento_interesse,
  op.etapa_id,
  et.nome                                   as etapa_atual,
  op.etapa_desde,
  (b.hoje - (op.etapa_desde at time zone 'America/Sao_Paulo')::date) as dias_na_etapa,
  op.valor_estimado_centavos,
  -- Próxima ação = tarefa pendente mais próxima
  prox.id                                   as proxima_tarefa_id,
  prox.titulo                               as proxima_acao,
  prox.vence_em                             as proxima_acao_em,
  prox.horario                              as proxima_acao_horario
from base b
left join public.origens orig on orig.id = b.origem_id
left join public.usuarios resp on resp.id = b.responsavel_id
left join public.oportunidades op on op.pessoa_id = b.id and op.status in ('aberta', 'pausada')
left join public.procedimentos proc on proc.id = op.procedimento_id
left join public.etapas_funil et on et.id = op.etapa_id
left join lateral (
  select t.id, t.titulo, t.vence_em, t.horario
    from public.tarefas t
   where t.pessoa_id = b.id and t.status = 'pendente'
   order by t.vence_em, t.horario nulls last,
            array_position(array['urgente', 'alta', 'normal', 'baixa']::public.prioridade_tarefa[], t.prioridade)
   limit 1
) prox on true;

-- ─── Parcelas com situação calculada ─────────────────────────────────────────

create view public.v_parcelas with (security_invoker = true) as
select
  pa.*,
  pe.nome                                           as pessoa_nome,
  fp.nome                                           as forma_pagamento,
  v.quantidade_parcelas,
  pa.valor_centavos - pa.valor_pago_centavos        as saldo_centavos,
  (now() at time zone c.fuso)::date - pa.vencimento as dias_atraso,
  case
    when pa.status in ('paga', 'cancelada', 'renegociada') then pa.status::text
    when pa.vencimento < (now() at time zone c.fuso)::date then 'atrasada'
    when pa.vencimento = (now() at time zone c.fuso)::date then 'vence_hoje'
    else 'a_vencer'
  end                                               as situacao
from public.parcelas pa
join public.pessoas pe on pe.id = pa.pessoa_id
join public.vendas v on v.id = pa.venda_id
join public.clinicas c on c.id = pa.clinica_id
left join public.formas_pagamento fp on fp.id = pa.forma_pagamento_id;

create view public.v_pendencias_financeiras with (security_invoker = true) as
select * from public.v_parcelas where situacao in ('vence_hoje', 'atrasada');

-- ─── Painel "O que eu tenho que fazer hoje?" ─────────────────────────────────

create view public.v_painel_tarefas with (security_invoker = true) as
with t as (
  select
    t.*,
    (now() at time zone c.fuso)::date as hoje,
    pe.nome as pessoa_nome,
    pe.whatsapp_e164,
    pe.telefone_e164,
    pa.valor_centavos - pa.valor_pago_centavos as saldo_parcela_centavos
  from public.tarefas t
  join public.clinicas c on c.id = t.clinica_id
  join public.pessoas pe on pe.id = t.pessoa_id
  left join public.parcelas pa on pa.id = t.parcela_id
  where t.status = 'pendente'
    and t.vence_em <= (now() at time zone c.fuso)::date
)
select
  t.id, t.clinica_id, t.pessoa_id, t.oportunidade_id, t.agendamento_id, t.parcela_id,
  t.tipo, t.categoria, t.titulo, t.descricao, t.vence_em, t.horario, t.prioridade,
  t.responsavel_id, t.origem, t.mensagem_sugerida, t.modelo_mensagem_id,
  t.pessoa_nome, t.whatsapp_e164, t.telefone_e164,
  t.hoje - t.vence_em as dias_atraso,
  case
    when t.tipo = 'confirmar_pagamento' and t.vence_em = t.hoje then 'Pagamento previsto hoje'
    when t.tipo = 'confirmar_pagamento' then
      'Pagamento em atraso há ' || (t.hoje - t.vence_em)
      || case when t.hoje - t.vence_em = 1 then ' dia' else ' dias' end
    when t.vence_em = t.hoje then 'Para hoje'
    else 'Atrasada há ' || (t.hoje - t.vence_em)
      || case when t.hoje - t.vence_em = 1 then ' dia' else ' dias' end
  end as situacao_prazo,
  -- Texto pronto para o painel
  case
    when t.tipo = 'confirmar_pagamento' and t.saldo_parcela_centavos is not null then
      case when t.vence_em = t.hoje then 'Pagamento previsto hoje'
           else 'Pagamento em atraso' end
      || ' — ' || t.pessoa_nome || ' — ' || public.formatar_brl(t.saldo_parcela_centavos)
    else t.titulo
  end as texto_painel,
  -- Ordem sugerida: urgência, atraso e horário
  array_position(array['urgente', 'alta', 'normal', 'baixa']::public.prioridade_tarefa[], t.prioridade) as ordem_prioridade
from t;

-- ─── Resumos ─────────────────────────────────────────────────────────────────

-- Vendido (competência) × recebido (caixa) por mês.
create view public.v_resumo_financeiro_mensal with (security_invoker = true) as
with vendido as (
  select clinica_id, date_trunc('month', fechada_em)::date as mes, sum(valor_final_centavos) as vendido_centavos
    from public.vendas where status = 'ativa' and tipo = 'venda'
   group by 1, 2
), recebido as (
  select clinica_id, date_trunc('month', pago_em)::date as mes, sum(valor_centavos) as recebido_centavos
    from public.pagamentos where estornado_em is null
   group by 1, 2
), previsto as (
  select clinica_id, date_trunc('month', vencimento)::date as mes,
         sum(valor_centavos - valor_pago_centavos) as a_receber_centavos
    from public.parcelas where status in ('pendente', 'parcial')
   group by 1, 2
)
select
  coalesce(v.clinica_id, r.clinica_id, p.clinica_id) as clinica_id,
  coalesce(v.mes, r.mes, p.mes)                      as mes,
  coalesce(v.vendido_centavos, 0)                    as vendido_centavos,
  coalesce(r.recebido_centavos, 0)                   as recebido_centavos,
  coalesce(p.a_receber_centavos, 0)                  as a_receber_centavos
from vendido v
full join recebido r on r.clinica_id = v.clinica_id and r.mes = v.mes
full join previsto p on p.clinica_id = coalesce(v.clinica_id, r.clinica_id)
                    and p.mes = coalesce(v.mes, r.mes);

-- Quantidade e valor por etapa (negociações em andamento).
create view public.v_funil with (security_invoker = true) as
select
  e.clinica_id, e.id as etapa_id, e.nome as etapa, e.ordem, e.tipo, e.cor,
  count(o.id)                                   as quantidade,
  coalesce(sum(o.valor_estimado_centavos), 0)   as valor_estimado_centavos
from public.etapas_funil e
left join public.oportunidades o on o.etapa_id = e.id and o.status in ('aberta', 'pausada')
where e.ativo
group by e.clinica_id, e.id, e.nome, e.ordem, e.tipo, e.cor;

-- ─── Inicialização da clínica (executar uma vez, pelo servidor) ──────────────

create or replace function public.inicializar_clinica(p_nome text)
returns uuid
language plpgsql
security definer
set search_path = public
as $$
declare
  c uuid;
begin
  insert into public.clinicas (nome, configuracoes)
  values (p_nome, jsonb_build_object(
    'horario', jsonb_build_object('dias', jsonb_build_array(1, 2, 3, 4, 5), 'inicio', '08:00', 'fim', '19:00'),
    'dias_fechados_extra', '[]'::jsonb,
    'fecha_pontos_facultativos', false,
    'sla_primeiro_contato_min', 15,
    'intervalo_min_contato_dias', 3,
    'intervalo_min_campanha_dias', 30,
    'limite_reativacao_dia', 10,
    'validade_orcamento_dias', 30,
    -- (Prazos e tentativas de follow-up ficam na tabela regras_followup.)
    -- Quantos dias as negociações encerradas (Fechou / Não fechou) ficam visíveis no funil.
    'dias_encerradas_no_funil', 30
  ))
  returning id into c;

  insert into public.profissionais (clinica_id, nome, cor) values (c, 'Dentista responsável', '#B08D57');

  insert into public.procedimentos (clinica_id, nome, categoria, ciclo_retorno_meses, ordem) values
    (c, 'Facetas de porcelana',      'Estética',      null, 1),
    (c, 'Facetas/lentes em resina',  'Estética',      null, 2),
    (c, 'Estética odontológica',     'Estética',      null, 3),
    (c, 'Clareamento dental',        'Estética',      12,   4),
    (c, 'Periodontia',               'Periodontia',   6,    5),
    (c, 'Implantes',                 'Reabilitação',  null, 6),
    (c, 'Manutenção e limpeza',      'Prevenção',     6,    7),
    (c, 'Outros serviços',           'Outros',        null, 99);

  insert into public.origens (clinica_id, nome, tipo, canal, ordem) values
    (c, 'Instagram',                   'organico',  'instagram',       1),
    (c, 'Anúncio Instagram/Facebook',  'pago',      'instagram',       2),
    (c, 'Google',                      'organico',  'google',          3),
    (c, 'Anúncio Google',              'pago',      'google',          4),
    (c, 'Site',                        'organico',  'outro',           5),
    (c, 'Indicação de paciente',       'indicacao', 'indicacao',       6),
    (c, 'Indicação de profissional',   'indicacao', 'indicacao',       7),
    (c, 'WhatsApp',                    'organico',  'whatsapp',        8),
    (c, 'Passou em frente à clínica',  'organico',  'outro',           9),
    (c, 'Paciente antigo',             'interno',   'paciente_antigo', 10),
    (c, 'Outro',                       'organico',  'outro',           99);

  -- Etapas editáveis (nome, cor, prazo). O "marco"/"resultado" diz ao sistema o papel de cada uma.
  insert into public.etapas_funil (clinica_id, nome, ordem, tipo, resultado, marco, sla_dias, cor) values
    (c, 'Novo contato',            1,  'aberta', null,           'novo_contato',          0,    '#C9A96E'),
    (c, 'Em contato',              2,  'aberta', null,           'em_contato',            3,    '#B99A62'),
    (c, 'Avaliação agendada',      3,  'aberta', null,           'avaliacao_agendada',    null, '#A88B57'),
    -- Passou pela consulta (onde o orçamento é apresentado) e ainda está decidindo.
    (c, 'Consulta realizada',      4,  'aberta', null,           'avaliacao_realizada',   14,   '#8A6A3A'),
    (c, 'Desmarcou',               5,  'aberta', null,           'desmarcou',             7,    '#B4533A'),
    (c, 'Sem resposta',            6,  'perda',  'sem_resposta', null,                    null, '#B3AAA0'),
    (c, 'Reativação',              7,  'aberta', null,           'reativacao',            30,   '#5F8A6A'),
    (c, 'Fechou',                  8,  'ganho',  'fechou',       null,                    null, '#5E7D5A'),
    (c, 'Não fechou',              9,  'perda',  'nao_fechou',   null,                    null, '#9A8F84'),
    (c, 'Desistiu',                10, 'perda',  'desistiu',     null,                    null, '#8A8178');

  insert into public.motivos (clinica_id, nome, aplica_a, retorno_sugerido_dias, grupo_perda, ordem) values
    (c, 'Valor alto',                        'nao_fechou', 30,   'preco',         1),
    (c, 'Forma de pagamento',                'nao_fechou', 15,   'preco',         2),
    (c, 'Precisa pensar',                    'nao_fechou', 7,    'adiou',         3),
    (c, 'Conversar com a família',           'nao_fechou', 7,    'adiou',         4),
    (c, 'Medo ou insegurança',               'nao_fechou', 10,   'outro',         5),
    (c, 'Pesquisando outras clínicas',       'nao_fechou', 10,   'outro_local',   6),
    (c, 'Não é o momento',                   'nao_fechou', 90,   'adiou',         7),
    (c, 'Momento financeiro',                'nao_fechou', 120,  'preco',         8),
    (c, 'Escolheu outra clínica',            'nao_fechou', 365,  'outro_local',   9),
    (c, 'Parou de responder',                'nao_fechou', 90,   'nao_respondeu', 10),
    (c, 'Outro',                             'nao_fechou', null, 'outro',         99),
    (c, 'Sem interesse no momento',          'desistiu',   180,  'desistiu',      1),
    (c, 'Fez o tratamento em outro lugar',   'desistiu',   365,  'outro_local',   2),
    (c, 'Mudou de cidade',                   'desistiu',   null, 'desistiu',      3),
    (c, 'Outro',                             'desistiu',   null, 'desistiu',      99),
    (c, 'Imprevisto pessoal',                'desmarcou',  null, null,            1),
    (c, 'Trabalho',                          'desmarcou',  null, null,            2),
    (c, 'Saúde',                             'desmarcou',  null, null,            3),
    (c, 'Financeiro',                        'desmarcou',  null, null,            4),
    (c, 'Não informou',                      'desmarcou',  null, null,            5),
    (c, 'Outro',                             'desmarcou',  null, null,            99);

  insert into public.formas_pagamento (clinica_id, nome, permite_parcelamento, max_parcelas, recebe_na_hora, ordem) values
    (c, 'PIX',                          true,  24, false, 1),
    (c, 'Cartão à vista',               false, 1,  true,  2),
    (c, 'Cartão parcelado',             true,  12, true,  3),
    (c, 'Dinheiro',                     true,  24, false, 4),
    (c, 'Transferência',                true,  24, false, 5);

  -- Mensagens prontas (editáveis em Mensagens). Tom: elegante, cordial, humano e sem pressão.
  -- "situacao" liga o modelo a uma tarefa específica; "padrao" é o sugerido na categoria.
  insert into public.modelos_mensagem (clinica_id, categoria, situacao, padrao, titulo, texto) values
    -- Primeiro contato
    (c, 'primeiro_contato', 'primeiro_contato', true, 'Boas-vindas',
     'Olá, {{nome}}! Tudo bem? Aqui é do {{clinica}}. Recebemos o seu contato e fico muito feliz com o seu interesse em {{procedimento}}. Posso te contar como funciona a avaliação e encontrar um horário que seja confortável para você?'),
    (c, 'primeiro_contato', 'follow_up', false, 'Convite para a avaliação',
     'Olá, {{nome}}! Que bom falar com você. O primeiro passo para {{procedimento}} é uma avaliação feita com calma, para entendermos exatamente o que você deseja. Qual período costuma ser melhor para você: manhã ou tarde?'),
    -- Passou pela primeira consulta (pensando)
    (c, 'pos_consulta', 'acompanhar_decisao', true, 'Depois da consulta',
     'Olá, {{nome}}! Tudo bem? Foi um prazer receber você na consulta. Sei que é uma decisão importante: se ficou alguma dúvida sobre {{procedimento}}, estou por aqui para ajudar — sem pressa.'),
    (c, 'pos_consulta', null, false, 'Conseguiu avaliar com calma?',
     'Olá, {{nome}}! Tudo bem? Estou passando para saber se conseguiu avaliar com calma as informações sobre {{procedimento}}. Se quiser, posso te ajudar com qualquer dúvida e verificar um novo horário para você.'),
    (c, 'pos_consulta', 'follow_up_orcamento', false, 'Sobre o plano de tratamento',
     'Olá, {{nome}}! Espero que esteja bem. Fico à disposição caso queira rever algum ponto do plano de tratamento ou conversar sobre as condições de pagamento. Podemos encontrar juntos o formato que fizer mais sentido para você.'),
    -- Paciente não fechou
    (c, 'nao_fechou', 'retorno_por_motivo', true, 'Retomar com leveza',
     'Olá, {{nome}}! Tudo bem? Lembrei de você e quis saber como está. Se ainda tiver vontade de realizar {{procedimento}}, será um prazer conversar sobre as possibilidades — sem compromisso.'),
    (c, 'nao_fechou', null, false, 'Novas possibilidades',
     'Olá, {{nome}}! Como vai? Queria te contar que temos algumas possibilidades de condições para {{procedimento}} que talvez façam sentido para você neste momento. Se quiser, te explico tudo com calma.'),
    -- Paciente sem resposta
    (c, 'sem_resposta', 'reabrir_sem_resposta', true, 'Retomar o contato',
     'Olá, {{nome}}! Tudo bem? Imagino que a rotina esteja corrida. Deixo esta mensagem só para dizer que seguimos à disposição sobre {{procedimento}}. Quando for um bom momento, é só me responder por aqui.'),
    (c, 'sem_resposta', null, false, 'Porta aberta',
     'Olá, {{nome}}! Não quero incomodar — esta é só uma mensagem para deixar a porta aberta. Quando quiser retomar a conversa sobre {{procedimento}}, será um prazer atender você.'),
    -- Paciente desmarcou
    (c, 'desmarcou', 'recuperar_desmarcacao', true, 'Desmarcou',
     'Olá, {{nome}}! Tudo bem? Vi que você precisou desmarcar {{consulta}} do dia {{data}}. Sem problema! Quando for melhor para você, encontramos um novo horário — é só me dizer os dias e horários que ficam mais fáceis.'),
    (c, 'desmarcou', 'recuperar_falta', false, 'Faltou à consulta',
     'Olá, {{nome}}! Sentimos sua falta na consulta do dia {{data}}. Está tudo bem? Se quiser, reservo um novo horário para você — é só me dizer o melhor dia.'),
    -- Confirmação
    (c, 'confirmacao', 'confirmar_agendamento', true, 'Confirmar presença',
     'Olá, {{nome}}! Tudo bem? Passando para confirmar {{consulta}} com {{dentista}} no dia {{data}}, às {{horario}}. Podemos contar com a sua presença? Se precisar ajustar o horário, é só me avisar.'),
    -- Remarcação
    (c, 'remarcacao', null, true, 'Novo horário',
     'Olá, {{nome}}! Tudo bem? Vamos encontrar um novo horário para {{consulta}}? Me diga os dias e períodos que ficam melhores para você, que eu verifico a agenda com carinho.'),
    (c, 'remarcacao', 'clinica_cancelou', false, 'A clínica precisou remarcar',
     'Olá, {{nome}}! Tudo bem? Precisamos reagendar {{consulta}} do dia {{data}} — pedimos desculpas pelo transtorno. Qual dia e horário ficam melhores para você?'),
    -- Reativação
    (c, 'reativacao', 'reativacao', true, 'Que saudade',
     'Olá, {{nome}}! Tudo bem? Faz um tempinho que não nos vemos aqui no {{clinica}} e lembrei de você. Que tal agendarmos uma avaliação para cuidarmos do seu sorriso? Será um prazer receber você novamente.'),
    -- Acompanhamento pós-atendimento
    (c, 'pos_atendimento', null, true, 'Como você está?',
     'Olá, {{nome}}! Tudo bem? Passando para saber como você está depois do atendimento. Se sentir qualquer coisa diferente ou tiver alguma dúvida, pode me chamar por aqui — estamos à disposição.'),
    (c, 'pos_atendimento', 'agendar_tratamento', false, 'Início do tratamento',
     'Olá, {{nome}}! Que alegria ter você conosco nesta nova etapa. Vamos combinar a data de início do seu tratamento? Me diga os dias e horários que ficam melhores para você.'),
    (c, 'pos_atendimento', 'pos_tratamento', false, 'Revisão após o tratamento',
     'Olá, {{nome}}! Tudo bem? Já faz um tempinho desde o seu tratamento aqui no {{clinica}}. Que tal agendarmos uma revisão para cuidarmos do resultado? Será um prazer rever você.'),
    -- Pagamentos (o painel escolhe conforme o vencimento)
    (c, 'pagamento_previsto', 'confirmar_pagamento', true, 'Lembrete antes do vencimento',
     'Olá, {{nome}}! Tudo bem? Passando só para lembrar, com antecedência, do pagamento de {{valor}} previsto para {{vencimento}}. Qualquer dúvida, estou por aqui.'),
    (c, 'cobranca_amigavel', null, true, 'Lembrete gentil',
     'Olá, {{nome}}! Tudo bem? Passando com carinho para lembrar do pagamento de {{valor}}, com vencimento em {{vencimento}}, que ainda consta em aberto por aqui. Se já tiver feito, por favor desconsidere — e, se precisar, envio os dados novamente.'),
    (c, 'pagamento_pendente', null, true, 'Pagamento em aberto',
     'Olá, {{nome}}! Tudo bem? O pagamento de {{valor}}, previsto para {{vencimento}}, segue em aberto aqui. Pode ter sido apenas um descompasso de datas — se preferir, podemos combinar juntos a melhor forma de acertar. Fico à disposição.'),
    -- Paciente antigo
    (c, 'paciente_antigo', 'manutencao', true, 'Hora da manutenção',
     'Olá, {{nome}}! Tudo bem? Está chegando a hora da sua manutenção de {{procedimento}}. Vamos reservar um horário para manter o resultado sempre bonito?'),
    (c, 'paciente_antigo', null, false, 'Quanto tempo!',
     'Olá, {{nome}}! Quanto tempo! Aqui é do {{clinica}}. Atualizamos o seu cadastro e quis saber como você está. Quando quiser, será um prazer receber você para uma revisão.');

  -- Regras de follow-up (tudo editável em Configurações).
  --   prazo_dias: 1ª ação N dias após o evento · intervalos: novas tentativas (dias após a anterior)
  --   ao_esgotar: o que fazer se continuar sem resposta
  insert into public.regras_followup (clinica_id, situacao, nome, quando, ativa, tipo_tarefa, titulo_modelo,
                                      prazo_dias, intervalos, prioridade, ao_esgotar, espera_reativacao_dias,
                                      periodo_meses, mensagem_situacao) values
    (c, 'novo_contato', 'Novo lead', 'Quando alguém é cadastrado como novo contato', true,
     'primeiro_contato', 'Fazer o primeiro contato com {primeiro_nome}', 0, '{1,2}', 'urgente', 'sem_resposta', null, null, 'primeiro_contato'),
    (c, 'em_contato', 'Demonstrou interesse', 'Quando a pessoa responde com interesse', true,
     'follow_up', 'Conduzir {primeiro_nome} para a avaliação', 1, '{3,4}', 'alta', 'sem_resposta', null, null, 'follow_up'),
    (c, 'confirmacao', 'Confirmar consulta', 'Quando uma avaliação ou consulta é agendada (prazo = dias úteis antes)', true,
     'confirmar_agendamento', 'Confirmar {consulta} de {primeiro_nome}', 1, '{}', 'normal', 'decidir', null, null, 'confirmar_agendamento'),
    (c, 'pos_consulta', 'Saiu da consulta sem fechar', 'Quando a pessoa passa pela consulta e ainda está decidindo', true,
     'acompanhar_decisao', 'Retomar com {primeiro_nome} depois da consulta', 3, '{4,7}', 'alta', 'sem_resposta', null, null, 'acompanhar_decisao'),
    (c, 'desmarcou', 'Desmarcou ou faltou', 'Quando uma consulta é desmarcada ou a pessoa não comparece', true,
     'recuperar_desmarcacao', 'Entrar em contato com {primeiro_nome} para remarcar', 1, '{3,4}', 'urgente', 'sem_resposta', null, null, 'recuperar_desmarcacao'),
    (c, 'sem_resposta', 'Parou de responder', 'Quando as tentativas terminam sem resposta', true,
     'reabrir_sem_resposta', 'Tentar novo contato com {primeiro_nome}', 7, '{14}', 'normal', 'reativacao', 60, null, 'reabrir_sem_resposta'),
    (c, 'nao_fechou', 'Não fechou', 'Quando a negociação não fecha — o prazo vem do motivo informado', true,
     'retorno_por_motivo', 'Retomar conversa com {primeiro_nome} sobre {procedimento}', null, '{}', 'baixa', 'decidir', null, null, 'retorno_por_motivo'),
    (c, 'fechou', 'Fechou', 'Quando a pessoa fecha o tratamento', true,
     'agendar_tratamento', 'Agendar o início do tratamento de {primeiro_nome}', 0, '{}', 'alta', 'decidir', null, null, 'agendar_tratamento'),
    (c, 'reativacao', 'Reativação', 'Quando a pessoa entra na etapa Reativação', true,
     'reativacao', 'Retomar contato com {primeiro_nome}', 0, '{21}', 'baixa', 'decidir', null, null, 'reativacao'),
    (c, 'paciente_inativo', 'Pacientes antigos sem atendimento', 'Pacientes sem atendimento há X meses (rotina diária, com limite por dia)', false,
     'reativacao', 'Reativar contato com {primeiro_nome}', 0, '{21}', 'baixa', 'decidir', null, 6, 'reativacao'),
    (c, 'manutencao', 'Manutenção devida', 'Tratamentos com retorno periódico (ex.: limpeza a cada 6 meses)', false,
     'manutencao', 'Lembrar {primeiro_nome} da manutenção', 0, '{21}', 'baixa', 'decidir', null, null, 'manutencao'),
    (c, 'pos_tratamento', 'Retorno após o tratamento', 'X meses depois de o tratamento ser concluído', true,
     'manutencao', 'Convidar {primeiro_nome} para a revisão', 0, '{21}', 'normal', 'decidir', null, 6, 'pos_tratamento');

  return c;
end;
$$;

-- Vincula um login existente a uma clínica com um papel (executar pelo servidor).
create or replace function public.adicionar_membro(
  p_clinica uuid,
  p_email text,
  p_papel public.papel_membro,
  p_pode_ver_financeiro boolean default true
)
returns uuid
language plpgsql
security definer
set search_path = public
as $$
declare
  v_usuario uuid;
  v_membro uuid;
begin
  select id into v_usuario from public.usuarios where lower(email) = lower(p_email);
  if v_usuario is null then
    raise exception 'Nenhum login encontrado para %', p_email using errcode = 'P0002';
  end if;
  insert into public.membros (clinica_id, usuario_id, papel, pode_ver_financeiro)
  values (p_clinica, v_usuario, p_papel, p_pode_ver_financeiro)
  on conflict (clinica_id, usuario_id)
    do update set papel = excluded.papel, pode_ver_financeiro = excluded.pode_ver_financeiro, ativo = true
  returning id into v_membro;
  return v_membro;
end;
$$;

-- Estas funções administrativas não podem ser chamadas pelo navegador.
revoke execute on function public.inicializar_clinica(text) from public, anon, authenticated;
revoke execute on function public.adicionar_membro(uuid, text, public.papel_membro, boolean) from public, anon, authenticated;

-- ---------------------------------------------------------------------------
-- 20260929120400_motor_de_acoes.sql
-- ---------------------------------------------------------------------------

-- =============================================================================
-- Migração 5: motor de ações ("o sistema cria as tarefas sozinho")
--
-- Três caminhos criam e encerram tarefas automaticamente:
--   1. Gatilhos: quando algo acontece (novo contato, agendamento, desmarcação,
--      orçamento apresentado, negociação encerrada…).
--   2. registrar_acao(): quando a usuária conclui uma tarefa ou registra um
--      contato, o próximo passo é criado conforme a cadência.
--   3. preparar_dia(): rotina diária (orçamentos expirados, reativação,
--      manutenção e garantia de que toda negociação tenha próxima ação).
--
-- Chaves de deduplicação (uma tarefa pendente por chave):
--   op:<oportunidade>   → a "próxima ação" comercial daquela negociação
--   ag:<agendamento>    → confirmação do agendamento
--   pessoa:<pessoa>     → reativação/manutenção de quem não está negociando
--   pagamento:<parcela> → lembrete financeiro (migração 3)
-- =============================================================================

-- ─── Calendário da clínica ───────────────────────────────────────────────────

create or replace function public.hoje_clinica(p_clinica uuid)
returns date
language sql stable security definer set search_path = public
as $$
  select (now() at time zone coalesce((select fuso from public.clinicas where id = p_clinica), 'America/Sao_Paulo'))::date;
$$;

create or replace function public.domingo_de_pascoa(p_ano int)
returns date
language plpgsql immutable
as $$
declare
  a int := p_ano % 19; b int := p_ano / 100; c int := p_ano % 100;
  d int := b / 4; e int := b % 4; f int := (b + 8) / 25; g int := (b - f + 1) / 3;
  h int := (19 * a + b - d - g + 15) % 30; i int := c / 4; k int := c % 4;
  l int := (32 + 2 * e + 2 * i - h - k) % 7; m int := (a + 11 * h + 22 * l) / 451;
begin
  return make_date(p_ano, (h + l - 7 * m + 114) / 31, ((h + l - 7 * m + 114) % 31) + 1);
end;
$$;

-- Mesma regra de src/lib/datas.ts: dias de funcionamento, feriados nacionais,
-- pontos facultativos (se a clínica fecha) e datas extras fechadas.
create or replace function public.eh_dia_util(p_clinica uuid, p_data date)
returns boolean
language plpgsql stable security definer set search_path = public
as $$
declare
  v_cfg    jsonb := (select configuracoes from public.clinicas where id = p_clinica);
  v_pascoa date := public.domingo_de_pascoa(extract(year from p_data)::int);
  v_dias   int[];
begin
  select coalesce(array_agg(x::int), array[1, 2, 3, 4, 5]) into v_dias
    from jsonb_array_elements_text(v_cfg -> 'horario' -> 'dias') x;
  if not extract(dow from p_data)::int = any (v_dias) then return false; end if;
  if to_char(p_data, 'MM-DD') in ('01-01', '04-21', '05-01', '09-07', '10-12', '11-02', '11-15', '11-20', '12-25')
     or p_data = v_pascoa - 2 then
    return false;
  end if;
  if coalesce((v_cfg ->> 'fecha_pontos_facultativos')::boolean, false)
     and p_data in (v_pascoa - 48, v_pascoa - 47, v_pascoa + 60) then
    return false;
  end if;
  return not coalesce(v_cfg -> 'dias_fechados_extra' ? p_data::text, false);
end;
$$;

create or replace function public.proximo_dia_util(p_clinica uuid, p_data date)
returns date
language plpgsql stable
as $$
declare
  d date := p_data;
begin
  for i in 1 .. 30 loop
    exit when public.eh_dia_util(p_clinica, d);
    d := d + 1;
  end loop;
  return d;
end;
$$;

create or replace function public.dia_util_anterior(p_clinica uuid, p_data date)
returns date
language plpgsql stable
as $$
declare
  d date := p_data - 1;
begin
  for i in 1 .. 30 loop
    exit when public.eh_dia_util(p_clinica, d);
    d := d - 1;
  end loop;
  return d;
end;
$$;

-- ─── Parâmetros ──────────────────────────────────────────────────────────────

-- Cada tipo de tarefa pertence a uma situação (e portanto a uma regra editável).
create or replace function public.situacao_do_tipo(p_tipo text)
returns text
language sql immutable
as $$
  select case p_tipo
    when 'primeiro_contato'      then 'novo_contato'
    when 'follow_up'             then 'em_contato'
    when 'confirmar_agendamento' then 'confirmacao'
    when 'apresentar_orcamento'  then 'pos_consulta'
    when 'follow_up_orcamento'   then 'pos_consulta'
    when 'acompanhar_decisao'    then 'pos_consulta'
    when 'recuperar_desmarcacao' then 'desmarcou'
    when 'recuperar_falta'       then 'desmarcou'
    when 'reabrir_sem_resposta'  then 'sem_resposta'
    when 'retorno_por_motivo'    then 'nao_fechou'
    when 'agendar_tratamento'    then 'fechou'
    when 'reativacao'            then 'reativacao'
    when 'manutencao'            then 'manutencao'
  end;
$$;

create or replace function public.categoria_do_tipo(p_tipo public.tipo_tarefa)
returns public.categoria_tarefa
language sql immutable
as $$
  select case
    when p_tipo in ('recuperar_desmarcacao', 'recuperar_falta', 'reabrir_sem_resposta', 'retorno_por_motivo') then 'recuperacao'
    when p_tipo in ('reativacao', 'manutencao') then 'reativacao'
    when p_tipo = 'confirmar_agendamento' then 'agenda'
    when p_tipo = 'confirmar_pagamento' then 'financeiro'
    else 'vendas'
  end::public.categoria_tarefa;
$$;

create or replace function public.regra(p_clinica uuid, p_situacao text)
returns public.regras_followup
language sql stable security definer set search_path = public
as $$
  select * from public.regras_followup where clinica_id = p_clinica and situacao = p_situacao;
$$;

-- Dias da 1ª ação e das tentativas seguintes (vem da regra da situação).
create or replace function public.cadencia(p_clinica uuid, p_tipo text)
returns int[]
language sql stable security definer set search_path = public
as $$
  select coalesce(
    (select array[coalesce(r.prazo_dias, 0)] || r.intervalos
       from public.regras_followup r
      where r.clinica_id = p_clinica and r.situacao = public.situacao_do_tipo(p_tipo)),
    array[2, 4, 7]);
$$;

create or replace function public.cfg_int(p_clinica uuid, p_chave text, p_padrao int)
returns int
language sql stable security definer set search_path = public
as $$
  select coalesce((select (configuracoes ->> p_chave)::int from public.clinicas where id = p_clinica), p_padrao);
$$;

create or replace function public.etapa_por_marco(p_clinica uuid, p_marco text)
returns public.etapas_funil
language sql stable security definer set search_path = public
as $$
  select * from public.etapas_funil where clinica_id = p_clinica and marco = p_marco and ativo limit 1;
$$;

create or replace function public.etapa_por_resultado(p_clinica uuid, p_resultado public.resultado_oportunidade)
returns uuid
language sql stable security definer set search_path = public
as $$
  select id from public.etapas_funil where clinica_id = p_clinica and resultado = p_resultado and ativo limit 1;
$$;

-- ─── Mensagens sugeridas ─────────────────────────────────────────────────────

-- Preenche as variáveis da mensagem com os dados do CRM. Aceita {{nome}} (biblioteca de
-- mensagens) e a forma curta {primeiro_nome} (títulos de tarefa).
--   {{nome}} primeiro nome (ou como prefere ser chamada) · {{nome_completo}} · {{procedimento}}
--   {{consulta}} "a avaliação" · {{data}} · {{horario}} · {{dentista}} · {{valor}} · {{vencimento}}
--   {{clinica}}
create or replace function public.renderizar_texto(
  p_texto        text,
  p_pessoa       uuid,
  p_procedimento text default null,
  p_extras       jsonb default '{}'::jsonb
)
returns text
language plpgsql stable security definer set search_path = public
as $$
declare
  v_nome     text;
  v_completo text;
  v_clinica  text;
  v_texto    text := p_texto;
  v_valores  jsonb;
  k          text;
begin
  if v_texto is null then return null; end if;
  select coalesce(nullif(p.apelido_tratamento, ''), split_part(p.nome, ' ', 1)), p.nome, c.nome
    into v_nome, v_completo, v_clinica
    from public.pessoas p join public.clinicas c on c.id = p.clinica_id where p.id = p_pessoa;
  v_valores := jsonb_build_object(
    'nome', coalesce(v_nome, ''),
    'primeiro_nome', coalesce(v_nome, ''),
    'nome_completo', coalesce(v_completo, ''),
    'procedimento', coalesce(lower(coalesce(p_procedimento, p_extras ->> 'procedimento')), 'o seu tratamento'),
    'consulta', coalesce(p_extras ->> 'consulta', 'a consulta'),
    'data', coalesce(p_extras ->> 'data', ''),
    'horario', coalesce(p_extras ->> 'horario', ''),
    'dentista', coalesce(p_extras ->> 'dentista', 'a doutora'),
    'valor', coalesce(p_extras ->> 'valor', ''),
    'vencimento', coalesce(p_extras ->> 'vencimento', p_extras ->> 'data', ''),
    'clinica', coalesce(v_clinica, 'clínica'));
  for k in select jsonb_object_keys(v_valores) loop
    v_texto := replace(v_texto, '{{' || k || '}}', v_valores ->> k);
    v_texto := replace(v_texto, '{' || k || '}', v_valores ->> k);
  end loop;
  return v_texto;
end;
$$;

-- Tarefa/regra → categoria da biblioteca de mensagens.
create or replace function public.categoria_mensagem(p_chave text)
returns text
language sql immutable
as $$
  select case p_chave
    when 'primeiro_contato' then 'primeiro_contato'
    when 'follow_up' then 'primeiro_contato'
    when 'acompanhar_decisao' then 'pos_consulta'
    when 'follow_up_orcamento' then 'pos_consulta'
    when 'apresentar_orcamento' then 'pos_consulta'
    when 'retorno_por_motivo' then 'nao_fechou'
    when 'reabrir_sem_resposta' then 'sem_resposta'
    when 'recuperar_desmarcacao' then 'desmarcou'
    when 'recuperar_falta' then 'desmarcou'
    when 'confirmar_agendamento' then 'confirmacao'
    when 'clinica_cancelou' then 'remarcacao'
    when 'reativacao' then 'reativacao'
    when 'pos_tratamento' then 'pos_atendimento'
    when 'agendar_tratamento' then 'pos_atendimento'
    when 'confirmar_pagamento' then 'pagamento_previsto'
    when 'manutencao' then 'paciente_antigo'
    else p_chave
  end;
$$;

-- Escolhe o modelo da biblioteca para uma situação: o específico do procedimento e da
-- tarefa primeiro; depois o da tarefa; depois o padrão da categoria.
create or replace function public.escolher_modelo(p_clinica uuid, p_chave text, p_procedimento text default null)
returns public.modelos_mensagem
language sql stable security definer set search_path = public
as $$
  select m.* from public.modelos_mensagem m
    left join public.procedimentos pr on pr.id = m.procedimento_id
   where m.clinica_id = p_clinica and m.ativo
     and (m.situacao = p_chave or m.categoria = public.categoria_mensagem(p_chave))
     and (m.procedimento_id is null or lower(pr.nome) = lower(p_procedimento))
   order by (m.procedimento_id is not null) desc, (m.situacao is not distinct from p_chave) desc, m.padrao desc, m.criado_em
   limit 1;
$$;

create or replace function public.renderizar_mensagem(
  p_clinica uuid,
  p_situacao text,
  p_pessoa uuid,
  p_procedimento text default null,
  p_extras jsonb default '{}'::jsonb
)
returns text
language sql stable security definer set search_path = public
as $$
  select public.renderizar_texto((public.escolher_modelo(p_clinica, p_situacao, p_procedimento)).texto,
                                 p_pessoa, p_procedimento, p_extras);
$$;

-- ─── Criação de tarefas automáticas ──────────────────────────────────────────

-- Cria (se ainda não existir) uma tarefa automática. Respeita "não contatar" e
-- consentimento, ajusta a data para um dia útil e nunca a coloca no passado.
create or replace function public.criar_tarefa_auto(
  p_pessoa        uuid,
  p_oportunidade  uuid,
  p_tipo          public.tipo_tarefa,
  p_categoria     public.categoria_tarefa,
  p_titulo        text,
  p_vence         date,
  p_prioridade    public.prioridade_tarefa,
  p_regra         text,
  p_chave         text,
  p_passo         int default 1,
  p_descricao     text default null,
  p_agendamento   uuid default null,
  p_mensagem      text default null
)
returns uuid
language plpgsql
security definer
set search_path = public
as $$
declare
  v_pessoa public.pessoas;
  v_proc   text;
  v_resp   uuid;
  v_id     uuid;
begin
  select * into v_pessoa from public.pessoas where id = p_pessoa;
  if v_pessoa.id is null or v_pessoa.arquivado_em is not null
     or v_pessoa.nao_contatar or not v_pessoa.consentimento_contato then
    return null;
  end if;

  select pr.nome, o.responsavel_id into v_proc, v_resp
    from public.oportunidades o left join public.procedimentos pr on pr.id = o.procedimento_id
   where o.id = p_oportunidade;

  -- Contatos de reativação (que a pessoa não pediu) respeitam um intervalo mínimo
  -- desde o último contato, para a clínica nunca parecer insistente.
  if p_categoria = 'reativacao' and v_pessoa.ultimo_contato_em is not null then
    p_vence := greatest(
      p_vence,
      (v_pessoa.ultimo_contato_em at time zone 'America/Sao_Paulo')::date
        + public.cfg_int(v_pessoa.clinica_id, 'intervalo_min_contato_dias', 3));
  end if;

  insert into public.tarefas (
    clinica_id, pessoa_id, oportunidade_id, agendamento_id, tipo, categoria, titulo, descricao,
    vence_em, prioridade, responsavel_id, origem, regra, chave_dedupe, passo, mensagem_sugerida
  ) values (
    v_pessoa.clinica_id, p_pessoa, p_oportunidade, p_agendamento, p_tipo, p_categoria, p_titulo, p_descricao,
    public.proximo_dia_util(v_pessoa.clinica_id, greatest(p_vence, public.hoje_clinica(v_pessoa.clinica_id))),
    p_prioridade, coalesce(v_resp, v_pessoa.responsavel_id), 'automatica', p_regra, p_chave, p_passo,
    coalesce(p_mensagem, public.renderizar_mensagem(v_pessoa.clinica_id, p_tipo::text, p_pessoa, v_proc))
  )
  on conflict (clinica_id, chave_dedupe) where status = 'pendente' and chave_dedupe is not null
  do nothing
  returning id into v_id;

  return v_id;
end;
$$;

-- Substitui a próxima ação comercial de uma negociação (cancela a anterior).
create or replace function public.definir_proxima_acao(
  p_oportunidade uuid,
  p_tipo         public.tipo_tarefa,
  p_titulo       text,
  p_vence        date,
  p_prioridade   public.prioridade_tarefa,
  p_regra        text,
  p_passo        int default 1,
  p_descricao    text default null,
  p_categoria    public.categoria_tarefa default 'vendas',
  p_mensagem     text default null
)
returns uuid
language plpgsql
security definer
set search_path = public
as $$
declare
  v_pessoa uuid;
begin
  select pessoa_id into v_pessoa from public.oportunidades where id = p_oportunidade;
  update public.tarefas
     set status = 'cancelada', cancelada_motivo = 'Substituída pela nova próxima ação'
   where chave_dedupe = 'op:' || p_oportunidade and status = 'pendente';
  return public.criar_tarefa_auto(
    v_pessoa, p_oportunidade, p_tipo, p_categoria, p_titulo, p_vence, p_prioridade,
    p_regra, 'op:' || p_oportunidade, p_passo, p_descricao, null, p_mensagem);
end;
$$;

-- A negociação já tem próxima ação? (tarefa pendente ou consulta marcada ainda por acontecer)
create or replace function public.tem_proxima_acao(p_oportunidade uuid)
returns boolean
language sql stable security definer set search_path = public
as $$
  select exists (select 1 from public.tarefas where oportunidade_id = p_oportunidade and status = 'pendente')
      or exists (select 1 from public.agendamentos a
                  where a.oportunidade_id = p_oportunidade and a.status in ('agendado', 'confirmado')
                    and (a.inicio at time zone 'America/Sao_Paulo')::date
                        >= public.hoje_clinica(a.clinica_id));
$$;

-- Move a negociação para a etapa de um marco, somente se ela estiver antes dele.
create or replace function public.avancar_para_marco(p_oportunidade uuid, p_marco text, p_observacao text default null)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  v_op    public.oportunidades;
  v_alvo  public.etapas_funil;
  v_atual int;
begin
  -- (atual = etapa em que a negociação está agora)
  select * into v_op from public.oportunidades where id = p_oportunidade;
  if v_op.id is null or v_op.status not in ('aberta', 'pausada') then return; end if;
  v_alvo := public.etapa_por_marco(v_op.clinica_id, p_marco);
  if v_alvo.id is null then return; end if;
  select ordem into v_atual from public.etapas_funil where id = v_op.etapa_id;
  -- Avança no fluxo; de "Desmarcou", "Reativação" ou "Sem resposta" volta para qualquer etapa.
  if v_atual < v_alvo.ordem
     or v_op.status = 'pausada'
     or (select marco from public.etapas_funil where id = v_op.etapa_id) in ('desmarcou', 'reativacao') then
    perform public.mover_etapa(p_oportunidade, v_alvo.id, p_observacao);
  end if;
end;
$$;

-- =============================================================================
-- Sugestão de próxima ação por etapa
--   A mesma regra serve para as automações e para a tela do funil, onde a
--   usuária vê a sugestão, pode editar título, data e mensagem — ou recusar.
-- =============================================================================

-- Uma movimentação feita pela usuária no funil já traz a ação que ela confirmou;
-- durante ela, os gatilhos não criam a ação automática (crm.acao_manual = on).
create or replace function public.acao_manual()
returns boolean
language sql stable
as $$ select coalesce(current_setting('crm.acao_manual', true), '') = 'on' $$;

-- Texto que explica a regra à usuária ("o que acontece e quando").
create or replace function public.explicar_regra(r public.regras_followup)
returns text
language plpgsql stable
as $$
declare
  v text;
  n int := coalesce(cardinality(r.intervalos), 0);
begin
  if r.id is null then return null; end if;
  if not r.ativa then
    return 'A regra “' || r.nome || '” está desligada em Configurações.';
  end if;
  v := 'Regra “' || r.nome || '”: ' || case
         when r.situacao = 'confirmacao' then 'confirmação ' || coalesce(r.prazo_dias, 1) || ' dia(s) útil(eis) antes da consulta'
         when r.prazo_dias is null then 'ação na data combinada'
         when r.prazo_dias = 0 then 'ação no mesmo dia'
         when r.prazo_dias = 1 then 'ação no dia seguinte'
         else 'ação em ' || r.prazo_dias || ' dias' end;
  if n > 0 then
    v := v || '; sem resposta, mais ' || n || case when n = 1 then ' tentativa' else ' tentativas' end
           || ' (após ' || array_to_string(r.intervalos, ', ') || ' dias)';
  end if;
  v := v || case r.ao_esgotar
              when 'sem_resposta' then '. Depois disso, a pessoa vai para “Sem resposta”.'
              when 'reativacao' then '. Depois disso, vai para “Reativação”, com novo contato em '
                                     || coalesce(r.espera_reativacao_dias, 60) || ' dias.'
              when 'encerrar' then '. Depois disso, a negociação é encerrada como “Não fechou”.'
              else '. Se continuar sem resposta, você decide o próximo passo.'
            end;
  return v;
end;
$$;

create or replace function public.sugerir_acao(
  p_oportunidade uuid,
  p_etapa        uuid,
  p_motivo       uuid default null,
  p_nova         boolean default false
)
returns jsonb
language plpgsql
stable
security definer
set search_path = public
as $$
declare
  op       public.oportunidades;
  et       public.etapas_funil;
  mo       public.motivos;
  r        public.regras_followup;
  v_sit    text;
  v_nome   text;
  v_proc   text;
  v_hoje   date;
  v_tipo   public.tipo_tarefa;
  v_cat    public.categoria_tarefa;
  v_prio   public.prioridade_tarefa;
  v_titulo text;
  v_desc   text;
  v_vence  date;
  v_expl   text;
  v_requer text;
begin
  select * into op from public.oportunidades where id = p_oportunidade;
  select * into et from public.etapas_funil where id = p_etapa;
  if op.id is null or et.id is null or et.clinica_id <> op.clinica_id
     or (auth.uid() is not null and op.clinica_id not in (select public.minhas_clinicas())) then
    return null;
  end if;
  select * into mo from public.motivos where id = coalesce(p_motivo, op.motivo_id);
  select coalesce(nullif(apelido_tratamento, ''), split_part(nome, ' ', 1)) into v_nome
    from public.pessoas where id = op.pessoa_id;
  select nome into v_proc from public.procedimentos where id = op.procedimento_id;
  v_hoje := public.hoje_clinica(op.clinica_id);

  v_sit := case
    when et.marco = 'novo_contato' then 'novo_contato'
    when et.marco = 'em_contato' then 'em_contato'
    when et.marco = 'avaliacao_agendada' then 'confirmacao'
    -- "Consulta realizada": o orçamento é apresentado na consulta; a pessoa está decidindo.
    when et.marco in ('avaliacao_realizada', 'orcamento_apresentado', 'em_negociacao') then 'pos_consulta'
    when et.marco = 'desmarcou' then 'desmarcou'
    when et.marco = 'reativacao' then 'reativacao'
    when et.resultado = 'fechou' then 'fechou'
    when et.resultado in ('nao_fechou', 'desistiu') then 'nao_fechou'
    when et.resultado = 'sem_resposta' then 'sem_resposta'
  end;
  r := public.regra(op.clinica_id, v_sit);

  if r.id is null then
    -- Etapa personalizada (sem regra própria): acompanhamento em 2 dias.
    v_tipo := 'follow_up'; v_prio := 'normal'; v_vence := v_hoje + 2;
    v_titulo := 'Acompanhar ' || v_nome || coalesce(' sobre ' || lower(v_proc), '');
    v_expl := 'Acompanhamento em 2 dias.';
  else
    v_tipo := r.tipo_tarefa;
    v_prio := r.prioridade;
    v_titulo := public.renderizar_texto(r.titulo_modelo, op.pessoa_id, v_proc,
                  jsonb_build_object('consulta', 'a avaliação'));
    v_vence := v_hoje + r.prazo_dias;
    v_expl := public.explicar_regra(r);

    if v_sit = 'em_contato' and p_nova then
      v_vence := v_hoje;
      v_titulo := 'Conversar com ' || v_nome || coalesce(' sobre ' || lower(v_proc), '');
      v_desc := 'Demonstrou interesse' || coalesce(' em ' || lower(v_proc), '');
    elsif v_sit = 'confirmacao' then
      v_requer := 'agendamento'; v_vence := null;
      v_expl := 'Informe a data e o horário: a confirmação fica marcada para '
                || coalesce(r.prazo_dias, 1) || ' dia(s) útil(eis) antes.';
    elsif v_sit = 'fechou' then
      v_requer := 'financeiro';
      v_desc := 'Fechou' || coalesce(' ' || lower(v_proc), '') || '. Combine a data de início.';
      v_expl := v_expl || ' Registre as condições de pagamento: os lembretes de cada parcela são criados sozinhos.';
    elsif v_sit = 'nao_fechou' then
      v_requer := 'motivo';
      if et.resultado = 'desistiu' then v_tipo := 'reativacao'; end if;
      if mo.id is not null then
        v_desc := case when et.resultado = 'desistiu' then 'Desistiu: ' else 'Não fechou: ' end || lower(mo.nome);
        if coalesce(mo.retorno_sugerido_dias, r.prazo_dias) is not null then
          v_vence := coalesce(op.reabre_em, v_hoje + coalesce(mo.retorno_sugerido_dias, r.prazo_dias));
          v_expl := 'A pessoa não é esquecida: um contato leve em ' || coalesce(mo.retorno_sugerido_dias, r.prazo_dias)
                    || ' dias (prazo sugerido para "' || lower(mo.nome) || '"). Até lá, nenhuma mensagem.';
        else
          v_tipo := null;
          v_expl := 'Para "' || lower(mo.nome) || '" não há retorno programado. Você pode escolher uma data, se quiser.';
        end if;
      else
        v_vence := null;
        v_expl := 'Escolha o motivo: ele define quando faz sentido voltar a conversar.';
      end if;
    elsif v_sit = 'sem_resposta' then
      v_desc := 'Sem resposta' || coalesce(' sobre ' || lower(v_proc), '');
    end if;

    if not r.ativa then
      v_tipo := null; v_vence := null;
    end if;
  end if;

  v_cat := case when v_tipo is null then null else public.categoria_do_tipo(v_tipo) end;
  if v_vence is not null then
    v_vence := public.proximo_dia_util(op.clinica_id, greatest(v_vence, v_hoje));
  end if;

  return jsonb_build_object(
    'situacao', v_sit,
    'regra', r.nome,
    'tipo', v_tipo,
    'categoria', v_cat,
    'prioridade', v_prio,
    'titulo', v_titulo,
    'descricao', v_desc,
    'vence_em', v_vence,
    'explicacao', v_expl,
    'requer', v_requer,
    'mensagem', case when v_tipo is not null then
                  public.renderizar_mensagem(op.clinica_id, coalesce(r.mensagem_situacao, v_tipo::text), op.pessoa_id, v_proc)
                end
  );
end;
$$;

-- Cria a tarefa definida por uma regra (usada pelos gatilhos e pela rotina).
--   p_base: data do evento (o prazo da regra conta a partir dela)
--   p_vence: data escolhida pela usuária (substitui o prazo da regra)
--   p_substituir: cancela a próxima ação pendente da negociação antes de criar
create or replace function public.criar_por_regra(
  p_situacao     text,
  p_pessoa       uuid,
  p_oportunidade uuid,
  p_chave        text,
  p_base         date default null,
  p_vence        date default null,
  p_agendamento  uuid default null,
  p_descricao    text default null,
  p_extras       jsonb default '{}'::jsonb,
  p_substituir   boolean default false,
  p_tipo         public.tipo_tarefa default null
)
returns uuid
language plpgsql
security definer
set search_path = public
as $$
declare
  v_clinica uuid := (select clinica_id from public.pessoas where id = p_pessoa);
  r         public.regras_followup := public.regra(v_clinica, p_situacao);
  v_proc    text;
  v_tipo    public.tipo_tarefa;
begin
  if r.id is null or not r.ativa then return null; end if;
  select pr.nome into v_proc from public.oportunidades o join public.procedimentos pr on pr.id = o.procedimento_id
   where o.id = p_oportunidade;
  if p_substituir and p_oportunidade is not null then
    update public.tarefas set status = 'cancelada', cancelada_motivo = 'Substituída pela nova próxima ação'
     where chave_dedupe = 'op:' || p_oportunidade and status = 'pendente';
  end if;
  v_tipo := coalesce(p_tipo, r.tipo_tarefa);
  return public.criar_tarefa_auto(
    p_pessoa, p_oportunidade, v_tipo, public.categoria_do_tipo(v_tipo),
    public.renderizar_texto(r.titulo_modelo, p_pessoa, v_proc, p_extras),
    coalesce(p_vence, coalesce(p_base, public.hoje_clinica(v_clinica)) + coalesce(r.prazo_dias, 0)),
    r.prioridade, p_situacao, p_chave, 1, p_descricao, p_agendamento,
    public.renderizar_mensagem(v_clinica,
      case when p_tipo is not null then p_tipo::text else coalesce(r.mensagem_situacao, r.tipo_tarefa::text) end,
      p_pessoa, v_proc, p_extras));
end;
$$;

-- Cria a ação sugerida para a etapa atual da negociação (usada pelos gatilhos).
create or replace function public.aplicar_sugestao(
  p_oportunidade uuid,
  p_regra        text,
  p_nova         boolean default false
)
returns uuid
language plpgsql
security definer
set search_path = public
as $$
declare
  s  jsonb;
  op public.oportunidades;
begin
  select * into op from public.oportunidades where id = p_oportunidade;
  s := public.sugerir_acao(p_oportunidade, op.etapa_id, null, p_nova);
  if s is null or s ->> 'tipo' is null or s ->> 'vence_em' is null or s ->> 'requer' = 'agendamento' then
    return null;
  end if;
  update public.tarefas set status = 'cancelada', cancelada_motivo = 'Substituída pela nova próxima ação'
   where chave_dedupe = 'op:' || p_oportunidade and status = 'pendente';
  return public.criar_tarefa_auto(
    op.pessoa_id, p_oportunidade, (s ->> 'tipo')::public.tipo_tarefa, (s ->> 'categoria')::public.categoria_tarefa,
    s ->> 'titulo', (s ->> 'vence_em')::date, (s ->> 'prioridade')::public.prioridade_tarefa,
    coalesce(s ->> 'situacao', p_regra), 'op:' || p_oportunidade, 1, s ->> 'descricao', null, s ->> 'mensagem');
end;
$$;

-- =============================================================================
-- 1. Gatilhos: situações que geram ações
-- =============================================================================

-- Nova negociação → primeiro contato (lead) ou conversa (paciente antigo).
create or replace function public.motor_nova_oportunidade()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  if new.status <> 'aberta' or public.acao_manual() then return null; end if;
  perform public.aplicar_sugestao(new.id, 'R-LEAD-01', true);
  return null;
end;
$$;

create trigger motor_nova_oportunidade
  after insert on public.oportunidades
  for each row execute function public.motor_nova_oportunidade();

-- Resultado da negociação → próxima ação adequada.
create or replace function public.motor_resultado_oportunidade()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  if new.status is not distinct from old.status or public.acao_manual() then return null; end if;
  if new.status in ('ganha', 'perdida', 'pausada') then
    perform public.aplicar_sugestao(new.id, 'R-OP-01');
  end if;
  return null;
end;
$$;

-- O nome começa com "motor_" para rodar depois de "encerrar_tarefas_..." (ordem alfabética).
create trigger motor_resultado_oportunidade
  after update on public.oportunidades
  for each row execute function public.motor_resultado_oportunidade();

-- "a avaliação", "o procedimento"… (usado nas mensagens e títulos)
create or replace function public.rotulo_consulta(p_tipo public.tipo_agendamento)
returns text
language sql immutable
as $$
  select case p_tipo
    when 'avaliacao' then 'a avaliação'
    when 'apresentacao_orcamento' then 'a apresentação do orçamento'
    when 'procedimento' then 'o procedimento'
    when 'retorno' then 'o retorno'
    when 'manutencao' then 'a manutenção'
    else 'a ligação' end;
$$;

-- Dentista da consulta: a escolhida (precisa ser desta clínica e estar atendendo); sem
-- escolha, só vale a padrão se a clínica tiver uma única dentista — com várias, pergunta.
create or replace function public.dentista_escolhida(p_clinica uuid, p_escolhida uuid)
returns uuid
language plpgsql
stable
security definer
set search_path = public
as $$
declare
  v_id uuid;
  v_n  int;
begin
  if p_escolhida is not null then
    select id into v_id from public.profissionais where id = p_escolhida and clinica_id = p_clinica and ativo;
    if v_id is null then
      raise exception 'Dentista não encontrada ou inativa.' using errcode = 'P0001';
    end if;
    return v_id;
  end if;
  select count(*), min(id::text)::uuid into v_n, v_id from public.profissionais where clinica_id = p_clinica and ativo;
  if v_n = 1 then return v_id; end if;
  if v_n = 0 then return null; end if;
  raise exception 'Escolha a dentista.' using errcode = 'P0001';
end;
$$;

-- Novo agendamento → confirmar na véspera; avaliação move o funil.
create or replace function public.motor_novo_agendamento()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare
  v_dia    date := (new.inicio at time zone 'America/Sao_Paulo')::date;
  v_hora   text := to_char(new.inicio at time zone 'America/Sao_Paulo', 'HH24:MI');
  r        public.regras_followup := public.regra(new.clinica_id, 'confirmacao');
  v_quando date;
  v_rotulo text := public.rotulo_consulta(new.tipo);
begin
  if new.status not in ('agendado', 'confirmado') then return null; end if;

  if new.oportunidade_id is not null then
    if new.tipo = 'avaliacao' then
      perform public.avancar_para_marco(new.oportunidade_id, 'avaliacao_agendada', 'Avaliação agendada');
    end if;
    -- Com a consulta marcada, a "próxima ação" passa a ser a confirmação.
    update public.tarefas
       set status = 'concluida', resultado = 'Agendou ' || v_rotulo
     where chave_dedupe = 'op:' || new.oportunidade_id and status = 'pendente'
       and tipo in ('primeiro_contato', 'follow_up', 'recuperar_desmarcacao', 'recuperar_falta',
                    'retorno_por_motivo', 'reabrir_sem_resposta', 'reativacao', 'manutencao', 'definir_proxima_acao');
  end if;

  if new.status = 'agendado' and new.tipo <> 'ligacao_agendada' and v_dia > public.hoje_clinica(new.clinica_id)
     and r.ativa then
    -- Confirmação N dias úteis antes (regra "Confirmar consulta").
    v_quando := v_dia;
    for i in 1 .. greatest(coalesce(r.prazo_dias, 1), 1) loop
      v_quando := public.dia_util_anterior(new.clinica_id, v_quando);
    end loop;
    perform public.criar_por_regra(
      'confirmacao', new.pessoa_id, new.oportunidade_id, 'ag:' || new.id, p_vence => v_quando,
      p_agendamento => new.id,
      p_extras => jsonb_build_object('consulta', v_rotulo, 'data', to_char(v_dia, 'DD/MM'), 'horario', v_hora,
                    'dentista', (select nome from public.profissionais where id = new.profissional_id)));
  end if;
  return null;
end;
$$;

create trigger motor_novo_agendamento
  after insert on public.agendamentos
  for each row execute function public.motor_novo_agendamento();

-- Mudança de status do agendamento → confirma, recupera ou avança o funil.
create or replace function public.motor_status_agendamento()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare
  v_nome  text;
  v_hoje  date := public.hoje_clinica(new.clinica_id);
  v_chave text;
  v_quando text := to_char(new.inicio at time zone 'America/Sao_Paulo', 'DD/MM "às" HH24:MI');
begin
  if new.status is not distinct from old.status then return null; end if;
  select split_part(nome, ' ', 1) into v_nome from public.pessoas where id = new.pessoa_id;
  v_chave := coalesce('op:' || new.oportunidade_id, 'pessoa:' || new.pessoa_id);

  if new.status = 'confirmado' then
    update public.tarefas set status = 'concluida', resultado = 'Confirmado'
     where chave_dedupe = 'ag:' || new.id and status = 'pendente';
    return null;
  end if;

  -- Qualquer outro desfecho encerra a confirmação pendente.
  update public.tarefas set status = 'cancelada', cancelada_motivo = 'Agendamento ' || new.status::text
   where chave_dedupe = 'ag:' || new.id and status = 'pendente';

  -- Desmarcou/faltou: o cartão vai para "Desmarcou" no funil.
  if new.status in ('desmarcado', 'faltou') and new.oportunidade_id is not null
     and (select status from public.oportunidades where id = new.oportunidade_id) = 'aberta' then
    perform public.mover_etapa(new.oportunidade_id, (public.etapa_por_marco(new.clinica_id, 'desmarcou')).id,
      case when new.status = 'faltou' then 'Faltou ao agendamento' else 'Desmarcou o agendamento' end);
  end if;
  -- Movimentação manual no funil: a usuária já definiu a próxima ação.
  if public.acao_manual() then return null; end if;

  if new.status in ('desmarcado', 'faltou') then
    -- Regra "Desmarcou ou faltou" (ex.: desmarcou dia 10 → contato dia 11). A falta usa a
    -- mesma regra, com a mensagem própria de quem faltou.
    perform public.criar_por_regra(
      'desmarcou', new.pessoa_id, new.oportunidade_id, v_chave, p_base => v_hoje, p_agendamento => new.id,
      p_descricao => case when new.status = 'faltou' then 'Faltou ao agendamento de ' else 'Desmarcou o agendamento de ' end || v_quando,
      p_substituir => true,
      p_tipo => case when new.status = 'faltou' then 'recuperar_falta'::public.tipo_tarefa end,
      p_extras => jsonb_build_object('consulta', public.rotulo_consulta(new.tipo),
                    'data', to_char(new.inicio at time zone 'America/Sao_Paulo', 'DD/MM'),
                    'horario', to_char(new.inicio at time zone 'America/Sao_Paulo', 'HH24:MI')));

  elsif new.status = 'cancelado_clinica' then
    perform public.criar_tarefa_auto(
      new.pessoa_id, new.oportunidade_id, 'follow_up', 'agenda',
      'Remarcar o horário de ' || v_nome, v_hoje, 'alta', 'clinica_cancelou', 'rec:' || new.id,
      p_agendamento => new.id, p_descricao => 'A clínica cancelou o horário',
      p_mensagem => public.renderizar_mensagem(new.clinica_id, 'clinica_cancelou', new.pessoa_id, null,
        jsonb_build_object('consulta', public.rotulo_consulta(new.tipo),
                           'data', to_char(new.inicio at time zone 'America/Sao_Paulo', 'DD/MM'))));

  elsif new.status = 'compareceu' and new.tipo = 'avaliacao' and new.oportunidade_id is not null then
    -- Passou pela consulta (onde recebe o orçamento): regra "Saiu da consulta sem fechar".
    perform public.avancar_para_marco(new.oportunidade_id, 'avaliacao_realizada', 'Compareceu à consulta');
    perform public.criar_por_regra('pos_consulta', new.pessoa_id, new.oportunidade_id, 'op:' || new.oportunidade_id,
      p_base => v_hoje, p_descricao => 'Passou pela consulta', p_substituir => true);
  end if;
  return null;
end;
$$;

create trigger motor_status_agendamento
  after update of status on public.agendamentos
  for each row execute function public.motor_status_agendamento();

-- Orçamento apresentado → funil avança e começa a cadência de follow-up.
create or replace function public.motor_orcamento_apresentado()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
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

create trigger motor_orcamento_apresentado
  after insert or update of status on public.orcamentos
  for each row execute function public.motor_orcamento_apresentado();

-- =============================================================================
-- 2. registrar_acao(): concluir tarefa / registrar contato
-- =============================================================================
--
-- Resultados aceitos:
--   feito                 → "Concluir": fez a ação; segue para a próxima tentativa da cadência
--   respondeu_interesse   → respondeu com interesse
--   agendou               → agendou (p_agendar_em obrigatório)
--   vai_pensar            → ficou de pensar
--   pediu_retorno         → pediu retorno em outra data (p_data obrigatório)
--   nao_respondeu         → não respondeu; próxima tentativa
--   fechou                → fechou o tratamento
--   nao_fechou            → não fechou (p_motivo obrigatório)
--   desistiu              → desistiu (p_motivo obrigatório)
--   nao_contatar          → não quer mais contato
--   numero_invalido       → número errado/inexistente
--   confirmou             → confirmou o agendamento
--   desmarcou             → desmarcou o agendamento
--   sem_interesse         → não tem interesse (desistiu, motivo "Sem interesse no momento")
--   outro                 → outro desfecho (p_observacao obrigatória; p_data opcional)
--   prometeu_pagar        → (lembrete financeiro) combinou pagar em p_data
--
-- Retorna a próxima ação criada: {"titulo": ..., "vence_em": ...} ou null.

create or replace function public.registrar_acao(
  p_tarefa        uuid,
  p_resultado     text,
  p_canal         public.canal_contato default null,
  p_observacao    text default null,
  p_data          date default null,
  p_motivo        uuid default null,
  p_agendar_em    timestamptz default null,
  p_profissional  uuid default null,        -- dentista (ao agendar/remarcar)
  p_encaixe       boolean default false
)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  t         public.tarefas;
  v_op      public.oportunidades;
  v_nome    text;
  v_proc    text;
  v_hoje    date;
  v_gaps    int[];
  v_marco   text;
  v_prox    uuid;
  v_ag      uuid;
  v_tipo_i  public.tipo_interacao;
  v_rotulo  text;
  v_res     jsonb;
  v_nova    uuid;
  v_sit     text;
  r         public.regras_followup;
  v_esgotar text;
  v_prof    uuid;
begin
  select * into t from public.tarefas where id = p_tarefa for update;
  -- Roda com privilégios do sistema: confere se a tarefa é da clínica de quem chama.
  if t.id is null or (auth.uid() is not null and t.clinica_id not in (select public.minhas_clinicas())) then
    raise exception 'Tarefa não encontrada.' using errcode = 'P0002';
  end if;
  if t.status <> 'pendente' then
    raise exception 'Esta tarefa já foi %.', case t.status when 'concluida' then 'concluída' else 'cancelada' end
      using errcode = 'P0001';
  end if;

  v_hoje := public.hoje_clinica(t.clinica_id);
  select split_part(nome, ' ', 1) into v_nome from public.pessoas where id = t.pessoa_id;
  select * into v_op from public.oportunidades where id = t.oportunidade_id;
  select lower(nome) into v_proc from public.procedimentos where id = v_op.procedimento_id;
  select marco into v_marco from public.etapas_funil where id = v_op.etapa_id;

  -- Validações por resultado
  if p_resultado = 'agendou' and p_agendar_em is null then
    raise exception 'Informe a data e o horário do agendamento.' using errcode = 'P0001';
  elsif p_resultado in ('pediu_retorno', 'prometeu_pagar') and p_data is null then
    raise exception 'Informe a data combinada.' using errcode = 'P0001';
  elsif p_resultado = 'outro' and nullif(btrim(p_observacao), '') is null then
    raise exception 'Descreva o que aconteceu.' using errcode = 'P0001';
  elsif p_resultado in ('nao_fechou', 'desistiu') and p_motivo is null then
    raise exception 'Informe o motivo.' using errcode = 'P0001';
  elsif p_resultado = 'prometeu_pagar' and t.tipo <> 'confirmar_pagamento' then
    raise exception '"Combinou pagar" só vale para lembretes de pagamento.' using errcode = 'P0001';
  elsif p_resultado in ('confirmou', 'desmarcou') and t.agendamento_id is null then
    raise exception 'Esta tarefa não está ligada a um agendamento.' using errcode = 'P0001';
  elsif t.tipo = 'confirmar_pagamento' and p_resultado not in ('nao_respondeu', 'prometeu_pagar', 'numero_invalido') then
    raise exception 'Para lembretes de pagamento, use "Marcar como pago".' using errcode = 'P0001';
  elsif p_resultado not in ('feito', 'respondeu_interesse', 'agendou', 'vai_pensar', 'pediu_retorno',
                            'nao_respondeu', 'fechou', 'nao_fechou', 'desistiu', 'nao_contatar',
                            'numero_invalido', 'confirmou', 'desmarcou', 'prometeu_pagar',
                            'sem_interesse', 'outro') then
    raise exception 'Resultado desconhecido: %', p_resultado using errcode = 'P0001';
  end if;

  if p_resultado = 'sem_interesse' then
    p_motivo := coalesce(p_motivo,
      (select id from public.motivos where clinica_id = t.clinica_id and aplica_a = 'desistiu' and ativo
        order by (nome = 'Sem interesse no momento') desc, ordem limit 1));
  end if;

  -- Regra que originou a tarefa (a situação guarda o código da regra).
  v_sit := case when exists (select 1 from public.regras_followup where clinica_id = t.clinica_id and situacao = t.regra)
                then t.regra else public.situacao_do_tipo(t.tipo::text) end;
  r := public.regra(t.clinica_id, v_sit);

  -- 1) Histórico (follow-up)
  v_tipo_i := case p_resultado
    when 'feito' then case when t.tipo in ('apresentar_orcamento', 'agendar_tratamento', 'definir_proxima_acao', 'personalizada')
                           then 'nota'
                           when p_canal = 'presencial' then 'atendimento'
                           else coalesce(p_canal::text, 'outro') end
    when 'respondeu_interesse' then 'paciente_respondeu'
    when 'agendou' then 'paciente_respondeu'
    when 'vai_pensar' then 'paciente_respondeu'
    when 'confirmou' then 'paciente_respondeu'
    when 'pediu_retorno' then 'retorno_solicitado'
    when 'nao_respondeu' then 'paciente_nao_respondeu'
    when 'fechou' then 'paciente_fechou'
    when 'nao_fechou' then 'paciente_recusou'
    when 'desistiu' then 'paciente_recusou'
    when 'desmarcou' then 'paciente_desmarcou'
    when 'sem_interesse' then 'paciente_recusou'
    when 'outro' then coalesce(p_canal::text, 'nota')
    else 'outro'
  end::public.tipo_interacao;
  v_rotulo := case p_resultado
    when 'feito' then 'Concluído: ' || t.titulo
    when 'respondeu_interesse' then 'Respondeu com interesse'
    when 'agendou' then 'Agendou para ' || to_char(p_agendar_em at time zone 'America/Sao_Paulo', 'DD/MM "às" HH24:MI')
    when 'vai_pensar' then 'Ficou de pensar'
    when 'pediu_retorno' then 'Pediu retorno em ' || to_char(p_data, 'DD/MM')
    when 'nao_respondeu' then 'Não respondeu'
    when 'fechou' then 'Fechou o tratamento'
    when 'nao_fechou' then 'Não fechou'
    when 'desistiu' then 'Desistiu'
    when 'nao_contatar' then 'Pediu para não receber mais contatos'
    when 'numero_invalido' then 'Número inválido'
    when 'confirmou' then 'Confirmou o agendamento'
    when 'desmarcou' then 'Desmarcou o agendamento'
    when 'prometeu_pagar' then 'Combinou pagar em ' || to_char(p_data, 'DD/MM')
    when 'sem_interesse' then 'Não tem interesse no momento'
    when 'outro' then 'Contato registrado'
  end;

  insert into public.interacoes (clinica_id, pessoa_id, oportunidade_id, tarefa_id, agendamento_id,
                                 tipo, canal, direcao, descricao, retorno_em)
  values (t.clinica_id, t.pessoa_id, t.oportunidade_id, t.id, t.agendamento_id, v_tipo_i, p_canal,
          case when v_tipo_i in ('paciente_respondeu', 'retorno_solicitado') then 'entrada'::public.direcao_contato end,
          v_rotulo || coalesce(' — ' || nullif(btrim(p_observacao), ''), ''),
          case when p_resultado = 'pediu_retorno' then p_data end);

  -- 2) Lembretes de pagamento continuam pendentes até o pagamento ser registrado.
  if t.tipo = 'confirmar_pagamento' then
    update public.tarefas
       set vence_em = public.proximo_dia_util(t.clinica_id, coalesce(p_data, v_hoje + 2))
     where id = t.id;
    select titulo, vence_em into v_rotulo, v_hoje from public.tarefas where id = t.id;
    return jsonb_build_object('titulo', v_rotulo, 'vence_em', v_hoje);
  end if;

  -- 3) Conclui a tarefa atual
  update public.tarefas set status = 'concluida', resultado = v_rotulo where id = t.id;

  -- Reativação/retorno de negociação encerrada: interesse abre nova negociação.
  if p_resultado in ('respondeu_interesse', 'agendou', 'vai_pensar', 'pediu_retorno', 'fechou')
     and (v_op.id is null or v_op.status in ('ganha', 'perdida', 'pausada')) then
    if v_op.status = 'pausada' then
      -- Quem estava sem resposta e voltou: a mesma negociação é reaberta.
      perform public.mover_etapa(v_op.id, (public.etapa_por_marco(t.clinica_id, 'em_contato')).id, 'Voltou a responder');
    else
      insert into public.oportunidades (clinica_id, pessoa_id, procedimento_id, origem_id, etapa_id,
                                        oportunidade_origem_id, responsavel_id)
      values (t.clinica_id, t.pessoa_id, v_op.procedimento_id,
              coalesce(v_op.origem_id, (select origem_id from public.pessoas where id = t.pessoa_id)),
              (public.etapa_por_marco(t.clinica_id, 'em_contato')).id, v_op.id, t.responsavel_id)
      returning id into v_nova;
      v_op.id := v_nova;
    end if;
    select * into v_op from public.oportunidades where id = v_op.id;
    v_marco := 'em_contato';
  end if;

  -- 4) Próximo passo
  case p_resultado
    when 'feito', 'nao_respondeu' then
      if t.tipo = 'confirmar_agendamento' and p_resultado = 'feito' then
        update public.agendamentos set status = 'confirmado' where id = t.agendamento_id;
      elsif t.tipo in ('primeiro_contato', 'follow_up', 'follow_up_orcamento', 'acompanhar_decisao',
                       'recuperar_desmarcacao', 'recuperar_falta', 'reabrir_sem_resposta', 'reativacao',
                       'manutencao', 'confirmar_agendamento') then
        v_gaps := case when r.id is null then public.cadencia(t.clinica_id, t.tipo::text)
                       else array[coalesce(r.prazo_dias, 0)] || r.intervalos end;
        if t.tipo = 'confirmar_agendamento' then
          -- Não confirmou: uma nova tentativa no próprio dia do agendamento.
          if t.passo = 1 and (select (inicio at time zone 'America/Sao_Paulo')::date from public.agendamentos
                              where id = t.agendamento_id) >= v_hoje then
            v_prox := public.criar_tarefa_auto(t.pessoa_id, t.oportunidade_id, t.tipo, t.categoria,
                        'Tentar confirmar novamente: ' || v_nome,
                        (select (inicio at time zone 'America/Sao_Paulo')::date from public.agendamentos where id = t.agendamento_id),
                        'alta', 'confirmacao', t.chave_dedupe, 2, 'Não respondeu à primeira confirmação',
                        t.agendamento_id, t.mensagem_sugerida);
          end if;
        elsif t.passo < coalesce(array_length(v_gaps, 1), 0) then
          -- Próxima tentativa da regra (mesmo título e mensagem).
          if v_op.id is not null and v_op.status = 'aberta' then
            v_prox := public.definir_proxima_acao(v_op.id, t.tipo, t.titulo,
                        v_hoje + greatest(v_gaps[t.passo + 1], 1), t.prioridade, v_sit, t.passo + 1, t.descricao,
                        t.categoria, t.mensagem_sugerida);
          else
            v_prox := public.criar_tarefa_auto(t.pessoa_id, t.oportunidade_id, t.tipo, t.categoria, t.titulo,
                        v_hoje + greatest(v_gaps[t.passo + 1], 1), t.prioridade, v_sit, t.chave_dedupe,
                        t.passo + 1, t.descricao, t.agendamento_id, t.mensagem_sugerida);
          end if;
        elsif v_op.id is not null and v_op.status in ('aberta', 'pausada') then
          -- Tentativas esgotadas: o que a regra manda fazer.
          -- Quem já está em "Sem resposta" não é movido para lá de novo: a usuária decide.
          v_esgotar := case when r.ao_esgotar = 'sem_resposta' and v_op.status = 'pausada' then 'decidir'
                            else coalesce(r.ao_esgotar, 'decidir') end;
          case v_esgotar
            when 'sem_resposta' then
              perform public.mover_etapa(v_op.id, public.etapa_por_resultado(t.clinica_id, 'sem_resposta'),
                'Sem resposta depois de ' || t.passo || ' tentativas');
            when 'reativacao' then
              perform set_config('crm.acao_manual', 'on', true);
              perform public.mover_etapa(v_op.id, (public.etapa_por_marco(t.clinica_id, 'reativacao')).id,
                'Sem resposta depois de ' || t.passo || ' tentativas');
              perform set_config('crm.acao_manual', '', true);
              v_prox := public.criar_por_regra('reativacao', t.pessoa_id, v_op.id, 'op:' || v_op.id,
                          p_vence => v_hoje + coalesce(r.espera_reativacao_dias, 60),
                          p_descricao => 'Sem resposta às tentativas anteriores', p_substituir => true);
              if v_prox is null then
                v_prox := public.definir_proxima_acao(v_op.id, 'reativacao', 'Retomar contato com ' || v_nome,
                            v_hoje + coalesce(r.espera_reativacao_dias, 60), 'baixa', 'reativacao', 1,
                            'Sem resposta às tentativas anteriores', 'reativacao');
              end if;
            when 'encerrar' then
              perform public.mover_etapa(v_op.id, public.etapa_por_resultado(t.clinica_id, 'nao_fechou'),
                'Sem resposta depois de ' || t.passo || ' tentativas',
                (select id from public.motivos where clinica_id = t.clinica_id and aplica_a = 'nao_fechou' and ativo
                  order by (nome = 'Parou de responder') desc, ordem limit 1));
            else
              v_prox := public.definir_proxima_acao(v_op.id, 'definir_proxima_acao',
                          'Decidir o próximo passo com ' || v_nome,
                          v_hoje + 2, 'normal', v_sit, 1,
                          'Sem retorno depois de ' || t.passo || ' tentativas: continuar acompanhando ou encerrar?');
          end case;
          if v_prox is null then
            select id into v_prox from public.tarefas where chave_dedupe = 'op:' || v_op.id and status = 'pendente';
          end if;
        end if;
      elsif v_op.id is not null and v_op.status = 'aberta' and p_data is not null then
        v_prox := public.definir_proxima_acao(v_op.id, 'follow_up', 'Acompanhar ' || v_nome || coalesce(' sobre ' || v_proc, ''),
                    p_data, 'normal', 'em_contato');
      end if;

    when 'respondeu_interesse' then
      if v_marco in ('novo_contato', 'desmarcou', 'reativacao') then
        perform public.avancar_para_marco(v_op.id, 'em_contato', 'Respondeu com interesse');
      end if;
      r := public.regra(t.clinica_id, 'em_contato');
      v_prox := public.definir_proxima_acao(v_op.id, coalesce(r.tipo_tarefa, 'follow_up'),
                  case when v_marco in ('novo_contato', 'em_contato', 'desmarcou', 'reativacao')
                       then coalesce(public.renderizar_texto(r.titulo_modelo, t.pessoa_id, v_proc),
                                     'Conduzir ' || v_nome || ' para a avaliação')
                       else 'Continuar a conversa com ' || v_nome end,
                  coalesce(p_data, v_hoje + coalesce(r.prazo_dias, 1)), coalesce(r.prioridade, 'alta'), 'em_contato');

    when 'agendou' then
      -- Recuperação de desmarcação/falta/cancelamento: é uma remarcação da consulta perdida.
      if t.tipo in ('recuperar_desmarcacao', 'recuperar_falta') or t.regra = 'clinica_cancelou' then
        select a.id into v_ag from public.agendamentos a
         where a.id = t.agendamento_id and a.remarcado_para_id is null
            or (t.agendamento_id is null and a.pessoa_id = t.pessoa_id and a.remarcado_para_id is null
                and a.status in ('desmarcado', 'faltou', 'cancelado_clinica'))
         order by a.status_em desc limit 1;
      end if;
      if v_ag is not null then
        -- Sem dentista escolhida, a remarcação mantém a da consulta perdida.
        v_ag := (public.remarcar_consulta(v_ag, p_agendar_em, null,
                   case when p_profissional is not null then public.dentista_escolhida(t.clinica_id, p_profissional) end,
                   p_encaixe) ->> 'id')::uuid;
      else
        v_prof := public.dentista_escolhida(t.clinica_id, p_profissional);
        -- Horário de atendimento e agenda da dentista valem também aqui.
        perform public.validar_horario(t.clinica_id, p_agendar_em, 60, v_prof, p_encaixe);
        insert into public.agendamentos (clinica_id, pessoa_id, oportunidade_id, profissional_id, tipo, inicio)
        values (t.clinica_id, t.pessoa_id, v_op.id, v_prof,
                case when v_marco = 'avaliacao_realizada' then 'apresentacao_orcamento' else 'avaliacao' end::public.tipo_agendamento,
                p_agendar_em)
        returning id into v_ag;
      end if;
      select id into v_prox from public.tarefas where chave_dedupe = 'ag:' || v_ag and status = 'pendente';

    when 'vai_pensar' then
      -- Depois da consulta: sequência "Saiu da consulta sem fechar" (espaçada e sem pressão).
      -- Antes da consulta: continua a conversa para levar à avaliação.
      v_prox := public.criar_por_regra(
                  case when v_marco = 'avaliacao_realizada' then 'pos_consulta' else 'em_contato' end,
                  t.pessoa_id, v_op.id, 'op:' || v_op.id,
                  p_vence => p_data, p_descricao => 'Ficou de pensar', p_substituir => true);

    when 'pediu_retorno' then
      v_prox := public.definir_proxima_acao(v_op.id, 'follow_up',
                  'Retornar para ' || v_nome || ' (pediu retorno)', p_data, 'alta', 'pediu_retorno');

    when 'fechou' then
      perform public.mover_etapa(v_op.id, public.etapa_por_resultado(t.clinica_id, 'fechou'), p_observacao);
      select id into v_prox from public.tarefas where chave_dedupe = 'op:' || v_op.id and status = 'pendente';

    when 'nao_fechou', 'desistiu', 'sem_interesse' then
      if v_op.id is not null and v_op.status in ('aberta', 'pausada') then
        update public.oportunidades set reabre_em = p_data where id = v_op.id;
        perform public.mover_etapa(v_op.id,
          public.etapa_por_resultado(t.clinica_id,
            case when p_resultado = 'nao_fechou' then 'nao_fechou' else 'desistiu' end::public.resultado_oportunidade),
          p_observacao, p_motivo);
        select id into v_prox from public.tarefas where chave_dedupe = 'op:' || v_op.id and status = 'pendente';
      end if;

    when 'nao_contatar' then
      update public.pessoas set nao_contatar = true,
             nao_contatar_motivo = coalesce(nullif(btrim(p_observacao), ''), 'Pediu para não receber mais contatos')
       where id = t.pessoa_id;
      update public.tarefas set status = 'cancelada', cancelada_motivo = 'Pediu para não receber contatos'
       where pessoa_id = t.pessoa_id and status = 'pendente' and categoria <> 'financeiro';
      if v_op.id is not null and v_op.status in ('aberta', 'pausada') then
        perform public.mover_etapa(v_op.id, public.etapa_por_resultado(t.clinica_id, 'desistiu'),
          'Pediu para não receber mais contatos',
          coalesce(p_motivo, (select id from public.motivos where clinica_id = t.clinica_id
                                and aplica_a = 'desistiu' and ativo order by ordem limit 1)));
        -- Mesmo que o motivo sugira retorno, quem pediu para não ser contatado não recebe tarefa.
      end if;

    when 'numero_invalido' then
      v_prox := public.criar_tarefa_auto(t.pessoa_id, v_op.id, 'follow_up', 'vendas',
                  'Buscar outro telefone de ' || v_nome, v_hoje, 'alta', 'numero_invalido',
                  coalesce('op:' || v_op.id, 'pessoa:' || t.pessoa_id),
                  p_descricao => 'O número cadastrado não funcionou');

    when 'confirmou' then
      update public.agendamentos set status = 'confirmado' where id = t.agendamento_id;

    when 'outro' then
      -- A usuária descreveu o que houve; se escolheu uma data, o próximo contato fica nela.
      if p_data is not null and v_op.id is not null and v_op.status = 'aberta' then
        v_prox := public.definir_proxima_acao(v_op.id, 'follow_up',
                    'Acompanhar ' || v_nome || coalesce(' sobre ' || v_proc, ''), p_data, 'normal', 'em_contato',
                    p_descricao => btrim(p_observacao));
      end if;

    when 'desmarcou' then
      update public.agendamentos set status = 'desmarcado' where id = t.agendamento_id;
      select id into v_prox from public.tarefas
       where pessoa_id = t.pessoa_id and status = 'pendente' and tipo = 'recuperar_desmarcacao'
       order by criado_em desc limit 1;
  end case;

  -- 5) Garantia: negociação aberta nunca fica sem próxima ação.
  if v_op.id is not null
     and (select status from public.oportunidades where id = v_op.id) = 'aberta'
     and not public.tem_proxima_acao(v_op.id) then
    v_prox := public.definir_proxima_acao(v_op.id, 'follow_up',
                'Acompanhar ' || v_nome || coalesce(' sobre ' || v_proc, ''),
                coalesce(p_data, v_hoje + 2), 'normal', 'em_contato');
  end if;

  if v_prox is null then
    select id into v_prox from public.tarefas
     where pessoa_id = t.pessoa_id and status = 'pendente' and id <> t.id
     order by vence_em, criado_em desc limit 1;
  end if;
  select jsonb_build_object('titulo', titulo, 'vence_em', vence_em) into v_res
    from public.tarefas where id = v_prox;
  return v_res;
end;
$$;

-- Marca a parcela do lembrete como paga (valor em aberto, data de hoje).
create or replace function public.marcar_parcela_paga(
  p_parcela uuid,
  p_forma   uuid default null,
  p_data    date default null
)
returns void
language plpgsql
as $$
declare
  p public.parcelas;
begin
  select * into p from public.parcelas where id = p_parcela for update;
  if p.id is null then
    raise exception 'Parcela não encontrada ou sem permissão.' using errcode = 'P0002';
  end if;
  if p.status not in ('pendente', 'parcial') then
    raise exception 'Esta parcela não está em aberto.' using errcode = 'P0001';
  end if;
  insert into public.pagamentos (clinica_id, parcela_id, valor_centavos, pago_em, forma_pagamento_id)
  values (p.clinica_id, p.id, p.valor_centavos - p.valor_pago_centavos,
          coalesce(p_data, public.hoje_clinica(p.clinica_id)), coalesce(p_forma, p.forma_pagamento_id));
end;
$$;

-- =============================================================================
-- 3. Rotina diária
-- =============================================================================

-- Abre uma negociação na etapa "Reativação" com a tarefa de contato.
-- Retorna o id da tarefa (ou null se a pessoa não aceita contato / já negocia).
create or replace function public.abrir_reativacao(
  p_pessoa       uuid,
  p_origem       uuid,
  p_procedimento uuid,
  p_tipo         public.tipo_tarefa,
  p_titulo       text,
  p_descricao    text,
  p_vence        date,
  p_regra        text,
  p_mensagem     text default null,
  p_prioridade   public.prioridade_tarefa default 'baixa'
)
returns uuid
language plpgsql
security definer
set search_path = public
as $$
declare
  v_pessoa public.pessoas;
  v_op     uuid;
  v_antes  text := coalesce(current_setting('crm.acao_manual', true), '');
begin
  select * into v_pessoa from public.pessoas where id = p_pessoa;
  if v_pessoa.id is null or v_pessoa.nao_contatar or not v_pessoa.consentimento_contato
     or v_pessoa.arquivado_em is not null
     or exists (select 1 from public.oportunidades where pessoa_id = p_pessoa and status in ('aberta', 'pausada')) then
    return null;
  end if;

  -- A tarefa é criada abaixo, com o texto certo; a sugestão genérica fica de fora.
  perform set_config('crm.acao_manual', 'on', true);
  insert into public.oportunidades (clinica_id, pessoa_id, procedimento_id, origem_id, etapa_id,
                                    oportunidade_origem_id, responsavel_id)
  values (v_pessoa.clinica_id, p_pessoa, p_procedimento, v_pessoa.origem_id,
          (public.etapa_por_marco(v_pessoa.clinica_id, 'reativacao')).id, p_origem, v_pessoa.responsavel_id)
  returning id into v_op;
  perform set_config('crm.acao_manual', v_antes, true);

  return public.criar_tarefa_auto(p_pessoa, v_op, p_tipo, 'reativacao', p_titulo, p_vence, p_prioridade, p_regra,
                                  'op:' || v_op, 1, p_descricao, null, p_mensagem);
end;
$$;

create table public.execucoes_rotina (
  clinica_id    uuid not null references public.clinicas (id),
  dia           date not null,
  executada_em  timestamptz not null default now(),
  resumo        jsonb,
  primary key (clinica_id, dia)
);
alter table public.execucoes_rotina enable row level security;
create policy membro_ler on public.execucoes_rotina for select to authenticated
  using (clinica_id in (select public.minhas_clinicas()));

-- Roda uma vez por dia por clínica (chamada ao abrir o painel e/ou por agendador).
create or replace function public.preparar_dia(p_clinica uuid, p_forcar boolean default false)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_hoje       date := public.hoje_clinica(p_clinica);
  v_cfg        jsonb := (select configuracoes from public.clinicas where id = p_clinica);
  r_manut      public.regras_followup := public.regra(p_clinica, 'manutencao');
  r_inativo    public.regras_followup := public.regra(p_clinica, 'paciente_inativo');
  r_pos        public.regras_followup := public.regra(p_clinica, 'pos_tratamento');
  v_pos        int := 0;
  v_intervalo  int := coalesce((v_cfg ->> 'intervalo_min_contato_dias')::int, 3);
  v_limite     int := coalesce((v_cfg ->> 'limite_reativacao_dia')::int, 10);
  v_expirados  int := 0;
  v_sentinela  int := 0;
  v_reativ     int := 0;
  v_manut      int := 0;
  v_retornos   int := 0;
  v_nova       uuid;
  r            record;
begin
  if auth.uid() is not null and p_clinica not in (select public.minhas_clinicas()) then
    raise exception 'Sem acesso a esta clínica.' using errcode = '42501';
  end if;

  if not p_forcar then
    insert into public.execucoes_rotina (clinica_id, dia) values (p_clinica, v_hoje)
    on conflict do nothing;
    if not found then
      return jsonb_build_object('ja_executada', true);
    end if;
  end if;

  -- Orçamentos vencidos (a negociação continua).
  update public.orcamentos set status = 'expirado'
   where clinica_id = p_clinica and status in ('apresentado', 'em_negociacao') and valido_ate < v_hoje;
  get diagnostics v_expirados = row_count;

  -- Consultas que já passaram sem registro: perguntar se a pessoa compareceu.
  for r in
    select a.id, a.pessoa_id, a.oportunidade_id, split_part(p.nome, ' ', 1) as nome, a.inicio
      from public.agendamentos a join public.pessoas p on p.id = a.pessoa_id
     where a.clinica_id = p_clinica and a.status in ('agendado', 'confirmado')
       and (a.inicio at time zone 'America/Sao_Paulo')::date < v_hoje
  loop
    perform public.criar_tarefa_auto(r.pessoa_id, r.oportunidade_id, 'definir_proxima_acao', 'agenda',
      r.nome || ' compareceu?', v_hoje, 'alta', 'confirmacao', 'ag:' || r.id,
      p_descricao => 'Consulta de ' || to_char(r.inicio at time zone 'America/Sao_Paulo', 'DD/MM "às" HH24:MI')
                     || ' sem registro de comparecimento',
      p_agendamento => r.id);
  end loop;

  -- Garantia: nenhuma desmarcação, falta ou cancelamento fica sem ação comercial.
  for r in
    select v.agendamento_id, v.pessoa_id, v.status, v.inicio, a.oportunidade_id,
           coalesce(nullif(p.apelido_tratamento, ''), split_part(p.nome, ' ', 1)) as nome
      from public.v_recuperacao v
      join public.agendamentos a on a.id = v.agendamento_id
      join public.pessoas p on p.id = v.pessoa_id
     where v.clinica_id = p_clinica and v.situacao = 'sem_acao'
       and not p.nao_contatar and p.consentimento_contato and p.arquivado_em is null
  loop
    perform public.criar_tarefa_auto(r.pessoa_id, r.oportunidade_id,
      case when r.status = 'faltou' then 'recuperar_falta' else 'recuperar_desmarcacao' end::public.tipo_tarefa,
      'recuperacao', 'Entrar em contato com ' || r.nome || ' para remarcar', v_hoje, 'urgente', 'desmarcou',
      'rec:' || r.agendamento_id, 1,
      'Consulta de ' || to_char(r.inicio at time zone 'America/Sao_Paulo', 'DD/MM "às" HH24:MI') || ' ainda sem recuperação',
      r.agendamento_id);
  end loop;

  -- Garantia: toda negociação aberta tem uma próxima ação.
  for r in
    select o.id, split_part(p.nome, ' ', 1) as nome
      from public.oportunidades o join public.pessoas p on p.id = o.pessoa_id
     where o.clinica_id = p_clinica and o.status = 'aberta'
       and not p.nao_contatar and p.arquivado_em is null
       and not public.tem_proxima_acao(o.id)
  loop
    if public.definir_proxima_acao(r.id, 'definir_proxima_acao', 'Definir o próximo passo com ' || r.nome,
                                   v_hoje, 'alta', 'em_contato') is not null then
      v_sentinela := v_sentinela + 1;
    end if;
  end loop;

  -- Retornos combinados (não fechou / desistiu) que chegaram na data: a pessoa passa
  -- para a coluna "Reativação" numa nova negociação, com a mesma tarefa (que a
  -- usuária pode ter ajustado).
  for r in
    select t.id as tarefa_id, t.pessoa_id, o.id as op_id, o.procedimento_id, o.origem_id, o.responsavel_id
      from public.tarefas t
      join public.oportunidades o on o.id = t.oportunidade_id
     where t.clinica_id = p_clinica and t.status = 'pendente' and o.status = 'perdida'
       and t.tipo in ('retorno_por_motivo', 'reativacao') and t.vence_em <= v_hoje
       and not exists (select 1 from public.oportunidades x where x.pessoa_id = t.pessoa_id and x.status in ('aberta', 'pausada'))
  loop
    perform set_config('crm.acao_manual', 'on', true);
    insert into public.oportunidades (clinica_id, pessoa_id, procedimento_id, origem_id, etapa_id,
                                      oportunidade_origem_id, responsavel_id)
    values (p_clinica, r.pessoa_id, r.procedimento_id, r.origem_id,
            (public.etapa_por_marco(p_clinica, 'reativacao')).id, r.op_id, r.responsavel_id)
    returning id into v_nova;
    perform set_config('crm.acao_manual', '', true);
    update public.tarefas set oportunidade_id = v_nova, chave_dedupe = 'op:' || v_nova where id = r.tarefa_id;
    v_retornos := v_retornos + 1;
  end loop;

  -- Reativação: cada regra (Configurações) liga/desliga e define o período.
  -- Um limite diário evita uma avalanche de contatos de uma vez.

  -- Retorno após o tratamento concluído (data prevista chegou).
  if r_pos.ativa then
    for r in
      select p.id, p.retorno_previsto_em
        from public.pessoas p
       where p.clinica_id = p_clinica and p.retorno_previsto_em <= v_hoje and not p.em_tratamento
         and p.arquivado_em is null and not p.nao_contatar and p.consentimento_contato
         and not exists (select 1 from public.oportunidades o where o.pessoa_id = p.id and o.status in ('aberta', 'pausada'))
       order by p.retorno_previsto_em
       limit v_limite
    loop
      if public.abrir_reativacao(r.id, null, null, r_pos.tipo_tarefa,
           public.renderizar_texto(r_pos.titulo_modelo, r.id), 'Tratamento concluído; hora da revisão',
           v_hoje, 'pos_tratamento',
           public.renderizar_mensagem(p_clinica, coalesce(r_pos.mensagem_situacao, 'pos_tratamento'), r.id),
           r_pos.prioridade) is not null then
        update public.pessoas set retorno_previsto_em = null where id = r.id;
        v_pos := v_pos + 1;
      end if;
    end loop;
  end if;

  -- Manutenção devida (procedimento com ciclo de retorno).
  if r_manut.ativa then
    for r in
      select distinct on (p.id) p.id, pr.id as proc_id, pr.nome as proc, ta.realizado_em
        from public.pessoas p
        join public.tratamentos_anteriores ta on ta.pessoa_id = p.id
        join public.procedimentos pr on pr.id = ta.procedimento_id and pr.ciclo_retorno_meses is not null
       where p.clinica_id = p_clinica and p.arquivado_em is null and not p.nao_contatar and p.consentimento_contato
         and ta.realizado_em + make_interval(months => pr.ciclo_retorno_meses) <= v_hoje
         and (p.ultimo_contato_em is null or p.ultimo_contato_em < now() - make_interval(days => v_intervalo))
         and not exists (select 1 from public.oportunidades o where o.pessoa_id = p.id and o.status in ('aberta', 'pausada'))
         and not exists (select 1 from public.tarefas t where t.pessoa_id = p.id and t.status = 'pendente')
         and not exists (select 1 from public.tarefas t where t.pessoa_id = p.id and t.tipo in ('manutencao', 'reativacao')
                           and t.criado_em > now() - interval '90 days')
       order by p.id, ta.realizado_em desc
       limit greatest(v_limite - v_pos, 0)
    loop
      if public.abrir_reativacao(r.id, null, r.proc_id, r_manut.tipo_tarefa,
           public.renderizar_texto(r_manut.titulo_modelo, r.id, r.proc),
           lower(r.proc) || ' em ' || to_char(r.realizado_em, 'MM/YYYY'),
           v_hoje, 'manutencao',
           public.renderizar_mensagem(p_clinica, coalesce(r_manut.mensagem_situacao, 'manutencao'), r.id, r.proc),
           r_manut.prioridade) is not null then
        v_manut := v_manut + 1;
      end if;
    end loop;
  end if;

  -- Pacientes antigos sem atendimento há X meses (período da regra).
  if r_inativo.ativa then
    for r in
      select c.id, c.ultimo_atendimento_em
        from public.v_contatos c
       where c.clinica_id = p_clinica and c.relacionamento = 'paciente_inativo'
         and c.arquivado_em is null and not c.nao_contatar and c.consentimento_contato
         and c.oportunidade_id is null and c.proxima_tarefa_id is null
         and (c.ultimo_contato_em is null or c.ultimo_contato_em < now() - make_interval(days => v_intervalo))
         and not exists (select 1 from public.tarefas t where t.pessoa_id = c.id and t.tipo in ('manutencao', 'reativacao')
                           and t.criado_em > now() - interval '90 days')
       order by c.ultimo_atendimento_em nulls first
       limit greatest(v_limite - v_pos - v_manut, 0)
    loop
      if public.abrir_reativacao(r.id, null, null, r_inativo.tipo_tarefa,
           public.renderizar_texto(r_inativo.titulo_modelo, r.id),
           case when r.ultimo_atendimento_em is null then 'Paciente antigo sem atendimento recente'
                else 'Último atendimento em ' || to_char(r.ultimo_atendimento_em, 'MM/YYYY') end,
           v_hoje, 'paciente_inativo',
           public.renderizar_mensagem(p_clinica, coalesce(r_inativo.mensagem_situacao, 'reativacao'), r.id),
           r_inativo.prioridade) is not null then
        v_reativ := v_reativ + 1;
      end if;
    end loop;
  end if;

  update public.execucoes_rotina
     set resumo = jsonb_build_object('orcamentos_expirados', v_expirados, 'proximas_acoes_criadas', v_sentinela,
                                     'manutencoes', v_manut, 'reativacoes', v_reativ, 'retornos', v_retornos,
                                     'pos_tratamento', v_pos)
   where clinica_id = p_clinica and dia = v_hoje;

  return jsonb_build_object('orcamentos_expirados', v_expirados, 'proximas_acoes_criadas', v_sentinela,
                            'manutencoes', v_manut, 'reativacoes', v_reativ, 'retornos', v_retornos,
                            'pos_tratamento', v_pos);
end;
$$;

-- =============================================================================
-- Visão usada pelo painel: todas as tarefas pendentes com o contexto necessário
-- para montar o cartão (paciente, procedimento, motivo, valores, agenda).
-- =============================================================================

create view public.v_tarefas_abertas with (security_invoker = true) as
select
  t.id, t.clinica_id, t.pessoa_id, t.oportunidade_id, t.agendamento_id, t.parcela_id,
  t.tipo, t.categoria, t.titulo, t.descricao, t.vence_em, t.horario, t.prioridade, t.passo,
  t.responsavel_id, t.origem, t.regra, t.mensagem_sugerida, t.adiamentos, t.criado_em,
  public.hoje_clinica(t.clinica_id)                       as hoje,
  public.hoje_clinica(t.clinica_id) - t.vence_em          as dias_atraso,
  pe.nome                                                 as pessoa_nome,
  pe.whatsapp_e164,
  pe.telefone_e164,
  pe.temperatura,
  pe.tipo_cadastro,
  pe.primeiro_contato_em,
  og.nome                                                 as origem_nome,
  coalesce(pr.nome, pr2.nome)                             as procedimento,
  op.status                                               as oportunidade_status,
  et.nome                                                 as etapa,
  et.marco                                                as etapa_marco,
  mo.nome                                                 as motivo,
  orc.apresentado_em                                      as orcamento_apresentado_em,
  orc.valor_final_centavos                                as orcamento_valor_centavos,
  ag.inicio                                               as agendamento_inicio,
  ag.tipo                                                 as agendamento_tipo,
  ag.status                                               as agendamento_status,
  pa.numero                                               as parcela_numero,
  pa.vencimento                                           as parcela_vencimento,
  pa.valor_centavos - pa.valor_pago_centavos              as parcela_saldo_centavos,
  pa.valor_pago_centavos                                  as parcela_pago_centavos,
  ve.quantidade_parcelas                                  as parcela_total,
  ve.tipo                                                 as venda_tipo,
  rg.nome                                                 as regra_nome
from public.tarefas t
left join public.regras_followup rg on rg.clinica_id = t.clinica_id and rg.situacao = t.regra
join public.pessoas pe on pe.id = t.pessoa_id
left join public.origens og on og.id = pe.origem_id
left join public.oportunidades op on op.id = t.oportunidade_id
left join public.procedimentos pr on pr.id = op.procedimento_id
left join public.etapas_funil et on et.id = op.etapa_id
left join public.motivos mo on mo.id = op.motivo_id
left join lateral (
  select o.apresentado_em, o.valor_final_centavos from public.orcamentos o
   where o.oportunidade_id = t.oportunidade_id and o.status <> 'rascunho'
   order by o.apresentado_em desc nulls last, o.criado_em desc limit 1
) orc on true
left join lateral (
  -- Sem negociação: usa o último tratamento conhecido (manutenção/reativação).
  select p2.nome from public.tratamentos_anteriores ta join public.procedimentos p2 on p2.id = ta.procedimento_id
   where ta.pessoa_id = t.pessoa_id and t.oportunidade_id is null
   order by ta.realizado_em desc nulls last limit 1
) pr2 on true
left join public.agendamentos ag on ag.id = t.agendamento_id
left join public.parcelas pa on pa.id = t.parcela_id
left join public.vendas ve on ve.id = pa.venda_id
where t.status = 'pendente';

grant execute on function public.registrar_acao(uuid, text, public.canal_contato, text, date, uuid, timestamptz, uuid, boolean)
  to authenticated;
revoke execute on function public.registrar_acao(uuid, text, public.canal_contato, text, date, uuid, timestamptz, uuid, boolean)
  from anon;
revoke execute on function public.marcar_parcela_paga(uuid, uuid, date) from anon;
revoke execute on function public.preparar_dia(uuid, boolean) from anon;

-- ---------------------------------------------------------------------------
-- 20260929120500_resgate.sql
-- ---------------------------------------------------------------------------

-- =============================================================================
-- Migração 6: resgate de pacientes antigos sob demanda
--   criar_resgate(pessoa) cria, na hora, a tarefa de contato para um paciente
--   antigo: "manutenção" quando algum tratamento anterior tem ciclo de retorno
--   (ex.: limpeza a cada 6 meses), senão "reativação". Funciona mesmo com a
--   reativação automática desligada (recadastramento).
-- =============================================================================

create or replace function public.criar_resgate(p_pessoa uuid)
returns uuid
language plpgsql
security definer
set search_path = public
as $$
declare
  v_pessoa public.pessoas;
  v_hoje   date;
  v_trat   record;
  v_id     uuid;
  r        public.regras_followup;
begin
  select * into v_pessoa from public.pessoas where id = p_pessoa;
  if v_pessoa.id is null or (auth.uid() is not null and v_pessoa.clinica_id not in (select public.minhas_clinicas())) then
    raise exception 'Cadastro não encontrado.' using errcode = 'P0002';
  end if;
  if v_pessoa.nao_contatar or not v_pessoa.consentimento_contato or v_pessoa.arquivado_em is not null then
    raise exception 'Esta pessoa não deseja receber contatos.' using errcode = 'P0001';
  end if;
  if exists (select 1 from public.oportunidades where pessoa_id = p_pessoa and status in ('aberta', 'pausada')) then
    raise exception 'Já existe uma negociação em andamento; use a próxima ação dela.' using errcode = 'P0001';
  end if;

  v_hoje := public.hoje_clinica(v_pessoa.clinica_id);

  -- Tratamento anterior com ciclo de retorno (o mais recente).
  select pr.id, pr.nome, ta.realizado_em into v_trat
    from public.tratamentos_anteriores ta
    join public.procedimentos pr on pr.id = ta.procedimento_id and pr.ciclo_retorno_meses is not null
   where ta.pessoa_id = p_pessoa
   order by ta.realizado_em desc nulls last
   limit 1;

  -- O resgate abre uma negociação na coluna "Reativação" do funil.
  if v_trat.nome is not null then
    r := public.regra(v_pessoa.clinica_id, 'manutencao');
    v_id := public.abrir_reativacao(
      p_pessoa, null, v_trat.id, 'manutencao',
      coalesce(public.renderizar_texto(r.titulo_modelo, p_pessoa, v_trat.nome),
               'Lembrar ' || split_part(v_pessoa.nome, ' ', 1) || ' da manutenção'),
      lower(v_trat.nome) || coalesce(' em ' || to_char(v_trat.realizado_em, 'MM/YYYY'), ''),
      v_hoje, 'manutencao', public.renderizar_mensagem(v_pessoa.clinica_id, 'manutencao', p_pessoa, v_trat.nome));
  else
    r := public.regra(v_pessoa.clinica_id, 'paciente_inativo');
    v_id := public.abrir_reativacao(
      p_pessoa, null, null, 'reativacao',
      coalesce(public.renderizar_texto(r.titulo_modelo, p_pessoa),
               'Reativar contato com ' || split_part(v_pessoa.nome, ' ', 1)),
      'Paciente antigo' || coalesce(', último atendimento em ' || to_char(v_pessoa.ultimo_atendimento_informado, 'MM/YYYY'), ''),
      v_hoje, 'paciente_inativo');
  end if;
  return v_id;
end;
$$;

revoke execute on function public.criar_resgate(uuid) from anon;

-- Busca sem acento ("joao" encontra "João").
create or replace function public.sem_acento(p_texto text)
returns text
language sql immutable parallel safe
as $$
  select lower(translate(p_texto,
    'ÁÀÂÃÄáàâãäÉÈÊËéèêëÍÌÎÏíìîïÓÒÔÕÖóòôõöÚÙÛÜúùûüÇçÑñ',
    'AAAAAaaaaaEEEEeeeeIIIIiiiiOOOOOoooooUUUUuuuuCcNn'));
$$;

create index pessoas_nome_sem_acento on public.pessoas (clinica_id, public.sem_acento(nome));

-- ---------------------------------------------------------------------------
-- 20260930120000_funil.sql
-- ---------------------------------------------------------------------------

-- =============================================================================
-- Migração 7: funil comercial
--   mover_etapa_manual() — a usuária move um cartão no funil. O sistema sugere a
--   próxima ação (sugerir_acao) e ela confirma, edita ou recusa. Casos especiais:
--     • negociação encerrada movida para uma etapa em andamento → nova negociação
--       ligada à anterior (o resultado antigo fica no histórico);
--     • Avaliação agendada → cria o agendamento (a confirmação vem sozinha);
--     • Desmarcou → marca o agendamento como desmarcado;
--     • Fechou → pode registrar valores e parcelas (lembretes de pagamento);
--     • Não fechou → exige motivo; retorno opcional na data escolhida.
-- Também: proteção das funções internas do motor.
-- =============================================================================

create or replace function public.mover_etapa_manual(
  p_oportunidade uuid,
  p_etapa        uuid,
  p_observacao   text default null,
  p_motivo       uuid default null,
  p_acao         jsonb default '{}'::jsonb
)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  op       public.oportunidades;
  et       public.etapas_funil;
  mo       public.motivos;
  s        jsonb;
  v_alvo   uuid;
  v_tarefa uuid;
  v_ag     uuid;
  v_venda  uuid;
  v_hoje   date;
  vd       jsonb := p_acao -> 'venda';
  v_final  bigint;
  v_parc   int;
  v_entr   bigint;
  v_prof   uuid;
begin
  select * into op from public.oportunidades where id = p_oportunidade for update;
  if op.id is null or (auth.uid() is not null and op.clinica_id not in (select public.minhas_clinicas())) then
    raise exception 'Negociação não encontrada.' using errcode = 'P0002';
  end if;
  select * into et from public.etapas_funil where id = p_etapa and clinica_id = op.clinica_id and ativo;
  if et.id is null then
    raise exception 'Etapa inválida.' using errcode = 'P0001';
  end if;
  if et.id = op.etapa_id then
    raise exception 'A negociação já está nesta etapa.' using errcode = 'P0001';
  end if;
  if et.resultado in ('nao_fechou', 'desistiu') then
    select * into mo from public.motivos where id = p_motivo and clinica_id = op.clinica_id;
    if mo.id is null then
      raise exception 'Informe o motivo.' using errcode = 'P0001';
    end if;
  end if;
  if op.status in ('ganha', 'perdida') and et.tipo <> 'aberta' then
    raise exception 'Esta negociação já foi encerrada. Para retomar, mova para uma etapa em andamento ou para Reativação.'
      using errcode = 'P0001';
  end if;
  v_hoje := public.hoje_clinica(op.clinica_id);

  -- Os gatilhos não criam a ação automática: a usuária já decidiu qual será.
  perform set_config('crm.acao_manual', 'on', true);
  perform set_config('crm.observacao_etapa', coalesce(p_observacao, ''), true);

  if op.status in ('ganha', 'perdida') then
    -- Retomada: nova negociação, preservando o resultado da anterior.
    insert into public.oportunidades (clinica_id, pessoa_id, procedimento_id, origem_id, etapa_id,
                                      oportunidade_origem_id, responsavel_id, valor_estimado_centavos)
    values (op.clinica_id, op.pessoa_id, op.procedimento_id, op.origem_id, et.id, op.id, op.responsavel_id,
            op.valor_estimado_centavos)
    returning id into v_alvo;
  else
    v_alvo := op.id;
    if et.marco = 'desmarcou' then
      update public.agendamentos set status = 'desmarcado'
       where oportunidade_id = op.id and status in ('agendado', 'confirmado');
    end if;
    if et.resultado in ('nao_fechou', 'desistiu') then
      update public.oportunidades set reabre_em = nullif(p_acao ->> 'vence_em', '')::date where id = op.id;
    end if;
    perform public.mover_etapa(op.id, et.id, p_observacao, p_motivo);
    -- A próxima ação antiga é substituída pela que a usuária confirmar agora.
    update public.tarefas set status = 'cancelada', cancelada_motivo = 'Negociação mudou de etapa'
     where chave_dedupe = 'op:' || op.id and status = 'pendente';
  end if;
  perform set_config('crm.observacao_etapa', '', true);

  if nullif(p_acao ->> 'valor_centavos', '') is not null then
    update public.oportunidades set valor_estimado_centavos = (p_acao ->> 'valor_centavos')::bigint where id = v_alvo;
  end if;

  if et.marco = 'avaliacao_agendada' and nullif(p_acao ->> 'agendar_em', '') is not null then
    -- A confirmação na véspera é criada pelo gatilho do agendamento.
    perform set_config('crm.acao_manual', '', true);
    v_prof := public.dentista_escolhida(op.clinica_id, nullif(p_acao ->> 'profissional_id', '')::uuid);
    perform public.validar_horario(op.clinica_id, (p_acao ->> 'agendar_em')::timestamp at time zone 'America/Sao_Paulo', 60,
                                   v_prof, coalesce((p_acao ->> 'encaixe')::boolean, false));
    insert into public.agendamentos (clinica_id, pessoa_id, oportunidade_id, profissional_id, tipo, inicio)
    values (op.clinica_id, op.pessoa_id, v_alvo, v_prof,
            'avaliacao', (p_acao ->> 'agendar_em')::timestamp at time zone 'America/Sao_Paulo')
    returning id into v_ag;
    select id into v_tarefa from public.tarefas where chave_dedupe = 'ag:' || v_ag and status = 'pendente';
  elsif coalesce((p_acao ->> 'criar')::boolean, false) then
    s := public.sugerir_acao(v_alvo, et.id, p_motivo);
    -- Sem data de avaliação ainda: a ação é combinar a data (não há o que confirmar).
    if s ->> 'requer' = 'agendamento' then
      s := s || jsonb_build_object('tipo', 'follow_up', 'categoria', 'vendas', 'prioridade', 'alta',
             'titulo', 'Combinar a data da avaliação com ' || split_part((select nome from public.pessoas where id = op.pessoa_id), ' ', 1));
    end if;
    v_tarefa := public.criar_tarefa_auto(
      op.pessoa_id, v_alvo,
      coalesce((s ->> 'tipo')::public.tipo_tarefa, 'personalizada'),
      coalesce((s ->> 'categoria')::public.categoria_tarefa, 'vendas'),
      coalesce(nullif(btrim(p_acao ->> 'titulo'), ''), s ->> 'titulo'),
      coalesce(nullif(p_acao ->> 'vence_em', '')::date, (s ->> 'vence_em')::date, v_hoje),
      coalesce((s ->> 'prioridade')::public.prioridade_tarefa, 'normal'),
      coalesce(s ->> 'situacao', 'R-FUN-01'), 'op:' || v_alvo, 1, s ->> 'descricao', null,
      coalesce(nullif(btrim(p_acao ->> 'mensagem'), ''), s ->> 'mensagem'));
  end if;

  -- Desmarcou: a ação confirmada pela usuária substitui a recuperação garantida pela
  -- agenda (se ela recusar a ação, a recuperação garantida permanece).
  if et.marco = 'desmarcou' and v_tarefa is not null then
    update public.tarefas
       set agendamento_id = (select a.id from public.agendamentos a where a.oportunidade_id = v_alvo
                              and a.status = 'desmarcado' order by a.status_em desc limit 1)
     where id = v_tarefa;
    update public.tarefas set status = 'cancelada', cancelada_motivo = 'Substituída pela ação confirmada no funil'
     where pessoa_id = op.pessoa_id and status = 'pendente' and chave_dedupe like 'rec:%';
  end if;

  -- Fechou: condições de pagamento → parcelas e lembretes financeiros.
  if et.resultado = 'fechou' and vd is not null then
    v_final := (vd ->> 'valor_total_centavos')::bigint - coalesce((vd ->> 'desconto_centavos')::bigint, 0);
    v_parc := greatest(coalesce((vd ->> 'parcelas')::int, 1), 1);
    v_entr := coalesce((vd ->> 'entrada_centavos')::bigint, 0);
    insert into public.vendas (clinica_id, pessoa_id, oportunidade_id, valor_total_centavos, desconto_centavos,
                               condicao_pagamento, entrada_centavos, quantidade_parcelas, forma_pagamento_id,
                               fechada_em, observacao_financeira)
    values (op.clinica_id, op.pessoa_id, v_alvo, (vd ->> 'valor_total_centavos')::bigint,
            coalesce((vd ->> 'desconto_centavos')::bigint, 0),
            case when v_parc = 1 and v_entr = 0 then 'a_vista' else 'parcelado' end::public.condicao_pagamento,
            v_entr, v_parc, nullif(vd ->> 'forma_pagamento_id', '')::uuid, v_hoje, nullif(vd ->> 'observacao', ''))
    returning id into v_venda;
    -- Sem data informada: com entrada, a 1ª parcela vence 30 dias depois; sem entrada, hoje.
    perform public.gerar_parcelas(v_venda, coalesce(nullif(vd ->> 'primeiro_vencimento', '')::date,
                                                    case when v_entr > 0 then v_hoje + 30 else v_hoje end),
                                  coalesce(nullif(vd ->> 'vencimento_entrada', '')::date, v_hoje));
    -- Cartão: recebido no ato.
    perform public.quitar_recebidos_na_hora(v_venda);
  end if;

  perform set_config('crm.acao_manual', '', true);

  return jsonb_build_object(
    'oportunidade', v_alvo,
    'venda', v_venda,
    'tarefa', (select jsonb_build_object('titulo', titulo, 'vence_em', vence_em) from public.tarefas where id = v_tarefa)
  );
end;
$$;

-- ─── Proteção: funções internas do motor não podem ser chamadas diretamente ──
-- (rodam com privilégios do sistema; só os gatilhos e as funções públicas acima,
-- que conferem a clínica de quem chama, podem usá-las)
revoke execute on function public.criar_tarefa_auto(uuid, uuid, public.tipo_tarefa, public.categoria_tarefa, text, date,
  public.prioridade_tarefa, text, text, int, text, uuid, text) from public, anon, authenticated;
revoke execute on function public.definir_proxima_acao(uuid, public.tipo_tarefa, text, date, public.prioridade_tarefa,
  text, int, text, public.categoria_tarefa, text) from public, anon, authenticated;
revoke execute on function public.avancar_para_marco(uuid, text, text) from public, anon, authenticated;
revoke execute on function public.aplicar_sugestao(uuid, text, boolean) from public, anon, authenticated;
revoke execute on function public.abrir_reativacao(uuid, uuid, uuid, public.tipo_tarefa, text, text, date, text, text,
  public.prioridade_tarefa) from public, anon, authenticated;
revoke execute on function public.criar_por_regra(text, uuid, uuid, text, date, date, uuid, text, jsonb, boolean,
  public.tipo_tarefa)
  from public, anon, authenticated;
revoke execute on function public.regra(uuid, text) from public, anon, authenticated;
revoke execute on function public.renderizar_texto(text, uuid, text, jsonb) from public, anon, authenticated;
revoke execute on function public.renderizar_mensagem(uuid, text, uuid, text, jsonb) from public, anon, authenticated;
revoke execute on function public.cadencia(uuid, text) from public, anon, authenticated;
revoke execute on function public.mover_etapa_manual(uuid, uuid, text, uuid, jsonb) from anon;
revoke execute on function public.sugerir_acao(uuid, uuid, uuid, boolean) from anon;

-- ---------------------------------------------------------------------------
-- 20260930130000_tratamento_e_campanhas.sql
-- ---------------------------------------------------------------------------

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

-- ---------------------------------------------------------------------------
-- 20261001120000_agenda.sql
-- ---------------------------------------------------------------------------

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

  insert into public.agendamentos (clinica_id, pessoa_id, oportunidade_id, profissional_id, tipo, procedimento_id,
                                   inicio, duracao_min, status, confirmado_em, observacoes)
  values (p_clinica, v_pessoa, v_op.id, v_prof, p_tipo, p_procedimento, p_inicio, coalesce(p_duracao, 60),
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

-- ---------------------------------------------------------------------------
-- 20261002120000_mensagens.sql
-- ---------------------------------------------------------------------------

-- =============================================================================
-- Migração 10: biblioteca de mensagens prontas
--   • variaveis_pessoa() / variaveis_tarefa(): os dados que preenchem {{nome}},
--     {{procedimento}}, {{data}}, {{dentista}}, {{valor}}, {{vencimento}}…
--   • chave_mensagem_tarefa(): a situação da tarefa (pagamentos mudam conforme o atraso:
--     previsto → cobrança amigável → pagamento pendente).
--   • sugestoes_mensagem(tarefa): a biblioteca inteira preenchida para a tarefa, com a
--     recomendada primeiro. Nada é enviado: a usuária copia, adapta e envia.
--   • mensagens_para_pessoa(pessoa): a biblioteca preenchida para um paciente.
-- =============================================================================

-- Dados do paciente: negociação em andamento, próxima consulta e parcela em aberto.
create or replace function public.variaveis_pessoa(p_pessoa uuid)
returns jsonb
language sql
stable
security definer
set search_path = public
as $$
  select jsonb_strip_nulls(jsonb_build_object(
    'procedimento', (select pr.nome from public.oportunidades o join public.procedimentos pr on pr.id = o.procedimento_id
                      where o.pessoa_id = p_pessoa order by (o.status in ('aberta', 'pausada')) desc, o.criado_em desc limit 1),
    'consulta', public.rotulo_consulta(ag.tipo),
    'data', to_char(ag.inicio at time zone 'America/Sao_Paulo', 'DD/MM'),
    'horario', to_char(ag.inicio at time zone 'America/Sao_Paulo', 'HH24:MI'),
    'dentista', pf.nome,
    'valor', public.formatar_brl(pa.valor_centavos - pa.valor_pago_centavos),
    'vencimento', to_char(pa.vencimento, 'DD/MM')))
  from (select 1) x
  left join lateral (
    select a.* from public.agendamentos a where a.pessoa_id = p_pessoa
     order by (a.status in ('agendado', 'confirmado') and a.inicio >= now()) desc, a.inicio desc limit 1
  ) ag on true
  left join public.profissionais pf on pf.id = ag.profissional_id
  left join lateral (
    select p.* from public.parcelas p where p.pessoa_id = p_pessoa and p.status in ('pendente', 'parcial')
     order by p.vencimento limit 1
  ) pa on true;
$$;

-- Dados da tarefa (a consulta, a parcela e o procedimento dela), completados pelos do paciente.
create or replace function public.variaveis_tarefa(p_tarefa uuid)
returns jsonb
language sql
stable
security definer
set search_path = public
as $$
  select public.variaveis_pessoa(t.pessoa_id) || jsonb_strip_nulls(jsonb_build_object(
    'procedimento', coalesce(pr.nome, pa_ag.nome),
    'consulta', public.rotulo_consulta(ag.tipo),
    'data', to_char(ag.inicio at time zone 'America/Sao_Paulo', 'DD/MM'),
    'horario', to_char(ag.inicio at time zone 'America/Sao_Paulo', 'HH24:MI'),
    'dentista', pf.nome,
    'valor', public.formatar_brl(pa.valor_centavos - pa.valor_pago_centavos),
    'vencimento', to_char(pa.vencimento, 'DD/MM')))
  from public.tarefas t
  left join public.oportunidades o on o.id = t.oportunidade_id
  left join public.procedimentos pr on pr.id = o.procedimento_id
  left join public.agendamentos ag on ag.id = t.agendamento_id
  left join public.procedimentos pa_ag on pa_ag.id = ag.procedimento_id
  left join public.profissionais pf on pf.id = ag.profissional_id
  left join public.parcelas pa on pa.id = t.parcela_id
  where t.id = p_tarefa;
$$;

-- Situação da mensagem para a tarefa. Pagamento: até o vencimento "previsto"; até 7 dias
-- de atraso "cobrança amigável"; depois "pagamento pendente".
create or replace function public.chave_mensagem_tarefa(t public.tarefas)
returns text
language sql
stable
set search_path = public
as $$
  select case
    when t.tipo = 'confirmar_pagamento' then
      case when (select p.vencimento from public.parcelas p where p.id = t.parcela_id) >= public.hoje_clinica(t.clinica_id)
             then 'confirmar_pagamento'
           when public.hoje_clinica(t.clinica_id) - (select p.vencimento from public.parcelas p where p.id = t.parcela_id) <= 7
             then 'cobranca_amigavel'
           else 'pagamento_pendente' end
    when t.regra in ('pos_tratamento', 'clinica_cancelou') then t.regra
    when t.regra = 'campanha' then 'reativacao'
    else t.tipo::text
  end;
$$;

-- A biblioteca preenchida para a tarefa; a recomendada vem primeiro, depois as da mesma
-- categoria, depois as demais.
create or replace function public.sugestoes_mensagem(p_tarefa uuid)
returns table (modelo_id uuid, titulo text, categoria text, procedimento text, texto text,
               recomendada boolean, mesma_categoria boolean)
language plpgsql
stable
security definer
set search_path = public
as $$
declare
  t       public.tarefas;
  v_chave text;
  v_cat   text;
  v_proc  text;
  v_vars  jsonb;
  v_rec   uuid;
begin
  select * into t from public.tarefas where id = p_tarefa;
  if t.id is null or (auth.uid() is not null and t.clinica_id not in (select public.minhas_clinicas())) then
    raise exception 'Tarefa não encontrada.' using errcode = 'P0002';
  end if;
  v_chave := public.chave_mensagem_tarefa(t);
  v_cat := public.categoria_mensagem(v_chave);
  v_vars := public.variaveis_tarefa(t.id);
  v_proc := v_vars ->> 'procedimento';
  v_rec := (public.escolher_modelo(t.clinica_id, v_chave, v_proc)).id;

  return query
  select m.id, m.titulo, m.categoria, pr.nome,
         public.renderizar_texto(m.texto, t.pessoa_id, v_proc, v_vars),
         m.id = v_rec, m.categoria = v_cat
    from public.modelos_mensagem m
    left join public.procedimentos pr on pr.id = m.procedimento_id
   where m.clinica_id = t.clinica_id and m.ativo
   order by m.id = v_rec desc, m.categoria = v_cat desc, m.categoria, m.padrao desc, m.titulo;
end;
$$;

-- A biblioteca preenchida para um paciente (tela Mensagens → "Preencher para").
create or replace function public.mensagens_para_pessoa(p_pessoa uuid)
returns table (modelo_id uuid, texto text)
language plpgsql
stable
security definer
set search_path = public
as $$
declare
  v_pessoa public.pessoas;
  v_vars   jsonb;
begin
  select * into v_pessoa from public.pessoas where id = p_pessoa;
  if v_pessoa.id is null or (auth.uid() is not null and v_pessoa.clinica_id not in (select public.minhas_clinicas())) then
    raise exception 'Cadastro não encontrado.' using errcode = 'P0002';
  end if;
  v_vars := public.variaveis_pessoa(p_pessoa);
  return query
  select m.id, public.renderizar_texto(m.texto, p_pessoa, v_vars ->> 'procedimento', v_vars)
    from public.modelos_mensagem m
   where m.clinica_id = v_pessoa.clinica_id and m.ativo;
end;
$$;

-- Tornar um modelo o padrão da categoria desmarca o padrão anterior (mesmo procedimento).
create or replace function public.um_padrao_por_categoria()
returns trigger
language plpgsql
as $$
begin
  if new.padrao and new.ativo then
    update public.modelos_mensagem
       set padrao = false
     where clinica_id = new.clinica_id and categoria = new.categoria and id <> new.id and padrao
       and procedimento_id is not distinct from new.procedimento_id;
  end if;
  return new;
end;
$$;

create trigger um_padrao_por_categoria
  before insert or update of padrao, ativo, categoria, procedimento_id on public.modelos_mensagem
  for each row execute function public.um_padrao_por_categoria();

revoke execute on function public.variaveis_pessoa(uuid) from public, anon, authenticated;
revoke execute on function public.variaveis_tarefa(uuid) from public, anon, authenticated;
revoke execute on function public.escolher_modelo(uuid, text, text) from public, anon, authenticated;
revoke execute on function public.sugestoes_mensagem(uuid) from anon;
revoke execute on function public.mensagens_para_pessoa(uuid) from anon;

-- ---------------------------------------------------------------------------
-- 20261003120000_financeiro_simples.sql
-- ---------------------------------------------------------------------------

-- =============================================================================
-- Migração 11: visão financeira simples (contas a receber, sem contabilidade)
--   • registrar_negociacao(): paciente, procedimento, valor, entrada (data e forma),
--     parcelas, forma de pagamento e observações → parcelas e lembretes automáticos.
--     Cartão (à vista ou parcelado) é recebido na hora: entra como pago, sem lembretes.
--   • registrar_pagamento(): total ou parcial, com data e forma.
--   • mudar_vencimento(): nova data prevista (o lembrete acompanha).
--   • v_financeiro_parcelas / v_financeiro_negociacoes e resumo_financeiro(mês).
-- Status: pendente · parcialmente pago · pago · atrasado.
-- =============================================================================

-- ─── Parcelas com o contexto da negociação ───────────────────────────────────

create view public.v_financeiro_parcelas with (security_invoker = true) as
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
  o.procedimento_id
from public.parcelas pa
join public.vendas v on v.id = pa.venda_id
join public.pessoas pe on pe.id = pa.pessoa_id
left join public.oportunidades o on o.id = v.oportunidade_id
left join public.procedimentos pr on pr.id = o.procedimento_id
left join public.formas_pagamento fp on fp.id = pa.forma_pagamento_id
where v.status = 'ativa' and pa.status <> 'cancelada';

-- ─── Uma linha por negociação (venda) ────────────────────────────────────────

create view public.v_financeiro_negociacoes with (security_invoker = true) as
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
  o.procedimento_id
from public.vendas v
join public.pessoas pe on pe.id = v.pessoa_id
left join public.oportunidades o on o.id = v.oportunidade_id
left join public.procedimentos pr on pr.id = o.procedimento_id
left join public.formas_pagamento fp on fp.id = v.forma_pagamento_id
left join public.v_financeiro_parcelas p on p.venda_id = v.id
where v.status = 'ativa'
group by v.id, pe.nome, pr.nome, fp.nome, o.procedimento_id;

-- ─── Resumo do mês ───────────────────────────────────────────────────────────

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
                                and (p_procedimento is null or o.procedimento_id = p_procedimento)
                                and v.fechada_em >= lim.ini and v.fechada_em < lim.fim), 0)
  );
$$;

-- Quadro por procedimento: vendido e recebido no mês, em aberto e atrasado.
create or replace function public.financeiro_por_procedimento(p_clinica uuid, p_mes date)
returns table (procedimento_id uuid, procedimento text, negociacoes bigint, vendido_mes bigint, recebido_mes bigint,
               em_aberto bigint, atrasado bigint)
language sql
stable
set search_path = public
as $$
  with lim as (
    select date_trunc('month', p_mes)::date as ini, (date_trunc('month', p_mes) + interval '1 month')::date as fim
  ),
  neg as (
    select n.procedimento_id,
           count(*) as negociacoes,
           sum(n.valor_final_centavos) filter (where n.tipo = 'venda' and n.fechada_em >= lim.ini and n.fechada_em < lim.fim) as vendido,
           sum(n.saldo_centavos) as em_aberto,
           sum(n.atrasado_centavos) as atrasado
      from public.v_financeiro_negociacoes n, lim
     where n.clinica_id = p_clinica
     group by n.procedimento_id
  ),
  rec as (
    select p.procedimento_id, sum(pg.valor_centavos) as recebido
      from public.pagamentos pg join public.v_financeiro_parcelas p on p.id = pg.parcela_id, lim
     where p.clinica_id = p_clinica and pg.estornado_em is null and pg.pago_em >= lim.ini and pg.pago_em < lim.fim
     group by p.procedimento_id
  )
  select neg.procedimento_id, coalesce(pr.nome, 'Sem procedimento informado'), neg.negociacoes,
         coalesce(neg.vendido, 0)::bigint, coalesce(rec.recebido, 0)::bigint,
         coalesce(neg.em_aberto, 0)::bigint, coalesce(neg.atrasado, 0)::bigint
    from neg
    left join rec on rec.procedimento_id is not distinct from neg.procedimento_id
    left join public.procedimentos pr on pr.id = neg.procedimento_id
   order by 5 desc, 4 desc, 2;
$$;



-- ─── Cartão: recebido no ato (sem lembretes de cobrança) ─────────────────────

create or replace function public.quitar_recebidos_na_hora(p_venda uuid)
returns int
language plpgsql
set search_path = public
as $$
declare
  x record;
  n int := 0;
begin
  for x in
    select pa.id, pa.clinica_id, pa.valor_centavos - pa.valor_pago_centavos as saldo, pa.forma_pagamento_id
      from public.parcelas pa join public.formas_pagamento fx on fx.id = pa.forma_pagamento_id
     where pa.venda_id = p_venda and fx.recebe_na_hora and pa.status in ('pendente', 'parcial')
  loop
    insert into public.pagamentos (clinica_id, parcela_id, valor_centavos, pago_em, forma_pagamento_id, observacao)
    values (x.clinica_id, x.id, x.saldo, public.hoje_clinica(x.clinica_id), x.forma_pagamento_id, 'Recebido no cartão');
    n := n + 1;
  end loop;
  return n;
end;
$$;

-- ─── Registrar negociação ────────────────────────────────────────────────────

create or replace function public.registrar_negociacao(
  p_clinica             uuid,
  p_pessoa              uuid,
  p_procedimento        uuid,
  p_valor_centavos      bigint,
  p_desconto_centavos   bigint default 0,
  p_entrada_centavos    bigint default 0,
  p_entrada_em          date default null,
  p_entrada_forma       uuid default null,
  p_parcelas            int default 1,
  p_primeiro_vencimento date default null,
  p_forma               uuid default null,
  p_observacao          text default null
)
returns jsonb
language plpgsql
set search_path = public
as $$
declare
  v_hoje   date;
  v_op     public.oportunidades;
  v_venda  uuid;
  v_final  bigint := p_valor_centavos - coalesce(p_desconto_centavos, 0);
  v_antes  text := coalesce(current_setting('crm.acao_manual', true), '');
  f        public.formas_pagamento;
  fe       public.formas_pagamento;
begin
  if not public.pode_ver_financeiro(p_clinica) then
    raise exception 'Sem acesso ao financeiro.' using errcode = '42501';
  end if;
  v_hoje := public.hoje_clinica(p_clinica);
  if not exists (select 1 from public.pessoas where id = p_pessoa and clinica_id = p_clinica) then
    raise exception 'Paciente não encontrado.' using errcode = 'P0002';
  end if;
  if coalesce(p_valor_centavos, 0) <= 0 then
    raise exception 'Informe o valor.' using errcode = 'P0001';
  end if;
  if coalesce(p_desconto_centavos, 0) >= p_valor_centavos then
    raise exception 'O desconto não pode ser maior que o valor.' using errcode = 'P0001';
  end if;
  if coalesce(p_entrada_centavos, 0) > v_final then
    raise exception 'A entrada não pode ser maior que o valor final.' using errcode = 'P0001';
  end if;
  if p_forma is null then
    raise exception 'Escolha a forma de pagamento.' using errcode = 'P0001';
  end if;
  select * into f from public.formas_pagamento where id = p_forma and clinica_id = p_clinica and ativo;
  select * into fe from public.formas_pagamento where id = coalesce(p_entrada_forma, p_forma) and clinica_id = p_clinica and ativo;
  if f.id is null or fe.id is null then
    raise exception 'Forma de pagamento inválida.' using errcode = 'P0001';
  end if;
  if coalesce(p_parcelas, 1) > f.max_parcelas then
    raise exception '% permite no máximo % parcela(s).', f.nome, f.max_parcelas using errcode = 'P0001';
  end if;

  -- A negociação do paciente (ou uma nova, já com o procedimento).
  select * into v_op from public.oportunidades where pessoa_id = p_pessoa and status in ('aberta', 'pausada');
  if v_op.id is null then
    perform set_config('crm.acao_manual', 'on', true);
    insert into public.oportunidades (clinica_id, pessoa_id, procedimento_id, origem_id, etapa_id, responsavel_id)
    select p_clinica, p_pessoa, p_procedimento, pe.origem_id, (public.etapa_por_marco(p_clinica, 'avaliacao_realizada')).id,
           coalesce(pe.responsavel_id, auth.uid())
      from public.pessoas pe where pe.id = p_pessoa
    returning * into v_op;
    perform set_config('crm.acao_manual', v_antes, true);
  elsif p_procedimento is not null and v_op.procedimento_id is distinct from p_procedimento then
    update public.oportunidades set procedimento_id = p_procedimento where id = v_op.id;
  end if;

  -- A venda move a negociação para "Fechou" (gatilho) e as parcelas geram os lembretes.
  insert into public.vendas (clinica_id, pessoa_id, oportunidade_id, valor_total_centavos, desconto_centavos,
                             condicao_pagamento, entrada_centavos, quantidade_parcelas, forma_pagamento_id,
                             fechada_em, observacao_financeira)
  values (p_clinica, p_pessoa, v_op.id, p_valor_centavos, coalesce(p_desconto_centavos, 0),
          case when coalesce(p_parcelas, 1) = 1 and coalesce(p_entrada_centavos, 0) = 0 then 'a_vista' else 'parcelado' end
            ::public.condicao_pagamento,
          coalesce(p_entrada_centavos, 0), greatest(coalesce(p_parcelas, 1), 1), p_forma, v_hoje,
          nullif(btrim(p_observacao), ''))
  returning id into v_venda;

  perform public.gerar_parcelas(v_venda,
    coalesce(p_primeiro_vencimento, case when coalesce(p_entrada_centavos, 0) > 0 then v_hoje + 30 else v_hoje end),
    coalesce(p_entrada_em, v_hoje));
  update public.parcelas set forma_pagamento_id = fe.id where venda_id = v_venda and numero = 0;

  perform public.quitar_recebidos_na_hora(v_venda);

  return jsonb_build_object('venda_id', v_venda,
    'parcelas', (select count(*) from public.parcelas where venda_id = v_venda),
    'lembretes', (select count(*) from public.tarefas t join public.parcelas pa on pa.id = t.parcela_id
                   where pa.venda_id = v_venda and t.status = 'pendente'));
end;
$$;

-- ─── Registrar pagamento (total ou parcial) ──────────────────────────────────

create or replace function public.registrar_pagamento(
  p_parcela     uuid,
  p_valor       bigint default null,     -- vazio = o saldo inteiro
  p_data        date default null,
  p_forma       uuid default null,
  p_observacao  text default null
)
returns jsonb
language plpgsql
set search_path = public
as $$
declare
  p      public.parcelas;
  v_saldo bigint;
  v_valor bigint;
begin
  select * into p from public.parcelas where id = p_parcela for update;
  if p.id is null then
    raise exception 'Parcela não encontrada ou sem permissão.' using errcode = 'P0002';
  end if;
  if p.status not in ('pendente', 'parcial') then
    raise exception 'Esta parcela não está em aberto.' using errcode = 'P0001';
  end if;
  v_saldo := p.valor_centavos - p.valor_pago_centavos;
  v_valor := coalesce(p_valor, v_saldo);
  if v_valor <= 0 then
    raise exception 'Informe o valor recebido.' using errcode = 'P0001';
  end if;
  if v_valor > v_saldo then
    raise exception 'O valor é maior que o saldo da parcela (%).', public.formatar_brl(v_saldo) using errcode = 'P0001';
  end if;
  if p_data > public.hoje_clinica(p.clinica_id) then
    raise exception 'A data do pagamento não pode ser futura.' using errcode = 'P0001';
  end if;
  insert into public.pagamentos (clinica_id, parcela_id, valor_centavos, pago_em, forma_pagamento_id, observacao)
  values (p.clinica_id, p.id, v_valor, coalesce(p_data, public.hoje_clinica(p.clinica_id)),
          coalesce(p_forma, p.forma_pagamento_id), nullif(btrim(p_observacao), ''));
  select * into p from public.parcelas where id = p_parcela;
  return jsonb_build_object('status', p.status, 'saldo_centavos', p.valor_centavos - p.valor_pago_centavos);
end;
$$;

-- ─── Nova data prevista (o lembrete acompanha) ───────────────────────────────

create or replace function public.mudar_vencimento(p_parcela uuid, p_data date, p_observacao text default null)
returns void
language plpgsql
set search_path = public
as $$
declare
  p public.parcelas;
begin
  select * into p from public.parcelas where id = p_parcela for update;
  if p.id is null then
    raise exception 'Parcela não encontrada ou sem permissão.' using errcode = 'P0002';
  end if;
  if p.status not in ('pendente', 'parcial') then
    raise exception 'Esta parcela não está em aberto.' using errcode = 'P0001';
  end if;
  if p_data is null or p_data < public.hoje_clinica(p.clinica_id) then
    raise exception 'Escolha hoje ou uma data futura.' using errcode = 'P0001';
  end if;
  update public.parcelas
     set vencimento = p_data,
         observacao_financeira = coalesce(nullif(btrim(p_observacao), ''), observacao_financeira)
   where id = p_parcela;
end;
$$;

revoke execute on function public.resumo_financeiro(uuid, date, uuid) from anon;
revoke execute on function public.financeiro_por_procedimento(uuid, date) from anon;
revoke execute on function public.registrar_negociacao(uuid, uuid, uuid, bigint, bigint, bigint, date, uuid, int, date, uuid, text) from anon;
revoke execute on function public.registrar_pagamento(uuid, bigint, date, uuid, text) from anon;
revoke execute on function public.mudar_vencimento(uuid, date, text) from anon;

-- ---------------------------------------------------------------------------
-- 20261004120000_indicadores.sql
-- ---------------------------------------------------------------------------

-- =============================================================================
-- Migração 12: indicadores comerciais e de marketing
--   indicadores(clínica, de, até, procedimento) → leads, origem, procedimentos,
--   funil, conversão, perdas e reativação, sempre por período.
--   Gestão da clínica: sem rankings de pessoas da equipe.
--
-- Definições
--   • Lead: negociação aberta no período que não é reativação.
--   • Reativação: negociação que começou na etapa "Reativação" ou que retomou uma
--     negociação anterior (paciente antigo, campanha, retorno após tratamento…).
--   • Chegou à consulta: compareceu a uma consulta, passou por "Consulta realizada" ou fechou.
--   • Chegou ao orçamento: orçamento registrado ou fechou (o orçamento é apresentado na consulta).
-- =============================================================================

create or replace function public.indicadores(p_clinica uuid, p_de date, p_ate date, p_procedimento uuid default null)
returns jsonb
language sql
stable
set search_path = public
as $$
  with
  -- Negociações abertas no período, com a etapa em que começaram.
  ops as (
    select o.*,
           (select e.marco from public.historico_etapas h join public.etapas_funil e on e.id = h.etapa_nova_id
             where h.oportunidade_id = o.id order by h.mudou_em, h.id limit 1)              as marco_inicial,
           coalesce(o.origem_id, pe.origem_id)                                              as origem_lead
      from public.oportunidades o
      join public.pessoas pe on pe.id = o.pessoa_id
     where o.clinica_id = p_clinica
       and (o.criado_em at time zone 'America/Sao_Paulo')::date between p_de and p_ate
       and (p_procedimento is null or o.procedimento_id = p_procedimento)
  ),
  marcados as (
    select ops.*,
           (ops.marco_inicial = 'reativacao' or ops.oportunidade_origem_id is not null)    as eh_reativacao,
           exists (select 1 from public.agendamentos a where a.oportunidade_id = ops.id)    as agendou,
           (ops.status = 'ganha'
            or exists (select 1 from public.agendamentos a where a.oportunidade_id = ops.id and a.status = 'compareceu')
            or exists (select 1 from public.historico_etapas h join public.etapas_funil e on e.id = h.etapa_nova_id
                        where h.oportunidade_id = ops.id and e.marco = 'avaliacao_realizada'))  as consultou,
           (ops.status = 'ganha'
            or exists (select 1 from public.orcamentos oc where oc.oportunidade_id = ops.id and oc.status <> 'rascunho')) as orcou
      from ops
  ),
  leads as (select * from marcados where not eh_reativacao),
  reativ as (select * from marcados where eh_reativacao),
  -- Encerradas como perda no período (pela data de encerramento).
  perdas as (
    select o.*, m.nome as motivo,
           coalesce(m.grupo_perda, case when o.resultado = 'desistiu' then 'desistiu' else 'outro' end) as grupo
      from public.oportunidades o left join public.motivos m on m.id = o.motivo_id
     where o.clinica_id = p_clinica and o.status = 'perdida'
       and (o.fechada_em at time zone 'America/Sao_Paulo')::date between p_de and p_ate
       and (p_procedimento is null or o.procedimento_id = p_procedimento)
  ),
  sem_resposta as (
    select o.* from public.oportunidades o
     where o.clinica_id = p_clinica and o.status = 'pausada'
       and (o.etapa_desde at time zone 'America/Sao_Paulo')::date between p_de and p_ate
       and (p_procedimento is null or o.procedimento_id = p_procedimento)
  )
  select jsonb_build_object(
    'leads', jsonb_build_object(
      'novos', (select count(*) from leads),
      'convertidos', (select count(*) from leads where status = 'ganha'),
      'em_negociacao', (select count(*) from leads where status = 'aberta'),
      'sem_resposta', (select count(*) from leads where status = 'pausada'),
      'perdidos', (select count(*) from leads where status = 'perdida')),
    'por_procedimento', coalesce((
      select jsonb_agg(x order by x.leads desc, x.procedimento) from (
        select l.procedimento_id, coalesce(pr.nome, 'Não definido') as procedimento, count(*) as leads,
               count(*) filter (where l.status = 'ganha') as convertidos
          from leads l left join public.procedimentos pr on pr.id = l.procedimento_id
         group by 1, 2) x), '[]'::jsonb),
    -- Canais: sempre os seis, mesmo zerados (Instagram, indicação, Google, WhatsApp, paciente antigo, outro).
    'por_canal', (
      select jsonb_agg(x order by x.ordem) from (
        select c.canal, c.ordem, count(l.id) as leads, count(l.id) filter (where l.status = 'ganha') as convertidos
          from (values ('instagram', 1), ('indicacao', 2), ('google', 3), ('whatsapp', 4), ('paciente_antigo', 5), ('outro', 6))
               as c (canal, ordem)
          left join (leads l left join public.origens og on og.id = l.origem_lead)
                 on coalesce(og.canal, 'outro') = c.canal
         group by c.canal, c.ordem) x),
    'por_origem', coalesce((
      select jsonb_agg(x order by x.leads desc, x.origem) from (
        select coalesce(og.nome, 'Não informada') as origem, coalesce(og.canal, 'outro') as canal, count(*) as leads,
               count(*) filter (where l.status = 'ganha') as convertidos
          from leads l left join public.origens og on og.id = l.origem_lead
         group by 1, 2) x), '[]'::jsonb),
    'conversao', jsonb_build_object(
      'leads', (select count(*) from leads),
      'agendaram', (select count(*) from leads where agendou or consultou),
      'consulta', (select count(*) from leads where consultou),
      'orcamento', (select count(*) from leads where orcou),
      'fechamento', (select count(*) from leads where status = 'ganha')),
    -- Funil: onde está agora cada pessoa que entrou no funil no período (leads e reativações).
    'funil', coalesce((
      select jsonb_agg(jsonb_build_object('etapa', e.nome, 'cor', e.cor, 'tipo', e.tipo,
               'quantidade', (select count(*) from marcados m where m.etapa_id = e.id)) order by e.ordem)
        from public.etapas_funil e where e.clinica_id = p_clinica and e.ativo), '[]'::jsonb),
    'perdas', jsonb_build_object(
      'total', (select count(*) from perdas) + (select count(*) from sem_resposta),
      -- Grupos: preço, desistiu, não respondeu, escolheu outro local, adiou, outro.
      'grupos', jsonb_build_object(
        'preco', (select count(*) from perdas where grupo = 'preco'),
        'desistiu', (select count(*) from perdas where grupo = 'desistiu'),
        'nao_respondeu', (select count(*) from perdas where grupo = 'nao_respondeu') + (select count(*) from sem_resposta),
        'outro_local', (select count(*) from perdas where grupo = 'outro_local'),
        'adiou', (select count(*) from perdas where grupo = 'adiou'),
        'outro', (select count(*) from perdas where grupo = 'outro')),
      'motivos', coalesce((
        select jsonb_agg(x order by x.quantidade desc, x.motivo) from (
          select coalesce(motivo, 'Sem motivo registrado') as motivo, count(*) as quantidade from perdas group by 1
          union all
          select 'Parou de responder (em "Sem resposta")', count(*) from sem_resposta having count(*) > 0
        ) x), '[]'::jsonb)),
    'reativacao', jsonb_build_object(
      'elegiveis', (select count(*) from public.v_contatos c
                     where c.clinica_id = p_clinica and c.relacionamento = 'paciente_inativo'
                       and c.arquivado_em is null and not c.nao_contatar and c.consentimento_contato
                       and c.oportunidade_id is null),
      'reativados', (select count(*) from reativ),
      'responderam', (select count(*) from reativ r
                       where r.status = 'ganha' or r.agendou
                          or (r.status = 'aberta' and (select e.marco from public.etapas_funil e where e.id = r.etapa_id) is distinct from 'reativacao')
                          or exists (select 1 from public.interacoes i where i.oportunidade_id = r.id
                                      and i.tipo in ('paciente_respondeu', 'retorno_solicitado'))),
      'agendaram', (select count(*) from reativ where agendou),
      'fecharam', (select count(*) from reativ where status = 'ganha'),
      'aguardando', (select count(*) from reativ r where r.status = 'aberta'
                       and (select e.marco from public.etapas_funil e where e.id = r.etapa_id) = 'reativacao'),
      'sem_retorno', (select count(*) from reativ where status in ('perdida', 'pausada')))
  );
$$;

revoke execute on function public.indicadores(uuid, date, date, uuid) from anon;

-- ---------------------------------------------------------------------------
-- 20261005120000_agenda_financeiro.sql
-- ---------------------------------------------------------------------------

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

-- ---------------------------------------------------------------------------
-- 20261006120000_prontuario.sql
-- ---------------------------------------------------------------------------

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

-- ---------------------------------------------------------------------------
-- Dados fictícios e modo de teste (seed.sql)
-- ---------------------------------------------------------------------------

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

  -- Consulta de hoje, com o valor do procedimento: para testar "Compareceu" + pagamento.
  insert into public.pessoas (clinica_id, nome, whatsapp_e164, cidade, uf, origem_id)
  values (c, 'Renata Alves', '+5511900000016', 'São Paulo', 'SP',
          (select id from public.origens where clinica_id = c and nome = 'Indicação de paciente'))
  returning id into p;
  insert into public.agendamentos (clinica_id, pessoa_id, profissional_id, tipo, procedimento_id, inicio, duracao_min,
                                   status, confirmado_em, valor_centavos)
  values (c, p, (select id from public.profissionais where clinica_id = c and nome = 'Dra. Lívia Moraes'), 'procedimento',
          (select id from public.procedimentos where clinica_id = c and nome = 'Clareamento dental'),
          (hoje + time '08:30') at time zone 'America/Sao_Paulo', 60, 'confirmado', now(), 180000);
  update public.agendamentos set valor_centavos = 350000
   where clinica_id = c and pessoa_id = (select id from public.pessoas where clinica_id = c and nome = 'Ana Costa');

  -- Prontuário da Maria: consulta 01 (avaliação, finalizada) com odontograma e plano de tratamento.
  insert into public.atendimentos (clinica_id, prontuario_id, pessoa_id, profissional_id, data, horario, tipo, procedimento_id,
                                   motivo, anamnese, anamnese_obs, diagnostico, evolucao, orientacoes, retorno_em, odontograma,
                                   status, finalizado_em)
  select c, pr.id, pr.pessoa_id, prof, hoje - 14, time '10:00', 'avaliacao',
         (select id from public.procedimentos where clinica_id = c and nome = 'Facetas de porcelana'),
         array['Avaliação', 'Estética'], array['Hipertensão'], 'Losartana 50 mg.', array['Manchas / escurecimento', 'Desgaste dental'],
         'Avaliação estética completa. Limpeza realizada. Planejado clareamento e facetas.',
         array['Higiene oral reforçada', 'Evitar alimentos com corante'], hoje + 7,
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
     'aceito', null, null),
    (c, orc, (select id from public.procedimentos where clinica_id = c and nome = 'Facetas de porcelana'), 1400000, '13 a 23', v,
     'orcado', null, null);

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

select teste.carregar_dados_ficticios();

commit;

-- Logins de teste: anote o e-mail e a senha de cada um.
-- (Para gerar senhas novas depois: select * from teste.criar_logins_de_teste();)
select * from teste.criar_logins_de_teste();
