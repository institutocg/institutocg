import "server-only";
import type { PoolClient } from "pg";
import type { Sessao } from "@/modules/sessao/sessao";
import type { TarefaAberta } from "@/modules/painel/painel";
import { ultimoAtendimento, type DadosCadastro } from "./cadastro";

type Db = PoolClient;

export interface Opcao {
  id: string;
  nome: string;
}

export interface OpcoesCadastro {
  origens: Opcao[];
  procedimentos: (Opcao & { ciclo_retorno_meses: number | null })[];
  responsaveis: Opcao[];
}

export async function carregarOpcoes(db: Db, clinicaId: string): Promise<OpcoesCadastro> {
  const [origens, procedimentos, responsaveis] = await Promise.all([
    db.query<Opcao>(
      "select id, nome from public.origens where clinica_id = $1 and ativo and tipo <> 'interno' order by ordem, nome",
      [clinicaId],
    ),
    db.query<Opcao & { ciclo_retorno_meses: number | null }>(
      "select id, nome, ciclo_retorno_meses from public.procedimentos where clinica_id = $1 and ativo order by ordem, nome",
      [clinicaId],
    ),
    db.query<Opcao>(
      `select u.id, u.nome from public.membros m join public.usuarios u on u.id = m.usuario_id
        where m.clinica_id = $1 and m.ativo and u.ativo order by u.nome`,
      [clinicaId],
    ),
  ]);
  return { origens: origens.rows, procedimentos: procedimentos.rows, responsaveis: responsaveis.rows };
}

/** Já existe alguém com este WhatsApp/telefone ou e-mail? */
export async function buscarDuplicado(
  db: Db,
  dados: Pick<DadosCadastro, "whatsapp" | "email">,
  excetoId?: string,
): Promise<Opcao | null> {
  if (!dados.whatsapp && !dados.email) return null;
  const { rows } = await db.query<Opcao>(
    `select id, nome from public.pessoas
      where ($1::text is not null and (whatsapp_e164 = $1 or telefone_e164 = $1)
             or $2::text is not null and lower(email) = $2)
        and ($3::uuid is null or id <> $3)
      limit 1`,
    [dados.whatsapp ?? null, dados.email ?? null, excetoId ?? null],
  );
  return rows[0] ?? null;
}

async function hojeDa(db: Db, clinicaId: string): Promise<string> {
  const { rows } = await db.query<{ hoje: string }>("select public.hoje_clinica($1) as hoje", [clinicaId]);
  return rows[0].hoje;
}

async function origemPacienteAntigo(db: Db, clinicaId: string): Promise<string | null> {
  const { rows } = await db.query<{ id: string }>(
    `select id from public.origens where clinica_id = $1 and tipo = 'interno'
      order by (nome = 'Paciente antigo') desc, ordem limit 1`,
    [clinicaId],
  );
  return rows[0]?.id ?? null;
}

/**
 * Cadastra a pessoa e, no mesmo passo:
 *  - registra a data do primeiro contato (hoje) e o responsável;
 *  - novo contato: abre a negociação na etapa "Novo contato" (o motor cria a
 *    tarefa "Fazer o primeiro contato");
 *  - paciente antigo: grava o último atendimento e os tratamentos já feitos; se
 *    houver interesse, abre a negociação em "Em contato".
 */
export async function cadastrar(db: Db, sessao: Sessao, d: DadosCadastro): Promise<string> {
  const hoje = await hojeDa(db, sessao.clinicaId);
  const antigo = d.tipo === "paciente_antigo";
  const ultimo = antigo ? ultimoAtendimento(d.ultimoAtendimentoMes, d.ultimoAtendimentoFaixa, hoje) : null;
  const origemId = antigo ? (d.origemId ?? (await origemPacienteAntigo(db, sessao.clinicaId))) : d.origemId;
  const responsavel = d.responsavelId ?? sessao.usuarioId;

  const { rows } = await db.query<{ id: string }>(
    `insert into public.pessoas (
       clinica_id, tipo_cadastro, nome, data_nascimento, whatsapp_e164, email, cep, logradouro, bairro, cidade, uf,
       origem_id, responsavel_id, observacoes_comerciais, consentimento_marketing, primeiro_contato_em,
       ultimo_atendimento_informado, ultimo_atendimento_faixa, em_tratamento
     ) values ($1, $2, $3, $4, $5, $6, $7, $8, $9, $10, $11, $12, $13, $14, $15, $16, $17, $18, $19)
     returning id`,
    [
      sessao.clinicaId, d.tipo, d.nome, d.nascimento ?? null, d.whatsapp ?? null, d.email ?? null, d.cep ?? null,
      d.endereco ?? null, d.bairro ?? null, d.cidade ?? null, d.uf ?? null, origemId ?? null, responsavel,
      d.observacoes ?? null, d.aceitaMarketing, hoje, ultimo?.data ?? null, ultimo?.faixa ?? null,
      antigo && d.emTratamento,
    ],
  );
  const pessoaId = rows[0].id;

  if (antigo && d.tratamentos.length > 0) {
    await db.query(
      `insert into public.tratamentos_anteriores (clinica_id, pessoa_id, procedimento_id, realizado_em)
       select $1, $2, p.id, $4 from public.procedimentos p where p.id = any($3::uuid[]) and p.clinica_id = $1`,
      [sessao.clinicaId, pessoaId, d.tratamentos, ultimo?.data ?? null],
    );
  }

  if (!antigo || d.procedimentoId) {
    await abrirNegociacao(db, sessao.clinicaId, pessoaId, d.procedimentoId ?? null, antigo ? "em_contato" : "novo_contato", origemId ?? null, responsavel);
  }
  return pessoaId;
}

export async function abrirNegociacao(
  db: Db,
  clinicaId: string,
  pessoaId: string,
  procedimentoId: string | null,
  marco: "novo_contato" | "em_contato",
  origemId: string | null,
  responsavelId: string | null,
): Promise<string> {
  const { rows } = await db.query<{ id: string }>(
    `insert into public.oportunidades (clinica_id, pessoa_id, procedimento_id, origem_id, responsavel_id, etapa_id)
     values ($1, $2, $3, $4, $5, (public.etapa_por_marco($1, $6)).id)
     returning id`,
    [clinicaId, pessoaId, procedimentoId, origemId, responsavelId, marco],
  );
  return rows[0].id;
}

/** Atualiza os dados cadastrais (o tipo de cadastro não muda aqui). */
export async function atualizar(db: Db, sessao: Sessao, pessoaId: string, d: DadosCadastro): Promise<void> {
  const hoje = await hojeDa(db, sessao.clinicaId);
  const antigo = d.tipo === "paciente_antigo";
  const ultimo = antigo ? ultimoAtendimento(d.ultimoAtendimentoMes, d.ultimoAtendimentoFaixa, hoje) : null;

  const r = await db.query(
    `update public.pessoas set
       nome = $2, data_nascimento = $3, whatsapp_e164 = $4, email = $5, cep = $6, logradouro = $7, bairro = $8,
       cidade = $9, uf = $10, origem_id = coalesce($11, origem_id), responsavel_id = coalesce($12, responsavel_id),
       observacoes_comerciais = $13, consentimento_marketing = $14,
       ultimo_atendimento_informado = case when $15 then $16::date else ultimo_atendimento_informado end,
       ultimo_atendimento_faixa = case when $15 then $17 else ultimo_atendimento_faixa end,
       em_tratamento = case when $15 then $18 else em_tratamento end
     where id = $1`,
    [
      pessoaId, d.nome, d.nascimento ?? null, d.whatsapp ?? null, d.email ?? null, d.cep ?? null, d.endereco ?? null,
      d.bairro ?? null, d.cidade ?? null, d.uf ?? null, d.origemId ?? null, d.responsavelId ?? null,
      d.observacoes ?? null, d.aceitaMarketing, antigo, ultimo?.data ?? null, ultimo?.faixa ?? null, d.emTratamento,
    ],
  );
  if (r.rowCount === 0) throw Object.assign(new Error("Cadastro não encontrado."), { code: "P0002" });

  // Tratamentos anteriores: só acrescenta (o histórico não é apagado).
  if (antigo && d.tratamentos.length > 0) {
    await db.query(
      `insert into public.tratamentos_anteriores (clinica_id, pessoa_id, procedimento_id, realizado_em)
       select $1, $2, p.id, $4 from public.procedimentos p
        where p.id = any($3::uuid[]) and p.clinica_id = $1
          and not exists (select 1 from public.tratamentos_anteriores t where t.pessoa_id = $2 and t.procedimento_id = p.id)`,
      [sessao.clinicaId, pessoaId, d.tratamentos, ultimo?.data ?? null],
    );
  }

  // Procedimento de interesse: ajusta a negociação em andamento ou abre uma nova.
  if (d.procedimentoId) {
    const { rows } = await db.query<{ id: string }>(
      "select id from public.oportunidades where pessoa_id = $1 and status in ('aberta', 'pausada')",
      [pessoaId],
    );
    if (rows[0]) {
      await db.query("update public.oportunidades set procedimento_id = $2 where id = $1", [rows[0].id, d.procedimentoId]);
    } else {
      await abrirNegociacao(db, sessao.clinicaId, pessoaId, d.procedimentoId, "em_contato", d.origemId ?? null, d.responsavelId ?? sessao.usuarioId);
    }
  }
}

// ─── Ficha ──────────────────────────────────────────────────────────────────

export interface Contato {
  id: string;
  tipo_cadastro: "novo_contato" | "paciente_antigo";
  nome: string;
  data_nascimento: string | null;
  whatsapp_e164: string | null;
  telefone_e164: string | null;
  email: string | null;
  cep: string | null;
  logradouro: string | null;
  bairro: string | null;
  cidade: string | null;
  uf: string | null;
  origem_id: string | null;
  origem: string | null;
  responsavel_id: string | null;
  responsavel: string | null;
  temperatura: string | null;
  observacoes_comerciais: string | null;
  primeiro_contato_em: string;
  ultimo_contato_em: Date | null;
  ultimo_atendimento_em: string | null;
  ultimo_atendimento_informado: string | null;
  ultimo_atendimento_faixa: string | null;
  paciente_desde: string | null;
  em_tratamento: boolean;
  retorno_previsto_em: string | null;
  consentimento_marketing: boolean;
  nao_contatar: boolean;
  nao_contatar_motivo: string | null;
  relacionamento: "lead" | "paciente_ativo" | "paciente_inativo";
  status_atual: string;
  oportunidade_id: string | null;
  procedimento_interesse_id: string | null;
  procedimento_interesse: string | null;
  etapa_id: string | null;
  etapa_atual: string | null;
  dias_na_etapa: number | null;
  valor_estimado_centavos: number | null;
  proxima_acao: string | null;
  proxima_acao_em: string | null;
  criado_em: Date;
}

export interface Etapa {
  id: string;
  nome: string;
  ordem: number;
  tipo: "aberta" | "ganho" | "perda";
}

export interface EventoLinha {
  quando: Date;
  tipo: string;
  titulo: string;
  detalhe: string | null;
  autor: string | null;
  anulado: boolean;
}

export interface Ficha {
  hoje: string;
  contato: Contato;
  etapas: Etapa[];
  interesses: string[];
  negociacoesAnteriores: { procedimento: string | null; resultado: string; motivo: string | null; fechada_em: Date | null }[];
  tratamentos: { procedimento: string; realizado_em: string | null; ciclo_retorno_meses: number | null }[];
  proximaTarefa: TarefaAberta | null;
  proximasConsultas: { inicio: Date; tipo: string; status: string }[];
  tarefasFuturas: { id: string; titulo: string; vence_em: string; tipo: string }[];
  tarefasFeitas: { titulo: string; status: string; resultado: string | null; quando: Date; autor: string | null }[];
  linha: EventoLinha[];
  financeiro: null | {
    orcamentos: { numero: number; versao: number; status: string; valor_final_centavos: number; apresentado_em: string | null; itens: string | null }[];
    vendas: {
      id: string;
      tipo: string;
      status: string;
      fechada_em: string;
      valor_total_centavos: number;
      desconto_centavos: number;
      valor_final_centavos: number;
      condicao_pagamento: string;
      quantidade_parcelas: number;
      forma: string | null;
      observacao_financeira: string | null;
    }[];
    parcelas: {
      id: string;
      venda_id: string;
      numero: number;
      valor_centavos: number;
      valor_pago_centavos: number;
      vencimento: string;
      pago_em: string | null;
      situacao: string;
      forma_pagamento: string | null;
    }[];
  };
  resgatePendente: boolean;
  /** Meses até o convite de retorno após o tratamento (null se a regra estiver desligada). */
  mesesRetorno: number | null;
}

const COLUNAS_TAREFA = `
  id, pessoa_id, oportunidade_id, agendamento_id, parcela_id, tipo, titulo, descricao, vence_em, horario,
  prioridade, passo, regra, mensagem_sugerida, pessoa_nome, whatsapp_e164, telefone_e164, origem_nome,
  primeiro_contato_em, procedimento, etapa_marco, orcamento_apresentado_em, orcamento_valor_centavos,
  agendamento_inicio, agendamento_tipo, parcela_numero, parcela_vencimento, parcela_saldo_centavos, parcela_total, regra_nome`;

export async function carregarFicha(db: Db, sessao: Sessao, pessoaId: string): Promise<Ficha | null> {
  const contato = (await db.query<Contato>("select * from public.v_contatos where id = $1", [pessoaId])).rows[0];
  if (!contato) return null;
  const hoje = await hojeDa(db, sessao.clinicaId);

  const [etapas, interesses, anteriores, tratamentos, proxima, consultas, futuras, feitas, linha, resgate] = await Promise.all([
    db.query<Etapa>(
      "select id, nome, ordem, tipo from public.etapas_funil where clinica_id = $1 and ativo order by ordem",
      [sessao.clinicaId],
    ),
    db.query<{ nome: string }>(
      `select p.nome from public.oportunidade_interesses i join public.procedimentos p on p.id = i.procedimento_id
        where i.oportunidade_id = $1`,
      [contato.oportunidade_id],
    ),
    db.query(
      `select p.nome as procedimento, o.resultado, m.nome as motivo, o.fechada_em
         from public.oportunidades o
         left join public.procedimentos p on p.id = o.procedimento_id
         left join public.motivos m on m.id = o.motivo_id
        where o.pessoa_id = $1 and o.status in ('ganha', 'perdida')
        order by o.fechada_em desc`,
      [pessoaId],
    ),
    db.query(
      `select p.nome as procedimento, t.realizado_em, p.ciclo_retorno_meses
         from public.tratamentos_anteriores t join public.procedimentos p on p.id = t.procedimento_id
        where t.pessoa_id = $1 order by t.realizado_em desc nulls last, p.nome`,
      [pessoaId],
    ),
    db.query<Omit<TarefaAberta, "agendamento_inicio"> & { agendamento_inicio: Date | null }>(
      `select ${COLUNAS_TAREFA} from public.v_tarefas_abertas where pessoa_id = $1
        order by vence_em, horario nulls last, array_position(array['urgente','alta','normal','baixa']::public.prioridade_tarefa[], prioridade)
        limit 1`,
      [pessoaId],
    ),
    db.query(
      `select inicio, tipo, status from public.agendamentos
        where pessoa_id = $1 and status in ('agendado', 'confirmado') and inicio >= now() - interval '12 hours'
        order by inicio limit 3`,
      [pessoaId],
    ),
    db.query(
      `select id, titulo, vence_em, tipo from public.tarefas
        where pessoa_id = $1 and status = 'pendente' order by vence_em, criado_em`,
      [pessoaId],
    ),
    db.query(
      `select t.titulo, t.status, coalesce(t.resultado, t.cancelada_motivo) as resultado,
              coalesce(t.concluida_em, t.cancelada_em) as quando, u.nome as autor
         from public.tarefas t left join public.usuarios u on u.id = t.concluida_por
        where t.pessoa_id = $1 and t.status <> 'pendente'
        order by coalesce(t.concluida_em, t.cancelada_em) desc limit 30`,
      [pessoaId],
    ),
    db.query<EventoLinha>(
      `select * from (
         select i.ocorreu_em as quando, i.tipo::text as tipo, i.tipo::text as titulo, i.descricao as detalhe,
                u.nome as autor, i.anulada_em is not null as anulado
           from public.interacoes i left join public.usuarios u on u.id = i.usuario_id
          where i.pessoa_id = $1
         union all
         select h.mudou_em, 'etapa',
                case when h.etapa_anterior_id is null then 'Entrou no funil: ' || en.nome
                     else 'Etapa: ' || ea.nome || ' → ' || en.nome end,
                h.observacao, u.nome, false
           from public.historico_etapas h
           join public.etapas_funil en on en.id = h.etapa_nova_id
           left join public.etapas_funil ea on ea.id = h.etapa_anterior_id
           left join public.usuarios u on u.id = h.usuario_id
          where h.pessoa_id = $1
         union all
         select p.criado_em, 'cadastro',
                case p.tipo_cadastro when 'paciente_antigo' then 'Cadastrado como paciente antigo'
                     else 'Cadastrado como novo contato' end,
                null, u.nome, false
           from public.pessoas p left join public.usuarios u on u.id = p.criado_por
          where p.id = $1
       ) eventos order by quando desc limit 60`,
      [pessoaId],
    ),
    // Resgate em andamento = negociação aberta na etapa "Reativação".
    db.query(
      `select 1 from public.oportunidades o join public.etapas_funil e on e.id = o.etapa_id
        where o.pessoa_id = $1 and o.status = 'aberta' and e.marco = 'reativacao'`,
      [pessoaId],
    ),
  ]);

  let financeiro: Ficha["financeiro"] = null;
  if (sessao.podeVerFinanceiro) {
    const [orcamentos, vendas, parcelas] = await Promise.all([
      db.query(
        `select o.numero, o.versao, o.status, o.valor_final_centavos, o.apresentado_em,
                (select string_agg(coalesce(i.descricao_comercial, p.nome), ', ')
                   from public.orcamento_itens i join public.procedimentos p on p.id = i.procedimento_id
                  where i.orcamento_id = o.id) as itens
           from public.orcamentos o where o.pessoa_id = $1 order by o.criado_em desc`,
        [pessoaId],
      ),
      db.query(
        `select v.id, v.tipo, v.status, v.fechada_em, v.valor_total_centavos, v.desconto_centavos, v.valor_final_centavos,
                v.condicao_pagamento, v.quantidade_parcelas, f.nome as forma, v.observacao_financeira
           from public.vendas v left join public.formas_pagamento f on f.id = v.forma_pagamento_id
          where v.pessoa_id = $1 order by v.fechada_em desc`,
        [pessoaId],
      ),
      db.query(
        `select id, venda_id, numero, valor_centavos, valor_pago_centavos, vencimento, pago_em, situacao, forma_pagamento
           from public.v_parcelas where pessoa_id = $1 order by vencimento, numero`,
        [pessoaId],
      ),
    ]);
    financeiro = { orcamentos: orcamentos.rows, vendas: vendas.rows, parcelas: parcelas.rows };
  }

  const regraRetorno = await db.query<{ periodo_meses: number | null; ativa: boolean }>(
    "select periodo_meses, ativa from public.regras_followup where clinica_id = $1 and situacao = 'pos_tratamento'",
    [sessao.clinicaId],
  );
  const p = proxima.rows[0];
  return {
    hoje,
    contato,
    etapas: etapas.rows,
    interesses: interesses.rows.map((r) => r.nome),
    negociacoesAnteriores: anteriores.rows,
    tratamentos: tratamentos.rows,
    proximaTarefa: p ? { ...p, agendamento_inicio: p.agendamento_inicio?.toISOString() ?? null } : null,
    proximasConsultas: consultas.rows,
    tarefasFuturas: futuras.rows,
    tarefasFeitas: feitas.rows,
    linha: linha.rows,
    financeiro,
    resgatePendente: (resgate.rowCount ?? 0) > 0,
    mesesRetorno: regraRetorno.rows[0]?.ativa ? (regraRetorno.rows[0].periodo_meses ?? 6) : null,
  };
}

// ─── Lista e funil ──────────────────────────────────────────────────────────

export const FILTROS = {
  todos: "Todos",
  novos: "Novos contatos",
  negociacao: "Em negociação",
  antigos: "Pacientes antigos",
  inativos: "Inativos (resgate)",
  sem_acao: "Sem próxima ação",
} as const;
export type Filtro = keyof typeof FILTROS;

export interface LinhaContato {
  id: string;
  nome: string;
  whatsapp_e164: string | null;
  relacionamento: string;
  status_atual: string;
  procedimento_interesse: string | null;
  etapa_atual: string | null;
  proxima_acao: string | null;
  proxima_acao_em: string | null;
  ultimo_contato_em: Date | null;
}

export async function listarContatos(db: Db, clinicaId: string, filtro: Filtro, busca: string): Promise<LinhaContato[]> {
  const condicao: Record<Filtro, string> = {
    todos: "true",
    novos: "relacionamento = 'lead'",
    negociacao: "status_atual = 'em_negociacao'",
    antigos: "tipo_cadastro = 'paciente_antigo'",
    inativos: "relacionamento = 'paciente_inativo' and oportunidade_id is null",
    sem_acao: "proxima_tarefa_id is null and not nao_contatar",
  };
  const termo = busca.trim();
  const digitos = termo.replace(/\D/g, "");
  const { rows } = await db.query<LinhaContato>(
    `select id, nome, whatsapp_e164, relacionamento, status_atual, procedimento_interesse, etapa_atual,
            proxima_acao, proxima_acao_em, ultimo_contato_em
       from public.v_contatos
      where clinica_id = $1 and arquivado_em is null and ${condicao[filtro]}
        and ($2 = '' or sem_acento(nome) like '%' || sem_acento($2) || '%'
             or ($3 <> '' and (coalesce(whatsapp_e164, '') like '%' || $3 || '%' or coalesce(telefone_e164, '') like '%' || $3 || '%'))
             or email ilike '%' || $2 || '%')
      order by proxima_acao_em nulls last, nome
      limit 300`,
    [clinicaId, termo, digitos.length >= 4 ? digitos : ""],
  );
  return rows;
}
