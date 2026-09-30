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
| `20260930120000_funil.sql` | `mover_etapa_manual()` (mudança de etapa com a ação confirmada/editada pela usuária, agendamento, fechamento com parcelas) e proteção das funções internas do motor |
| `20260929120500_resgate.sql` | `criar_resgate()` (tarefa de manutenção/reativação sob demanda para paciente antigo) e `sem_acento()` para a busca |
| `20260930130000_tratamento_e_campanhas.sql` | Fechou → "em tratamento"; `concluir_tratamento()` (agenda o convite de retorno); campanhas de reativação (`prever_campanha`, `criar_campanha`, `encerrar_campanha`, visão `v_campanhas`) |

## Motor de ações — regras de follow-up configuráveis

Cada situação comercial tem uma linha em `regras_followup` (editável em **Configurações**, só pela administradora). A regra responde às quatro perguntas: **o que aconteceu** (situação), **o que fazer** (tarefa e prioridade), **quando** (prazo e novas tentativas) e **com qual mensagem** (`modelos_mensagem`). Tudo é disparado por eventos e datas — ninguém precisa criar tarefas à mão.

| Situação (regra) | Padrão |
|---|---|
| Novo lead | Primeiro contato hoje, urgente; sem resposta: +1 e +2 dias; depois → "Sem resposta" |
| Demonstrou interesse | Conduzir para a avaliação no dia seguinte; +3 e +4 dias; depois → "Sem resposta" |
| Confirmar consulta | 1 dia útil antes; sem resposta, nova tentativa no dia da consulta |
| Compareceu à avaliação | Registrar o orçamento, no mesmo dia |
| Orçamento enviado | Follow-up em 3 dias; +4 e +7 dias; depois → "Sem resposta" |
| Paciente está pensando | Acompanhar em 4 dias; +6 e +10 dias; depois → "Sem resposta" |
| Paciente desmarcou | **"Entrar em contato com X para remarcar" no dia seguinte** (desmarcou dia 10 → tarefa dia 11), urgente; +3 e +4 dias |
| Paciente faltou | Contato no dia seguinte; +2 e +3 dias |
| Parou de responder | Nova tentativa em 7 dias; +14 dias; depois → "Reativação", com contato leve em 60 dias |
| Não fechou | Retomada no prazo do motivo (ex.: valor alto = 30 dias; "parou de responder" = 90) |
| Fechou | Agendar o início do tratamento; a pessoa sai do funil de vendas e fica "em tratamento" |
| Reativação | Contato no dia; +21 dias; depois a usuária decide |
| Pacientes antigos sem atendimento | X meses sem atendimento (padrão 6) — **desligada** durante o recadastramento |
| Manutenção devida | Ciclo de retorno do procedimento — **desligada** durante o recadastramento |
| Retorno após o tratamento | Convite para revisão 6 meses após `concluir_tratamento()` |

**Ao registrar o contato**, a usuária escolhe o resultado e ele define o próximo passo: *remarcou* (novo agendamento + confirmação), *pediu para falar depois* (tarefa na data combinada), *não respondeu* (próxima tentativa da regra; esgotadas, o que a regra mandar: "Sem resposta", "Reativação", encerrar como "Não fechou — parou de responder" ou pedir decisão), *não tem interesse* (encerra como "Desistiu — sem interesse no momento", com retomada leve em 180 dias) ou *outro* (descrição obrigatória, data opcional). Sem registro, a tarefa continua pendente (e aparece como atrasada).

**Garantias:** negociação aberta nunca fica sem próxima ação (a rotina diária cria "Definir o próximo passo", mesmo com a regra desligada); datas sempre em dia útil; reativações respeitam limite por dia e intervalo mínimo desde o último contato; quem pediu para não ser contatado nunca recebe tarefa; **nenhuma mensagem é enviada automaticamente** — o CRM só sugere.

**Campanhas:** a administradora escolhe o público (sem atendimento há X meses, quem fez um procedimento há X meses, quem não fechou há X meses), revisa a lista, escreve a mensagem e o sistema distribui os contatos em dias úteis com limite diário. Ficam de fora: quem não aceita contato (ou marketing, se marcado), quem está negociando, quem participou de campanha nos últimos 30 dias e quem está com pagamento em atraso.

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

Os testes (`tests/10_integridade.sql`, `15_motor_de_acoes.sql`, `17_funil.sql` e `18_regras_e_campanhas.sql`) cobrem relacionamentos, regras de acesso, histórico, lembretes financeiros e isolamento entre clínicas. `tests/00_simulacao_supabase.sql` imita o mínimo do Supabase e **não** deve ser aplicado no projeto real.

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
