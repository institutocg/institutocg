# Banco de dados — CRM Instituto CG

PostgreSQL (Supabase). Somente dados **comerciais e administrativos**: não há nenhum campo de prontuário, diagnóstico, anamnese, exame ou imagem.

## Migrações

| Arquivo | Conteúdo |
|---|---|
| `20260929120000_fundacao.sql` | Clínica, usuários, membros e papéis, profissionais, catálogos editáveis (procedimentos, origens, etapas do funil, motivos, formas de pagamento, modelos de mensagem), auditoria e funções de acesso |
| `20260929120100_crm.sql` | Pessoas (leads/pacientes), oportunidades (funil) + histórico de etapas, interesses, tratamentos anteriores, agenda, follow-ups e tarefas |
| `20260929120200_financeiro.sql` | Orçamentos + itens, vendas, parcelas, pagamentos e lembretes financeiros automáticos |
| `20260929120300_visoes_e_inicializacao.sql` | Visões de leitura (`v_contatos`, `v_painel_tarefas`, `v_parcelas`, `v_pendencias_financeiras`, `v_resumo_financeiro_mensal`, `v_funil`) e `inicializar_clinica()` |
| `20260929120400_motor_de_acoes.sql` | **Motor de ações**: calendário (dias úteis e feriados), cadências, gatilhos que criam tarefas, `registrar_acao()`, `marcar_parcela_paga()`, rotina diária `preparar_dia()` e a visão `v_tarefas_abertas` usada pelo painel |

## Motor de ações — quando o sistema cria tarefas sozinho

| Situação | Ação criada |
|---|---|
| Novo contato cadastrado | Primeiro contato, hoje, urgente (cadência 0 → 1 → 2 → 4 dias) |
| Paciente antigo com interesse | "Conversar com X sobre Y", hoje |
| Agendamento criado | Confirmação na véspera útil; funil vai para "Avaliação agendada" |
| Confirmação sem resposta | Nova tentativa no dia da consulta |
| Consulta passou sem registro | "X compareceu?" (rotina diária) |
| Desmarcou / faltou | Recuperação urgente, hoje (cadência 0 → 2 → 5 / 0 → 1 → 4 dias) |
| Compareceu à avaliação | "Registrar o orçamento"; funil "Avaliação realizada" |
| Orçamento apresentado | Follow-up em 2 dias (cadência 2 → 5 → 8 → 15 dias) |
| Vai pensar / pediu retorno / respondeu | Próximo contato em 3 dias / na data combinada / amanhã |
| Não fechou | Retomar no prazo do motivo (ex.: valor alto = 30 dias) |
| Desistiu | Reativação no prazo do motivo |
| Sem resposta (cadência esgotada) | Decisão humana; se pausada, nova tentativa em 60 dias |
| Fechou | "Agendar o início do tratamento" |
| Parcela em aberto | Lembrete na data prevista; em atraso aparece como urgente |
| Paciente antigo inativo / manutenção devida | Reativação (somente com a reativação ligada; limite diário) |
| Não quer mais contato | Nenhuma tarefa, nunca (exceto lembretes financeiros) |

Nenhuma cadência se estende para sempre: a última tentativa vira "Decidir o próximo passo". Datas caem sempre em dia útil (seg–sex, sem feriados).

## Onde está cada requisito

| Requisito | Onde |
|---|---|
| Nome, nascimento, telefone, WhatsApp, e-mail, endereço, cidade, observações, 1º/último contato, responsável | `pessoas` |
| Como conheceu a clínica | `pessoas.origem_id` → `origens` |
| Procedimento de interesse, etapa atual | `oportunidades` (uma em andamento por pessoa) |
| Status atual, próxima ação e data da próxima ação | `v_contatos` (calculados — nunca ficam desatualizados) |
| Procedimentos editáveis pela administradora | `procedimentos` (RLS: só `admin` escreve) |
| Histórico do funil (anterior, nova, data, usuário, observação) | `historico_etapas`, gravado por gatilho; use `mover_etapa(oportunidade, etapa, observação, motivo)` |
| Tarefas (título, descrição, paciente, data, horário, prioridade, status, responsável, origem, mensagem sugerida) | `tarefas` |
| Follow-ups (WhatsApp, ligação, atendimento, orçamento enviado, retorno solicitado, respondeu, não respondeu, desmarcou, fechou, recusou…) | `interacoes.tipo` |
| Valor total, desconto, valor final, forma, nº de parcelas, valor da parcela, observação | `orcamentos` e `vendas` |
| Data prevista, status e data efetiva do pagamento | `parcelas.vencimento`, `parcelas.status`, `parcelas.pago_em` (+ `pagamentos`) |
| Formas de pagamento configuráveis; à vista ou parcelado | `formas_pagamento` + `condicao_pagamento` |
| Lembrete financeiro automático e atrasados no painel | gatilho `sincronizar_tarefa_parcela` + `v_painel_tarefas` ("Pagamento previsto hoje — Maria Silva — R$ X" / "Pagamento em atraso há N dias") |
| Histórico de alterações | `auditoria` (antes/depois dos campos alterados, quem e quando) |

## Regras garantidas pelo próprio banco

- Uma única etapa atual por pessoa; status e resultado da negociação derivam da etapa.
- "Não fechou" e "Desistiu" exigem motivo.
- Registros não se misturam entre clínicas (chaves estrangeiras incluem `clinica_id`) e cada usuária só vê a própria clínica (RLS).
- Nada importante é apagado: contatos são arquivados, tarefas canceladas, follow-ups anulados com motivo, pagamentos estornados com motivo. Anonimização LGPD só pela administradora (`anonimizar_pessoa`).
- Toda parcela em aberto tem um lembrete; pagou → lembrete concluído; mudou a data → lembrete acompanha; cancelou → lembrete cancelado.

## Testes

```bash
npm run test:db    # sobe um PostgreSQL temporário, aplica as migrações, o seed e os testes
```

Os testes (`tests/10_integridade.sql` e `tests/15_motor_de_acoes.sql`) cobrem relacionamentos, regras de acesso, histórico, lembretes financeiros e isolamento entre clínicas. `tests/00_simulacao_supabase.sql` imita o mínimo do Supabase e **não** deve ser aplicado no projeto real.

## Implantação no Supabase (quando formos para produção)

1. Criar o projeto na região **São Paulo** e aplicar as migrações (`supabase db push`).
2. No SQL Editor: `select inicializar_clinica('Instituto CG');` (guarde o id retornado).
3. Convidar os dois logins em *Authentication → Users*.
4. No SQL Editor:
   ```sql
   select adicionar_membro('<id da clínica>', 'email-da-dona@...', 'admin');
   select adicionar_membro('<id da clínica>', 'email-da-secretaria@...', 'comercial', true);
   ```
5. **Não** executar `seed.sql` em produção (são dados fictícios).
6. (Opcional) Agendar a rotina diária com pg_cron: `select cron.schedule('rotina-diaria', '0 8 * * *', $$select public.preparar_dia(id) from public.clinicas$$);` — mesmo sem isso, ela roda ao abrir o painel.
