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

-- Intervalos da cadência (em dias entre tentativas). Tipos sem cadência própria
-- usam a de "follow_up".
create or replace function public.cadencia(p_clinica uuid, p_tipo text)
returns int[]
language sql stable security definer set search_path = public
as $$
  select coalesce(
    (select array_agg(x.valor::int order by x.ordem)
       from public.clinicas c,
            jsonb_array_elements_text(c.configuracoes -> 'cadencias' -> p_tipo) with ordinality as x(valor, ordem)
      where c.id = p_clinica),
    case p_tipo
      when 'primeiro_contato'      then array[0, 1, 3]
      when 'follow_up_orcamento'   then array[3, 7, 14]
      when 'acompanhar_decisao'    then array[4, 10, 20]
      when 'recuperar_desmarcacao' then array[0, 3, 7]
      when 'recuperar_falta'       then array[0, 2, 5]
      when 'reabrir_sem_resposta'  then array[7, 21, 45]
      when 'reativacao'            then array[0, 21]
      when 'manutencao'            then array[0, 21]
    end,
    case when p_tipo <> 'follow_up' then public.cadencia(p_clinica, 'follow_up') end,
    array[2, 4, 7]
  );
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

create or replace function public.renderizar_mensagem(
  p_clinica uuid,
  p_situacao text,
  p_pessoa uuid,
  p_procedimento text default null,
  p_extras jsonb default '{}'::jsonb
)
returns text
language plpgsql stable security definer set search_path = public
as $$
declare
  v_texto text;
  v_nome  text;
begin
  select texto into v_texto from public.modelos_mensagem
   where clinica_id = p_clinica and situacao = p_situacao and ativo
   order by criado_em limit 1;
  if v_texto is null then return null; end if;

  select coalesce(nullif(apelido_tratamento, ''), split_part(nome, ' ', 1)) into v_nome
    from public.pessoas where id = p_pessoa;

  v_texto := replace(v_texto, '{primeiro_nome}', coalesce(v_nome, ''));
  v_texto := replace(v_texto, '{procedimento}', coalesce(lower(p_procedimento), 'o seu tratamento'));
  v_texto := replace(v_texto, '{data}', coalesce(p_extras ->> 'data', ''));
  v_texto := replace(v_texto, '{horario}', coalesce(p_extras ->> 'horario', ''));
  v_texto := replace(v_texto, '{valor}', coalesce(p_extras ->> 'valor', ''));
  return v_texto;
end;
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
  p_categoria    public.categoria_tarefa default 'vendas'
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
    p_regra, 'op:' || p_oportunidade, p_passo, p_descricao);
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
  v_nome   text;
  v_proc   text;
  v_hoje   date;
  v_gaps   int[];
  v_tipo   public.tipo_tarefa;
  v_cat    public.categoria_tarefa := 'vendas';
  v_prio   public.prioridade_tarefa := 'normal';
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
  select lower(nome) into v_proc from public.procedimentos where id = op.procedimento_id;
  v_hoje := public.hoje_clinica(op.clinica_id);

  case
    when et.marco = 'novo_contato' then
      v_tipo := 'primeiro_contato'; v_prio := 'urgente'; v_vence := v_hoje;
      v_titulo := 'Fazer o primeiro contato com ' || v_nome;
      v_expl := 'Primeiro retorno ainda hoje — quem recebe resposta rápida tem mais chance de agendar.';

    when et.marco = 'em_contato' then
      v_tipo := 'follow_up'; v_prio := 'alta';
      if p_nova then
        v_vence := v_hoje;
        v_titulo := 'Conversar com ' || v_nome || coalesce(' sobre ' || v_proc, '');
        v_desc := 'Demonstrou interesse' || coalesce(' em ' || v_proc, '');
      else
        v_vence := v_hoje + 1;
        v_titulo := 'Conduzir ' || v_nome || ' para a avaliação';
      end if;
      v_expl := 'Conversa para entender o que a pessoa busca e convidar para a avaliação.';

    when et.marco = 'avaliacao_agendada' then
      v_tipo := 'confirmar_agendamento'; v_cat := 'agenda'; v_requer := 'agendamento';
      v_titulo := 'Confirmar a avaliação de ' || v_nome;
      v_expl := 'Informe a data e o horário: a confirmação fica marcada para a véspera (dia útil).';

    when et.marco = 'avaliacao_realizada' then
      v_tipo := 'apresentar_orcamento'; v_prio := 'alta'; v_vence := v_hoje;
      v_titulo := 'Registrar o orçamento de ' || v_nome;
      v_expl := 'Anote o orçamento apresentado para começar o acompanhamento.';

    when et.marco = 'orcamento_apresentado' then
      v_gaps := public.cadencia(op.clinica_id, 'follow_up_orcamento');
      v_tipo := 'follow_up_orcamento'; v_prio := 'alta'; v_vence := v_hoje + v_gaps[1];
      v_titulo := 'Retornar ' || v_nome || coalesce(' sobre ' || v_proc, ' sobre o orçamento');
      v_expl := 'Um follow-up leve em ' || v_gaps[1] || ' dias, perguntando se ficou alguma dúvida. Depois, no máximo mais '
                || (array_length(v_gaps, 1) - 1) || ' contatos espaçados.';

    when et.marco = 'em_negociacao' then
      v_gaps := public.cadencia(op.clinica_id, 'acompanhar_decisao');
      v_tipo := 'acompanhar_decisao'; v_vence := v_hoje + v_gaps[1];
      v_titulo := 'Acompanhar a decisão de ' || v_nome;
      v_expl := 'Sequência de acompanhamento sem pressão: ' || array_length(v_gaps, 1) || ' contatos espaçados ('
                || array_to_string(v_gaps, ', ') || ' dias). Se a pessoa responder, a sequência para.';

    when et.marco = 'desmarcou' then
      v_tipo := 'recuperar_desmarcacao'; v_cat := 'recuperacao'; v_prio := 'urgente'; v_vence := v_hoje;
      v_titulo := 'Falar com ' || v_nome || ', que desmarcou';
      v_expl := 'Contato ainda hoje, com acolhimento, para entender o motivo e oferecer um novo horário.';

    when et.marco = 'reativacao' then
      v_tipo := 'reativacao'; v_cat := 'reativacao'; v_prio := 'baixa'; v_vence := v_hoje;
      v_titulo := 'Retomar contato com ' || v_nome;
      v_expl := 'Mensagem de reaproximação, sem oferta agressiva. Respeita um intervalo mínimo desde o último contato.';

    when et.resultado = 'fechou' then
      v_tipo := 'agendar_tratamento'; v_prio := 'alta'; v_vence := v_hoje; v_requer := 'financeiro';
      v_titulo := 'Agendar o início do tratamento de ' || v_nome;
      v_desc := 'Fechou' || coalesce(' ' || v_proc, '') || '. Combine a data de início.';
      v_expl := 'Registre as condições de pagamento: os lembretes de cada parcela são criados sozinhos.';

    when et.resultado in ('nao_fechou', 'desistiu') then
      v_requer := 'motivo';
      v_tipo := case when et.resultado = 'desistiu' then 'reativacao' else 'retorno_por_motivo' end;
      v_cat := case when et.resultado = 'desistiu' then 'reativacao' else 'recuperacao' end;
      v_prio := 'baixa';
      v_titulo := 'Retomar conversa com ' || v_nome || coalesce(' sobre ' || v_proc, '');
      if mo.id is not null then
        v_desc := case when et.resultado = 'desistiu' then 'Desistiu: ' else 'Não fechou: ' end || lower(mo.nome);
        if mo.retorno_sugerido_dias is not null then
          v_vence := coalesce(op.reabre_em, v_hoje + mo.retorno_sugerido_dias);
          v_expl := 'A pessoa não é esquecida: um contato leve em ' || mo.retorno_sugerido_dias
                    || ' dias (prazo sugerido para "' || lower(mo.nome) || '"). Até lá, nenhuma mensagem.';
        else
          v_tipo := null;
          v_expl := 'Para "' || lower(mo.nome) || '" não há retorno programado. Você pode escolher uma data, se quiser.';
        end if;
      else
        v_expl := 'Escolha o motivo: ele define quando faz sentido voltar a conversar.';
      end if;

    when et.resultado = 'sem_resposta' then
      v_gaps := public.cadencia(op.clinica_id, 'reabrir_sem_resposta');
      v_tipo := 'reabrir_sem_resposta'; v_cat := 'recuperacao'; v_vence := v_hoje + v_gaps[1];
      v_titulo := 'Tentar novo contato com ' || v_nome;
      v_desc := 'Sem resposta' || coalesce(' sobre ' || v_proc, '');
      v_expl := 'Nova tentativa leve em ' || v_gaps[1] || ' dias; no máximo ' || array_length(v_gaps, 1)
                || ' tentativas bem espaçadas (' || array_to_string(v_gaps, ', ') || ' dias).';

    else -- etapa personalizada
      v_tipo := 'follow_up'; v_vence := v_hoje + 2;
      v_titulo := 'Acompanhar ' || v_nome || coalesce(' sobre ' || v_proc, '');
      v_expl := 'Acompanhamento em 2 dias.';
  end case;

  if v_vence is not null then
    v_vence := public.proximo_dia_util(op.clinica_id, greatest(v_vence, v_hoje));
  end if;

  return jsonb_build_object(
    'tipo', v_tipo,
    'categoria', v_cat,
    'prioridade', v_prio,
    'titulo', v_titulo,
    'descricao', v_desc,
    'vence_em', v_vence,
    'explicacao', v_expl,
    'requer', v_requer,
    'mensagem', case when v_tipo is not null
                     then public.renderizar_mensagem(op.clinica_id, v_tipo::text, op.pessoa_id, v_proc) end
  );
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
  s jsonb;
begin
  s := public.sugerir_acao(p_oportunidade, (select etapa_id from public.oportunidades where id = p_oportunidade),
                           null, p_nova);
  if s is null or s ->> 'tipo' is null or s ->> 'vence_em' is null or s ->> 'requer' = 'agendamento' then
    return null;
  end if;
  return public.definir_proxima_acao(
    p_oportunidade, (s ->> 'tipo')::public.tipo_tarefa, s ->> 'titulo', (s ->> 'vence_em')::date,
    (s ->> 'prioridade')::public.prioridade_tarefa, p_regra, 1, s ->> 'descricao',
    (s ->> 'categoria')::public.categoria_tarefa);
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

-- Novo agendamento → confirmar na véspera; avaliação move o funil.
create or replace function public.motor_novo_agendamento()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare
  v_nome  text;
  v_dia   date := (new.inicio at time zone 'America/Sao_Paulo')::date;
  v_rotulo text := case new.tipo
    when 'avaliacao' then 'a avaliação'
    when 'apresentacao_orcamento' then 'a apresentação do orçamento'
    when 'procedimento' then 'o procedimento'
    when 'retorno' then 'o retorno'
    when 'manutencao' then 'a manutenção'
    else 'a ligação' end;
begin
  if new.status not in ('agendado', 'confirmado') then return null; end if;
  select split_part(nome, ' ', 1) into v_nome from public.pessoas where id = new.pessoa_id;

  if new.oportunidade_id is not null then
    if new.tipo = 'avaliacao' then
      perform public.avancar_para_marco(new.oportunidade_id, 'avaliacao_agendada', 'Avaliação agendada');
    end if;
    -- Com a consulta marcada, a "próxima ação" passa a ser a confirmação.
    update public.tarefas
       set status = 'concluida', resultado = 'Agendou ' || v_rotulo
     where chave_dedupe = 'op:' || new.oportunidade_id and status = 'pendente'
       and tipo in ('primeiro_contato', 'follow_up', 'recuperar_desmarcacao', 'recuperar_falta',
                    'retorno_por_motivo', 'reabrir_sem_resposta', 'definir_proxima_acao');
  end if;

  if new.status = 'agendado' and new.tipo <> 'ligacao_agendada' and v_dia > public.hoje_clinica(new.clinica_id) then
    perform public.criar_tarefa_auto(
      new.pessoa_id, new.oportunidade_id, 'confirmar_agendamento', 'agenda',
      'Confirmar ' || v_rotulo || ' de ' || v_nome,
      public.dia_util_anterior(new.clinica_id, v_dia), 'normal', 'R-AG-01', 'ag:' || new.id,
      p_agendamento => new.id,
      p_mensagem => public.renderizar_mensagem(new.clinica_id, 'confirmar_agendamento', new.pessoa_id, null,
        jsonb_build_object('data', to_char(v_dia, 'DD/MM'),
                           'horario', to_char(new.inicio at time zone 'America/Sao_Paulo', 'HH24:MI'))));
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
  v_nome text;
  v_hoje date := public.hoje_clinica(new.clinica_id);
  v_chave text;
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

  if new.status = 'desmarcado' then
    update public.tarefas set status = 'cancelada', cancelada_motivo = 'Substituída pela recuperação'
     where chave_dedupe = v_chave and status = 'pendente';
    perform public.criar_tarefa_auto(
      new.pessoa_id, new.oportunidade_id, 'recuperar_desmarcacao', 'recuperacao',
      'Falar com ' || v_nome || ', que desmarcou', v_hoje, 'urgente', 'R-AG-02', v_chave,
      p_agendamento => new.id,
      p_descricao => 'Desmarcou o agendamento de ' || to_char(new.inicio at time zone 'America/Sao_Paulo', 'DD/MM "às" HH24:MI'));

  elsif new.status = 'faltou' then
    update public.tarefas set status = 'cancelada', cancelada_motivo = 'Substituída pela recuperação'
     where chave_dedupe = v_chave and status = 'pendente';
    perform public.criar_tarefa_auto(
      new.pessoa_id, new.oportunidade_id, 'recuperar_falta', 'recuperacao',
      'Falar com ' || v_nome || ', que faltou', v_hoje, 'urgente', 'R-AG-03', v_chave,
      p_agendamento => new.id,
      p_descricao => 'Faltou ao agendamento de ' || to_char(new.inicio at time zone 'America/Sao_Paulo', 'DD/MM "às" HH24:MI'));

  elsif new.status = 'cancelado_clinica' then
    perform public.criar_tarefa_auto(
      new.pessoa_id, new.oportunidade_id, 'follow_up', 'agenda',
      'Remarcar o horário de ' || v_nome, v_hoje, 'alta', 'R-AG-04', v_chave,
      p_agendamento => new.id, p_descricao => 'A clínica cancelou o horário');

  elsif new.status = 'compareceu' and new.tipo = 'avaliacao' and new.oportunidade_id is not null then
    perform public.avancar_para_marco(new.oportunidade_id, 'avaliacao_realizada', 'Compareceu à avaliação');
    if not exists (select 1 from public.orcamentos o where o.oportunidade_id = new.oportunidade_id
                    and o.status in ('apresentado', 'em_negociacao', 'aprovado')) then
      perform public.definir_proxima_acao(
        new.oportunidade_id, 'apresentar_orcamento', 'Registrar o orçamento de ' || v_nome,
        v_hoje, 'alta', 'R-AG-05', p_descricao => 'Compareceu à avaliação');
    end if;
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
declare
  v_nome text;
  v_proc text;
  v_gaps int[];
begin
  if new.status <> 'apresentado' or (tg_op = 'UPDATE' and old.status = 'apresentado') then
    return null;
  end if;
  select split_part(p.nome, ' ', 1), lower(pr.nome) into v_nome, v_proc
    from public.oportunidades o
    join public.pessoas p on p.id = o.pessoa_id
    left join public.procedimentos pr on pr.id = o.procedimento_id
   where o.id = new.oportunidade_id;
  v_gaps := public.cadencia(new.clinica_id, 'follow_up_orcamento');

  perform public.avancar_para_marco(new.oportunidade_id, 'orcamento_apresentado', 'Orçamento apresentado');
  perform public.definir_proxima_acao(
    new.oportunidade_id, 'follow_up_orcamento',
    'Retornar ' || v_nome || coalesce(' sobre ' || v_proc, ' sobre o orçamento'),
    coalesce(new.apresentado_em, public.hoje_clinica(new.clinica_id)) + v_gaps[1],
    'alta', 'R-OR-01', 1);
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
  p_agendar_em    timestamptz default null
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
  v_cadencia text;
  v_marco   text;
  v_prox    uuid;
  v_ag      uuid;
  v_tipo_i  public.tipo_interacao;
  v_rotulo  text;
  v_res     jsonb;
  v_nova    uuid;
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
                            'numero_invalido', 'confirmou', 'desmarcou', 'prometeu_pagar') then
    raise exception 'Resultado desconhecido: %', p_resultado using errcode = 'P0001';
  end if;

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
        v_cadencia := case when t.tipo = 'confirmar_agendamento' then 'follow_up' else t.tipo::text end;
        v_gaps := public.cadencia(t.clinica_id, v_cadencia);
        if t.tipo = 'confirmar_agendamento' then
          -- Não confirmou: uma nova tentativa no próprio dia do agendamento.
          if t.passo = 1 and (select (inicio at time zone 'America/Sao_Paulo')::date from public.agendamentos
                              where id = t.agendamento_id) >= v_hoje then
            v_prox := public.criar_tarefa_auto(t.pessoa_id, t.oportunidade_id, t.tipo, t.categoria,
                        'Tentar confirmar novamente: ' || v_nome,
                        (select (inicio at time zone 'America/Sao_Paulo')::date from public.agendamentos where id = t.agendamento_id),
                        'alta', 'R-AG-06', t.chave_dedupe, 2, 'Não respondeu à primeira confirmação',
                        t.agendamento_id, t.mensagem_sugerida);
          end if;
        elsif t.passo < coalesce(array_length(v_gaps, 1), 0) then
          if v_op.id is not null and v_op.status = 'aberta' then
            v_prox := public.definir_proxima_acao(v_op.id, t.tipo, t.titulo,
                        v_hoje + greatest(v_gaps[t.passo + 1], 1), t.prioridade, 'R-CAD-01', t.passo + 1, t.descricao,
                        t.categoria);
          else
            v_prox := public.criar_tarefa_auto(t.pessoa_id, t.oportunidade_id, t.tipo, t.categoria, t.titulo,
                        v_hoje + greatest(v_gaps[t.passo + 1], 1), t.prioridade, 'R-CAD-01', t.chave_dedupe,
                        t.passo + 1, t.descricao, t.agendamento_id);
          end if;
        elsif v_op.id is not null and v_op.status in ('aberta', 'pausada') then
          v_prox := public.definir_proxima_acao(v_op.id, 'definir_proxima_acao',
                      'Decidir o próximo passo com ' || v_nome,
                      v_hoje + 2, 'normal', 'R-CAD-02', 1,
                      'Sem retorno depois de ' || t.passo || ' tentativas: continuar acompanhando ou encerrar?');
        end if;
      elsif v_op.id is not null and v_op.status = 'aberta' and p_data is not null then
        v_prox := public.definir_proxima_acao(v_op.id, 'follow_up', 'Acompanhar ' || v_nome || coalesce(' sobre ' || v_proc, ''),
                    p_data, 'normal', 'R-CAD-03');
      end if;

    when 'respondeu_interesse' then
      if v_marco in ('novo_contato', 'desmarcou', 'reativacao') then
        perform public.avancar_para_marco(v_op.id, 'em_contato', 'Respondeu com interesse');
      end if;
      v_prox := public.definir_proxima_acao(v_op.id, 'follow_up',
                  case when v_marco in ('novo_contato', 'em_contato')
                       then 'Conduzir ' || v_nome || ' para a avaliação'
                       else 'Continuar a conversa com ' || v_nome end,
                  coalesce(p_data, v_hoje + 1), 'alta', 'R-RES-01');

    when 'agendou' then
      insert into public.agendamentos (clinica_id, pessoa_id, oportunidade_id, profissional_id, tipo, inicio)
      values (t.clinica_id, t.pessoa_id, v_op.id,
              (select id from public.profissionais where clinica_id = t.clinica_id and ativo order by criado_em limit 1),
              case when v_marco in ('avaliacao_realizada', 'orcamento_apresentado', 'em_negociacao')
                   then 'apresentacao_orcamento' else 'avaliacao' end::public.tipo_agendamento,
              p_agendar_em)
      returning id into v_ag;
      -- Se a recuperação veio de um agendamento desmarcado, registra a remarcação.
      if t.agendamento_id is not null and t.tipo in ('recuperar_desmarcacao', 'recuperar_falta') then
        update public.agendamentos set remarcado_para_id = v_ag where id = t.agendamento_id;
      end if;
      select id into v_prox from public.tarefas where chave_dedupe = 'ag:' || v_ag and status = 'pendente';

    when 'vai_pensar' then
      -- Começa a sequência de acompanhamento (espaçada e sem pressão).
      perform public.avancar_para_marco(v_op.id, 'em_negociacao', 'Ficou de pensar');
      v_gaps := public.cadencia(t.clinica_id, 'acompanhar_decisao');
      v_prox := public.definir_proxima_acao(v_op.id, 'acompanhar_decisao',
                  'Acompanhar a decisão de ' || v_nome,
                  coalesce(p_data, v_hoje + v_gaps[1]), 'normal', 'R-RES-02', 1, 'Ficou de pensar');

    when 'pediu_retorno' then
      v_prox := public.definir_proxima_acao(v_op.id, 'follow_up',
                  'Retornar para ' || v_nome || ' (pediu retorno)', p_data, 'alta', 'R-RES-03');

    when 'fechou' then
      perform public.mover_etapa(v_op.id, public.etapa_por_resultado(t.clinica_id, 'fechou'), p_observacao);
      select id into v_prox from public.tarefas where chave_dedupe = 'op:' || v_op.id and status = 'pendente';

    when 'nao_fechou', 'desistiu' then
      if v_op.id is not null and v_op.status in ('aberta', 'pausada') then
        update public.oportunidades set reabre_em = p_data where id = v_op.id;
        perform public.mover_etapa(v_op.id,
          public.etapa_por_resultado(t.clinica_id, p_resultado::public.resultado_oportunidade),
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
                  'Buscar outro telefone de ' || v_nome, v_hoje, 'alta', 'R-RES-04',
                  coalesce('op:' || v_op.id, 'pessoa:' || t.pessoa_id),
                  p_descricao => 'O número cadastrado não funcionou');

    when 'confirmou' then
      update public.agendamentos set status = 'confirmado' where id = t.agendamento_id;

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
                coalesce(p_data, v_hoje + 2), 'normal', 'R-GAR-01');
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
  p_mensagem     text default null
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

  return public.criar_tarefa_auto(p_pessoa, v_op, p_tipo, 'reativacao', p_titulo, p_vence, 'baixa', p_regra,
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
  v_meses      int := coalesce((v_cfg ->> 'meses_paciente_inativo')::int, 12);
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
      r.nome || ' compareceu?', v_hoje, 'alta', 'R-DIA-04', 'ag:' || r.id,
      p_descricao => 'Consulta de ' || to_char(r.inicio at time zone 'America/Sao_Paulo', 'DD/MM "às" HH24:MI')
                     || ' sem registro de comparecimento',
      p_agendamento => r.id);
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
                                   v_hoje, 'alta', 'R-DIA-01') is not null then
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

  -- Reativação e manutenção: somente quando ligadas (desligadas durante o recadastramento).
  if coalesce((v_cfg ->> 'reativacao_automatica')::boolean, false) then
    -- Manutenção devida (procedimento com ciclo de retorno).
    for r in
      select distinct on (p.id) p.id, split_part(p.nome, ' ', 1) as nome, pr.id as proc_id, pr.nome as proc, ta.realizado_em
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
       limit v_limite
    loop
      if public.abrir_reativacao(r.id, null, r.proc_id, 'manutencao',
           'Lembrar ' || r.nome || ' da manutenção', lower(r.proc) || ' em ' || to_char(r.realizado_em, 'MM/YYYY'),
           v_hoje, 'R-DIA-02', public.renderizar_mensagem(p_clinica, 'manutencao', r.id, r.proc)) is not null then
        v_manut := v_manut + 1;
      end if;
    end loop;

    -- Pacientes inativos.
    for r in
      select c.id, split_part(c.nome, ' ', 1) as nome, c.ultimo_atendimento_em
        from public.v_contatos c
       where c.clinica_id = p_clinica and c.relacionamento = 'paciente_inativo'
         and c.arquivado_em is null and not c.nao_contatar and c.consentimento_contato
         and c.oportunidade_id is null and c.proxima_tarefa_id is null
         and (c.ultimo_contato_em is null or c.ultimo_contato_em < now() - make_interval(days => v_intervalo))
         and not exists (select 1 from public.tarefas t where t.pessoa_id = c.id and t.tipo in ('manutencao', 'reativacao')
                           and t.criado_em > now() - interval '90 days')
       order by c.ultimo_atendimento_em nulls first
       limit greatest(v_limite - v_manut, 0)
    loop
      if public.abrir_reativacao(r.id, null, null, 'reativacao',
           'Reativar contato com ' || r.nome,
           case when r.ultimo_atendimento_em is null then 'Paciente antigo sem atendimento recente'
                else 'Último atendimento em ' || to_char(r.ultimo_atendimento_em, 'MM/YYYY') end,
           v_hoje, 'R-DIA-03') is not null then
        v_reativ := v_reativ + 1;
      end if;
    end loop;
  end if;

  update public.execucoes_rotina
     set resumo = jsonb_build_object('orcamentos_expirados', v_expirados, 'proximas_acoes_criadas', v_sentinela,
                                     'manutencoes', v_manut, 'reativacoes', v_reativ, 'retornos', v_retornos)
   where clinica_id = p_clinica and dia = v_hoje;

  return jsonb_build_object('orcamentos_expirados', v_expirados, 'proximas_acoes_criadas', v_sentinela,
                            'manutencoes', v_manut, 'reativacoes', v_reativ, 'retornos', v_retornos);
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
  ve.tipo                                                 as venda_tipo
from public.tarefas t
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

grant execute on function public.registrar_acao(uuid, text, public.canal_contato, text, date, uuid, timestamptz) to authenticated;
revoke execute on function public.registrar_acao(uuid, text, public.canal_contato, text, date, uuid, timestamptz) from anon;
revoke execute on function public.marcar_parcela_paga(uuid, uuid, date) from anon;
revoke execute on function public.preparar_dia(uuid, boolean) from anon;
