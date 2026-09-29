import { z } from "zod";

/**
 * Parâmetros da clínica (guardados em `clinicas.configuracoes`).
 * Todos são ajustáveis em Configurações; estes são os valores padrão
 * decididos na especificação (docs/ARQUITETURA_CRM.md, seção 15).
 */
export const esquemaConfiguracoes = z.object({
  horario: z.object({
    /** Dias da semana em que a clínica abre (0 = domingo … 6 = sábado). */
    dias: z.array(z.number().int().min(0).max(6)),
    inicio: z.string().regex(/^\d{2}:\d{2}$/),
    fim: z.string().regex(/^\d{2}:\d{2}$/),
  }),
  /** Datas extras em que a clínica fecha (AAAA-MM-DD), além dos feriados nacionais. */
  dias_fechados_extra: z.array(z.string().regex(/^\d{4}-\d{2}-\d{2}$/)),
  /** A clínica fecha nos pontos facultativos (Carnaval, Corpus Christi)? */
  fecha_pontos_facultativos: z.boolean(),
  sla_primeiro_contato_min: z.number().int().positive(),
  meses_paciente_inativo: z.number().int().positive(),
  dias_reativacao_desistiu: z.number().int().positive(),
  intervalo_min_contato_dias: z.number().int().nonnegative(),
  intervalo_min_campanha_dias: z.number().int().nonnegative(),
  /** Desligada durante o recadastramento; a administradora liga quando quiser. */
  reativacao_automatica: z.boolean(),
  limite_reativacao_dia: z.number().int().positive(),
  validade_orcamento_dias: z.number().int().positive(),
});

export type Configuracoes = z.infer<typeof esquemaConfiguracoes>;

export const CONFIGURACOES_PADRAO: Configuracoes = {
  horario: { dias: [1, 2, 3, 4, 5], inicio: "08:00", fim: "19:00" },
  dias_fechados_extra: [],
  fecha_pontos_facultativos: false,
  sla_primeiro_contato_min: 15,
  meses_paciente_inativo: 12,
  dias_reativacao_desistiu: 180,
  intervalo_min_contato_dias: 3,
  intervalo_min_campanha_dias: 30,
  reativacao_automatica: false,
  limite_reativacao_dia: 10,
  validade_orcamento_dias: 30,
};

/** Lê o JSON do banco completando o que faltar com os valores padrão. */
export function lerConfiguracoes(bruto: unknown): Configuracoes {
  const parcial = esquemaConfiguracoes.partial().safeParse(bruto ?? {});
  return { ...CONFIGURACOES_PADRAO, ...(parcial.success ? parcial.data : {}) };
}
