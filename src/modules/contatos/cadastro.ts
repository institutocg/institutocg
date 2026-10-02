/**
 * Regras do formulário de cadastro (novo contato e paciente antigo).
 * Funções puras: validação, normalização e conversão da data do último atendimento.
 */
import { z } from "zod";
import type { DataCivil } from "@/lib/datas";
import { normalizarTelefone } from "@/lib/telefone";

export const FAIXAS_ATENDIMENTO = {
  menos_6_meses: { rotulo: "Menos de 6 meses", mesesAtras: 3 },
  "6_a_12_meses": { rotulo: "6 a 12 meses", mesesAtras: 9 },
  "1_a_2_anos": { rotulo: "1 a 2 anos", mesesAtras: 18 },
  mais_2_anos: { rotulo: "Mais de 2 anos", mesesAtras: 30 },
  nao_lembra: { rotulo: "Não lembra", mesesAtras: null },
} as const;

export type FaixaAtendimento = keyof typeof FAIXAS_ATENDIMENTO;

const opcional = <T extends z.ZodType<string>>(s: T) =>
  z.preprocess((v) => (typeof v === "string" && v.trim() === "" ? undefined : typeof v === "string" ? v.trim() : v), s.optional());

const uuidOpcional = z.preprocess((v) => (v === "" || v === null ? undefined : v), z.uuid().optional());

export const esquemaCadastro = z
  .object({
    tipo: z.enum(["novo_contato", "paciente_antigo"]),
    nome: z
      .string()
      .transform((v) => v.trim().replace(/\s+/g, " "))
      .pipe(z.string().min(3, "Informe o nome completo.").max(200)),
    nascimento: opcional(z.string().regex(/^\d{4}-\d{2}-\d{2}$/, "Data de nascimento inválida.")),
    whatsapp: opcional(z.string()),
    email: opcional(z.email("E-mail inválido.")).transform((v) => v?.toLowerCase()),
    cep: opcional(z.string()).transform((v) => v?.replace(/\D/g, "")).pipe(
      z.string().regex(/^\d{8}$/, "CEP deve ter 8 números.").optional(),
    ),
    endereco: opcional(z.string().max(200)),
    bairro: opcional(z.string().max(100)),
    cidade: opcional(z.string().max(100)),
    uf: opcional(z.string()).transform((v) => v?.toUpperCase()).pipe(
      z.string().regex(/^[A-Z]{2}$/, "UF com 2 letras (ex.: SP).").optional(),
    ),
    origemId: uuidOpcional,
    // Procedimento: id de um já cadastrado ou o nome escrito livremente.
    procedimentoId: opcional(z.string().max(120, "Procedimento: no máximo 120 caracteres.")),
    responsavelId: uuidOpcional,
    observacoes: opcional(z.string().max(1000, "Observações: no máximo 1.000 caracteres.")),
    aceitaMarketing: z.preprocess((v) => v === "on" || v === "true" || v === true, z.boolean()),
    // Paciente antigo
    ultimoAtendimentoMes: opcional(z.string().regex(/^\d{4}-\d{2}$/, "Mês inválido.")),
    ultimoAtendimentoFaixa: z.preprocess(
      (v) => (v === "" || v === null ? undefined : v),
      z.enum(Object.keys(FAIXAS_ATENDIMENTO) as [FaixaAtendimento, ...FaixaAtendimento[]]).optional(),
    ),
    tratamentos: z.array(z.string().trim().min(2).max(120)).max(30).default([]),
    emTratamento: z.preprocess((v) => v === "on" || v === "true" || v === true, z.boolean()),
  })
;

/**
 * Regras que envolvem mais de um campo. Rodam sempre — mesmo quando outro campo
 * tem erro — para que a pessoa veja todos os problemas de uma vez.
 */
function regrasCruzadas(bruto: Record<string, unknown>): z.core.$ZodIssue[] {
  const texto = (k: string) => (typeof bruto[k] === "string" ? (bruto[k] as string).trim() : "");
  const problemas: z.core.$ZodIssue[] = [];
  const erro = (campo: string, message: string) =>
    problemas.push({ code: "custom", path: [campo], message, input: bruto[campo] } as z.core.$ZodIssue);

  const whatsapp = texto("whatsapp");
  if (whatsapp && !normalizarTelefone(whatsapp)) erro("whatsapp", "WhatsApp inválido. Use DDD + número.");
  if (!whatsapp && !texto("email")) erro("whatsapp", "Informe o WhatsApp ou o e-mail.");
  if (bruto.tipo === "novo_contato" && !texto("origemId")) erro("origemId", "Informe como conheceu a clínica.");
  const nascimento = texto("nascimento");
  if (nascimento && (nascimento < "1900-01-01" || nascimento > new Date().toISOString().slice(0, 10))) {
    erro("nascimento", "Data de nascimento inválida.");
  }
  return problemas;
}

export type DadosCadastro = z.output<typeof esquemaCadastro> & { whatsapp?: string };
export type ErrosCadastro = Partial<Record<keyof DadosCadastro | "geral", string>>;

/** Lê o FormData do formulário. */
export function lerFormulario(form: FormData) {
  const obj: Record<string, unknown> = {};
  for (const [chave, valor] of form.entries()) {
    if (chave === "tratamentos") continue;
    obj[chave] = valor;
  }
  obj.tratamentos = form.getAll("tratamentos");

  const base = esquemaCadastro.safeParse(obj);
  const cruzados = regrasCruzadas(obj);
  const jaTem = new Set(base.success ? [] : base.error.issues.map((i) => String(i.path[0])));
  const extras = cruzados.filter((i) => !jaTem.has(String(i.path[0])));
  if (!base.success || extras.length > 0) {
    const issues = [...(base.success ? [] : base.error.issues), ...extras];
    return { success: false as const, error: new z.ZodError(issues) };
  }
  return {
    success: true as const,
    data: { ...base.data, whatsapp: base.data.whatsapp ? normalizarTelefone(base.data.whatsapp)! : undefined } as DadosCadastro,
  };
}

export function errosPorCampo(erro: z.ZodError): ErrosCadastro {
  const erros: ErrosCadastro = {};
  for (const i of erro.issues) {
    const campo = (i.path[0] as keyof ErrosCadastro) ?? "geral";
    erros[campo] ??= i.message;
  }
  return erros;
}

/**
 * Data que representa o último atendimento:
 *  - mês lembrado → dia 1 daquele mês;
 *  - faixa ("1 a 2 anos") → data aproximada no meio da faixa (para os cálculos
 *    de reativação), guardando a faixa para exibição.
 */
export function ultimoAtendimento(
  mes: string | undefined,
  faixa: FaixaAtendimento | undefined,
  hoje: DataCivil,
): { data: DataCivil | null; faixa: FaixaAtendimento | null } {
  if (mes) return { data: `${mes}-01`, faixa: null };
  if (!faixa) return { data: null, faixa: null };
  const meses = FAIXAS_ATENDIMENTO[faixa].mesesAtras;
  return { data: meses === null ? null : subtrairMeses(hoje, meses), faixa };
}

/** "2026-09-29" − 18 meses → "2025-03-29" (ajusta o dia no fim de mês). */
export function subtrairMeses(data: DataCivil, meses: number): DataCivil {
  const [a, m, d] = data.split("-").map(Number);
  const total = a * 12 + (m - 1) - meses;
  const ano = Math.floor(total / 12);
  const mes = (total % 12) + 1;
  const ultimoDia = new Date(Date.UTC(ano, mes, 0)).getUTCDate();
  return `${ano}-${String(mes).padStart(2, "0")}-${String(Math.min(d, ultimoDia)).padStart(2, "0")}`;
}

/** Texto para exibir o último atendimento. */
export function rotuloUltimoAtendimento(data: DataCivil | null, faixa: string | null): string | null {
  if (faixa && faixa in FAIXAS_ATENDIMENTO) {
    const f = FAIXAS_ATENDIMENTO[faixa as FaixaAtendimento];
    return faixa === "nao_lembra" ? "Não lembra" : `Há ${f.rotulo.toLowerCase()}`;
  }
  if (!data) return null;
  const [a, m] = data.split("-");
  const meses = ["jan", "fev", "mar", "abr", "mai", "jun", "jul", "ago", "set", "out", "nov", "dez"];
  return `${meses[Number(m) - 1]}/${a}`;
}
