import { TZDate } from "@date-fns/tz";
import type { Configuracoes } from "@/modules/configuracoes/padroes";

/**
 * Todo o sistema trabalha no fuso da clínica. Datas "de calendário"
 * (vencimentos, dias de tarefa) circulam como texto AAAA-MM-DD, o que evita
 * qualquer confusão de fuso; horários exatos usam Date/timestamptz.
 */
export const FUSO_CLINICA = "America/Sao_Paulo";

export type DataCivil = string; // "AAAA-MM-DD"

type Horario = Pick<Configuracoes, "horario" | "dias_fechados_extra" | "fecha_pontos_facultativos">;

function noFuso(instante: Date) {
  return new TZDate(instante.getTime(), FUSO_CLINICA);
}

/** Data de hoje no fuso da clínica. */
export function hoje(agora: Date = new Date()): DataCivil {
  const d = noFuso(agora);
  return montar(d.getFullYear(), d.getMonth() + 1, d.getDate());
}

export function somarDias(data: DataCivil, dias: number): DataCivil {
  const d = paraUtc(data);
  d.setUTCDate(d.getUTCDate() + dias);
  return deUtc(d);
}

/** 0 = domingo … 6 = sábado */
export function diaDaSemana(data: DataCivil): number {
  return paraUtc(data).getUTCDay();
}

/** Diferença em dias de calendário (b − a). */
export function diasEntre(a: DataCivil, b: DataCivil): number {
  return Math.round((paraUtc(b).getTime() - paraUtc(a).getTime()) / 86_400_000);
}

/** Feriados nacionais (lei federal), incluindo Sexta-feira Santa. */
export function feriadosNacionais(ano: number): Map<DataCivil, string> {
  const pascoa = domingoDePascoa(ano);
  const f = new Map<DataCivil, string>([
    [montar(ano, 1, 1), "Confraternização Universal"],
    [somarDias(pascoa, -2), "Sexta-feira Santa"],
    [montar(ano, 4, 21), "Tiradentes"],
    [montar(ano, 5, 1), "Dia do Trabalho"],
    [montar(ano, 9, 7), "Independência do Brasil"],
    [montar(ano, 10, 12), "Nossa Senhora Aparecida"],
    [montar(ano, 11, 2), "Finados"],
    [montar(ano, 11, 15), "Proclamação da República"],
    [montar(ano, 12, 25), "Natal"],
  ]);
  if (ano >= 2024) f.set(montar(ano, 11, 20), "Dia Nacional de Zumbi e da Consciência Negra");
  return f;
}

/** Pontos facultativos nacionais mais comuns (a clínica decide se fecha). */
export function pontosFacultativos(ano: number): Map<DataCivil, string> {
  const pascoa = domingoDePascoa(ano);
  return new Map([
    [somarDias(pascoa, -48), "Carnaval (segunda-feira)"],
    [somarDias(pascoa, -47), "Carnaval (terça-feira)"],
    [somarDias(pascoa, 60), "Corpus Christi"],
  ]);
}

/** A clínica abre nesta data? */
export function ehDiaUtil(data: DataCivil, cfg: Horario): boolean {
  if (!cfg.horario.dias.includes(diaDaSemana(data))) return false;
  const ano = Number(data.slice(0, 4));
  if (feriadosNacionais(ano).has(data)) return false;
  if (cfg.fecha_pontos_facultativos && pontosFacultativos(ano).has(data)) return false;
  return !cfg.dias_fechados_extra.includes(data);
}

/** Último dia útil antes da data (ex.: véspera para confirmar uma consulta). */
export function diaUtilAnterior(data: DataCivil, cfg: Horario): DataCivil {
  let d = somarDias(data, -1);
  for (let i = 0; i < 30 && !ehDiaUtil(d, cfg); i++) d = somarDias(d, -1);
  return d;
}

/** Próximo dia útil a partir da data (inclusive). */
export function proximoDiaUtil(data: DataCivil, cfg: Horario): DataCivil {
  let d = data;
  for (let i = 0; i < 30 && !ehDiaUtil(d, cfg); i++) d = somarDias(d, 1);
  return d;
}

/** Agora está dentro do horário de funcionamento? */
export function dentroDoHorario(agora: Date, cfg: Horario): boolean {
  if (!ehDiaUtil(hoje(agora), cfg)) return false;
  const d = noFuso(agora);
  const minutos = d.getHours() * 60 + d.getMinutes();
  return minutos >= paraMinutos(cfg.horario.inicio) && minutos < paraMinutos(cfg.horario.fim);
}

export function saudacao(agora: Date = new Date()): string {
  const hora = noFuso(agora).getHours();
  if (hora < 12) return "Bom dia";
  if (hora < 18) return "Boa tarde";
  return "Boa noite";
}

const formatadorLongo = new Intl.DateTimeFormat("pt-BR", {
  weekday: "long",
  day: "numeric",
  month: "long",
  timeZone: "UTC",
});

/** "2026-09-29" → "terça-feira, 29 de setembro" */
export function formatarDataLonga(data: DataCivil): string {
  return formatadorLongo.format(paraUtc(data));
}

// ── utilitários internos ────────────────────────────────────────────────

function montar(ano: number, mes: number, dia: number): DataCivil {
  return `${ano}-${String(mes).padStart(2, "0")}-${String(dia).padStart(2, "0")}`;
}

function paraUtc(data: DataCivil): Date {
  const [a, m, d] = data.split("-").map(Number);
  return new Date(Date.UTC(a, m - 1, d));
}

function deUtc(d: Date): DataCivil {
  return montar(d.getUTCFullYear(), d.getUTCMonth() + 1, d.getUTCDate());
}

function paraMinutos(hhmm: string) {
  const [h, m] = hhmm.split(":").map(Number);
  return h * 60 + m;
}

/** Algoritmo de Meeus/Jones/Butcher (calendário gregoriano). */
function domingoDePascoa(ano: number): DataCivil {
  const a = ano % 19;
  const b = Math.floor(ano / 100);
  const c = ano % 100;
  const d = Math.floor(b / 4);
  const e = b % 4;
  const f = Math.floor((b + 8) / 25);
  const g = Math.floor((b - f + 1) / 3);
  const h = (19 * a + b - d - g + 15) % 30;
  const i = Math.floor(c / 4);
  const k = c % 4;
  const l = (32 + 2 * e + 2 * i - h - k) % 7;
  const m = Math.floor((a + 11 * h + 22 * l) / 451);
  const mes = Math.floor((h + l - 7 * m + 114) / 31);
  const dia = ((h + l - 7 * m + 114) % 31) + 1;
  return montar(ano, mes, dia);
}
