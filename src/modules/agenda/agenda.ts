/**
 * Agenda comercial: rótulos, semana de atendimento e ações permitidas por status.
 * Funções puras (sem banco, sem tela).
 */
import { diasEntre, somarDias, type DataCivil } from "@/lib/datas";

export type StatusConsulta =
  | "agendado"
  | "confirmado"
  | "compareceu"
  | "desmarcado"
  | "faltou"
  | "remarcado"
  | "cancelado_clinica";

export type TipoConsulta = "avaliacao" | "apresentacao_orcamento" | "procedimento" | "retorno" | "manutencao";

export type SituacaoRecuperacao = "a_recuperar" | "acompanhando" | "recuperado" | "encerrado" | "sem_acao";

export interface Consulta {
  id: string;
  pessoa_id: string;
  pessoa_nome: string;
  whatsapp: string | null;
  tipo: TipoConsulta;
  status: StatusConsulta;
  dia: DataCivil;
  horario: string;
  duracao_min: number;
  procedimento_id: string | null;
  procedimento: string | null;
  profissional_id: string | null;
  profissional: string | null;
  profissional_cor: string | null;
  motivo: string | null;
  observacoes: string | null;
  remarcado_para: Date | null;
  recuperacao: SituacaoRecuperacao | null;
  /** Valor do procedimento informado ao agendar (centavos). */
  valor_centavos: number | null;
  /** Situação do pagamento registrado ao marcar "Compareceu". */
  cobranca: SituacaoCobranca | null;
  /** Negociação já registrada no financeiro (pelo funil ou pelo Financeiro), ex.: "Facetas — R$ 5.000,00 (em aberto R$ 3.000,00)". */
  negociacao_registrada: string | null;
}

export type SituacaoCobranca = "pendente" | "parcial" | "pago" | "atrasado";
export const COBRANCA: Record<SituacaoCobranca, { rotulo: string; classe: string }> = {
  pago: { rotulo: "Pago", classe: "text-rotina" },
  pendente: { rotulo: "A receber", classe: "text-dourado-escuro" },
  parcial: { rotulo: "Parcialmente pago", classe: "text-dourado-escuro" },
  atrasado: { rotulo: "Pagamento atrasado", classe: "text-urgente" },
};

/** Como ficou o pagamento ao marcar "Compareceu". */
export type ComoPagou = "pago" | "a_pagar" | "sem_cobranca" | "ja_registrado";

export interface Recuperacao {
  agendamento_id: string;
  pessoa_id: string;
  pessoa_nome: string;
  whatsapp: string | null;
  tipo: TipoConsulta;
  status: "desmarcado" | "faltou" | "cancelado_clinica";
  inicio: Date;
  duracao_min: number;
  profissional_id: string | null;
  procedimento: string | null;
  motivo: string | null;
  observacoes: string | null;
  tarefa_id: string | null;
  tarefa_titulo: string | null;
  tarefa_vence_em: DataCivil | null;
  mensagem_sugerida: string | null;
  proxima_acao: string | null;
  proxima_acao_em: DataCivil | null;
  desfecho: string | null;
  situacao: SituacaoRecuperacao;
  remarcado_para: Date | null;
}

export const STATUS: Record<StatusConsulta, { rotulo: string; classe: string }> = {
  agendado: { rotulo: "Agendado", classe: "bg-fundo text-suave ring-1 ring-borda-forte" },
  confirmado: { rotulo: "Confirmado", classe: "bg-rotina-claro text-rotina" },
  compareceu: { rotulo: "Compareceu", classe: "bg-dourado-claro text-dourado-escuro" },
  desmarcado: { rotulo: "Desmarcou", classe: "bg-urgente-claro text-urgente" },
  faltou: { rotulo: "Faltou", classe: "bg-urgente-claro text-urgente" },
  remarcado: { rotulo: "Remarcou", classe: "bg-fundo text-sutil ring-1 ring-borda" },
  cancelado_clinica: { rotulo: "Cancelado", classe: "bg-fundo text-sutil ring-1 ring-borda" },
};

export const TIPOS: Record<TipoConsulta, string> = {
  avaliacao: "Avaliação",
  apresentacao_orcamento: "Retorno para decisão",
  procedimento: "Procedimento",
  retorno: "Retorno",
  manutencao: "Manutenção",
};

/** Artigo de cada tipo ("a avaliação", "o procedimento"). */
const ARTIGO: Record<TipoConsulta, "a" | "o"> = {
  avaliacao: "a",
  apresentacao_orcamento: "o",
  procedimento: "o",
  retorno: "o",
  manutencao: "a",
};

export const SITUACAO_RECUPERACAO: Record<SituacaoRecuperacao, string> = {
  a_recuperar: "A recuperar",
  acompanhando: "Em acompanhamento",
  recuperado: "Recuperado",
  encerrado: "Encerrado",
  sem_acao: "Sem ação",
};

export const DURACOES = [30, 45, 60, 90, 120] as const;

/** Segunda-feira da semana de `data`. */
export function inicioDaSemana(data: DataCivil): DataCivil {
  const [a, m, d] = data.split("-").map(Number);
  const semana = new Date(Date.UTC(a, m - 1, d)).getUTCDay(); // 0 = domingo
  return somarDias(data, semana === 0 ? -6 : 1 - semana);
}

/** Segunda a sexta (a clínica não atende sábado e domingo). */
export function diasDaSemana(segunda: DataCivil): DataCivil[] {
  return [0, 1, 2, 3, 4].map((i) => somarDias(segunda, i));
}

const SEMANA = new Intl.DateTimeFormat("pt-BR", { weekday: "long", timeZone: "UTC" });

/** "segunda, 05/10" */
export function rotuloDia(dia: DataCivil): string {
  const [a, m, d] = dia.split("-").map(Number);
  const nome = SEMANA.format(new Date(Date.UTC(a, m - 1, d))).replace("-feira", "");
  return `${nome}, ${dia.slice(8, 10)}/${dia.slice(5, 7)}`;
}

/** "10:00–11:00" */
export function intervalo(horario: string, duracao: number): string {
  const [h, m] = horario.split(":").map(Number);
  const fim = h * 60 + m + duracao;
  return `${horario}–${String(Math.floor(fim / 60)).padStart(2, "0")}:${String(fim % 60).padStart(2, "0")}`;
}

export type AcaoConsulta = "confirmar" | "compareceu" | "faltou" | "desmarcar" | "remarcar" | "cancelar";

/** O que a usuária pode fazer com a consulta, conforme o status e o dia. */
export function acoesPermitidas(c: Pick<Consulta, "status" | "dia" | "remarcado_para">, hoje: DataCivil): AcaoConsulta[] {
  const chegou = c.dia <= hoje;
  switch (c.status) {
    case "agendado":
      return [...(chegou ? (["compareceu", "faltou"] as const) : []), "confirmar", "desmarcar", "remarcar", "cancelar"];
    case "confirmado":
      return [...(chegou ? (["compareceu", "faltou"] as const) : []), "desmarcar", "remarcar", "cancelar"];
    case "desmarcado":
    case "faltou":
    case "cancelado_clinica":
      // Correção de registro: marcou falta, mas a pessoa veio.
      return [...(c.status === "faltou" ? (["compareceu"] as const) : []), ...(c.remarcado_para ? [] : (["remarcar"] as const))];
    case "compareceu":
      return [];
    case "remarcado":
      return [];
  }
}

/** Texto do prazo da recuperação: "Hoje", "Atrasada há 2 dias", "Amanhã", "qui. 08/10". */
export function prazoRecuperacao(vence: DataCivil | null, hoje: DataCivil): { texto: string; atrasada: boolean } {
  if (!vence) return { texto: "Sem tarefa", atrasada: true };
  const d = diasEntre(hoje, vence);
  if (d < 0) return { texto: `Atrasada há ${-d} ${d === -1 ? "dia" : "dias"}`, atrasada: true };
  if (d === 0) return { texto: "Hoje", atrasada: false };
  if (d === 1) return { texto: "Amanhã", atrasada: false };
  return { texto: `${vence.slice(8, 10)}/${vence.slice(5, 7)}`, atrasada: false };
}

/** "Desmarcou a avaliação de 05/10 às 10:00" */
export function descreverPerda(r: Pick<Recuperacao, "status" | "tipo" | "inicio">): string {
  const artigo = ARTIGO[r.tipo];
  const verbo =
    r.status === "faltou"
      ? artigo === "a" ? "Faltou à" : "Faltou ao"
      : r.status === "cancelado_clinica" ? `Clínica cancelou ${artigo}` : `Desmarcou ${artigo}`;
  const quando = new Intl.DateTimeFormat("pt-BR", {
    timeZone: "America/Sao_Paulo",
    day: "2-digit",
    month: "2-digit",
    hour: "2-digit",
    minute: "2-digit",
  })
    .format(r.inicio)
    .replace(", ", " às ");
  return `${verbo} ${TIPOS[r.tipo].toLowerCase()} de ${quando}`;
}
