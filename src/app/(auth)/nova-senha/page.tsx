import Link from "next/link";
import { redirect } from "next/navigation";
import { connection } from "next/server";
import { Marca } from "@/components/marca";
import { supabaseConfigurado, supabaseServidor } from "@/lib/supabase/servidor";
import { loginDeDesenvolvimento } from "@/modules/sessao/sessao";
import { FormularioNovaSenha } from "./formulario";

export const metadata = { title: "Nova senha · Instituto CG" };

/** Nova senha: pelo link do e-mail ("Esqueci minha senha") ou em Configurações → Minha senha. */
export default async function NovaSenha() {
  await connection();
  if (loginDeDesenvolvimento() || !supabaseConfigurado()) redirect("/login");
  const { data } = await (await supabaseServidor()).auth.getUser();
  if (!data.user) redirect("/esqueci-senha?expirado=1");
  return (
    <main className="flex min-h-screen items-center justify-center px-4 py-12">
      <div className="w-full max-w-sm rounded-2xl border border-borda bg-superficie p-8">
        <Marca tamanho="grande" />
        <h1 className="mt-6 font-titulo text-2xl">Criar nova senha</h1>
        <p className="mt-2 text-sm text-suave">Para {data.user.email}.</p>
        <FormularioNovaSenha />
        <Link href="/hoje" className="mt-6 block text-center text-sm text-dourado-escuro underline underline-offset-4">
          Voltar sem alterar
        </Link>
      </div>
    </main>
  );
}
