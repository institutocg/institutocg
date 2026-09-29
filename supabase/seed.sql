-- =============================================================================
-- Dados FICTÍCIOS para desenvolvimento e demonstração.
-- Nunca executar em produção. Nomes e telefones inventados.
--
-- As situações são criadas como na vida real (novo contato, orçamento,
-- desmarcação, venda…) e o MOTOR cria as tarefas sozinho. No fim, algumas datas
-- são deslocadas para o passado para simular atrasos.
-- =============================================================================

do $$
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
  select id into credito from public.formas_pagamento where clinica_id = c and nome = 'Cartão de crédito';

  -- 1. Beatriz: novo contato que chegou hoje pelo Instagram → primeiro contato (urgente)
  insert into public.pessoas (clinica_id, nome, whatsapp_e164, cidade, uf, origem_id, temperatura)
  values (c, 'Beatriz Almeida', '+5511900000006', 'São Paulo', 'SP',
          (select id from public.origens where clinica_id = c and nome = 'Instagram'), 'quente')
  returning id into p;
  insert into public.oportunidades (clinica_id, pessoa_id, procedimento_id, etapa_id)
  values (c, p, (select id from public.procedimentos where clinica_id = c and nome = 'Facetas/lentes em resina'),
          (public.etapa_por_marco(c, 'novo_contato')).id);

  -- 2. Maria: orçamento de facetas apresentado há 7 dias → follow-up (importante)
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

  -- 3. João: lead com quem a conversa começou; a tarefa ficou atrasada 2 dias
  insert into public.pessoas (clinica_id, nome, telefone_e164, whatsapp_e164, origem_id, primeiro_contato_em)
  values (c, 'João Lima', '+5511900000002', '+5511900000002',
          (select id from public.origens where clinica_id = c and nome = 'Google'), hoje - 4)
  returning id into p;
  insert into public.oportunidades (clinica_id, pessoa_id, procedimento_id, etapa_id)
  values (c, p, (select id from public.procedimentos where clinica_id = c and nome = 'Implantes'),
          (public.etapa_por_marco(c, 'em_contato')).id);
  update public.tarefas set vence_em = hoje - 2 where pessoa_id = p and status = 'pendente';

  -- 4. Carla: avaliação amanhã, mas desmarcou → recuperação (urgente)
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

  -- 6. Luiza: ficou de pensar → follow-up em 2 dias (próximos dias)
  insert into public.pessoas (clinica_id, nome, whatsapp_e164, origem_id, primeiro_contato_em)
  values (c, 'Luiza Prado', '+5511900000008',
          (select id from public.origens where clinica_id = c and nome = 'Instagram'), hoje - 30)
  returning id into p;
  insert into public.oportunidades (clinica_id, pessoa_id, procedimento_id, etapa_id, valor_estimado_centavos)
  values (c, p, (select id from public.procedimentos where clinica_id = c and nome = 'Facetas de porcelana'),
          (public.etapa_por_marco(c, 'em_negociacao')).id, 2200000)
  returning id into o;
  perform public.definir_proxima_acao(o, 'follow_up', 'Retomar a conversa com Luiza (ficou de pensar)',
                                      hoje + 2, 'alta', 'R-RES-02');

  -- 7. Marcos: follow-up de orçamento que deveria ter sido feito há 3 dias (atrasada)
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
  perform public.criar_tarefa_auto(p, null, 'reativacao', 'reativacao', 'Reativar contato com Sofia', hoje,
                                   'baixa', 'R-DIA-03', 'pessoa:' || p,
                                   p_descricao => 'Último atendimento em ' || to_char(hoje - 600, 'MM/YYYY'));
  update public.tarefas set vence_em = hoje where pessoa_id = p and status = 'pendente';

  -- 10. Ana: fechou lentes; entrada paga; parcela 1 vence hoje (importante)
  insert into public.pessoas (clinica_id, nome, whatsapp_e164, origem_id, primeiro_contato_em)
  values (c, 'Ana Costa', '+5511900000005',
          (select id from public.origens where clinica_id = c and nome = 'Instagram'), hoje - 60)
  returning id into p;
  insert into public.oportunidades (clinica_id, pessoa_id, procedimento_id, etapa_id)
  values (c, p, (select id from public.procedimentos where clinica_id = c and nome = 'Facetas/lentes em resina'),
          (public.etapa_por_marco(c, 'em_negociacao')).id)
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
                                      hoje + 4, 'alta', 'R-RES-03');
end;
$$;

-- A rotina de hoje já "rodou" para estes dados.
insert into public.execucoes_rotina (clinica_id, dia)
select id, public.hoje_clinica(id) from public.clinicas where nome = 'Instituto CG';
