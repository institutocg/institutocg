"use server";

import { cookies } from "next/headers";
import { redirect } from "next/navigation";
import { z } from "zod";
import { supabaseConfigurado, supabaseServidor } from "@/lib/supabase/servidor";
import { COOKIE_DEV, loginDeDesenvolvimento } from "@/modules/sessao/sessao";

export type EstadoLogin = { erro?: string };

const esquema = z.object({
  email: z.email("Informe um e-mail válido."),
  senha: z.string(),
});

export async function entrar(_: EstadoLogin, dados: FormData): Promise<EstadoLogin> {
  const lido = esquema.safeParse({ email: dados.get("email"), senha: dados.get("senha") ?? "" });
  if (!lido.success) return { erro: lido.error.issues[0].message };

  if (loginDeDesenvolvimento()) {
    (await cookies()).set(COOKIE_DEV, lido.data.email, { httpOnly: true, sameSite: "lax", path: "/" });
    redirect("/hoje");
  }

  if (!supabaseConfigurado()) return { erro: "O sistema ainda não foi conectado ao banco de dados." };
  if (!lido.data.senha) return { erro: "Informe a senha." };

  const supabase = await supabaseServidor();
  const { error } = await supabase.auth.signInWithPassword({ email: lido.data.email, password: lido.data.senha });
  if (error) {
    return {
      erro: error.message.includes("Invalid login")
        ? "E-mail ou senha incorretos."
        : "Não foi possível entrar agora. Tente novamente.",
    };
  }
  redirect("/hoje");
}

export async function sair() {
  if (loginDeDesenvolvimento()) {
    (await cookies()).delete(COOKIE_DEV);
  } else if (supabaseConfigurado()) {
    await (await supabaseServidor()).auth.signOut();
  }
  redirect("/login");
}
