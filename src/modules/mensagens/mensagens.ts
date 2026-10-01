/**
 * Biblioteca de mensagens prontas: categorias, variáveis e utilitários puros.
 * As mensagens nunca são enviadas pelo sistema — a usuária copia, adapta e envia.
 */
import { z } from "zod";

export type Categoria =
  | "primeiro_contato"
  | "pos_consulta"
  | "nao_fechou"
  | "sem_resposta"
  | "desmarcou"
  | "confirmacao"
  | "remarcacao"
  | "reativacao"
  | "pos_atendimento"
  | "cobranca_amigavel"
  | "pagamento_pendente"
  | "pagamento_previsto"
  | "paciente_antigo";

/** Na ordem em que aparecem na tela. */
export const CATEGORIAS: { id: Categoria; rotulo: string; quando: string }[] = [
  { id: "primeiro_contato", rotulo: "Primeiro contato", quando: "Quem acabou de chegar e ainda não conversou com a clínica." },
  { id: "pos_consulta", rotulo: "Passou pela primeira consulta (pensando)", quando: "Recebeu o plano na consulta e está decidindo." },
  { id: "nao_fechou", rotulo: "Paciente não fechou", quando: "Retomar com leveza, no prazo do motivo." },
  { id: "sem_resposta", rotulo: "Paciente sem resposta", quando: "Parou de responder; mensagens curtas e sem cobrança." },
  { id: "desmarcou", rotulo: "Paciente desmarcou", quando: "Desmarcou ou faltou à consulta." },
  { id: "confirmacao", rotulo: "Confirmação", quando: "Confirmar a presença na consulta." },
  { id: "remarcacao", rotulo: "Remarcação", quando: "Encontrar um novo horário." },
  { id: "reativacao", rotulo: "Reativação", quando: "Reaproximar quem está há um tempo sem vir." },
  { id: "pos_atendimento", rotulo: "Acompanhamento pós-atendimento", quando: "Depois do atendimento ou do tratamento." },
  { id: "cobranca_amigavel", rotulo: "Cobrança amigável", quando: "Pagamento vencido há poucos dias." },
  { id: "pagamento_pendente", rotulo: "Pagamento pendente", quando: "Pagamento em aberto há mais tempo." },
  { id: "pagamento_previsto", rotulo: "Pagamento previsto", quando: "Lembrete antes do vencimento." },
  { id: "paciente_antigo", rotulo: "Paciente antigo", quando: "Manutenção, revisão e reaproximação de pacientes antigos." },
];

export const ROTULO_CATEGORIA = Object.fromEntries(CATEGORIAS.map((c) => [c.id, c.rotulo])) as Record<Categoria, string>;

/** Variáveis que o CRM preenche sozinho (com exemplo para a pré-visualização). */
export const VARIAVEIS: { token: string; rotulo: string; exemplo: string }[] = [
  { token: "nome", rotulo: "Nome", exemplo: "Maria" },
  { token: "nome_completo", rotulo: "Nome completo", exemplo: "Maria Silva" },
  { token: "procedimento", rotulo: "Procedimento", exemplo: "facetas de porcelana" },
  { token: "consulta", rotulo: "Consulta", exemplo: "a avaliação" },
  { token: "data", rotulo: "Data", exemplo: "15/10" },
  { token: "horario", rotulo: "Horário", exemplo: "14:30" },
  { token: "dentista", rotulo: "Dentista", exemplo: "Dra. Cristina" },
  { token: "valor", rotulo: "Valor", exemplo: "R$ 1.200,00" },
  { token: "vencimento", rotulo: "Vencimento", exemplo: "10/10" },
  { token: "clinica", rotulo: "Clínica", exemplo: "Instituto CG" },
];

const PADRAO_VARIAVEL = /\{\{\s*([a-z_]+)\s*\}\}|\{([a-z_]+)\}/g;

/** Texto com as variáveis trocadas pelos exemplos (pré-visualização sem paciente). */
export function preencherExemplo(texto: string): string {
  const exemplos = Object.fromEntries(VARIAVEIS.map((v) => [v.token, v.exemplo]));
  exemplos.primeiro_nome = exemplos.nome;
  return texto.replace(PADRAO_VARIAVEL, (todo, a, b) => exemplos[a ?? b] ?? todo);
}

/** Divide o texto em trechos, marcando as variáveis (para destacá-las na tela). */
export function trechos(texto: string): { texto: string; variavel: boolean }[] {
  const partes: { texto: string; variavel: boolean }[] = [];
  let ultimo = 0;
  for (const m of texto.matchAll(PADRAO_VARIAVEL)) {
    if (m.index > ultimo) partes.push({ texto: texto.slice(ultimo, m.index), variavel: false });
    partes.push({ texto: m[0], variavel: true });
    ultimo = m.index + m[0].length;
  }
  if (ultimo < texto.length) partes.push({ texto: texto.slice(ultimo), variavel: false });
  return partes;
}

/** Variáveis usadas que o CRM não conhece (para avisar ao salvar). */
export function variaveisDesconhecidas(texto: string): string[] {
  const conhecidas = new Set([...VARIAVEIS.map((v) => v.token), "primeiro_nome"]);
  return [...new Set([...texto.matchAll(PADRAO_VARIAVEL)].map((m) => m[1] ?? m[2]).filter((t) => !conhecidas.has(t)))];
}

export const esquemaModelo = z
  .object({
    id: z.union([z.literal(""), z.uuid()]),
    categoria: z.enum(CATEGORIAS.map((c) => c.id) as [Categoria, ...Categoria[]]),
    procedimentoId: z.union([z.literal(""), z.uuid()]),
    titulo: z.string().trim().min(2, "Dê um nome à mensagem.").max(80),
    texto: z.string().trim().min(10, "Escreva a mensagem.").max(2000),
    padrao: z.boolean(),
    ativo: z.boolean(),
  })
  .superRefine((v, ctx) => {
    const desconhecidas = variaveisDesconhecidas(v.texto);
    if (desconhecidas.length) {
      ctx.addIssue({ code: "custom", message: `Variável desconhecida: {{${desconhecidas[0]}}}. Use as variáveis da lista.` });
    }
  });

export type DadosModelo = z.input<typeof esquemaModelo>;

export interface Modelo {
  id: string;
  categoria: Categoria;
  situacao: string | null;
  procedimento_id: string | null;
  procedimento: string | null;
  titulo: string;
  texto: string;
  padrao: boolean;
  ativo: boolean;
}

export interface Sugestao {
  modelo_id: string;
  titulo: string;
  categoria: Categoria;
  procedimento: string | null;
  texto: string;
  recomendada: boolean;
  mesma_categoria: boolean;
}
