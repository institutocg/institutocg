"use server";

import { headers } from "next/headers";
import { z } from "zod";
import { supabaseConfigurado, supabaseServidor } from "@/lib/supabase/servidor";

export type EstadoSenha = { erro?: string; ok?: string };

/** Endereço do site (para o link do e-mail de redefinição voltar para cá). */
async function origem() {
  const h = await headers();
  const host = h.get("x-forwarded-host") ?? h.get("host");
  const protocolo = h.get("x-forwarded-proto") ?? (host?.startsWith("localhost") ? "http" : "https");
  return `${protocolo}://${host}`;
}

/** Esqueci minha senha: envia o link por e-mail (a resposta é a mesma exista ou não o e-mail). */
export async function pedirNovaSenha(_: EstadoSenha, dados: FormData): Promise<EstadoSenha> {
  const email = z.email("Informe um e-mail válido.").safeParse(String(dados.get("email") ?? "").trim());
  if (!email.success) return { erro: email.error.issues[0].message };
  if (!supabaseConfigurado()) return { erro: "O sistema ainda não foi conectado ao banco de dados." };
  const supabase = await supabaseServidor();
  const { error } = await supabase.auth.resetPasswordForEmail(email.data, {
    redirectTo: `${await origem()}/auth/confirmar?proximo=/nova-senha`,
  });
  if (error && !/rate|limit/i.test(error.message)) console.error("Redefinição de senha:", error.message);
  if (error && /rate|limit/i.test(error.message)) return { erro: "Muitos pedidos seguidos. Aguarde alguns minutos e tente de novo." };
  return { ok: "Se este e-mail tiver acesso ao sistema, você vai receber um link para criar uma nova senha. Confira também a caixa de spam." };
}

const esquemaSenha = z
  .object({
    senha: z.string().min(8, "A senha precisa ter pelo menos 8 caracteres.").max(72),
    confirmacao: z.string(),
  })
  .refine((v) => v.senha === v.confirmacao, { message: "As duas senhas não são iguais.", path: ["confirmacao"] });

/** Nova senha para quem está logada (pelo link do e-mail ou em Configurações). */
export async function definirNovaSenha(_: EstadoSenha, dados: FormData): Promise<EstadoSenha> {
  const lido = esquemaSenha.safeParse({ senha: dados.get("senha"), confirmacao: dados.get("confirmacao") });
  if (!lido.success) return { erro: lido.error.issues[0].message };
  if (!supabaseConfigurado()) return { erro: "O sistema ainda não foi conectado ao banco de dados." };
  const supabase = await supabaseServidor();
  const { data } = await supabase.auth.getUser();
  if (!data.user) return { erro: "O link expirou. Peça um novo em “Esqueci minha senha”." };
  const { error } = await supabase.auth.updateUser({ password: lido.data.senha });
  if (error) {
    return {
      erro: /different|same/i.test(error.message)
        ? "A nova senha precisa ser diferente da atual."
        : /weak|pwned|leaked/i.test(error.message)
          ? "Essa senha é muito fraca ou já apareceu em vazamentos. Escolha outra."
          : "Não foi possível trocar a senha agora. Tente novamente.",
    };
  }
  return { ok: "Senha alterada. Use a nova senha nos próximos acessos." };
}
