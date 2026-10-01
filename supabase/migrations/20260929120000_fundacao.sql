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
