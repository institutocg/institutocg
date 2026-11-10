# NG Clinic — Planejamento da Fase 1

> Documento para revisão e aprovação. **Nenhum código, banco ou serviço foi criado ainda.**
> Data: 10/11/2026

Este documento tem quatro partes:

- **A.** Como o sistema funciona por dentro (visão geral)
- **B.** Modelo de dados: as "tabelas" (gavetas) do banco, como se ligam e quem pode ver o quê (RLS)
- **C.** As telas da Fase 1
- **D.** O que você precisa fazer fora do código (contas, projetos e chaves)
- **E.** Decisões técnicas que tomei e por quê
- **F.** Perguntas para você

---

## A. Visão geral

```
 Você / secretária (celular ou computador)
          │  conexão criptografada (HTTPS)
          ▼
 ┌───────────────────────────────┐
 │ Aplicação NG Clinic (Next.js) │  Telas + regras. Hospedada na Vercel,
 │ servidores em São Paulo       │  servidores em São Paulo (gru1).
 └──────────────┬────────────────┘
                │
 ┌──────────────▼────────────────┐
 │ Supabase — São Paulo          │  • Banco de dados (Postgres), criptografado
 │                               │  • Login + 2 fatores (aplicativo autenticador)
 │                               │  • Regras de acesso linha a linha (RLS)
 │                               │  • Rotina automática toda madrugada (03:00)
 │                               │  • Backup diário
 └───────────────────────────────┘
        (Fase 2 em diante)  ──►  Anthropic (IA) — só recebe dados sem nome/CPF/contato
```

**Como o sistema "lembra" das coisas — dois mecanismos:**

1. **Na hora da ação.** Quando você muda a etapa de um paciente, registra uma consulta ou o resultado de um contato, o sistema cria na mesma hora a próxima tarefa (ex.: "Consulta agendada para 20/11" → tarefa "Confirmar consulta" em 19/11).
2. **Rotina da madrugada (03:00, horário de Brasília).** Verifica o que depende só da passagem do tempo: retorno que venceu sem consulta, 6 e 12 meses sem consulta, pagamento vencido, término de plano, comparecimento não registrado.

Essas regras ficam **dentro do banco de dados** (não espalhadas pelas telas). Assim, a tela, o quadro (kanban) e a rotina da madrugada usam exatamente a mesma regra, e não há risco de uma tela "esquecer" de criar uma tarefa.

---

## B. Modelo de dados

### B.1 Em linguagem simples

Pense no banco como um arquivo com gavetas. As principais:

| Gaveta | O que guarda |
|---|---|
| **Equipe** | Quem pode entrar no sistema (você = administradora; secretária no futuro). |
| **Pacientes** | O cadastro (seção 3 do escopo) + etapa atual, data da última consulta e data prevista de retorno. |
| **Problemas de saúde do paciente** | A lista de problemas de cada paciente, com um marcado como principal. |
| **Histórico de etapas** | Cada vez que o paciente muda de etapa: qual etapa, quando entrou, quando saiu e os dados do formulário (valor ofertado, motivo, "posso recontatar?" etc.). É daqui que saem o funil e o tempo em cada etapa. |
| **Agendamentos** | Consultas marcadas (data, horário, presencial/tele, confirmada ou não, compareceu/faltou/desmarcou). |
| **Consultas** | O registro simples da Fase 1: data, tipo (1ª, 2ª, 3ª...), "Retornar em X meses" e a data prevista de retorno calculada. |
| **Planos de acompanhamento** | Cada ciclo de plano (início, 3/4/6 meses, término, renovado ou não e por quê). |
| **Tarefas** | Tudo que aparece na tela "Hoje": tipo, paciente, data, tentativa (1ª, 2ª, 3ª), marcações (ex.: "Há mais de 6 meses sem consulta") e resultado. |
| **Contatos** | O registro de cada contato feito (canal, resultado, observação) — aparece na linha do tempo. |
| **Lançamentos financeiros** | Valor, tipo, forma de pagamento, vencimento, pago/não pago. |
| **Lembretes de reativação** | Quando o lembrete de 6 ou 12 meses foi gerado e se o paciente voltou — para calcular a taxa de reativação. |
| **Listas editáveis** | Origens ("como nos procurou"), motivos, catálogo de problemas de saúde, modelos de mensagem e prazos. |
| **Registro de auditoria** | Quem viu, criou, alterou ou apagou o quê, e quando. Ninguém consegue editar nem apagar este registro. |

### B.2 Diagrama das relações

```
 equipe (usuários)
                                 ┌──────────── origens (lista editável)
                                 │
 condicoes (catálogo) ──┐        ▼
                        └──► paciente_problemas ◄── pacientes ──► pacientes (quem indicou)
                                                        │
        ┌─────────────┬───────────────┬─────────────────┼──────────────┬──────────────┬──────────────┐
        ▼             ▼               ▼                 ▼              ▼              ▼              ▼
 etapas_historico  agendamentos    consultas   planos_acompanhamento  tarefas      contatos    lancamentos
        │                             │                 │              │              │              │
        └──► motivos (lista)          └──────┬──────────┘              └──── modelos_mensagem         │
                                             └───────────────────────────────────────────────────────┘
                                               (lançamento pode apontar para a consulta ou o plano)

 configuracoes (prazos) · reativacoes · audit_log  ← ligados ao paciente, usados pela rotina e pelo dashboard
```

### B.3 Tabelas (detalhe técnico)

Convenções: toda tabela tem `id uuid`, `criado_em`, `atualizado_em`, `criado_por`, `atualizado_por` (preenchidos automaticamente). Datas de calendário = `date`; instantes = `timestamptz`.

#### Equipe e configurações

**`equipe`** — perfil de quem usa o sistema (ligado ao login do Supabase)
- `id` (= usuário do Supabase Auth), `nome`, `papel` (`admin` | `secretaria`), `ativo`

**`configuracoes`** — prazos e dados da clínica (chave → valor), editáveis em Configurações. Valores padrão:

| Chave | Padrão |
|---|---|
| `responder_novo_contato_dias` | 0 (mesmo dia) |
| `retomar_conversa_dias` | 1 |
| `cadencia_interessado_dias` | [2, 5, 10] |
| `recontato_sem_resposta_dias` | 60 |
| `confirmacao_dias_antes` | 1 |
| `reagendar_desmarcou_dias` | 2 |
| `cadencia_faltou_dias` | [1, 5] |
| `contato_pos_primeira_consulta_dias` | 7 |
| `lembrete_retorno_dias_antes` | 15 |
| `renovacao_plano_dias_antes` | 15 |
| `cadencia_retorno_atrasado_dias` | [0, 7, 30] |
| `sugerir_inativo_apos_dias` | 60 |
| `reativacao_meses` | [6, 12] |
| `checkin_intervalo_dias` | 7 |

**`origens`** — "Como nos procurou": Instagram, Google, Indicação de paciente, Indicação médica, Outro. Coluna `tipo_indicacao` (`nenhuma` | `paciente` | `medico`) define se aparece a busca de paciente ou o campo de nome do médico. Itens podem ser desativados (não apagados, para não quebrar o histórico).

**`motivos`** — Preço/financeiro; Quer fazer mais para frente; Prefere usar convênio; Escolheu outro profissional; Outro. Coluna `usado_em` (lista: `sem_interesse`, `desmarcou`, `inativo`, `nao_renovou`) para você poder ter motivos específicos de cada situação.

**`condicoes`** — catálogo de problemas de saúde (diabetes tipo 2, obesidade, hipertensão...). Na Fase 2 vira a base da biblioteca de diretrizes.

**`modelos_mensagem`** — um ou mais textos por tipo de tarefa, com variáveis `{nome}`, `{primeiro_nome}`, `{data_consulta}`, `{hora_consulta}`, `{valor}`, `{data_ultima_consulta}`, `{problemas}`.

#### Pacientes

**`pacientes`**
- Identificação: `nome`, `data_nascimento`, `sexo` (`feminino` | `masculino` | `outro`), `cpf` (só dígitos, **único** quando preenchido), `telefone`, `email`
- Endereço: `cep`, `logradouro`, `numero`, `complemento`, `bairro`, `cidade`, `uf`
- Origem: `origem_id`, `indicado_por_paciente_id`, `indicado_por_nome` (médico), `canal_primeiro_contato` (`whatsapp` | `instagram`), `primeiro_contato_em`
- `motivo_consulta`, `modalidade` (`avulsa` | `plano`), `observacoes`
- Situação no CRM (mantida automaticamente): `etapa`, `etapa_desde`, `data_ultima_consulta`, `data_prevista_retorno`, `retorno_atrasado` (marcação para quem está em plano), `nao_contatar` ("Não quero ser contatado")
- `arquivado_em` (em vez de apagar; apagar de verdade só por pedido do paciente — direito LGPD)

A idade **não é guardada**: é calculada na hora a partir da data de nascimento.

**`paciente_problemas`** — `paciente_id`, `condicao_id` (ou `descricao` livre), `principal` (no máximo um por paciente — o banco garante), `ativo`.

**Etapas** (valor do campo `etapa`):

| Grupo | Etapas |
|---|---|
| Antes da consulta | `novo_contato`, `em_conversa`, `interessado`, `sem_interesse`, `sem_resposta`, `consulta_agendada`, `desmarcou`, `faltou` |
| Em cuidado | `consulta_realizada`, `em_plano`, `retorno_atrasado`, `inativo` |

**`etapas_historico`** — uma linha por passagem por etapa: `paciente_id`, `etapa`, `entrou_em`, `saiu_em` (vazio = etapa atual), e os dados do formulário em colunas próprias (para o dashboard conseguir somar e agrupar): `valor_ofertado`, `modalidade_ofertada` (`avulsa` | `plano_3m` | `plano_4m` | `plano_6m`), `motivo_id`, `motivo_outro`, `pode_recontatar`, `recontatar_em`, `observacao`.

#### Atendimento

**`agendamentos`** — `paciente_id`, `inicio` (data e hora), `formato` (`presencial` | `teleconsulta`), `confirmacao` (`pendente` | `confirmada` | `nao_confirmada`), `situacao` (`agendada` | `compareceu` | `faltou` | `desmarcou`), `motivo_id` (se desmarcou), `consulta_id` (preenchido quando a consulta é registrada).

**`consultas`** (versão simples da Fase 1; expandida na Fase 3) — `paciente_id`, `data`, `numero` (1ª, 2ª, 3ª... calculado automaticamente), `retornar_em_meses` (1, 2, 3, 4, 6, 12) **ou** `retornar_em_data`, `data_prevista_retorno` (calculada), `agendamento_id`.

**`planos_acompanhamento`** — `paciente_id`, `ciclo` (1, 2, 3...), `inicio`, `duracao_meses` (3, 4, 6), `termino` (calculado), `situacao` (`ativo` | `renovado` | `encerrado`), `motivo_id`/`motivo_outro` (se não renovou), `destino_apos_termino` (`consulta_realizada` | `inativo`).

#### Tarefas e contatos

**`tarefas`** — o coração da tela "Hoje".
- `paciente_id`, `tipo`, `vencimento` (data), `situacao` (`aberta` | `feita` | `cancelada`), `tentativa` (1ª, 2ª, 3ª da cadência)
- `marcacoes` (lista; ex.: `mais_6_meses_sem_consulta`)
- referências opcionais: `agendamento_id`, `plano_id`, `lancamento_id`
- `automatica` (criada pelo sistema ou manual), `concluida_em`, `concluida_por`, `resultado`
- Tipos: `responder_novo_contato`, `retomar_conversa`, `retomar_interessado`, `confirmar_consulta`, `registrar_comparecimento`, `reagendar`, `contato_pos_consulta`, `lembrete_retorno`, `retorno_atrasado`, `reativacao`, `checkin_semanal`, `renovacao_plano`, `pagamento_atrasado`, `recontato_programado`, `manual`
- Proteção contra duplicidade: o banco impede duas tarefas automáticas abertas do mesmo tipo para o mesmo paciente/agendamento/plano/lançamento.

**`contatos`** — cada contato registrado: `paciente_id`, `tarefa_id`, `canal`, `resultado` (`respondeu`, `agendou`, `nao_quer_agora`, `nao_respondeu`, `confirmou`, `pediu_para_remarcar`, `pagou`, `outro`), `observacao`, `quando`, `por`.

**`reativacoes`** — `paciente_id`, `marco` (6 ou 12 meses), `data_ultima_consulta_ref`, `gerado_em`, `tarefa_id`, `voltou_em` (preenchido quando uma nova consulta é registrada → taxa de reativação).

#### Financeiro

**`lancamentos`** — `paciente_id`, `tipo` (`consulta_avulsa` | `plano` | `retorno` | `outro`), `plano_meses` (3/4/6 quando for plano), `descricao`, `valor` (R$, 2 casas), `vencimento`, `forma_pagamento` (`pix` | `credito` | `debito` | `dinheiro` | `transferencia` | `boleto`), `pago` (a "caixinha de pago"), `pago_em`, `consulta_id`, `plano_id`.

#### Auditoria

**`audit_log`** — `quando`, `usuario_id`, `acao` (`criou` | `alterou` | `apagou` | `visualizou` | `exportou` | `enviou` | `entrou` | `saiu`), `tabela`, `registro_id`, `paciente_id`, `antes`, `depois` (só os campos alterados).
- Criação/alteração/exclusão: registradas **automaticamente pelo banco** (trigger), então nenhuma tela consegue "pular" o registro.
- "Visualizou" (abrir ficha), exportações e envios: registrados pelo servidor da aplicação.
- Somente inclusão: não existe nenhuma permissão de editar ou apagar linhas do log.

#### Visões prontas (consultas salvas) para as telas

- `v_tarefas_hoje` — tarefas abertas com vencimento até hoje + dados do paciente, etapa, tempo na etapa e mensagem sugerida, já na ordem pedida.
- `v_linha_do_tempo` — junta etapas, contatos, agendamentos, consultas, planos e lançamentos de um paciente em ordem de data (nas fases seguintes entram check-ins e documentos).
- Visões do dashboard (funil, conversão por origem, motivos, faltas, tempos médios, renovação, reativação, financeiro).

### B.4 Regras automáticas (funções do banco)

| Função | O que faz |
|---|---|
| `mudar_etapa(paciente, etapa, dados)` | Valida os campos obrigatórios da etapa, fecha a etapa anterior no histórico, abre a nova, cancela tarefas que não fazem mais sentido e cria as próximas. Usada pelo formulário, pelo kanban e pela tela "Hoje". |
| `registrar_consulta(...)` | Cria a consulta, calcula a data prevista de retorno, atualiza a etapa (consulta realizada ou mantém em plano), conclui tarefas de retorno atrasado e de reativação, marca `voltou_em` em reativações, cria o contato de 7 dias (1ª consulta) e o lembrete 15 dias antes do retorno. |
| `registrar_resultado_contato(tarefa, resultado, ...)` | Registra o contato, conclui a tarefa, cria a próxima tentativa da cadência ou devolve a sugestão de nova etapa (ex.: 3ª tentativa sem resposta → sugerir "Sem resposta"). |
| `iniciar_plano` / `renovar_plano` / `encerrar_plano` | Ciclos de plano, tarefas de check-in semanal, renovação 15 dias antes do término, sugestão de lançamento financeiro. |
| `marcar_pago(lancamento)` | Marca pago e conclui a tarefa de pagamento atrasado. |
| `rotina_diaria()` | Roda às 03:00 (Brasília) via `pg_cron`: (1) consulta realizada com retorno vencido → "Retorno atrasado"; (2) em plano com retorno vencido → marcação + tarefa; (3) plano no término → tarefa de decisão; (4) reativações de 6 e 12 meses (sem duplicar; respeitando "não contatar"); (5) pagamentos vencidos → tarefa; (6) comparecimento não registrado → tarefa; (7) check-in semanal; (8) paciente em etapa ativa sem nenhuma tarefa aberta → tarefa "Definir próxima ação" (rede de segurança). |

"Próxima ação sempre definida": as telas não deixam salvar sem próxima ação, e a rotina da madrugada garante que ninguém ficou sem (item 8). Etapas que **não** exigem próxima ação: "Sem interesse" com "não pode recontatar", "Sem resposta" sem recontato agendado e "Inativo" com "não pode recontatar".

### B.5 Políticas de acesso (RLS)

RLS = cada linha de cada tabela só é entregue a quem a regra permite. A regra é verificada **dentro do banco**, então vale mesmo que alguém tente acessar o banco "por fora" da aplicação.

Duas funções-base:
- `eh_equipe()` → o usuário está logado, **concluiu o segundo fator** (sessão `aal2`) e está ativo na tabela `equipe`.
- `eh_admin()` → `eh_equipe()` e papel `admin`.

| Tabelas | Ver | Criar / editar | Apagar |
|---|---|---|---|
| `pacientes`, `paciente_problemas`, `etapas_historico`, `agendamentos`, `consultas`, `planos_acompanhamento`, `tarefas`, `contatos`, `reativacoes` | equipe | equipe | ninguém (arquivar) — exclusão definitiva só pela admin, via função específica com registro no log |
| `lancamentos` | equipe* | equipe* | admin |
| `configuracoes`, `origens`, `motivos`, `condicoes`, `modelos_mensagem` | equipe | admin | admin |
| `equipe` | a própria linha; admin vê todas | admin | ninguém (desativar) |
| `audit_log` | admin | ninguém diretamente (só triggers/funções do sistema) | ninguém |

\* depende da sua resposta à pergunta 2 (secretária vê financeiro?).

Outras proteções:
- Papel `anon` (visitante não logado) sem acesso a nenhuma tabela.
- Cadastro público de contas **desligado**: só a admin convida novos usuários.
- Chave secreta do Supabase só no servidor, usada apenas para convidar usuários.
- Teste automatizado que falha se alguma tabela for criada sem RLS.

---

## C. Telas da Fase 1

Navegação: no computador, menu lateral; no celular, barra inferior com **Hoje · Pacientes · Quadro · Financeiro · Mais**.

1. **Entrar** — e-mail e senha → código de 6 dígitos do aplicativo autenticador. No primeiro acesso: tela com QR code para cadastrar o aplicativo. "Esqueci a senha" por e-mail. Sessão expira após inatividade.

2. **Hoje** (tela inicial)
   - Frase-resumo no topo: "Hoje: 3 novos contatos para responder, 2 confirmações, 4 retornos para lembrar."
   - Atrasadas destacadas em laranja; grupos por tipo, na ordem pedida (novos contatos e interessados primeiro).
   - Cada cartão: paciente, etapa, há quanto tempo na etapa, motivo do contato, mensagem sugerida (editável antes de enviar).
   - Botões: **WhatsApp** (abre a conversa com a mensagem pronta), **Feito**, **Reagendar** (escolher nova data), **Registrar resultado** (sugere a nova etapa → abre o formulário da etapa → cria a próxima tarefa).
   - Botão "+ Novo contato" sempre visível (cadastro rápido: nome, telefone, origem, canal).

3. **Pacientes** (lista) — busca por nome/CPF/telefone; filtros: etapa, origem, motivo, modalidade, período, "há mais de 6 meses sem consulta", "retorno atrasado". No celular vira lista de cartões.

4. **Cadastro / edição do paciente** — todos os campos da seção 3; CEP preenche o endereço; CPF com validação e aviso de duplicado ("Já existe um paciente com este CPF: abrir ficha"); busca de quem indicou; problemas de saúde com estrela para o principal.

5. **Ficha do paciente**
   - Cabeçalho: nome, idade, etapa (com botão "Mudar etapa"), modalidade, última consulta, retorno previsto, marcações (retorno atrasado, +6 meses sem consulta, não contatar), próxima ação.
   - Abas: **Resumo** (dados + problemas) · **Linha do tempo** · **Consultas** (registrar consulta: data, tipo, "Retornar em") · **Agendamentos** · **Plano** (ciclos) · **Tarefas** · **Financeiro**.
   - Ao abrir a ficha, o acesso é registrado no log.

6. **Formulários de etapa** (janelas que abrem ao mudar de etapa, pelo botão, pelo kanban ou pela tela "Hoje") — um formulário curto por etapa com os campos obrigatórios e a próxima ação já sugerida (editável).

7. **Quadro (kanban)** — duas abas: "Antes da consulta" e "Em cuidado". Arrastar o cartão para outra coluna abre o formulário da etapa. No celular: colunas com rolagem lateral e opção "Mover para…" no cartão (arrastar no celular é ruim).

8. **Financeiro (geral)** — período; cartões "Recebido", "A receber", "Em atraso"; filtro por forma de pagamento e tipo; lista de lançamentos com a caixinha "Pago".

9. **Dashboard** — filtro de período (mês atual, últimos 3 meses, ano, personalizado); indicadores da seção 6 em blocos: Pacientes · Funil · Origem · Motivos · Faltas e tempos · Planos · Retornos e reativação · Oportunidades · Financeiro. Cada número que representa pacientes é clicável e abre a lista.

10. **Configurações** (só admin) — Prazos · Origens · Motivos · Problemas de saúde · Modelos de mensagem · Dados da clínica · Equipe (convidar secretária, desativar acesso) · Registro de auditoria (com filtros por paciente, usuário e período).

### Indicadores extras que sugiro para o dashboard

1. **Taxa de retorno no prazo** — dos pacientes cujo retorno venceu no período, quantos voltaram até a data prevista (+ tolerância). É o melhor indicador de adesão ao seguimento de doença crônica.
2. **Tempo médio em cada etapa** — mostra onde o funil "trava".
3. **Faltas por formato e dia da semana** — presencial vs. teleconsulta.
4. **Tarefas atrasadas** (quantidade e há quanto tempo) — saúde da operação.
5. **Inadimplência** — % do valor a receber que está vencido.
6. **Receita por paciente ao longo do tempo** (valor médio de um paciente desde a primeira consulta).
7. **Pacientes que mais indicam** e conversão das indicações (indicação costuma ser o melhor canal).
8. **Distribuição pelo problema principal** — já dá para fazer na Fase 1 com a lista de problemas do cadastro.
9. **Duração média em plano** (quantos ciclos cada paciente faz).

---

## D. O que você precisa fazer fora do código

> **Regra de ouro:** nunca cole senhas ou chaves aqui no chat, em e-mail ou em mensagem. Quando chegar a hora, eu te mostro exatamente onde colar (arquivo `.env.local` no seu computador e o painel da Vercel).

### Passo 0 — Aplicativo autenticador (5 min)
Instale no celular um aplicativo autenticador: Google Authenticator, Microsoft Authenticator ou 1Password. Use-o também para proteger as contas abaixo (GitHub, Supabase, Vercel, Anthropic) — todas aceitam dois fatores e **devem** tê-lo ligado, porque quem invade essas contas acessa os dados.

### Passo 1 — GitHub (já existe)
O repositório `institutocg/institutocg` já está criado e é onde estou trabalhando. Confirme apenas que ele está **privado** (GitHub → repositório → Settings → General → "Danger Zone" → visibilidade). Ative 2FA na sua conta GitHub (Settings → Password and authentication).

### Passo 2 — Supabase (20 min)
1. Crie a conta em supabase.com (pode entrar com o GitHub). Ative o 2FA da conta.
2. Crie uma **Organization** e assine o plano **Pro** (US$ 25/mês). Motivo: o plano gratuito não tem backups diários e pausa o projeto se ficar parado; para dados de saúde reais, o Pro é necessário.
3. Crie o projeto: nome `ng-clinic`, **Region: South America (São Paulo)**. Gere uma senha forte do banco e guarde num gerenciador de senhas.
4. Em **Authentication → Sign In / Providers**: desligue "Allow new users to sign up" (só você convida). Em **Authentication → Multi-Factor**: confirme que **TOTP (app authenticator)** está habilitado.
5. Em **Organization → Legal Documents**: baixe/assine o **DPA** (acordo de tratamento de dados) — é um documento importante para a LGPD.
6. Me avise quando terminar. Eu vou te pedir para copiar 3 informações de **Project Settings → API** (URL do projeto, chave pública e chave secreta) e te mostro onde colar.
7. (Opcional, recomendado antes de ir para produção) Considerar o adicional **PITR** (recuperação em qualquer ponto no tempo) — permite voltar o banco para qualquer minuto dos últimos dias.

### Passo 3 — Vercel (15 min) — pode ficar para o fim da Fase 1
1. Crie a conta em vercel.com entrando com o GitHub. Ative o 2FA.
2. Assine o plano **Pro** (US$ 20/mês por usuário). O plano gratuito (Hobby) não permite uso comercial.
3. "Add New → Project" → importar `institutocg/institutocg`. Eu deixo a região São Paulo (gru1) configurada no código.
4. Eu te guio para colar as variáveis (chaves) em **Settings → Environment Variables**.
5. (Opcional) Domínio próprio, ex.: `app.ngclinic.com.br` (registro.br, ~R$ 40/ano).

### Passo 4 — Anthropic (10 min) — só antes da Fase 2
1. Crie a conta em console.anthropic.com, ative 2FA, cadastre o cartão.
2. Defina um **limite de gastos mensal** (ex.: US$ 30) em Settings → Limits.
3. Gere uma chave de API chamada `ng-clinic-producao` (eu te aviso quando).
4. Leia/aceite os termos comerciais e o DPA da Anthropic.

### Passo 5 — Documentos de LGPD (fora do sistema, com apoio jurídico)
Não sou advogado, mas um consultório que usa este sistema normalmente precisa de:
- **Aviso de privacidade** para pacientes (quais dados, para quê, com quem compartilha — Supabase, Vercel, Anthropic).
- **Termo de consentimento** para dados de saúde e para o uso de IA na produção de materiais educativos (com dados pseudonimizados, processados nos EUA).
- **Encarregado de dados (DPO)** indicado — em consultório pequeno costuma ser a própria médica.
- Os DPAs (acordos) dos fornecedores arquivados.
Recomendo revisão por advogado(a) especializado(a) em saúde/LGPD.

### Custos mensais estimados
| Serviço | Custo |
|---|---|
| Supabase Pro | US$ 25 (+ PITR opcional) |
| Vercel Pro | US$ 20 |
| Anthropic (a partir da Fase 2) | por uso; estimo US$ 5–30/mês para um consultório |
| Domínio (opcional) | ~R$ 40/ano |

---

## E. Decisões técnicas (e por quê)

1. **Rotina diária no `pg_cron` do Supabase (não no Vercel Cron).** Roda dentro do banco, em São Paulo, sem precisar abrir um endereço público na internet para disparar a rotina, e tudo acontece numa única transação (ou faz tudo, ou não faz nada). Horário: 03:00 de Brasília = 06:00 UTC (o Brasil não tem mais horário de verão).
2. **Regras de negócio em funções do Postgres** (ver B.4): uma única fonte da verdade para tela, kanban e rotina.
3. **2FA verificado também no banco** (sessão `aal2` nas políticas RLS), não só na tela.
4. **CPF:** guardado só com dígitos, com índice único (impede duplicado). Fica protegido pela criptografia do disco do Supabase (AES-256), pela conexão criptografada (TLS) e pelo RLS. Não uso criptografia adicional por coluna porque impediria a checagem de duplicidade e a busca, sem ganho real de segurança neste cenário.
5. **CEP:** consulta ao ViaCEP feita **pelo servidor** (o navegador não fala com serviços de terceiros).
6. **PDFs (Fases 2 e 3):** recomendo **Puppeteer + `@sparticuz/chromium`** numa função da Vercel em São Paulo — gera o PDF a partir da mesma página HTML A4 que você vê na tela (fidelidade total de fontes, cores e gráficos), sem enviar dados a serviços externos de PDF.
7. **IA (Fase 2+):** antes de enviar qualquer texto à Anthropic, o servidor remove automaticamente nome, CPF, telefone, e-mail e endereço do paciente (inclusive se estiverem no texto colado do Afya) e substitui por iniciais. Você poderá ver exatamente o que foi enviado.
8. **Exclusão de pacientes:** padrão é **arquivar**. Exclusão definitiva (direito do titular na LGPD) só pela admin, com confirmação e registro no log.
9. **Testes automatizados** das regras de etapas e da rotina diária (é a parte mais crítica: se falhar, pacientes "somem" da tela Hoje).

---

## F. Perguntas para você

1. **Campos obrigatórios no "Novo contato".** Quem chega pelo Instagram normalmente não informa CPF nem data de nascimento. Proposta: no novo contato, obrigatórios só **nome, telefone, origem e canal**; **CPF e data de nascimento** passam a ser obrigatórios ao **agendar a consulta**. Concorda?
2. **Permissões da secretária.** Proposta: ela vê e usa tudo do CRM (Hoje, pacientes, quadro, agendamentos, registrar contatos) e **lança/marca pagamentos**, mas **não** vê o dashboard financeiro, Configurações nem o registro de auditoria. Concorda? Ela deve ver os problemas de saúde dos pacientes? (Ela precisa deles para personalizar mensagens de reativação.)
3. **Pagamento do plano.** O plano é pago de uma vez ou em parcelas (ex.: mensalidades)? Se puder ser parcelado, ao criar o plano o sistema gera as parcelas com vencimentos. Também incluí o campo **vencimento** nos lançamentos (necessário para "a receber" e "pagamento atrasado") — ok?
4. **Retornos agendados.** Não existe etapa "retorno agendado" (combinado). Mas, quando um paciente em cuidado **marca** o retorno, você quer registrar o agendamento (para gerar a tarefa de confirmação na véspera), sem mudar a etapa dele? Recomendo que sim.
5. **Check-in semanal na Fase 1.** O módulo de check-in é da Fase 4. Na Fase 1 posso já criar a tarefa semanal "Enviar formulário de check-in" para pacientes em plano (sem o resumo por IA). Quer?
6. **Pacientes existentes.** Você tem hoje uma planilha de pacientes para importar? Se sim, a importação vira uma etapa própria no fim da Fase 1.
7. **Sexo.** Opções "Feminino", "Masculino" e "Outro"? (Nas Fases 3/4 o sexo biológico influencia metas de exames; podemos ter um campo separado se necessário.)
