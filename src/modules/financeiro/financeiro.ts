/** Visão financeira simples: tipos, status e rótulos (funções puras). */
import { diasEntre, type DataCivil } from "@/lib/datas";

export type Situacao = "pendente" | "parcial" | "pago" | "atrasado";

export const SITUACAO: Record<Situacao, { rotulo: string; classe: string }> = {
  pendente: { rotulo: "Pendente", classe: "bg-fundo text-suave ring-1 ring-borda-forte" },
  parcial: { rotulo: "Parcialmente pago", classe: "bg-importante-claro text-importante" },
  pago: { rotulo: "Pago", classe: "bg-rotina-claro text-rotina" },
  atrasado: { rotulo: "Atrasado", classe: "bg-urgente-claro text-urgente" },
};

export interface Resumo {
  recebido_mes: number;
  pagamentos_mes: number;
  previsto_mes: number;
  pendente: number;
  atrasado: number;
  atrasados: number;
  vendido_mes: number;
}

export interface ParcelaFin {
  id: string;
  venda_id: string;
  pessoa_id: string;
  numero: number;
  vencimento: DataCivil;
  pago_em: DataCivil | null;
  valor_centavos: number;
  valor_pago_centavos: number;
  saldo_centavos: number;
  observacao: string | null;
  pessoa_nome: string;
  whatsapp: string | null;
  procedimento: string | null;
  forma_pagamento: string | null;
  quantidade_parcelas: number;
  dias_atraso: number;
  situacao: Situacao;
  tarefa_id: string | null;
}

export interface NegociacaoFin {
  id: string;
  pessoa_id: string;
  pessoa_nome: string;
  procedimento: string | null;
  fechada_em: DataCivil;
  valor_final_centavos: number;
  desconto_centavos: number;
  entrada_centavos: number;
  quantidade_parcelas: number;
  valor_parcela_centavos: number;
  forma_pagamento: string | null;
  observacao: string | null;
  pago_centavos: number;
  saldo_centavos: number;
  atrasado_centavos: number;
  proximo_vencimento: DataCivil | null;
  ultimo_pagamento_em: DataCivil | null;
  situacao: Situacao;
}

export interface PagamentoMes {
  id: string;
  pago_em: DataCivil;
  valor_centavos: number;
  pessoa_id: string;
  pessoa_nome: string;
  procedimento: string | null;
  forma_pagamento: string | null;
  numero: number;
  quantidade_parcelas: number;
}

/** "Entrada" ou "Parcela 2 de 4" */
export function rotuloParcela(numero: number, total: number): string {
  return numero === 0 ? "Entrada" : `Parcela ${numero} de ${total}`;
}

/** "Vence hoje", "Vence amanhã", "Vence em 12/10", "Vencido há 3 dias" */
export function rotuloVencimento(vencimento: DataCivil, hoje: DataCivil): string {
  const d = diasEntre(hoje, vencimento);
  if (d < 0) return `Vencido há ${-d} ${d === -1 ? "dia" : "dias"}`;
  if (d === 0) return "Vence hoje";
  if (d === 1) return "Vence amanhã";
  return `Vence em ${vencimento.slice(8, 10)}/${vencimento.slice(5, 7)}`;
}

/** Primeiro dia do mês e o mês anterior/seguinte (navegação). */
export function mesDe(data: DataCivil): DataCivil {
  return `${data.slice(0, 7)}-01`;
}

export function somarMes(mes: DataCivil, n: number): DataCivil {
  const [a, m] = mes.split("-").map(Number);
  const d = new Date(Date.UTC(a, m - 1 + n, 1));
  return d.toISOString().slice(0, 10);
}

const MES = new Intl.DateTimeFormat("pt-BR", { month: "long", year: "numeric", timeZone: "UTC" });

export function rotuloMes(mes: DataCivil): string {
  const t = MES.format(new Date(`${mes}T12:00:00Z`));
  return t.charAt(0).toUpperCase() + t.slice(1);
}

/** Valor de cada parcela (a diferença de centavos vai para a última, como no banco). */
export function simularParcelas(finalCentavos: number, entradaCentavos: number, parcelas: number) {
  const restante = Math.max(finalCentavos - entradaCentavos, 0);
  const n = Math.max(parcelas, 1);
  const valor = Math.floor(restante / n);
  return { restante, valor, ultima: restante - valor * (n - 1) };
}
