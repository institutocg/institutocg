/**
 * Regras de follow-up (tabela regras_followup): textos e validação.
 * Funções puras — a mesma explicação que o banco mostra no funil.
 */
import { z } from "zod";

export type Situacao =
  | "novo_contato"
  | "em_contato"
  | "confirmacao"
  | "compareceu"
  | "orcamento_apresentado"
  | "pensando"
  | "desmarcou"
  | "faltou"
  | "sem_resposta"
  | "nao_fechou"
  | "fechou"
  | "reativacao"
  | "paciente_inativo"
  | "manutencao"
  | "pos_tratamento";

export type AoEsgotar = "decidir" | "sem_resposta" | "reativacao" | "encerrar";
export type Prioridade = "baixa" | "normal" | "alta" | "urgente";

export interface Regra {
  id: string;
  situacao: Situacao;
  nome: string;
  quando: string;
  ativa: boolean;
  titulo_modelo: string;
  prazo_dias: number | null;
  intervalos: number[];
  prioridade: Prioridade;
  ao_esgotar: AoEsgotar;
  espera_reativacao_dias: number | null;
  periodo_meses: number | null;
  mensagem_situacao: string | null;
  /** Texto do modelo de mensagem ligado à regra. */
  mensagem: string | null;
}

export const GRUPOS: { titulo: string; descricao: string; situacoes: Situacao[] }[] = [
  {
    titulo: "Vendas",
    descricao: "Do primeiro contato ao fechamento.",
    situacoes: ["novo_contato", "em_contato", "confirmacao", "compareceu", "orcamento_apresentado", "pensando", "fechou"],
  },
  {
    titulo: "Recuperação",
    descricao: "Quando algo não saiu como o combinado.",
    situacoes: ["desmarcou", "faltou", "sem_resposta", "nao_fechou"],
  },
  {
    titulo: "Reativação",
    descricao: "Pacientes que já passaram pela clínica.",
    situacoes: ["reativacao", "paciente_inativo", "manutencao", "pos_tratamento"],
  },
];

/** Situações em que "não respondeu" gera novas tentativas (e, no fim, o que fazer). */
const COM_TENTATIVAS: Situacao[] = [
  "novo_contato", "em_contato", "orcamento_apresentado", "pensando", "desmarcou", "faltou", "sem_resposta",
  "reativacao", "paciente_inativo", "manutencao", "pos_tratamento",
];

export function campos(situacao: Situacao) {
  return {
    prazo: situacao !== "manutencao" && situacao !== "paciente_inativo" && situacao !== "pos_tratamento",
    prazoOpcional: situacao === "nao_fechou",
    prazoEmDiasUteisAntes: situacao === "confirmacao",
    tentativas: COM_TENTATIVAS.includes(situacao),
    periodo: situacao === "paciente_inativo" || situacao === "pos_tratamento",
    // Uma regra não pode mandar a pessoa para a própria etapa.
    opcoesAoEsgotar: (["decidir", "sem_resposta", "reativacao", "encerrar"] as AoEsgotar[]).filter(
      (o) => !(o === "sem_resposta" && situacao === "sem_resposta") && !(o === "reativacao" && situacao === "reativacao"),
    ),
  };
}

export const ROTULO_AO_ESGOTAR: Record<AoEsgotar, string> = {
  decidir: "Pedir para você decidir o próximo passo",
  sem_resposta: "Mover para “Sem resposta”",
  reativacao: "Mover para “Reativação” e tentar de novo mais tarde",
  encerrar: "Encerrar como “Não fechou — parou de responder”",
};

export const ROTULO_PRIORIDADE: Record<Prioridade, string> = {
  urgente: "Urgente",
  alta: "Alta",
  normal: "Normal",
  baixa: "Baixa",
};

function dias(n: number) {
  return n === 1 ? "1 dia" : `${n} dias`;
}

/** "Ação no dia seguinte; sem resposta, mais 2 tentativas (após 3 e 4 dias). Depois disso, …" */
export function descreverRegra(r: Pick<Regra, "situacao" | "ativa" | "prazo_dias" | "intervalos" | "ao_esgotar" | "espera_reativacao_dias" | "periodo_meses">): string {
  if (!r.ativa) return "Desligada: nenhuma tarefa automática nesta situação.";
  const c = campos(r.situacao);
  const partes: string[] = [];

  if (r.situacao === "paciente_inativo") partes.push(`Contato com quem está há ${r.periodo_meses ?? 6} meses sem atendimento`);
  else if (r.situacao === "pos_tratamento") partes.push(`Convite para revisão ${r.periodo_meses ?? 6} meses após concluir o tratamento`);
  else if (r.situacao === "manutencao") partes.push("Convite quando chega a hora da manutenção de cada procedimento");
  else if (c.prazoEmDiasUteisAntes) partes.push(`Confirmação ${r.prazo_dias ?? 1} dia(s) útil(eis) antes da consulta`);
  else if (r.prazo_dias === null) partes.push("Ação na data sugerida pelo motivo");
  else if (r.prazo_dias === 0) partes.push("Ação no mesmo dia");
  else if (r.prazo_dias === 1) partes.push("Ação no dia seguinte");
  else partes.push(`Ação em ${dias(r.prazo_dias)}`);

  if (r.situacao === "nao_fechou" && r.prazo_dias !== null) partes[0] += ` (ou em ${dias(r.prazo_dias)}, se o motivo não tiver prazo)`;

  if (c.tentativas) {
    const n = r.intervalos.length;
    if (n > 0) {
      const lista = r.intervalos.length === 1 ? `${r.intervalos[0]}` : `${r.intervalos.slice(0, -1).join(", ")} e ${r.intervalos.at(-1)}`;
      partes.push(`sem resposta, mais ${n} ${n === 1 ? "tentativa" : "tentativas"} (após ${lista} dias)`);
    }
    const fim: Record<AoEsgotar, string> = {
      decidir: "Depois disso, você decide o próximo passo.",
      sem_resposta: "Depois disso, vai para “Sem resposta”.",
      reativacao: `Depois disso, vai para “Reativação”, com novo contato em ${dias(r.espera_reativacao_dias ?? 60)}.`,
      encerrar: "Depois disso, a negociação é encerrada como “Não fechou”.",
    };
    return `${partes.join("; ")}. ${fim[r.ao_esgotar]}`;
  }
  return `${partes.join("; ")}.`;
}

/** "3, 7" → [3, 7] */
export function lerIntervalos(texto: string): number[] | null {
  const limpo = texto.trim();
  if (!limpo) return [];
  const numeros = limpo.split(/[\s,;]+/).map(Number);
  return numeros.every((n) => Number.isInteger(n) && n > 0 && n <= 365) ? numeros : null;
}

const inteiro = (min: number, max: number, msg: string) =>
  z.coerce.number({ error: msg }).int(msg).min(min, msg).max(max, msg);

export const esquemaRegra = z
  .object({
    id: z.uuid(),
    situacao: z.string(),
    ativa: z.boolean(),
    titulo_modelo: z.string().trim().min(3, "Escreva o título da tarefa.").max(200),
    prazo_dias: z.union([z.literal(""), inteiro(0, 730, "Prazo entre 0 e 730 dias.")]),
    intervalos: z.string().max(60),
    prioridade: z.enum(["baixa", "normal", "alta", "urgente"]),
    ao_esgotar: z.enum(["decidir", "sem_resposta", "reativacao", "encerrar"]),
    espera_reativacao_dias: z.union([z.literal(""), inteiro(1, 365, "Espera entre 1 e 365 dias.")]),
    periodo_meses: z.union([z.literal(""), inteiro(1, 60, "Período entre 1 e 60 meses.")]),
    mensagem: z.string().trim().max(2000),
  })
  .superRefine((v, ctx) => {
    const lidos = lerIntervalos(v.intervalos);
    if (lidos === null) ctx.addIssue({ code: "custom", path: ["intervalos"], message: "Use números de dias separados por vírgula (ex.: 3, 7)." });
    else if (lidos.length > 5) ctx.addIssue({ code: "custom", path: ["intervalos"], message: "No máximo 5 tentativas extras — evite insistir." });
    if (v.situacao !== "nao_fechou" && v.situacao !== "manutencao" && v.situacao !== "paciente_inativo"
        && v.situacao !== "pos_tratamento" && v.prazo_dias === "") {
      ctx.addIssue({ code: "custom", path: ["prazo_dias"], message: "Informe o prazo." });
    }
    if ((v.situacao === "paciente_inativo" || v.situacao === "pos_tratamento") && v.periodo_meses === "") {
      ctx.addIssue({ code: "custom", path: ["periodo_meses"], message: "Informe o período em meses." });
    }
    if (v.ao_esgotar === "reativacao" && v.espera_reativacao_dias === "") {
      ctx.addIssue({ code: "custom", path: ["espera_reativacao_dias"], message: "Informe em quantos dias tentar de novo." });
    }
  });

export type DadosRegra = z.input<typeof esquemaRegra>;

/** Mostra como o texto fica para uma pessoa de exemplo. */
export function exemplo(texto: string, procedimento = "clareamento dental"): string {
  return texto
    .replaceAll("{primeiro_nome}", "Maria")
    .replaceAll("{procedimento}", procedimento)
    .replaceAll("{consulta}", "a avaliação")
    .replaceAll("{data}", "15/10")
    .replaceAll("{horario}", "14:30")
    .replaceAll("{valor}", "R$ 1.000,00");
}
