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
