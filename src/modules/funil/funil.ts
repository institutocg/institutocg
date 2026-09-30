/**
 * Monta o quadro (kanban) do funil a partir das etapas e das negociações.
 * Funções puras: sem banco, sem tela.
 */
import { diasEntre, type DataCivil } from "@/lib/datas";

export interface EtapaFunil {
  id: string;
  nome: string;
  ordem: number;
  tipo: "aberta" | "ganho" | "perda";
  resultado: "fechou" | "nao_fechou" | "desistiu" | "sem_resposta" | null;
  marco: string | null;
  cor: string;
  sla_dias: number | null;
}

export interface NegociacaoFunil {
  id: string;
  pessoa_id: string;
  nome: string;
  procedimento: string | null;
  etapa_id: string;
  status: "aberta" | "pausada" | "ganha" | "perdida";
  resultado: string | null;
  dias_na_etapa: number;
  primeiro_contato_em: DataCivil;
  ultimo_contato_em: string | null; // ISO
  proxima_acao: string | null;
  proxima_acao_em: DataCivil | null;
  valor_potencial_centavos: number | null;
  motivo: string | null;
}

export interface CartaoFunil extends NegociacaoFunil {
  encerrada: boolean;
  desistiu: boolean;
  parada: boolean; // passou do prazo da etapa
  acaoAtrasada: boolean;
  semProximaAcao: boolean;
}

export interface ColunaFunil {
  etapa: EtapaFunil;
  /** Etapas que caem nesta coluna (ex.: "Não fechou" também recebe "Desistiu"). */
  etapasIds: string[];
  encerrada: boolean;
  cartoes: CartaoFunil[];
  totalCentavos: number;
  descricao: string;
}

const DESCRICOES: Record<string, string> = {
  novo_contato: "Entrou em contato e ainda não conversou com a clínica.",
  em_contato: "Conversando; demonstrou interesse.",
  avaliacao_agendada: "Consulta de avaliação marcada.",
  avaliacao_realizada: "Veio à avaliação.",
  orcamento_apresentado: "Recebeu o orçamento.",
  em_negociacao: "Está pensando; acompanhamento sem pressão.",
  desmarcou: "Desmarcou ou faltou; recuperar com acolhimento.",
  reativacao: "Hora de retomar o contato.",
  sem_resposta: "Parou de responder; tentativas leves e espaçadas.",
  fechou: "Fechou o tratamento.",
  nao_fechou: "Não fechou ou desistiu; pode ser retomado no futuro.",
};

function chave(e: EtapaFunil) {
  return e.marco ?? e.resultado ?? "";
}

export function montarQuadro(etapas: EtapaFunil[], negociacoes: NegociacaoFunil[], hoje: DataCivil): ColunaFunil[] {
  const naoFechou = etapas.find((e) => e.resultado === "nao_fechou");
  const desistiu = etapas.find((e) => e.resultado === "desistiu");
  const visiveis = etapas.filter((e) => !(e.resultado === "desistiu" && naoFechou));

  return visiveis
    .sort((a, b) => a.ordem - b.ordem)
    .map((etapa) => {
      const ids = [etapa.id];
      if (etapa.resultado === "nao_fechou" && desistiu) ids.push(desistiu.id);
      const encerrada = etapa.tipo === "ganho" || (etapa.tipo === "perda" && etapa.resultado !== "sem_resposta");
      const cartoes = negociacoes
        .filter((n) => ids.includes(n.etapa_id))
        .map<CartaoFunil>((n) => ({
          ...n,
          encerrada,
          desistiu: desistiu?.id === n.etapa_id,
          parada: !encerrada && etapa.sla_dias !== null && n.dias_na_etapa > etapa.sla_dias,
          acaoAtrasada: n.proxima_acao_em !== null && n.proxima_acao_em < hoje,
          semProximaAcao: n.status === "aberta" && !n.proxima_acao,
        }))
        .sort((a, b) => ordemCartao(a, b));
      return {
        etapa,
        etapasIds: ids,
        encerrada,
        cartoes,
        totalCentavos: cartoes.reduce((s, c) => s + (c.valor_potencial_centavos ?? 0), 0),
        descricao: DESCRICOES[chave(etapa)] ?? "",
      };
    });
}

/** Quem precisa de atenção vem primeiro: ação atrasada, sem próxima ação, parado há mais tempo. */
function ordemCartao(a: CartaoFunil, b: CartaoFunil) {
  const peso = (c: CartaoFunil) => (c.acaoAtrasada ? 0 : c.semProximaAcao ? 1 : 2);
  return peso(a) - peso(b) || b.dias_na_etapa - a.dias_na_etapa || a.nome.localeCompare(b.nome, "pt-BR");
}

/** "hoje", "ontem", "há 5 dias", "nenhuma ainda" */
export function rotuloUltimaInteracao(iso: string | null, hoje: DataCivil): string {
  if (!iso) return "nenhuma ainda";
  const data = new Date(iso).toLocaleDateString("sv-SE", { timeZone: "America/Sao_Paulo" });
  const d = diasEntre(data, hoje);
  if (d <= 0) return "hoje";
  if (d === 1) return "ontem";
  return `há ${d} dias`;
}

/** "3 dias" / "1 dia" / "hoje" — tempo na etapa. */
export function rotuloTempoNaEtapa(dias: number): string {
  if (dias <= 0) return "entrou hoje";
  return `há ${dias} ${dias === 1 ? "dia" : "dias"} na etapa`;
}

export function resumoQuadro(colunas: ColunaFunil[]) {
  const abertas = colunas.filter((c) => !c.encerrada);
  return {
    emAndamento: abertas.reduce((s, c) => s + c.cartoes.length, 0),
    potencialCentavos: abertas.reduce((s, c) => s + c.totalCentavos, 0),
    precisamAtencao: abertas.reduce((s, c) => s + c.cartoes.filter((x) => x.acaoAtrasada || x.semProximaAcao).length, 0),
  };
}
