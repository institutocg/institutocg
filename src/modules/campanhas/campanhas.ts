/** Campanhas de reativação: textos e cálculos puros (sem banco). */
import { somarDias, type DataCivil } from "@/lib/datas";

export type Segmento = "inativos" | "procedimento" | "nao_fecharam";

export const SEGMENTOS: Record<Segmento, { rotulo: string; ajuda: string; mesesPadrao: number; mensagem: string }> = {
  inativos: {
    rotulo: "Pacientes sem atendimento",
    ajuda: "Pacientes antigos que não vêm à clínica há alguns meses.",
    mesesPadrao: 6,
    mensagem:
      "Olá, {{nome}}! Tudo bem? Sentimos sua falta aqui no {{clinica}}. Que tal agendarmos uma avaliação para cuidarmos do seu sorriso?",
  },
  procedimento: {
    rotulo: "Quem fez um procedimento",
    ajuda: "Ex.: clareamento há mais de 12 meses — hora do retoque.",
    mesesPadrao: 12,
    mensagem:
      "Olá, {{nome}}! Já faz um tempo desde o seu {{procedimento}}. Que tal agendarmos uma revisão para manter o resultado?",
  },
  nao_fecharam: {
    rotulo: "Quem não fechou",
    ajuda: "Negociações encerradas há alguns meses. Muitos voltam quando o momento muda.",
    mesesPadrao: 3,
    mensagem:
      "Olá, {{nome}}! Tudo bem? Lembrei de você e quis saber se ainda tem interesse em {{procedimento}}. Se quiser, podemos conversar sobre as possibilidades, sem compromisso.",
  },
};

export interface Destinatario {
  pessoa_id: string;
  nome: string;
  detalhe: string;
  referencia: string | null;
}

export interface CampanhaResumo {
  id: string;
  nome: string;
  segmento: Segmento;
  meses: number;
  procedimento: string | null;
  limite_dia: number;
  inicia_em: string;
  encerrada_em: Date | null;
  criado_em: Date;
  pessoas: number;
  contatadas: number;
  a_contatar: number;
  para_hoje: number;
  responderam: number;
  agendaram: number;
  fecharam: number;
  primeiro_contato: string | null;
  ultimo_contato: string | null;
}

/** Quantos dias úteis a campanha leva (aproximado: ignora feriados). */
export function diasDeCampanha(pessoas: number, limiteDia: number): number {
  if (pessoas <= 0 || limiteDia <= 0) return 0;
  return Math.ceil(pessoas / limiteDia);
}

/** Data aproximada do último contato, pulando fins de semana. */
export function terminoPrevisto(inicio: DataCivil, pessoas: number, limiteDia: number): DataCivil | null {
  const dias = diasDeCampanha(pessoas, limiteDia);
  if (!dias) return null;
  let d = inicio;
  const util = (x: DataCivil) => {
    const s = new Date(`${x}T12:00:00Z`).getUTCDay();
    return s !== 0 && s !== 6;
  };
  while (!util(d)) d = somarDias(d, 1);
  for (let i = 1; i < dias; i++) {
    d = somarDias(d, 1);
    while (!util(d)) d = somarDias(d, 1);
  }
  return d;
}

/** "40%" — proporção de quem respondeu entre as contatadas. */
export function taxa(parte: number, total: number): string {
  if (!total) return "—";
  return `${Math.round((parte / total) * 100)}%`;
}
