import { NextResponse, type NextRequest } from "next/server";
import { supabaseServidor } from "@/lib/supabase/servidor";

/**
 * Volta do e-mail de "Esqueci minha senha": troca o código por uma sessão e
 * leva para a tela de nova senha. Só aceita destinos internos.
 */
export async function GET(request: NextRequest) {
  const url = new URL(request.url);
  const codigo = url.searchParams.get("code");
  const proximo = url.searchParams.get("proximo") ?? "/nova-senha";
  const destino = proximo.startsWith("/") && !proximo.startsWith("//") ? proximo : "/nova-senha";
  if (codigo) {
    const supabase = await supabaseServidor();
    const { error } = await supabase.auth.exchangeCodeForSession(codigo);
    if (!error) return NextResponse.redirect(new URL(destino, url.origin));
  }
  return NextResponse.redirect(new URL("/esqueci-senha?expirado=1", url.origin));
}
