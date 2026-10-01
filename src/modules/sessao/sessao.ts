import "server-only";
import { cookies } from "next/headers";
import { redirect } from "next/navigation";
import { cache } from "react";
import { comoUsuaria, pool } from "@/lib/db";
import { supabaseConfigurado, supabaseServidor } from "@/lib/supabase/servidor";

export interface Sessao {
  usuarioId: string;
  nome: string;
  email: string;
  clinicaId: string;
  clinicaNome: string;
  papel: "admin" | "gestor" | "comercial" | "dentista";
  podeVerFinanceiro: boolean;
  /** Prontuário (dado de saúde): administradora, dentistas ou acesso liberado. */
  podeVerProntuario: boolean;
}

export const COOKIE_DEV = "crm_dev_usuaria";

/**
 * Login de desenvolvimento: permite testar o sistema localmente sem um projeto
 * Supabase. Só funciona com AUTH_MODO=desenvolvimento e NUNCA na Vercel.
 */
export function loginDeDesenvolvimento(): boolean {
  return process.env.AUTH_MODO === "desenvolvimento" && !process.env.VERCEL;
}

async function usuarioAutenticado(): Promise<{ id: string } | null> {
  if (loginDeDesenvolvimento()) {
    const email = (await cookies()).get(COOKIE_DEV)?.value;
    if (!email) return null;
    const r = await pool().query<{ id: string }>("select id from public.usuarios where lower(email) = lower($1)", [email]);
    return r.rows[0] ?? null;
  }
  if (!supabaseConfigurado()) return null;
  const supabase = await supabaseServidor();
  const { data } = await supabase.auth.getUser();
  return data.user ? { id: data.user.id } : null;
}

/** Sessão da usuária logada; null se não estiver logada. */
export const obterSessao = cache(async (): Promise<Sessao | "sem_acesso" | null> => {
  const usuario = await usuarioAutenticado();
  if (!usuario) return null;
  const linhas = await comoUsuaria(usuario.id, async (db) => {
    const r = await db.query<Sessao>(
      `select u.id as "usuarioId", u.nome, u.email, c.id as "clinicaId", c.nome as "clinicaNome",
              m.papel, (m.papel in ('admin', 'gestor') or m.pode_ver_financeiro) as "podeVerFinanceiro",
              (m.papel in ('admin', 'dentista') or m.pode_ver_prontuario) as "podeVerProntuario"
         from public.membros m
         join public.usuarios u on u.id = m.usuario_id
         join public.clinicas c on c.id = m.clinica_id
        where m.usuario_id = auth.uid() and m.ativo and u.ativo
        order by m.criado_em
        limit 1`,
    );
    return r.rows;
  });
  return linhas[0] ?? "sem_acesso";
});

/** Para páginas internas: exige login e acesso liberado. */
export async function exigirSessao(): Promise<Sessao> {
  const sessao = await obterSessao();
  if (!sessao) redirect("/login");
  if (sessao === "sem_acesso") redirect("/sem-acesso");
  return sessao;
}
