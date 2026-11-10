# NG Clinic — Escopo do sistema

> Escopo original enviado pela médica responsável, salvo como referência permanente do projeto.
> Registrado em 10/11/2026. Alterações de escopo devem ser feitas neste arquivo, com data e motivo, em "Histórico de alterações" no final.

Construir em FASES: começar pela Fase 1 e só avançar para a próxima após aprovação. Explicações sempre em linguagem simples (a usuária não é programadora).

---

## 1. Contexto

- Médica que atende pacientes com doenças crônicas e metabólicas (diabetes, obesidade, hipertensão, dislipidemia, hipotireoidismo, osteoporose, menopausa, entre outras).
- O sistema é COMPLEMENTAR ao prontuário (Afya Clinic). Ele NÃO é um prontuário. Serve para: gestão de pacientes (CRM), gestão financeira simples, materiais educativos para o paciente e acompanhamento da evolução.
- Usuários: a médica (administradora) e, futuramente, uma secretária.
- Idioma: português do Brasil. Datas no formato dd/mm/aaaa, valores em reais (R$) e fuso horário de Brasília. Tem que funcionar bem no celular e no computador.

## 2. Segurança e LGPD (obrigatório desde a Fase 1)

- Login com e-mail e senha, e autenticação em dois fatores.
- Dados de saúde são dados sensíveis: row-level security em TODAS as tabelas, banco hospedado no Brasil, criptografia em trânsito e em repouso, backups automáticos.
- Registro de log de acesso e de alterações (quem viu e quem editou o quê, e quando).
- Ao enviar dados para a IA gerar materiais, NÃO enviar nome, CPF, endereço, contato nem dados financeiros. Enviar apenas dados pseudonimizados (iniciais, idade, sexo, problemas, exames, texto clínico). O nome só é inserido no documento final, dentro do sistema.
- Todo conteúdo gerado por IA nasce como RASCUNHO e só pode ser exportado ou enviado depois que a médica marcar "Revisado e aprovado".

## 3. Cadastro do paciente

Campos:
- Nome completo
- Data de nascimento (calcular a idade automaticamente)
- Sexo
- CPF (não permitir duplicado)
- Telefone/WhatsApp e e-mail
- Endereço (CEP com preenchimento automático)
- Como nos procurou: Instagram, Google, indicação de paciente, indicação médica, outro (lista editável). Se for indicação, campo para quem indicou (com busca entre os pacientes cadastrados).
- Canal do primeiro contato: WhatsApp, Instagram
- Motivo da consulta (texto livre)
- Lista de problemas de saúde, com a opção de marcar um como PRINCIPAL
- Modalidade de atendimento: "Consulta avulsa" ou "Plano de acompanhamento"
- Etapa do paciente no funil (seção 4)
- Observações

## 4. CRM: etapas, retornos e "O que devo fazer hoje"

### Princípios
- Todo paciente em etapa ativa tem SEMPRE uma próxima ação com data. Se tentar salvar sem próxima ação, o sistema pede uma.
- Cada mudança de etapa abre um formulário curto com os campos obrigatórios daquela etapa.
- O sistema guarda o histórico de etapas (data de entrada e de saída de cada uma) para calcular o funil e o tempo em cada etapa.
- Um paciente pode voltar para uma etapa anterior (por exemplo, de "Sem interesse no momento" para "Interessado") sem perder o histórico.
- Todos os prazos abaixo são valores padrão, editáveis em Configurações.

### Lista de motivos (editável)
Preço / financeiro; Quer fazer mais para frente; Prefere usar convênio; Escolheu outro profissional; Outro (texto livre).

### Etapas: ANTES DA CONSULTA

1. **Novo contato**
   - Quando: o paciente entrou em contato e ainda não foi respondido.
   - Obrigatório: origem (como nos procurou) e canal.
   - Próxima ação: "Responder" no mesmo dia. Mostrar há quanto tempo o contato está sem resposta.

2. **Em conversa**
   - Quando: já respondeu e o paciente está tirando dúvidas.
   - Próxima ação: retomar em 1 dia se ele não responder.

3. **Interessado, não agendou**
   - Quando: o paciente recebeu os valores e demonstrou interesse, mas não marcou.
   - Obrigatório: valor ofertado, modalidade (consulta avulsa ou plano de 3, 4 ou 6 meses).
   - Próxima ação: cadência de retomada em 2, 5 e 10 dias. Depois da 3ª tentativa sem resposta, sugerir mover para "Sem resposta".

4. **Sem interesse no momento**
   - Quando: o paciente disse que não quer agora.
   - Obrigatório: motivo (lista), "Posso entrar em contato novamente?" (sim/não) e, se sim, quando (30, 60, 90 dias ou data específica).
   - Próxima ação: tarefa de recontato na data escolhida. Se a resposta for "não", o paciente sai da tela "Hoje".

5. **Sem resposta**
   - Quando: 3 tentativas de contato sem retorno (o sistema sugere a mudança automaticamente).
   - Próxima ação: recontato opcional em 60 dias.

6. **Consulta agendada**
   - Quando: a primeira consulta foi marcada.
   - Obrigatório: data, horário e formato (presencial ou teleconsulta).
   - Próximas ações: tarefa de confirmação 1 dia antes (com status "confirmada" ou "não confirmada"). No dia seguinte à consulta, se nada tiver sido registrado, tarefa "Registrar comparecimento" (compareceu ou faltou).

7. **Desmarcou**
   - Quando: o paciente cancelou antes da consulta.
   - Obrigatório: motivo.
   - Próxima ação: tentar reagendar em 2 dias.

8. **Faltou**
   - Quando: o paciente não compareceu.
   - Próxima ação: tentar reagendar em 1 dia e de novo em 5 dias. Depois disso, sugerir mover para "Sem resposta" ou "Sem interesse no momento".

### Etapas: EM CUIDADO

Previsão de retorno (vale para todas as etapas abaixo):
- Ao registrar QUALQUER consulta (seção 9), informar obrigatoriamente "Retornar em: X meses" (opções rápidas: 1, 2, 3, 4, 6 e 12 meses, ou uma data específica). O sistema calcula a DATA PREVISTA DE RETORNO = data da consulta + X meses.
- A cada nova consulta registrada, a data prevista é atualizada e as tarefas de retorno atrasado do paciente são concluídas.
- NÃO existe etapa de "retorno agendado": muitas vezes o paciente sai sem o retorno marcado.

9. **Consulta realizada (consulta avulsa)**
   - Quando: o paciente fez a consulta e não está em plano.
   - Próximas ações: contato 7 dias depois da primeira consulta para saber como está a adaptação; 15 dias antes da data prevista de retorno, "Lembrar o paciente de agendar o retorno e fazer os exames".
   - Se a data prevista passar sem nova consulta registrada: mover AUTOMATICAMENTE para "Retorno atrasado".

10. **Em plano de acompanhamento**
    - Obrigatório: data de início e duração (3, 4 ou 6 meses). O sistema calcula a data de término.
    - Próximas ações: check-in semanal (seção 12); lembrete de retorno conforme a data prevista; tarefa "Conversar sobre a renovação" 15 dias antes do término.
    - Se a data prevista de retorno passar sem consulta: o paciente continua no plano, mas recebe a marcação "Retorno atrasado" e é criada uma tarefa de contato.
    - No término: se renovar, abre um novo ciclo (3, 4 ou 6 meses). Se não renovar, o sistema pede o motivo e o paciente passa para "Consulta realizada" (seguindo a data prevista de retorno) ou para "Inativo".

11. **Retorno atrasado**
    - Quando: a data prevista passou sem nova consulta (paciente de consulta avulsa).
    - Próxima ação: contato imediato e nova tentativa em 7 e 30 dias. Depois de 60 dias sem resposta, sugerir mover para "Inativo".

12. **Inativo**
    - Quando: o paciente saiu do acompanhamento.
    - Obrigatório: motivo e "Posso entrar em contato novamente?" (sim/não).
    - Próxima ação: se sim, recontato em 6 ou 12 meses (escolhido na hora).

### Reativação: pacientes há mais de 6 meses sem consulta
- Vale para TODO paciente com pelo menos uma consulta registrada, em qualquer etapa, contando a partir da data da ÚLTIMA consulta.
- Ao completar 6 meses sem nova consulta, o sistema cria a tarefa "Reativação: há mais de 6 meses sem consulta", com a data da última consulta e os principais problemas de saúde do paciente (para personalizar a mensagem).
- Se não houver nova consulta, gerar um novo lembrete aos 12 meses. Depois disso, não gerar mais lembretes automáticos (pode ser programado manualmente).
- Não duplicar: se o paciente já tiver uma tarefa de contato em aberto (por exemplo, por "Retorno atrasado"), apenas acrescentar a marcação "Há mais de 6 meses sem consulta" à tarefa existente.
- Não gerar o lembrete para pacientes marcados com "Não quero ser contatado".
- Sugestão de mensagem com tom de cuidado (exemplo: "Oi, [nome], tudo bem? Faz um tempo desde a sua última consulta e queria saber como você está. Que tal agendarmos uma reavaliação e atualizarmos seus exames?").

### Tela "Hoje" (tela inicial do sistema)
- Lista de tarefas do dia e das tarefas atrasadas (estas destacadas), agrupadas por tipo: responder novos contatos, retomar interessados, confirmações, registrar comparecimento, reagendamentos, lembretes de retorno, retornos atrasados, reativações, check-ins, renovações de plano, pagamentos atrasados e recontatos programados.
- Ordenação: primeiro os novos contatos sem resposta e os interessados; depois as demais tarefas por data.
- Cada tarefa mostra: paciente, etapa, há quanto tempo está na etapa, motivo do contato e uma sugestão de mensagem (cordial; nas cobranças, um tom gentil).
- Botões: abrir conversa no WhatsApp (link wa.me com a mensagem preenchida), marcar como feito, reagendar e registrar o resultado do contato.
- Ao registrar o resultado (por exemplo, "agendou", "disse que não quer agora", "não respondeu"), o sistema sugere a nova etapa, abre os campos obrigatórios dela e cria a próxima tarefa automaticamente.
- Modelos de mensagem por tipo de tarefa, editáveis, com variáveis (nome, data da consulta, valor).

### Visualizações
- Quadro (kanban) por etapa, com arrastar e soltar (ao soltar, abre o formulário da etapa), dividido em "Antes da consulta" e "Em cuidado".
- Lista com filtros: etapa, origem, motivo, modalidade, período e "há mais de 6 meses sem consulta".
- Linha do tempo na ficha do paciente com todo o histórico: contatos, mudanças de etapa, consultas, pagamentos, check-ins e documentos enviados.

## 5. Financeiro

Uma aba "Financeiro" na ficha de cada paciente, com uma lista de lançamentos. Cada lançamento tem:
- Descrição/tipo: consulta avulsa, plano de acompanhamento (3, 4 ou 6 meses), retorno, outro
- Valor
- Forma de pagamento: Pix, cartão de crédito, cartão de débito, dinheiro, transferência, boleto e check de pago

Regras:
- Ao marcar como pago, a tarefa é concluída.
- Ao colocar um paciente em plano de acompanhamento (ou renovar o plano), sugerir a criação do lançamento correspondente.
- Uma tela geral de financeiro: recebido no período, a receber e filtro por forma de pagamento.

## 6. Dashboard

Com filtro de período (mês atual, últimos 3 meses, ano, personalizado).

Gestão e CRM:
- Pacientes cadastrados (total e novos no período)
- Pacientes atendidos no período (primeiras consultas e retornos, separados)
- Funil de conversão entre etapas: novo contato → interessado → agendado → compareceu → plano de acompanhamento
- Origem dos pacientes (como nos procurou) e a conversão por canal
- Motivos de "Sem interesse", "Desmarcou" e "Inativo", em gráfico, com filtro por período e por origem
- Taxa de faltas
- Tempo médio de resposta a novos contatos e tempo médio até o agendamento
- Pacientes em plano de acompanhamento ativo, a taxa de renovação dos planos e a taxa de resposta ao check-in semanal
- Retornos atrasados (número e lista)
- Pacientes há mais de 6 meses sem consulta (número e lista) e a taxa de reativação (quantos voltaram depois do lembrete)
- Oportunidades em aberto: soma dos valores ofertados a pacientes "Interessado, não agendou"

Financeiro:
- Faturamento recebido
- Ticket médio, receita por tipo (avulsa versus plano) e por forma de pagamento

Clínico (a partir da Fase 4):
- Diagnósticos mais frequentes
- Perda de peso média (em % e kg) dos pacientes em tratamento de obesidade

Sugerir outros indicadores que façam sentido para o consultório.

## 7. Biblioteca de diretrizes (base de todo o conteúdo educativo)

- Uma ficha por doença (diabetes tipo 2, obesidade, hipertensão, dislipidemia, esteatose hepática, hipotireoidismo, menopausa, osteoporose, pré-diabetes; lista editável).
- Cada ficha tem um TEXTO-BASE em linguagem leiga, dividido nas seções dos slides (seção 8), além de: metas padrão dos exames por perfil de paciente, fonte (diretriz e ano) e data da última revisão.
- A IA pode redigir uma primeira versão do texto-base a partir das diretrizes brasileiras mais recentes (SBD, ABESO, SBC, SBEM e outras pertinentes), citando a diretriz e o ano. Essa versão fica como rascunho até ser aprovada.
- Status: rascunho, aprovado, revisar (alertar quando a ficha tiver mais de 12 meses sem revisão).
- REGRA: os materiais dos pacientes só podem usar fichas APROVADAS. A IA não cria conteúdo médico novo a cada paciente; ela parte do texto-base aprovado e só adapta ao caso (idade, comorbidades, nível de linguagem).

## 8. Slides pré-consulta

- Botão "Gerar slides" na ficha do paciente. Antes de gerar, escolher a comorbidade principal (vem marcada a que estiver como principal no cadastro).
- Estrutura: 5 a 7 slides sobre a doença principal, mais um slide final de conexão.
  1. O que é: uma frase e uma imagem simples
  2. Por que acontece: a fisiopatologia em linguagem leiga, com analogias (no diabetes, a "chave" da insulina que não abre a "porta" da célula)
  3. O que pode causar se não tratar: as complicações, em tom honesto mas sem assustar
  4. Tem tratamento: os pilares (estilo de vida, medicação, acompanhamento)
  5. O que depende de você: 2 ou 3 ações concretas
  6. Slide de conexão: um mapa visual de como os problemas do paciente se relacionam entre si (por exemplo, obesidade → resistência à insulina → diabetes → risco cardiovascular)
- Estilo: pouco texto, fonte grande, ícones e ilustrações simples (sem fotos), visual limpo.
- Os slides são para a médica mostrar durante a consulta: modo de apresentação em tela cheia, exportação em PDF e possibilidade de editar o texto antes de apresentar.

## 9. Consultas

- Na ficha do paciente, uma linha do tempo de consultas. Em cada consulta: tipo (primeira consulta, segunda consulta, terceira...), data, "Retornar em: X meses" (obrigatório; ver seção 4) e um campo de texto onde é colado o que foi escrito no prontuário do Afya Clinic.
- Ao salvar, a IA extrai e propõe: problemas de saúde (novos ou já existentes), exames com valores e datas, condutas combinadas e próximos passos. A médica revisa e confirma antes de qualquer dado ser gravado.
- Registrar uma consulta atualiza automaticamente a etapa do paciente e a data prevista de retorno, e conclui as tarefas de retorno atrasado e de reativação dele.

## 10. Exames e metas

- Tabela de exames por paciente: nome, valor, unidade e data, com histórico.
- Cada exame tem uma META INDIVIDUAL com tipo "abaixo de", "acima de" ou "entre", e valor ou valores.
- O sistema SUGERE a meta com base nas metas da biblioteca de diretrizes e no perfil do paciente (idade, comorbidades, fragilidade, risco cardiovascular), mostrando o motivo (exemplo: "LDL < 70: alto risco por diabetes, mulher, 58 anos"). A médica pode aceitar ou editar manualmente, e a meta editada passa a valer dali em diante.
- Uma caixa de seleção "Mostrar no resumo" em cada exame. O sistema pré-marca os exames ligados aos problemas do paciente, a médica ajusta, e a escolha fica salva para o paciente até ser mudada.
- Se for marcado um exame que não tem meta, o sistema pede a meta antes de incluí-lo no resumo.

## 11. Materiais pós-consulta

Botão "Gerar materiais" em cada consulta, que gera:

**Camada 1: Resumo da consulta** (sempre, 1 página A4)
- Cabeçalho: nome, idade, data da consulta, nome e CRM da médica + logomarca
- Seus problemas de saúde: um cartão por problema, com uma frase explicativa em linguagem leiga (sem destacar diagnóstico principal)
- Como estão seus exames: só os marcados "Mostrar no resumo". Cada um com uma barra horizontal em que a faixa verde é a meta e um ponto laranja mostra o valor atual, além do valor, da meta e de um status ("Dentro da meta", "Quase lá", "Fora da meta", com o valor anterior quando houver)
- Se o paciente estiver em tratamento de obesidade: a tabela de evolução da bioimpedância (seção 13) com uma frase-resumo
- O que combinamos hoje: lista numerada
- Próximos passos: exames a fazer, previsão de retorno (mês e ano), check-in semanal se estiver em plano
- Rodapé: contato da equipe e "Este resumo não substitui a consulta"

**Camada 2: "Entenda seu diagnóstico"** (1 a 2 páginas por condição)
- Gerada a partir do texto-base aprovado da biblioteca, adaptada ao paciente.
- O sistema registra quais folhas o paciente já recebeu. Quando surge um diagnóstico novo, gera só a folha nova.

Exportação em PDF, com uma opção para copiar o link ou enviar por WhatsApp.

## 12. Check-in semanal (pacientes em plano de acompanhamento)

- A médica envia um formulário semanal ao paciente (inicialmente pelo Google Forms) e depois anexa ou cola as respostas no sistema (PDF, imagem, texto ou exportação do formulário).
- A IA gera o "Resumo do check-in da semana" com três blocos: Como você está nesta semana, O que vamos manter e O que vamos mudar (se houver).
- Se aparecer uma queixa nova, um efeito colateral importante ou baixa adesão, o sistema alerta e sugere criar uma tarefa de agendamento de consulta no CRM.
- Histórico de check-ins na ficha do paciente, com um gráfico simples de adesão ao longo das semanas.

## 13. Relatório de obesidade (pacientes em tratamento de obesidade)

- Anexar o laudo da bioimpedância (PDF ou foto) a cada consulta. A IA extrai: data, peso, IMC, % de gordura, massa gorda, massa magra/muscular e gordura visceral. A médica confere antes de salvar.
- Registro também da medicação e da dose em cada data.
- Relatório visual que se atualiza a cada consulta:
  - Tabela de evolução (data, peso, total perdido em kg e %, % de gordura, massa muscular, gordura visceral, medicação e dose)
  - Gráficos: peso e IMC ao longo do tempo; massa gorda versus massa magra (mostrando quanto da perda foi gordura e quanto foi músculo)
  - Uma frase-resumo em linguagem simples (exemplo: "Em 3 meses você perdeu 6 kg, quase 5 kg de gordura, e manteve sua massa muscular")
- Duas versões: uma para a médica (mais detalhada) e outra para o paciente (mais visual e simples).

## 14. Identidade visual

- Visual limpo, acolhedor e profissional.
- Cor principal verde-petróleo `#0F5F4F`; destaque laranja `#D9620F` (usado para "você hoje" nos gráficos); fundo branco; cinzas suaves.
- Tipografia: Inter para os textos e Fraunces para os títulos dos documentos.
- Documentos em A4, prontos para imprimir e para ler no celular.

## 15. Stack definida

- Next.js (App Router) com TypeScript, Tailwind CSS e shadcn/ui
- Supabase: banco Postgres, autenticação (com 2FA/MFA por aplicativo autenticador), Storage para os laudos e documentos (buckets PRIVADOS, acesso só por URL assinada e temporária) e row-level security em TODAS as tabelas
- Projeto do Supabase na região South America (São Paulo)
- Deploy na Vercel, com as funções na região de São Paulo (gru1)
- IA: API da Anthropic (Claude), chamada SOMENTE pelo servidor (rotas de API/server actions). A chave nunca vai para o navegador.
- Gráficos: Recharts
- PDFs: gerados a partir de páginas HTML no formato A4, com uma solução que funcione bem na Vercel
- Rotinas automáticas diárias (mudanças automáticas de etapa, retornos atrasados, reativações de 6 e 12 meses, pagamentos atrasados e criação das tarefas do dia): Vercel Cron ou pg_cron do Supabase, rodando de madrugada no horário de Brasília
- Migrações do banco versionadas no repositório (Supabase CLI)
- Variáveis secretas em `.env.local` (nunca commitadas) e nas configurações da Vercel

## 16. Ordem de construção e forma de trabalho

Fases:
- **Fase 1:** login e segurança; cadastro; CRM completo (etapas, motivos, previsão de retorno, plano de acompanhamento, reativação, tela "Hoje", kanban, linha do tempo); financeiro; dashboard (indicadores de gestão, CRM e financeiro). Na Fase 1, ainda sem o módulo clínico, criar um registro simples de consulta (data, tipo e "Retornar em: X meses") para que o CRM e os retornos já funcionem. Na Fase 3 ele será expandido.
- **Fase 2:** biblioteca de diretrizes e slides pré-consulta.
- **Fase 3:** consultas completas, exames e metas, resumo da consulta e "Entenda seu diagnóstico".
- **Fase 4:** check-in semanal, relatório de obesidade e indicadores clínicos no dashboard.

Forma de trabalho:
- Escopo salvo em `docs/escopo.md` e regras principais em `CLAUDE.md`.
- Git com commits pequenos e mensagens claras ao final de cada etapa.
- Antes de escrever código, apresentar: (1) o modelo de dados (tabelas, relações e políticas de RLS), (2) as telas da Fase 1 e (3) um passo a passo do que a médica precisa fazer fora do código (contas, projetos e chaves no GitHub, Supabase, Vercel e Anthropic).
- Fazer perguntas se algo estiver ambíguo.
- Criar dados fictícios de teste (seed) cobrindo todas as etapas do funil, e nunca usar dados reais de pacientes.
- Ao final de cada fase, entregar um roteiro de teste simples ("entre em tal tela, clique em tal botão, o esperado é...") para validação antes de seguir.

---

## Histórico de alterações

| Data | Alteração | Motivo |
|---|---|---|
| 10/11/2026 | Versão inicial | Escopo enviado pela médica |
