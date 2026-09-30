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
| `20261001120000_agenda.sql` | **Agenda comercial**: `agendar()` (paciente existente ou novo, procedimento, data, horário, dentista, status; horário de atendimento e conflito por dentista), `desmarcar_consulta()`, `remarcar_consulta()`, `mudar_status_consulta()`, `buscar_pacientes()`, garantia de recuperação e visões `v_agenda` e `v_recuperacao` |

## Motor de ações — regras de follow-up configuráveis

Cada situação comercial tem uma linha em `regras_followup` (editável em **Configurações**, só pela administradora). A regra responde às quatro perguntas: **o que aconteceu** (situação), **o que fazer** (tarefa e prioridade), **quando** (prazo e novas tentativas) e **com qual mensagem** (`modelos_mensagem`). Tudo é disparado por eventos e datas — ninguém precisa criar tarefas à mão.

A tela mostra **seis casos e o grupo "Paciente antigo"**; os passos automáticos entre eles ficam recolhidos.

| Caso (regra) | Padrão |
|---|---|
| Novo lead | Primeiro contato hoje, urgente; sem resposta: +1 e +2 dias; depois → "Parou de responder" |
| Saiu da consulta sem fechar | O orçamento é apresentado na consulta. Contato em 3 dias para tirar dúvidas; +4 e +7 dias; depois → "Parou de responder" |
| Parou de responder | Nova tentativa em 7 dias; +14 dias; depois → "Reativação", com contato leve em 60 dias |
| Desmarcou ou faltou | **"Entrar em contato com X para remarcar" no dia seguinte** (desmarcou dia 10 → tarefa dia 11), urgente; +3 e +4 dias. Quem faltou recebe a mensagem própria de falta |
| Não fechou | Motivo obrigatório; retomada no prazo do motivo (ex.: valor alto = 30 dias; "parou de responder" = 90) |
| Fechou | Agendar o início do tratamento; a pessoa sai do funil de vendas e fica "em tratamento" |
| Paciente antigo → sem atendimento | X meses sem atendimento (padrão 6) — **desligada** durante o recadastramento |
| Paciente antigo → retorno após o tratamento | Convite para revisão 6 meses após `concluir_tratamento()` |
| Paciente antigo → manutenção devida | Ciclo de retorno do procedimento — **desligada** durante o recadastramento |
| *Automático:* respondeu com interesse | Conduzir para a avaliação no dia seguinte |
| *Automático:* confirmar consulta | 1 dia útil antes; sem resposta, nova tentativa no dia da consulta |
| *Automático:* entrou em "Reativação" | Contato no dia; +21 dias; depois a usuária decide |

**Funil:** Novo contato → Em contato → Avaliação agendada → **Consulta realizada** (passou pela consulta, recebeu o orçamento e está decidindo) → Fechou / Não fechou, mais Desmarcou, Sem resposta e Reativação.

**Ao registrar o contato**, a usuária escolhe o resultado e ele define o próximo passo: *remarcou* (novo agendamento + confirmação), *pediu para falar depois* (tarefa na data combinada), *não respondeu* (próxima tentativa da regra; esgotadas, o que a regra mandar: "Sem resposta", "Reativação", encerrar como "Não fechou — parou de responder" ou pedir decisão), *não tem interesse* (encerra como "Desistiu — sem interesse no momento", com retomada leve em 180 dias) ou *outro* (descrição obrigatória, data opcional). Sem registro, a tarefa continua pendente (e aparece como atrasada).

**Garantias:** negociação aberta nunca fica sem próxima ação (a rotina diária cria "Definir o próximo passo", mesmo com a regra desligada); datas sempre em dia útil; reativações respeitam limite por dia e intervalo mínimo desde o último contato; quem pediu para não ser contatado nunca recebe tarefa; **nenhuma mensagem é enviada automaticamente** — o CRM só sugere.

**Campanhas:** a administradora escolhe o público (sem atendimento há X meses, quem fez um procedimento há X meses, quem não fechou há X meses), revisa a lista, escreve a mensagem e o sistema distribui os contatos em dias úteis com limite diário. Ficam de fora: quem não aceita contato (ou marketing, se marcado), quem está negociando, quem participou de campanha nos últimos 30 dias e quem está com pagamento em atraso.

## Agenda comercial — nenhuma desmarcação desaparece

| Evento na agenda | O que o sistema faz |
|---|---|
| Consulta marcada | Liga à negociação (abre uma, se for avaliação); funil vai para "Avaliação agendada"; confirmação 1 dia útil antes (se não veio já confirmada) |
| Confirmou | Confirmação concluída |
| Desmarcou | Evento no histórico (com motivo e observação) → status "desmarcou" → tarefa urgente "Entrar em contato com X para remarcar" no dia seguinte (ou na data combinada), com mensagem de remarcação citando a consulta → aparece no painel "Hoje" e em "Pacientes a recuperar" |
| Faltou | Ação específica de recuperação, com mensagem de quem faltou |
| Cancelado pela clínica | Motivo obrigatório; tarefa "Remarcar o horário de X" com pedido de desculpas |
| Remarcou | Nova consulta na agenda; a antiga aponta para ela; a recuperação é concluída ("Remarcou para …"), a confirmação antiga é cancelada e a nova é criada |
| Compareceu | Funil vai para "Consulta realizada" e começa o contato pós-consulta |

**Garantias:** consultas nunca são apagadas; desmarcada/remarcada/cancelada não volta a "agendada" (é preciso remarcar); um gatilho cria a recuperação mesmo com a regra desligada ou a ação recusada no funil; a tarefa de recuperação não pode ser descartada (só resolvida registrando o resultado); a rotina diária recria a recuperação de qualquer desmarcação que tenha ficado "sem ação". `v_recuperacao` classifica cada desmarcação/falta/cancelamento dos últimos 120 dias em *a recuperar*, *em acompanhamento*, *recuperado*, *encerrado* ou *sem ação*.

**Dentistas:** cadastradas em Configurações (nome, cor, se atende). Com mais de uma dentista ativa, toda consulta pede a escolha — na agenda, no funil (avaliação com data) e no "Registrar contato" do painel (`dentista_escolhida()`); na remarcação de uma recuperação, a sugestão é a mesma dentista da consulta perdida. Conflito de horário só com a mesma dentista; desativar exige remarcar as consultas futuras.

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

Os testes (`tests/10_integridade.sql`, `15_motor_de_acoes.sql`, `17_funil.sql`, `18_regras_e_campanhas.sql` e `19_agenda.sql`) cobrem relacionamentos, regras de acesso, histórico, lembretes financeiros e isolamento entre clínicas. `tests/00_simulacao_supabase.sql` imita o mínimo do Supabase e **não** deve ser aplicado no projeto real.

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
