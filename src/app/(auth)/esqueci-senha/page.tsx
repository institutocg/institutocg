import Link from "next/link";
import { Marca } from "@/components/marca";
import { FormularioEsqueci } from "./formulario";

export const metadata = { title: "Esqueci minha senha · Instituto CG" };

export default async function EsqueciSenha({ searchParams }: { searchParams: Promise<{ expirado?: string }> }) {
  const { expirado } = await searchParams;
  return (
    <main className="flex min-h-screen items-center justify-center px-4 py-12">
      <div className="w-full max-w-sm rounded-2xl border border-borda bg-superficie p-8">
        <Marca tamanho="grande" />
        <h1 className="mt-6 font-titulo text-2xl">Esqueci minha senha</h1>
        <p className="mt-2 text-sm text-suave">Informe o seu e-mail de acesso. Enviaremos um link para você criar uma nova senha.</p>
        {expirado && (
          <p role="alert" className="mt-4 rounded-lg bg-importante-claro px-3.5 py-2.5 text-sm text-importante">
            O link expirou ou já foi usado. Peça um novo abaixo.
          </p>
        )}
        <FormularioEsqueci />
        <Link href="/login" className="mt-6 block text-center text-sm text-dourado-escuro underline underline-offset-4">
          Voltar para o login
        </Link>
      </div>
    </main>
  );
}
