# NG Clinic — regras do projeto

Sistema web complementar ao prontuário (Afya Clinic) de um consultório médico de doenças crônicas e metabólicas: CRM de pacientes, financeiro simples, materiais educativos e acompanhamento da evolução. **Não é um prontuário.**

- Escopo completo: `docs/escopo.md` (fonte da verdade; alterações registradas no histórico do próprio arquivo).
- Planejamento da fase atual: `docs/fase1-planejamento.md`.

## Como trabalhar com a usuária

- A usuária é a médica dona do consultório e **não é programadora**. Toda explicação em português do Brasil, linguagem simples, sem jargão (ou com o jargão explicado).
- Construir em **fases** (ver abaixo). Nunca começar a fase seguinte sem aprovação explícita.
- Perguntar quando algo for ambíguo, em vez de supor regra de negócio.
- Commits pequenos, mensagens claras em português, ao final de cada etapa.
- Ao final de cada fase, entregar um roteiro de teste simples ("entre em tal tela, clique em tal botão, o esperado é...").

## Fases

1. Login (e-mail e senha), cadastro, CRM completo (etapas, motivos, previsão de retorno, plano de acompanhamento, reativação, tela "Hoje", kanban, linha do tempo), financeiro, dashboard de gestão/CRM/financeiro. Registro **simples** de consulta (data, tipo, "Retornar em").
2. Biblioteca de diretrizes e slides pré-consulta.
3. Consultas completas, exames e metas, resumo da consulta, "Entenda seu diagnóstico".
4. Check-in semanal, relatório de obesidade, indicadores clínicos.

## Regras de segurança e privacidade (inegociáveis)

- **Dados de saúde são dados sensíveis.** Row-level security (RLS) habilitado em **todas** as tabelas, sem exceção, inclusive tabelas de configuração. Nenhuma política para o papel `anon`.
- Acesso aos dados só com usuário autenticado (e-mail e senha; **sem 2FA** por decisão da usuária) e cadastrado como membro ativo da equipe. Checado no banco (RLS) e na aplicação (middleware). Cadastro público de contas desligado.
- Uso pessoal da médica (único usuário por enquanto). Fase de teste em **planos gratuitos** (Supabase Free, Vercel Hobby): sem backup automático, então manter a exportação manual de cópia de segurança. Não depender de recursos pagos.
- Banco no Supabase região São Paulo; funções da Vercel na região `gru1`.
- **Auditoria:** toda inclusão/alteração/exclusão em tabelas com dados de pacientes é registrada por trigger no `audit_log` (quem, quando, antes/depois). Visualização de ficha, exportações e envios também são registrados. O log é somente-inclusão (ninguém edita nem apaga).
- **Sem IA no sistema** (decisão da usuária): nenhuma integração com serviços de IA e nenhum dado enviado a terceiros, exceto o CEP (ViaCEP, chamado pelo servidor). Materiais são montados por modelos fixos a partir de dados digitados e de textos-base aprovados. Se um dia a IA for reintroduzida: só pelo servidor, só com dados pseudonimizados, e tudo nasce como rascunho.
- Textos-base e o mapa de conexões entre doenças nascem como **RASCUNHO**; materiais de pacientes só usam itens da biblioteca com status **aprovado**.
- Storage: buckets **privados**, acesso apenas por URL assinada e temporária.
- Segredos só em `.env.local` (no `.gitignore`) e nas variáveis da Vercel. A chave `service_role`/secret do Supabase é usada apenas no servidor e apenas quando indispensável.
- **Nunca usar dados reais de pacientes** em código, seed, testes, commits ou mensagens. Seed somente com dados fictícios (CPFs fictícios válidos apenas no formato).

## Convenções

- Idioma da interface: pt-BR. Datas `dd/mm/aaaa`, moeda `R$ 1.234,56`, fuso `America/Sao_Paulo`. Datas de calendário (vencimentos, data prevista de retorno) usam tipo `date`; instantes usam `timestamptz`.
- Nomes de tabelas, colunas e regras de negócio em português, sem acentos (`pacientes`, `data_prevista_retorno`).
- Stack: Next.js (App Router) + TypeScript + Tailwind + shadcn/ui; Supabase (Postgres, Auth com e-mail e senha, Storage); Recharts; deploy Vercel; migrações via Supabase CLI em `supabase/migrations`.
- Regras de mudança de etapa e criação de tarefas ficam em **funções do Postgres** (uma única fonte da verdade, usada pela tela e pela rotina diária). A rotina diária roda via `pg_cron` às 03:00 de Brasília (06:00 UTC).
- Todo prazo de tarefa vem da tabela de configurações (editável), nunca fixo no código.
- Responsivo: tudo precisa funcionar no celular e no computador.
- Identidade visual: verde-petróleo `#0F5F4F` (principal), laranja `#D9620F` (destaque / "você hoje"), fundo branco, cinzas suaves; fontes Inter (texto) e Fraunces (títulos de documentos).
