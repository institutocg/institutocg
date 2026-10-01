/**
 * Monta o painel "O que eu tenho que fazer hoje?" a partir das tarefas
 * pendentes (visão v_tarefas_abertas). Funções puras: sem banco, sem tela.
 */
import { diasEntre, somarDias, type DataCivil } from "@/lib/datas";
import { formatarMoeda } from "@/lib/moeda";

export type TipoTarefa =
  | "primeiro_contato"
  | "follow_up"
  | "follow_up_orcamento"
  | "confirmar_agendamento"
  | "recuperar_desmarcacao"
  | "recuperar_falta"
  | "reabrir_sem_resposta"
  | "retorno_por_motivo"
  | "reativacao"
  | "manutencao"
  | "confirmar_pagamento"
  | "apresentar_orcamento"
  | "acompanhar_decisao"
  | "agendar_tratamento"
  | "definir_proxima_acao"
  | "personalizada";

export type Prioridade = "baixa" | "normal" | "alta" | "urgente";

/** Uma linha de v_tarefas_abertas. */
export interface TarefaAberta {
  id: string;
  pessoa_id: string;
  oportunidade_id: string | null;
  agendamento_id: string | null;
  parcela_id: string | null;
  tipo: TipoTarefa;
  titulo: string;
  descricao: string | null;
  vence_em: DataCivil;
  horario: string | null;
  prioridade: Prioridade;
  passo: number;
  regra: string | null;
  /** Nome da regra de follow-up que criou a tarefa (Configurações). */
  regra_nome?: string | null;
  mensagem_sugerida: string | null;
  pessoa_nome: string;
  whatsapp_e164: string | null;
  telefone_e164: string | null;
  origem_nome: string | null;
  primeiro_contato_em: DataCivil | null;
  procedimento: string | null;
  etapa_marco: string | null;
  orcamento_apresentado_em: DataCivil | null;
  orcamento_valor_centavos: number | null;
  agendamento_inicio: string | null; // ISO
  agendamento_tipo: string | null;
  parcela_numero: number | null;
  parcela_vencimento: DataCivil | null;
  parcela_saldo_centavos: number | null;
  parcela_total: number | null;
}

export type Grupo = "urgente" | "importante" | "rotina";

export type Botao =
  | "abrir_paciente"
  | "ver_mensagem"
  | "registrar_contato"
  | "concluir"
  | "ver_negociacao"
  | "marcar_pago";

/**
 * Qual conjunto de resultados o diálogo "Registrar contato" oferece:
 * venda (negociação), agendamento (confirmação), pagamento (lembrete),
 * recuperacao (desmarcou/faltou/sem resposta) e reativacao (paciente antigo).
 */
export type TipoRegistro = "venda" | "agendamento" | "pagamento" | "recuperacao" | "reativacao";

export interface Cartao {
  id: string;
  pessoaId: string;
  parcelaId: string | null;
  grupo: Grupo;
  pagamento: boolean;
  /** Título da tarefa como está gravado (editável pela usuária). */
  tituloTarefa: string;
  horario: string | null;
  /** Linha principal: nome da pessoa (ou "Pagamento previsto" / "Pagamento atrasado" nos pagamentos). */
  titulo: string;
  /** Linha secundária dos pagamentos: "Maria Silva — R$ 2.500,00". */
  subtitulo: string | null;
  procedimento: string | null;
  motivo: string;
  acaoRecomendada: string;
  quando: string;
  diasAtraso: number;
  vence: DataCivil;
  mensagem: string | null;
  whatsapp: string | null;
  valorCentavos: number | null;
  botoes: Botao[];
  registro: TipoRegistro;
  /** "Criada pela regra …" (quando veio de uma regra de follow-up). */
  regraNome: string | null;
  /**
   * Pode ser recusada ("Não fazer esta ação")? Lembretes de pagamento e recuperações de
   * desmarcação/falta não: saem ao pagar ou ao registrar o resultado do contato.
   */
  recusavel: boolean;
}

export interface Painel {
  hoje: DataCivil;
  atrasadas: Cartao[];
  doDia: Record<Grupo, Cartao[]>;
  proximos: { dia: DataCivil; cartoes: Cartao[] }[];
  resumo: {
    totalHoje: number;
    atrasadas: number;
    urgentes: number;
    importantes: number;
    rotina: number;
    proximos: number;
  };
}

const ORDEM_GRUPO: Record<Grupo, number> = { urgente: 0, importante: 1, rotina: 2 };
const ORDEM_PRIORIDADE: Record<Prioridade, number> = { urgente: 0, alta: 1, normal: 2, baixa: 3 };

export const DIAS_PROXIMOS = 7;

// ─── Classificação ──────────────────────────────────────────────────────────

/**
 * 🔴 Urgente: leads que precisam de retorno hoje, desmarcações/faltas,
 *    pagamentos atrasados, e tudo marcado como urgente.
 * 🟠 Importante: follow-ups, orçamentos enviados, quem demonstrou interesse,
 *    pagamentos do dia, decisões pendentes.
 * 🟢 Rotina: confirmações, reativações, manutenções e demais tarefas.
 */
export function classificar(t: TarefaAberta, hoje: DataCivil): Grupo {
  const atrasada = t.vence_em < hoje;
  if (t.prioridade === "urgente") return "urgente";

  switch (t.tipo) {
    case "primeiro_contato":
    case "recuperar_desmarcacao":
    case "recuperar_falta":
      return "urgente";
    case "confirmar_pagamento":
      return atrasada ? "urgente" : "importante";
    case "follow_up":
      if (t.regra === "pediu_retorno") return "urgente"; // pediu retorno para hoje
      return "importante";
    case "follow_up_orcamento":
    case "acompanhar_decisao":
    case "retorno_por_motivo":
    case "reabrir_sem_resposta":
    case "apresentar_orcamento":
    case "agendar_tratamento":
    case "definir_proxima_acao":
      return "importante";
    case "confirmar_agendamento":
    case "reativacao":
    case "manutencao":
      return "rotina";
    case "personalizada":
      return t.prioridade === "alta" ? "importante" : "rotina";
  }
}

// ─── Textos do cartão ───────────────────────────────────────────────────────

const ROTULO_AGENDAMENTO: Record<string, string> = {
  avaliacao: "Avaliação",
  apresentacao_orcamento: "Apresentação do orçamento",
  procedimento: "Procedimento",
  retorno: "Retorno",
  manutencao: "Manutenção",
  ligacao_agendada: "Ligação",
};

const DIA_SEMANA = new Intl.DateTimeFormat("pt-BR", { weekday: "short", timeZone: "UTC" });

/** "hoje", "ontem", "há 5 dias" */
export function haQuantoTempo(data: DataCivil, hoje: DataCivil): string {
  const d = diasEntre(data, hoje);
  if (d <= 0) return "hoje";
  if (d === 1) return "ontem";
  return `há ${d} dias`;
}

/** "Hoje", "Amanhã", "Ontem", "Atrasada há 3 dias", "qui., 02/10" */
export function rotuloData(data: DataCivil, hoje: DataCivil, horario?: string | null): string {
  const d = diasEntre(hoje, data);
  const hora = horario ? ` às ${horario.slice(0, 5)}` : "";
  if (d === 0) return `Hoje${hora}`;
  if (d === 1) return `Amanhã${hora}`;
  if (d === -1) return `Ontem${hora}`;
  if (d < 0) return `Atrasada há ${-d} dias`;
  return `${diaCurto(data)}${hora}`;
}

function diaCurto(data: DataCivil): string {
  const [a, m, d] = data.split("-").map(Number);
  const semana = DIA_SEMANA.format(new Date(Date.UTC(a, m - 1, d)));
  return `${semana} ${String(d).padStart(2, "0")}/${String(m).padStart(2, "0")}`;
}

function ddmm(data: DataCivil): string {
  return `${data.slice(8, 10)}/${data.slice(5, 7)}`;
}

/** "amanhã às 14:30", "hoje às 10:00", "qui. 02/10 às 09:00" (fuso de São Paulo) */
function quandoAgendamento(iso: string, hoje: DataCivil): string {
  const partes = new Intl.DateTimeFormat("en-CA", {
    timeZone: "America/Sao_Paulo",
    year: "numeric",
    month: "2-digit",
    day: "2-digit",
    hour: "2-digit",
    minute: "2-digit",
    hourCycle: "h23",
  }).formatToParts(new Date(iso));
  const v = (tipo: string) => partes.find((p) => p.type === tipo)?.value ?? "";
  const data = `${v("year")}-${v("month")}-${v("day")}`;
  const hora = `${v("hour")}:${v("minute")}`;
  const d = diasEntre(hoje, data);
  const dia = d === 0 ? "hoje" : d === 1 ? "amanhã" : d === -1 ? "ontem" : diaCurto(data);
  return `${dia} às ${hora}`;
}

function primeiroNome(nome: string) {
  return nome.split(" ")[0];
}

export function motivoDoContato(t: TarefaAberta, hoje: DataCivil): string {
  switch (t.tipo) {
    case "primeiro_contato": {
      const quando = t.primeiro_contato_em ? `chegou ${haQuantoTempo(t.primeiro_contato_em, hoje)}` : null;
      const origem = t.origem_nome ? `via ${t.origem_nome}` : null;
      return ["Novo contato", [origem, quando].filter(Boolean).join(", ")].filter(Boolean).join(" — ");
    }
    case "follow_up_orcamento": {
      const valor = t.orcamento_valor_centavos ? ` de ${formatarMoeda(t.orcamento_valor_centavos)}` : "";
      if (!t.orcamento_apresentado_em) return `Orçamento${valor} enviado`;
      return `Orçamento${valor} enviado ${haQuantoTempo(t.orcamento_apresentado_em, hoje)}`;
    }
    case "recuperar_desmarcacao":
      return t.agendamento_inicio
        ? `Desmarcou a consulta de ${quandoAgendamento(t.agendamento_inicio, hoje)}`
        : "Desmarcou a consulta";
    case "recuperar_falta":
      return t.agendamento_inicio
        ? `Faltou à consulta de ${quandoAgendamento(t.agendamento_inicio, hoje)}`
        : "Faltou à consulta";
    case "confirmar_agendamento": {
      const rotulo = ROTULO_AGENDAMENTO[t.agendamento_tipo ?? ""] ?? "Consulta";
      return t.agendamento_inicio ? `${rotulo} ${quandoAgendamento(t.agendamento_inicio, hoje)}` : rotulo;
    }
    case "confirmar_pagamento": {
      const parcela =
        t.parcela_numero === 0
          ? "Entrada"
          : t.parcela_numero && t.parcela_total
            ? `Parcela ${t.parcela_numero} de ${t.parcela_total}`
            : "Pagamento";
      const venc = t.parcela_vencimento ?? t.vence_em;
      const atraso = diasEntre(venc, hoje);
      return atraso > 0
        ? `Vencido há ${atraso} ${atraso === 1 ? "dia" : "dias"} · ${parcela} · vencimento ${ddmm(venc)}`
        : `${parcela} · vencimento ${ddmm(venc)}`;
    }
    case "acompanhar_decisao": {
      // Depois da consulta (onde o orçamento é apresentado): a pessoa está decidindo.
      const pensando = t.descricao === "Ficou de pensar" ? " — ficou de pensar" : "";
      if (t.orcamento_apresentado_em) {
        const valor = t.orcamento_valor_centavos ? ` de ${formatarMoeda(t.orcamento_valor_centavos)}` : "";
        return `Recebeu o orçamento${valor} na consulta ${haQuantoTempo(t.orcamento_apresentado_em, hoje)}${pensando}`;
      }
      const orcamento = t.orcamento_valor_centavos ? ` (orçamento de ${formatarMoeda(t.orcamento_valor_centavos)})` : "";
      return `${t.descricao && !pensando ? t.descricao : "Passou pela consulta e está decidindo"}${orcamento}${pensando}`;
    }
    case "agendar_tratamento":
      return "Fechou o tratamento";
    case "apresentar_orcamento":
      return "Passou pela avaliação";
    case "reabrir_sem_resposta":
      return t.descricao ?? "Sem resposta há algum tempo";
    case "follow_up":
      if (t.descricao) return t.descricao;
      switch (t.regra) {
        case "em_contato":
          return "Demonstrou interesse";
        case "pediu_retorno":
          return "Pediu retorno";
        case "clinica_cancelou":
          return "A clínica cancelou o horário";
        default:
          return "Follow-up programado";
      }
    case "definir_proxima_acao":
      return t.descricao ?? "Negociação sem próximo passo definido";
    default:
      return t.descricao ?? t.titulo;
  }
}

export function acaoRecomendada(t: TarefaAberta, hoje: DataCivil): string {
  const nome = primeiroNome(t.pessoa_nome);
  switch (t.tipo) {
    case "primeiro_contato":
      return t.passo <= 1
        ? "Fazer o primeiro contato ainda hoje — quem recebe retorno rápido tem mais chance de agendar."
        : `Fazer a ${t.passo}ª tentativa de contato.`;
    case "follow_up_orcamento":
      return t.passo >= 3
        ? "Fazer follow-up hoje e oferecer uma conversa com a doutora para tirar dúvidas."
        : "Fazer follow-up hoje: perguntar se ficou alguma dúvida sobre o orçamento.";
    case "acompanhar_decisao":
      if (t.passo >= 3) return "Último contato da sequência: deixar a porta aberta, com gentileza.";
      if (t.passo === 2) return "Oferecer uma conversa com a doutora para esclarecer dúvidas, sem pressa.";
      return "Perguntar como ficou depois da consulta e se restou alguma dúvida sobre o plano, sem pressionar.";
    case "recuperar_desmarcacao":
      return "Entrar em contato para entender se deseja remarcar.";
    case "recuperar_falta":
      return "Entrar em contato com cuidado e oferecer um novo horário.";
    case "confirmar_agendamento":
      return t.passo > 1 ? "Tentar confirmar a presença novamente." : "Confirmar a presença.";
    case "confirmar_pagamento":
      return t.parcela_vencimento && t.parcela_vencimento < hoje
        ? `Lembrar ${nome} do pagamento, com gentileza.`
        : "Confirmar se o pagamento foi feito.";
    case "retorno_por_motivo":
      return "Retomar a conversa sem pressão, oferecendo ajuda com o que impediu o fechamento.";
    case "reabrir_sem_resposta":
      return "Enviar uma mensagem leve para retomar o contato.";
    case "reativacao":
      return t.regra === "campanha"
        ? "Enviar a mensagem da campanha, com um convite pessoal."
        : "Enviar mensagem de reativação convidando para uma visita.";
    case "manutencao":
      return t.regra === "pos_tratamento"
        ? "Convidar para a revisão após o tratamento."
        : "Convidar para agendar a manutenção.";
    case "agendar_tratamento":
      return "Registrar as condições de pagamento e combinar a data de início.";
    case "apresentar_orcamento":
      return "Registrar o orçamento apresentado na avaliação.";
    case "definir_proxima_acao":
      return t.titulo.endsWith("compareceu?")
        ? `Registrar se ${nome} compareceu à consulta.`
        : "Decidir: continuar acompanhando ou encerrar a negociação.";
    case "follow_up":
      switch (t.regra) {
        case "em_contato":
          return "Conduzir para o agendamento da avaliação.";
        case "pediu_retorno":
          return t.vence_em > hoje ? "Retornar na data combinada." : "Retornar hoje, como combinado.";
        case "numero_invalido":
          return "Buscar outro telefone (indicação, redes sociais, cadastro antigo).";
        case "clinica_cancelou":
          return "Oferecer um novo horário.";
        default:
          return t.titulo;
      }
    case "personalizada":
      return t.titulo;
  }
}

// ─── Montagem ───────────────────────────────────────────────────────────────

export function montarCartao(t: TarefaAberta, hoje: DataCivil): Cartao {
  const pagamento = t.tipo === "confirmar_pagamento";
  const vencimento = pagamento ? (t.parcela_vencimento ?? t.vence_em) : t.vence_em;
  const diasAtraso = Math.max(0, diasEntre(t.vence_em, hoje));
  const atrasoPagamento = Math.max(0, diasEntre(vencimento, hoje));
  const valor = t.parcela_saldo_centavos;

  let titulo = t.pessoa_nome;
  let subtitulo: string | null = null;
  if (pagamento) {
    titulo =
      atrasoPagamento === 0
        ? vencimento === hoje
          ? "Pagamento previsto"
          : `Pagamento previsto para ${ddmm(vencimento)}`
        : "Pagamento atrasado";
    subtitulo = valor !== null ? `${t.pessoa_nome} — ${formatarMoeda(valor)}` : t.pessoa_nome;
  }

  let botoes: Botao[];
  let registro: TipoRegistro = "venda";
  if (pagamento) {
    botoes = ["ver_negociacao", "marcar_pago", "ver_mensagem", "registrar_contato"];
    registro = "pagamento";
  } else if (t.tipo === "confirmar_agendamento") {
    botoes = ["abrir_paciente", "ver_mensagem", "registrar_contato", "concluir"];
    registro = "agendamento";
  } else if (
    t.tipo === "recuperar_desmarcacao" ||
    t.tipo === "recuperar_falta" ||
    t.tipo === "reabrir_sem_resposta" ||
    t.tipo === "definir_proxima_acao"
  ) {
    // Estas situações precisam do resultado da conversa, não de um simples "feito".
    botoes = ["abrir_paciente", "ver_mensagem", "registrar_contato"];
    if (t.tipo !== "definir_proxima_acao") registro = "recuperacao";
  } else if (t.tipo === "reativacao" || t.tipo === "manutencao") {
    botoes = ["abrir_paciente", "ver_mensagem", "registrar_contato"];
    registro = "reativacao";
  } else {
    botoes = ["abrir_paciente", "ver_mensagem", "registrar_contato", "concluir"];
  }
  // A mensagem vem da biblioteca mesmo quando a tarefa não guardou uma.

  return {
    id: t.id,
    pessoaId: t.pessoa_id,
    parcelaId: t.parcela_id,
    grupo: classificar(t, hoje),
    pagamento,
    tituloTarefa: t.titulo,
    horario: t.horario,
    titulo,
    subtitulo,
    procedimento: t.procedimento,
    motivo: motivoDoContato(t, hoje),
    acaoRecomendada: acaoRecomendada(t, hoje),
    quando: rotuloData(t.vence_em, hoje, t.horario),
    diasAtraso,
    vence: t.vence_em,
    mensagem: t.mensagem_sugerida,
    whatsapp: t.whatsapp_e164 ?? t.telefone_e164,
    valorCentavos: valor,
    botoes,
    registro,
    regraNome: t.regra_nome ?? null,
    recusavel: !pagamento && t.tipo !== "recuperar_desmarcacao" && t.tipo !== "recuperar_falta",
  };
}

function ordenar(a: { cartao: Cartao; t: TarefaAberta }, b: { cartao: Cartao; t: TarefaAberta }) {
  return (
    ORDEM_GRUPO[a.cartao.grupo] - ORDEM_GRUPO[b.cartao.grupo] ||
    a.t.vence_em.localeCompare(b.t.vence_em) ||
    ORDEM_PRIORIDADE[a.t.prioridade] - ORDEM_PRIORIDADE[b.t.prioridade] ||
    (a.t.horario ?? "99").localeCompare(b.t.horario ?? "99") ||
    a.t.pessoa_nome.localeCompare(b.t.pessoa_nome, "pt-BR")
  );
}

export function montarPainel(tarefas: TarefaAberta[], hoje: DataCivil): Painel {
  const limite = somarDias(hoje, DIAS_PROXIMOS);
  const itens = tarefas
    .filter((t) => t.vence_em <= limite)
    .map((t) => ({ t, cartao: montarCartao(t, hoje) }))
    .sort(ordenar);

  const atrasadas = itens.filter((i) => i.t.vence_em < hoje).map((i) => i.cartao);
  const deHoje = itens.filter((i) => i.t.vence_em === hoje).map((i) => i.cartao);
  const futuras = itens
    .filter((i) => i.t.vence_em > hoje)
    .sort((a, b) => a.t.vence_em.localeCompare(b.t.vence_em) || ordenar(a, b))
    .map((i) => i.cartao);

  const doDia: Record<Grupo, Cartao[]> = {
    urgente: deHoje.filter((c) => c.grupo === "urgente"),
    importante: deHoje.filter((c) => c.grupo === "importante"),
    rotina: deHoje.filter((c) => c.grupo === "rotina"),
  };

  const proximos: Painel["proximos"] = [];
  for (const c of futuras) {
    const ultimo = proximos.at(-1);
    if (ultimo?.dia === c.vence) ultimo.cartoes.push(c);
    else proximos.push({ dia: c.vence, cartoes: [c] });
  }

  return {
    hoje,
    atrasadas,
    doDia,
    proximos,
    resumo: {
      totalHoje: atrasadas.length + deHoje.length,
      atrasadas: atrasadas.length,
      urgentes: doDia.urgente.length,
      importantes: doDia.importante.length,
      rotina: doDia.rotina.length,
      proximos: futuras.length,
    },
  };
}

/** Frase de abertura do painel, em linguagem natural. */
export function fraseResumo(p: Painel): string {
  const r = p.resumo;
  if (r.totalHoje === 0) {
    return r.proximos > 0
      ? `Tudo em dia por aqui. ${r.proximos === 1 ? "Há 1 ação programada" : `Há ${r.proximos} ações programadas`} para os próximos dias.`
      : "Tudo em dia por aqui. Nenhuma ação pendente.";
  }
  const partes: string[] = [];
  if (r.atrasadas) partes.push(`${r.atrasadas} ${r.atrasadas === 1 ? "atrasada" : "atrasadas"}`);
  if (r.urgentes) partes.push(`${r.urgentes} ${r.urgentes === 1 ? "urgente" : "urgentes"}`);
  if (r.importantes) partes.push(`${r.importantes} ${r.importantes === 1 ? "importante" : "importantes"}`);
  if (r.rotina) partes.push(`${r.rotina} de rotina`);
  const total = r.totalHoje === 1 ? "1 ação" : `${r.totalHoje} ações`;
  return `Hoje você tem ${total}: ${juntar(partes)}.`;
}

function juntar(partes: string[]) {
  if (partes.length <= 1) return partes.join("");
  return `${partes.slice(0, -1).join(", ")} e ${partes.at(-1)}`;
}
