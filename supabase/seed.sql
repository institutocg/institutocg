-- =============================================================================
-- Dados FICTÍCIOS para desenvolvimento e demonstração.
-- Nunca executar em produção. Nomes e telefones inventados.
-- =============================================================================

do $$
declare
  c         uuid := public.inicializar_clinica('Instituto CG');
  hoje      date := (now() at time zone 'America/Sao_Paulo')::date;
  e_novo    uuid; e_contato uuid; e_agendada uuid; e_orcamento uuid; e_negociacao uuid;
  pix       uuid; credito uuid;
  prof      uuid;
  p_maria   uuid; p_joao uuid; p_ana uuid; p_carla uuid; p_paulo uuid; p_beatriz uuid;
  o         uuid;
  v         uuid;
  orc       uuid;
begin
  select id into e_novo from public.etapas_funil where clinica_id = c and nome = 'Novo contato';
  select id into e_contato from public.etapas_funil where clinica_id = c and nome = 'Em contato';
  select id into e_agendada from public.etapas_funil where clinica_id = c and nome = 'Avaliação agendada';
  select id into e_orcamento from public.etapas_funil where clinica_id = c and nome = 'Orçamento apresentado';
  select id into e_negociacao from public.etapas_funil where clinica_id = c and nome = 'Em negociação';
  select id into pix from public.formas_pagamento where clinica_id = c and nome = 'PIX';
  select id into credito from public.formas_pagamento where clinica_id = c and nome = 'Cartão de crédito';
  select id into prof from public.profissionais where clinica_id = c limit 1;

  -- Novo contato que chegou hoje pelo Instagram
  insert into public.pessoas (clinica_id, nome, whatsapp_e164, cidade, uf, origem_id, temperatura, primeiro_contato_em)
  values (c, 'Beatriz Almeida', '+5511900000006', 'São Paulo', 'SP',
          (select id from public.origens where clinica_id = c and nome = 'Instagram'), 'quente', hoje)
  returning id into p_beatriz;
  insert into public.oportunidades (clinica_id, pessoa_id, procedimento_id, etapa_id)
  values (c, p_beatriz, (select id from public.procedimentos where clinica_id = c and nome = 'Facetas/lentes em resina'), e_novo)
  returning id into o;
  insert into public.tarefas (clinica_id, pessoa_id, oportunidade_id, tipo, categoria, titulo, descricao, vence_em,
                              prioridade, origem, regra, chave_dedupe, mensagem_sugerida)
  values (c, p_beatriz, o, 'primeiro_contato', 'vendas', 'Fazer primeiro contato com Beatriz',
          'Pediu informações sobre lentes em resina pelo Instagram', hoje, 'urgente', 'automatica', 'R-LEAD-01',
          'primeiro_contato:' || o,
          'Olá, Beatriz! Aqui é do Instituto CG. Recebemos o seu interesse em lentes em resina e será um prazer conversar com você.');

  -- Orçamento de facetas apresentado há 8 dias
  insert into public.pessoas (clinica_id, nome, whatsapp_e164, email, cidade, uf, origem_id, temperatura, primeiro_contato_em)
  values (c, 'Maria Souza', '+5511900000001', 'maria.souza@exemplo.com', 'São Paulo', 'SP',
          (select id from public.origens where clinica_id = c and nome = 'Indicação de paciente'), 'morna', hoje - 20)
  returning id into p_maria;
  insert into public.oportunidades (clinica_id, pessoa_id, procedimento_id, etapa_id, valor_estimado_centavos)
  values (c, p_maria, (select id from public.procedimentos where clinica_id = c and nome = 'Facetas de porcelana'),
          e_orcamento, 1400000)
  returning id into o;
  insert into public.orcamentos (clinica_id, pessoa_id, oportunidade_id, status, valor_total_centavos,
                                 condicao_pagamento, entrada_centavos, quantidade_parcelas, forma_pagamento_id,
                                 apresentado_em, valido_ate, apresentado_por)
  values (c, p_maria, o, 'apresentado', 1400000, 'parcelado', 200000, 10, credito, hoje - 8, hoje + 22, prof);
  insert into public.tarefas (clinica_id, pessoa_id, oportunidade_id, tipo, categoria, titulo, descricao, vence_em,
                              prioridade, origem, regra, chave_dedupe, mensagem_sugerida)
  values (c, p_maria, o, 'follow_up_orcamento', 'vendas', 'Retornar Maria sobre facetas',
          'Orçamento de R$ 14.000 apresentado há 8 dias · 2º follow-up', hoje, 'alta', 'automatica', 'R-OR-02',
          'follow_up_orcamento:' || o,
          'Olá, Maria! Tudo bem? Fico à disposição caso tenha ficado alguma dúvida sobre o planejamento das facetas.');

  -- João pediu orçamento
  insert into public.pessoas (clinica_id, nome, telefone_e164, whatsapp_e164, origem_id, primeiro_contato_em)
  values (c, 'João Lima', '+5511900000002', '+5511900000002',
          (select id from public.origens where clinica_id = c and nome = 'Google'), hoje - 2)
  returning id into p_joao;
  insert into public.oportunidades (clinica_id, pessoa_id, procedimento_id, etapa_id)
  values (c, p_joao, (select id from public.procedimentos where clinica_id = c and nome = 'Implantes'), e_contato)
  returning id into o;
  insert into public.tarefas (clinica_id, pessoa_id, oportunidade_id, tipo, categoria, titulo, vence_em, prioridade)
  values (c, p_joao, o, 'follow_up', 'vendas', 'Enviar mensagem para João, que pediu orçamento', hoje - 1, 'alta');

  -- Carla desmarcou a avaliação
  insert into public.pessoas (clinica_id, nome, whatsapp_e164, origem_id, primeiro_contato_em)
  values (c, 'Carla Mendes', '+5511900000003',
          (select id from public.origens where clinica_id = c and nome = 'Site'), hoje - 15)
  returning id into p_carla;
  insert into public.oportunidades (clinica_id, pessoa_id, procedimento_id, etapa_id)
  values (c, p_carla, (select id from public.procedimentos where clinica_id = c and nome = 'Clareamento dental'), e_agendada)
  returning id into o;
  insert into public.agendamentos (clinica_id, pessoa_id, oportunidade_id, profissional_id, tipo, inicio)
  values (c, p_carla, o, prof, 'avaliacao', (hoje + 1 + time '10:00') at time zone 'America/Sao_Paulo');
  update public.agendamentos set status = 'desmarcado',
         motivo_id = (select id from public.motivos where clinica_id = c and nome = 'Trabalho')
   where pessoa_id = p_carla;
  insert into public.tarefas (clinica_id, pessoa_id, oportunidade_id, tipo, categoria, titulo, vence_em, prioridade,
                              origem, regra, mensagem_sugerida)
  values (c, p_carla, o, 'recuperar_desmarcacao', 'recuperacao', 'Entrar em contato com Carla, que desmarcou',
          hoje, 'alta', 'automatica', 'R-AG-02',
          'Olá, Carla! Sentimos sua falta. Quando for melhor para você, reservamos um novo horário.');

  -- Paulo: paciente antigo, elegível para reativação
  insert into public.pessoas (clinica_id, tipo_cadastro, nome, whatsapp_e164, origem_id,
                              paciente_desde, ultimo_atendimento_informado, consentimento_marketing)
  values (c, 'paciente_antigo', 'Paulo Ribeiro', '+5511900000004',
          (select id from public.origens where clinica_id = c and nome = 'Paciente antigo'),
          '2018-05-01', hoje - 420, true)
  returning id into p_paulo;
  insert into public.tratamentos_anteriores (clinica_id, pessoa_id, procedimento_id, realizado_em)
  values (c, p_paulo, (select id from public.procedimentos where clinica_id = c and nome = 'Manutenção e limpeza'), hoje - 420);

  -- Ana fechou lentes: entrada hoje e parcelas (uma delas atrasada)
  insert into public.pessoas (clinica_id, nome, whatsapp_e164, origem_id, primeiro_contato_em)
  values (c, 'Ana Costa', '+5511900000005',
          (select id from public.origens where clinica_id = c and nome = 'Instagram'), hoje - 60)
  returning id into p_ana;
  insert into public.oportunidades (clinica_id, pessoa_id, procedimento_id, etapa_id)
  values (c, p_ana, (select id from public.procedimentos where clinica_id = c and nome = 'Facetas/lentes em resina'), e_negociacao)
  returning id into o;
  insert into public.orcamentos (clinica_id, pessoa_id, oportunidade_id, status, valor_total_centavos, desconto_centavos,
                                 condicao_pagamento, entrada_centavos, quantidade_parcelas, forma_pagamento_id, apresentado_em)
  values (c, p_ana, o, 'em_negociacao', 1250000, 50000, 'parcelado', 120000, 4, pix, hoje - 40)
  returning id into orc;
  insert into public.vendas (clinica_id, pessoa_id, oportunidade_id, orcamento_id, valor_total_centavos, desconto_centavos,
                             condicao_pagamento, entrada_centavos, quantidade_parcelas, forma_pagamento_id, fechada_em)
  values (c, p_ana, o, orc, 1250000, 50000, 'parcelado', 120000, 4, pix, hoje - 35)
  returning id into v;
  perform public.gerar_parcelas(v, hoje, hoje - 35);  -- entrada paga; parcela 1 vence hoje
  insert into public.pagamentos (clinica_id, parcela_id, valor_centavos, pago_em, forma_pagamento_id)
  select c, id, valor_centavos, hoje - 35, pix from public.parcelas where venda_id = v and numero = 0;

  -- Paulo tinha um saldo do tratamento anterior: parcela atrasada há 5 dias
  insert into public.vendas (clinica_id, pessoa_id, tipo, valor_total_centavos, condicao_pagamento,
                             quantidade_parcelas, forma_pagamento_id, fechada_em, observacao_financeira)
  values (c, p_paulo, 'saldo_anterior', 160000, 'parcelado', 2, pix, hoje - 400,
          'Saldo informado no recadastro')
  returning id into v;
  perform public.gerar_parcelas(v, hoje - 5);
end;
$$;
