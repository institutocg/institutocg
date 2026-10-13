/** Receituário: tipos e textos (sem banco). */
import type { DataCivil } from "@/lib/datas";

export type Uso = "oral" | "topico" | "sublingual" | "externo";
export type TipoReceita = "simples" | "controle_especial";

export const USOS: Record<Uso, string> = {
  oral: "Uso oral",
  topico: "Uso tópico",
  sublingual: "Uso sublingual",
  externo: "Uso externo",
};

export const TIPOS_RECEITA: Record<TipoReceita, string> = {
  simples: "Receita simples",
  controle_especial: "Controle especial",
};

export interface ItemReceita {
  medicamento: string;
  quantidade: string;
  uso: Uso;
  posologia: string;
}

export interface Receita {
  id: string;
  pessoa_id: string;
  atendimento_id: string | null;
  atendimento_numero: number | null;
  profissional_id: string | null;
  profissional: string | null;
  profissional_cro: string | null;
  profissional_especialidade: string | null;
  tipo: TipoReceita;
  vias: 1 | 2;
  data: DataCivil;
  itens: ItemReceita[];
  orientacoes: string | null;
}

export interface ModeloReceita {
  id: string;
  nome: string;
  tipo: TipoReceita;
  itens: ItemReceita[];
  orientacoes: string | null;
}

/** Cabeçalho e rodapé da receita (Configurações → Receituário). */
export interface DadosReceituario {
  endereco: string | null;
  telefone: string | null;
  cidade: string | null;
  rodape: string | null;
}

export const ITEM_VAZIO: ItemReceita = { medicamento: "", quantidade: "", uso: "oral", posologia: "" };

/** Medicamentos agrupados por via ("Uso oral", "Uso tópico"…), numerados na ordem da receita. */
export function agruparPorUso(itens: ItemReceita[]): { uso: Uso; itens: (ItemReceita & { n: number })[] }[] {
  const grupos: { uso: Uso; itens: (ItemReceita & { n: number })[] }[] = [];
  let n = 0;
  for (const uso of Object.keys(USOS) as Uso[]) {
    const doUso = itens.filter((i) => (i.uso ?? "oral") === uso);
    if (doUso.length) grupos.push({ uso, itens: doUso.map((i) => ({ ...i, n: ++n })) });
  }
  return grupos;
}

const MESES = ["janeiro", "fevereiro", "março", "abril", "maio", "junho", "julho", "agosto", "setembro", "outubro", "novembro", "dezembro"];

/** "13 de outubro de 2026". */
export function dataPorExtenso(d: DataCivil): string {
  const [a, m, dia] = d.split("-").map(Number);
  return `${dia} de ${MESES[m - 1]} de ${a}`;
}

/** Resumo para a lista do prontuário: "Amoxicilina 500 mg, Dipirona 500 mg". */
export function resumoReceita(itens: ItemReceita[]): string {
  return itens.map((i) => i.medicamento).join(", ");
}

/** Sugestões para o campo de medicamento (a dentista pode escrever qualquer outro). */
export const SUGESTOES_MEDICAMENTOS = [
  "Amoxicilina 500 mg",
  "Amoxicilina + clavulanato 875 mg",
  "Azitromicina 500 mg",
  "Clindamicina 300 mg",
  "Metronidazol 400 mg",
  "Dipirona 500 mg",
  "Dipirona 1 g",
  "Paracetamol 750 mg",
  "Ibuprofeno 600 mg",
  "Nimesulida 100 mg",
  "Cetorolaco 10 mg",
  "Dexametasona 4 mg",
  "Digluconato de clorexidina 0,12%",
  "Aciclovir creme 5%",
  "Omeprazol 20 mg",
];
