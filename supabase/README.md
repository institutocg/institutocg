# Banco de dados — CRM Instituto CG

PostgreSQL (Supabase). Somente dados **comerciais e administrativos**: não há nenhum campo de prontuário, diagnóstico, anamnese, exame ou imagem.

## Migrações

| Arquivo | Conteúdo |
|---|---|
| `20260929120000_fundacao.sql` | Clínica, usuários, membros e papéis, profissionais, catálogos editáveis (procedimentos, origens, etapas do funil, motivos, formas de pagamento, modelos de mensagem), auditoria e funções de acesso |
| `20260929120100_crm.sql` | Pessoas (leads/pacientes), oportunidades (funil) + histórico de etapas, interesses, tratamentos anteriores, agenda, follow-ups e tarefas |
| `20260929120200_financeiro.sql` | Orçamentos + itens, vendas, parcelas, pagamentos e lembretes financeiros automáticos |
| `20260929120300_visoes_e_inicializacao.sql` | Visões de leitura (`v_contatos`, `v_painel_tarefas`, `v_parcelas`, `v_pendencias_financeiras`, `v_resumo_financeiro_mensal`, `v_funil`) e `inicializar_clinica()` |

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

Os testes (`tests/10_integridade.sql`) cobrem relacionamentos, regras de acesso, histórico, lembretes financeiros e isolamento entre clínicas. `tests/00_simulacao_supabase.sql` imita o mínimo do Supabase e **não** deve ser aplicado no projeto real.

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
