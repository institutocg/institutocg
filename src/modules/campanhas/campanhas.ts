/** Campanhas de reativação: textos e cálculos puros (sem banco). */
import { somarDias, type DataCivil } from "@/lib/datas";

export type Segmento =
  | "inativos"
  | "procedimento"
  | "nao_fecharam"
  | "tratamento_pendente"
  | "avaliacao_nao_agendada"
  | "aniversario"
  | "pos_tratamento"
  | "interesse"
  | "desmarcou"
  | "especiais";

export interface DefSegmento {
  rotulo: string;
  ajuda: string;
  grupo: "vendas" | "relacionamento";
  /** Rótulo do campo de meses; null = não usa (ex.: especiais). */
  rotuloMeses: string | null;
  mesesPadrao: number;
  procedimento: "nao" | "opcional" | "obrigatorio";
  mensagem: string;
}

// Mensagens sem preço, desconto ou promoção (regras de publicidade odontológica).
export const SEGMENTOS: Record<Segmento, DefSegmento> = {
  tratamento_pendente: {
    rotulo: "Tratamento pendente",
    ajuda: "Procedimentos pendentes no plano e nenhuma consulta marcada. Quem já aceitou (e às vezes já pagou).",
    grupo: "relacionamento",
    rotuloMeses: "Plano parado há mais de (meses)",
    mesesPadrao: 1,
    procedimento: "opcional",
    mensagem:
      "Olá, {{nome}}! Tudo bem? Passando para lembrar que ainda temos a continuidade do seu tratamento ({{procedimento}}). Quando fica melhor para você? Posso reservar um horário.",
  },
  avaliacao_nao_agendada: {
    rotulo: "Avaliação que não aconteceu",
    ajuda: "Demonstraram interesse, mas nunca chegaram a marcar a avaliação.",
    grupo: "vendas",
    rotuloMeses: "Interesse há mais de (meses)",
    mesesPadrao: 1,
    procedimento: "opcional",
    mensagem:
      "Olá, {{nome}}! Tudo bem? Há um tempo você conversou com a gente sobre o seu sorriso. Se ainda fizer sentido, podemos marcar uma avaliação para entender o que você deseja — sem compromisso.",
  },
  aniversario: {
    rotulo: "Aniversário",
    ajuda: "Parabéns no dia, sem nenhuma oferta. Só relacionamento.",
    grupo: "relacionamento",
    rotuloMeses: "Aniversários nos próximos (meses)",
    mesesPadrao: 1,
    procedimento: "nao",
    mensagem: "Feliz aniversário, {{nome}}! 🎉 Toda a equipe do {{clinica}} deseja um dia muito especial e um ano cheio de sorrisos.",
  },
  pos_tratamento: {
    rotulo: "Avaliação no Google e indicação",
    ajuda: "Cerca de 1 a 3 meses depois do tratamento, quando o resultado está bonito.",
    grupo: "relacionamento",
    rotuloMeses: "Tratamento feito há mais de (meses)",
    mesesPadrao: 1,
    procedimento: "nao",
    mensagem:
      "Olá, {{nome}}! Como você está se sentindo com o resultado do seu {{procedimento}}? Se puder, sua avaliação no Google ajuda muito outras pessoas a nos conhecerem: [cole aqui o link de avaliação]. E se alguém próximo quiser cuidar do sorriso, será um prazer receber!",
  },
  interesse: {
    rotulo: "Quem se interessou por um procedimento",
    ajuda: "Para campanhas de época: interessados que ainda não fizeram.",
    grupo: "vendas",
    rotuloMeses: "Interesse nos últimos (meses)",
    mesesPadrao: 12,
    procedimento: "obrigatorio",
    mensagem:
      "Olá, {{nome}}! Tudo bem? Lembrei de você, que tinha interesse em {{procedimento}}. Se quiser retomar, posso reservar um horário para conversarmos.",
  },
  desmarcou: {
    rotulo: "Desmarcou e não remarcou",
    ajuda: "Desmarcou ou faltou há meses e a recuperação não deu certo. Uma nova tentativa, com calma.",
    grupo: "vendas",
    rotuloMeses: "Desmarcou há mais de (meses)",
    mesesPadrao: 2,
    procedimento: "nao",
    mensagem:
      "Olá, {{nome}}! Tudo bem? Faz um tempinho que ficamos de remarcar a sua consulta. Quando ficar bom para você, encontramos um horário.",
  },
  especiais: {
    rotulo: "Pacientes especiais",
    ajuda: "Os de maior histórico com a clínica. Um contato de agradecimento, mais pessoal.",
    grupo: "relacionamento",
    rotuloMeses: null,
    mesesPadrao: 12,
    procedimento: "nao",
    mensagem:
      "Olá, {{nome}}! Tudo bem? Você faz parte da história do {{clinica}} e queríamos agradecer pela confiança. Sempre que precisar, estamos aqui — será um prazer receber você.",
  },
  inativos: {
    rotulo: "Pacientes sem atendimento",
    ajuda: "Pacientes antigos que não vêm à clínica há alguns meses.",
    grupo: "vendas",
    rotuloMeses: "Sem atendimento há mais de (meses)",
    mesesPadrao: 6,
    procedimento: "nao",
    mensagem:
      "Olá, {{nome}}! Tudo bem? Sentimos sua falta aqui no {{clinica}}. Que tal agendarmos uma avaliação para cuidarmos do seu sorriso?",
  },
  procedimento: {
    rotulo: "Quem fez um procedimento",
    ajuda: "Ex.: clareamento há mais de 12 meses — hora do retoque.",
    grupo: "vendas",
    rotuloMeses: "Feito há mais de (meses)",
    mesesPadrao: 12,
    procedimento: "obrigatorio",
    mensagem:
      "Olá, {{nome}}! Já faz um tempo desde o seu {{procedimento}}. Que tal agendarmos uma revisão para manter o resultado?",
  },
  nao_fecharam: {
    rotulo: "Quem não fechou",
    ajuda: "Negociações encerradas há alguns meses. Muitos voltam quando o momento muda.",
    grupo: "vendas",
    rotuloMeses: "Encerradas há mais de (meses)",
    mesesPadrao: 3,
    procedimento: "opcional",
    mensagem:
      "Olá, {{nome}}! Tudo bem? Lembrei de você e quis saber se ainda tem interesse em {{procedimento}}. Se quiser, podemos conversar sobre as possibilidades, sem compromisso.",
  },
};

export const GRUPOS_SEGMENTO: { id: DefSegmento["grupo"]; titulo: string; ajuda: string }[] = [
  { id: "vendas", titulo: "Trazer de volta", ajuda: "Abrem a negociação em “Reativação” no funil." },
  { id: "relacionamento", titulo: "Relacionamento e cuidado", ajuda: "Só criam o contato do dia com a mensagem; não mexem no funil." },
];

/** Campanhas de época: atalhos que preenchem nome e mensagem (escolha o procedimento). */
export const EPOCAS: { id: string; nome: string; quando: string; mensagem: string }[] = [
  {
    id: "festas",
    nome: "Sorriso para as festas",
    quando: "outubro e novembro",
    mensagem:
      "Olá, {{nome}}! As festas de fim de ano estão chegando. Se ainda tiver vontade de fazer o {{procedimento}}, dá tempo de planejar com calma. Quer que eu veja um horário?",
  },
  {
    id: "eventos",
    nome: "Noivas e formaturas",
    quando: "o ano todo",
    mensagem:
      "Olá, {{nome}}! Tem algum evento especial chegando — casamento, formatura? Se quiser chegar com o sorriso do jeito que sonha, podemos planejar o {{procedimento}} com antecedência.",
  },
  {
    id: "ano-novo",
    nome: "Começo de ano",
    quando: "janeiro e fevereiro",
    mensagem:
      "Olá, {{nome}}! Ano novo, novos planos 😊 Se cuidar do sorriso estiver na sua lista, podemos retomar a conversa sobre {{procedimento}}.",
  },
];

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
