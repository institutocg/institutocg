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

-- Substitui {primeiro_nome}, {procedimento}, {consulta}, {data}, {horario} e {valor}.
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
  v_nome  text;
  v_texto text := p_texto;
begin
  if v_texto is null then return null; end if;
  select coalesce(nullif(apelido_tratamento, ''), split_part(nome, ' ', 1)) into v_nome
    from public.pessoas where id = p_pessoa;
  v_texto := replace(v_texto, '{primeiro_nome}', coalesce(v_nome, ''));
  v_texto := replace(v_texto, '{procedimento}', coalesce(lower(p_procedimento), 'o seu tratamento'));
  v_texto := replace(v_texto, '{consulta}', coalesce(p_extras ->> 'consulta', 'a consulta'));
  v_texto := replace(v_texto, '{data}', coalesce(p_extras ->> 'data', ''));
  v_texto := replace(v_texto, '{horario}', coalesce(p_extras ->> 'horario', ''));
  v_texto := replace(v_texto, '{valor}', coalesce(p_extras ->> 'valor', ''));
  return v_texto;
end;
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
  select public.renderizar_texto(
    (select texto from public.modelos_mensagem
      where clinica_id = p_clinica and situacao = p_situacao and ativo order by criado_em limit 1),
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
      p_extras => jsonb_build_object('consulta', v_rotulo, 'data', to_char(v_dia, 'DD/MM'), 'horario', v_hora));
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
