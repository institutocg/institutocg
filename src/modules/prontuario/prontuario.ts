import { z } from "zod";
import type { DataCivil } from "@/lib/datas";

// ─── Ficha da consulta: opções de seleção (preenchimento rápido) ─────────────

export const MOTIVOS = [
  "Avaliação",
  "Dor",
  "Estética",
  "Continuidade do tratamento",
  "Retorno",
  "Manutenção / limpeza",
  "Urgência",
  "Sensibilidade",
  "Sangramento gengival",
] as const;

export const ANAMNESE = [
  "Hipertensão",
  "Diabetes",
  "Cardiopatia",
  "Alergia a medicamentos",
  "Alergia a látex",
  "Uso de anticoagulante",
  "Gestante",
  "Fumante",
  "Bruxismo",
  "Problemas de cicatrização",
  "Sensibilidade dentária",
  "Ansiedade em tratamento",
] as const;

export const DIAGNOSTICOS = [
  "Cárie",
  "Gengivite",
  "Periodontite",
  "Desgaste dental",
  "Fratura",
  "Manchas / escurecimento",
  "Má oclusão",
  "Perda dentária",
  "Restauração insatisfatória",
  "Lesão periapical",
] as const;

export const ORIENTACOES = [
  "Higiene oral reforçada",
  "Uso de fio dental",
  "Evitar alimentos com corante",
  "Evitar alimentos duros",
  "Compressa fria",
  "Medicação conforme prescrição",
  "Usar a placa à noite",
  "Retornar se houver dor",
] as const;

/** Atalhos de retorno (dias). */
export const RETORNOS = [
  { rotulo: "7 dias", dias: 7 },
  { rotulo: "15 dias", dias: 15 },
  { rotulo: "30 dias", dias: 30 },
  { rotulo: "3 meses", dias: 90 },
  { rotulo: "6 meses", dias: 180 },
] as const;

// ─── Odontograma ─────────────────────────────────────────────────────────────

/** Arcadas na ordem em que aparecem na tela (notação FDI), como o paciente é visto de frente. */
export const ARCADAS = {
  superior: [18, 17, 16, 15, 14, 13, 12, 11, 21, 22, 23, 24, 25, 26, 27, 28],
  inferior: [48, 47, 46, 45, 44, 43, 42, 41, 31, 32, 33, 34, 35, 36, 37, 38],
} as const;
export const DENTES: readonly number[] = [...ARCADAS.superior, ...ARCADAS.inferior];

/** Faces: Vestibular, Lingual/Palatina, Mesial, Distal, Oclusal/Incisal. */
export const FACES = ["V", "L", "M", "D", "O"] as const;
export type Face = (typeof FACES)[number];
export const ROTULO_FACE: Record<Face, string> = {
  V: "Vestibular",
  L: "Lingual / palatina",
  M: "Mesial",
  D: "Distal",
  O: "Oclusal / incisal",
};

export const CONDICOES = {
  carie: { rotulo: "Cárie", faces: true },
  restauracao: { rotulo: "Restauração", faces: true },
  canal: { rotulo: "Canal (endodontia)", faces: false },
  coroa: { rotulo: "Coroa / prótese", faces: false },
  faceta: { rotulo: "Faceta / lente", faces: false },
  implante: { rotulo: "Implante", faces: false },
  ausente: { rotulo: "Ausente", faces: false },
  extracao: { rotulo: "Extração indicada", faces: false },
  fratura: { rotulo: "Fratura", faces: true },
  selante: { rotulo: "Selante", faces: true },
  mancha: { rotulo: "Mancha / escurecimento", faces: false },
} as const;
export type Condicao = keyof typeof CONDICOES;

/** a_tratar = precisa de tratamento (vermelho); existente = já tratado/realizado (verde). */
export const SITUACAO_DENTE = {
  a_tratar: { rotulo: "A tratar", cor: "#b4533a" },
  existente: { rotulo: "Existente / realizado", cor: "#5f8a6a" },
} as const;
export type SituacaoDente = keyof typeof SITUACAO_DENTE;

export const esquemaDente = z.object({
  c: z.enum(Object.keys(CONDICOES) as [Condicao, ...Condicao[]]),
  f: z.array(z.enum(FACES)).max(5).default([]),
  s: z.enum(["a_tratar", "existente"]).default("a_tratar"),
  o: z.string().trim().max(200).optional(),
});
export type Dente = z.infer<typeof esquemaDente>;
export type Odontograma = Record<string, Dente>;

/** Só dentes válidos e registros bem formados (o que vier diferente é descartado). */
export function normalizarOdontograma(bruto: unknown): Odontograma {
  const saida: Odontograma = {};
  if (!bruto || typeof bruto !== "object") return saida;
  for (const [chave, valor] of Object.entries(bruto as Record<string, unknown>)) {
    if (!DENTES.includes(Number(chave))) continue;
    const lido = esquemaDente.safeParse(valor);
    if (!lido.success) continue;
    const d = lido.data;
    saida[chave] = {
      c: d.c,
      f: CONDICOES[d.c].faces ? [...new Set(d.f)] : [],
      s: d.s,
      ...(d.o ? { o: d.o } : {}),
    };
  }
  return saida;
}

/** "16 — Cárie (O) · a tratar". */
export function descreverDente(numero: string, d: Dente): string {
  const faces = d.f.length ? ` (${d.f.join("")})` : "";
  return `${numero} — ${CONDICOES[d.c].rotulo}${faces} · ${SITUACAO_DENTE[d.s].rotulo.toLowerCase()}`;
}

/** O que mudou de uma consulta para a outra (para acompanhar a evolução). */
export function diferencasOdontograma(antes: Odontograma, depois: Odontograma): string[] {
  const dentes = [...new Set([...Object.keys(antes), ...Object.keys(depois)])].sort((a, b) => DENTES.indexOf(Number(a)) - DENTES.indexOf(Number(b)));
  const linhas: string[] = [];
  for (const n of dentes) {
    const a = antes[n];
    const d = depois[n];
    if (a && !d) linhas.push(`${n}: registro removido`);
    else if (!a && d) linhas.push(`${descreverDente(n, d)} (novo)`);
    else if (a && d && JSON.stringify(a) !== JSON.stringify(d)) linhas.push(`${n}: ${CONDICOES[a.c].rotulo} → ${descreverDente(n, d).slice(n.length + 3)}`);
  }
  return linhas;
}

// ─── Plano de tratamento ─────────────────────────────────────────────────────

export type StatusItem = "orcado" | "aceito" | "pendente" | "realizado" | "nao_realizado" | "cancelado";
export const STATUS_ITEM: Record<StatusItem, { rotulo: string; classe: string }> = {
  orcado: { rotulo: "Orçado", classe: "bg-fundo text-suave ring-1 ring-borda" },
  aceito: { rotulo: "Aceito", classe: "bg-dourado-claro text-dourado-escuro" },
  pendente: { rotulo: "Pendente", classe: "bg-importante-claro text-importante" },
  realizado: { rotulo: "Realizado", classe: "bg-rotina-claro text-rotina" },
  nao_realizado: { rotulo: "Não realizado", classe: "bg-fundo text-sutil ring-1 ring-borda" },
  cancelado: { rotulo: "Cancelado", classe: "bg-fundo text-sutil line-through ring-1 ring-borda" },
};
/** Status que a dentista escolhe à mão ("Realizado" é registrado dentro da consulta). */
export const STATUS_MANUAIS: StatusItem[] = ["orcado", "aceito", "pendente", "nao_realizado", "cancelado"];
export const ainda_a_fazer = (s: StatusItem) => s === "orcado" || s === "aceito" || s === "pendente";

export interface ItemPlano {
  id: string;
  procedimento_id: string;
  procedimento: string;
  dente: string | null;
  status: StatusItem;
  valor_centavos: number;
  atendimento_numero: number | null;
  realizado_atendimento_id: string | null;
  realizado_atendimento_numero: number | null;
  realizado_em: DataCivil | null;
  venda_id: string | null;
  financeiro: "pendente" | "parcial" | "pago" | "atrasado" | null;
  saldo_centavos: number | null;
  proximo_vencimento: DataCivil | null;
}

export function totaisPlano(itens: Pick<ItemPlano, "status" | "valor_centavos">[]) {
  const soma = (f: (s: StatusItem) => boolean) => itens.filter((i) => f(i.status)).reduce((t, i) => t + Number(i.valor_centavos), 0);
  return {
    realizado: soma((s) => s === "realizado"),
    aFazer: soma(ainda_a_fazer),
    total: soma((s) => s !== "cancelado" && s !== "nao_realizado"),
  };
}

// ─── Consultas ───────────────────────────────────────────────────────────────

export interface ResumoConsulta {
  id: string;
  numero: number;
  data: DataCivil;
  horario: string | null;
  tipo: string | null;
  procedimento: string | null;
  profissional: string | null;
  profissional_cor: string | null;
  status: "em_andamento" | "finalizado";
  motivo: string[];
  anamnese: string[];
  diagnostico: string[];
  retorno_em: DataCivil | null;
  realizados: number;
  procedimentos_realizados: string | null;
}

/** "Consulta 03 — Facetas — 30/10/2026". */
export function tituloConsulta(c: Pick<ResumoConsulta, "numero" | "data" | "procedimento" | "motivo" | "tipo">): string {
  const assunto = c.procedimento ?? c.motivo[0] ?? (c.tipo ? ROTULO_TIPO[c.tipo] : null);
  return [`Consulta ${String(c.numero).padStart(2, "0")}`, assunto, c.data.split("-").reverse().join("/")].filter(Boolean).join(" — ");
}

const ROTULO_TIPO: Record<string, string> = {
  avaliacao: "Avaliação",
  apresentacao_orcamento: "Retorno para decisão",
  procedimento: "Procedimento",
  retorno: "Retorno",
  manutencao: "Manutenção",
};

/** Dados da ficha enviados ao salvar. */
const lista = (opcoes: readonly string[]) => z.array(z.string().trim().min(1).max(60)).max(opcoes.length + 10);
export const esquemaFicha = z.object({
  profissional_id: z.union([z.literal(""), z.uuid()]).default(""),
  motivo: lista(MOTIVOS),
  motivo_obs: z.string().trim().max(500).default(""),
  anamnese: lista(ANAMNESE),
  anamnese_obs: z.string().trim().max(2000).default(""),
  diagnostico: lista(DIAGNOSTICOS),
  diagnostico_obs: z.string().trim().max(2000).default(""),
  evolucao: z.string().trim().max(4000).default(""),
  orientacoes: lista(ORIENTACOES),
  orientacoes_obs: z.string().trim().max(1000).default(""),
  retorno_em: z.union([z.literal(""), z.string().regex(/^\d{4}-\d{2}-\d{2}$/, "Data de retorno inválida.")]).default(""),
  retorno_obs: z.string().trim().max(300).default(""),
  odontograma: z.record(z.string(), z.unknown()).default({}),
});
export type Ficha = z.input<typeof esquemaFicha>;

/** Idade em anos completos na data informada. */
export function idade(nascimento: DataCivil | null, hoje: DataCivil): number | null {
  if (!nascimento) return null;
  const [an, mn, dn] = nascimento.split("-").map(Number);
  const [ah, mh, dh] = hoje.split("-").map(Number);
  return ah - an - (mh < mn || (mh === mn && dh < dn) ? 1 : 0);
}
