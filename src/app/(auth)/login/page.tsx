import { redirect } from "next/navigation";
import { Marca } from "@/components/marca";
import { loginDeDesenvolvimento, obterSessao } from "@/modules/sessao/sessao";
import { FormularioLogin } from "./formulario";

export const metadata = { title: "Entrar · Instituto CG" };

export default async function PaginaLogin() {
  const sessao = await obterSessao().catch(() => null);
  if (sessao && sessao !== "sem_acesso") redirect("/hoje");
  const desenvolvimento = loginDeDesenvolvimento();

  return (
    <main className="flex min-h-screen items-center justify-center px-4 py-12">
      <div className="w-full max-w-sm rounded-2xl border border-borda bg-superficie p-8 shadow-[0_1px_2px_rgba(43,40,36,0.04)]">
        <Marca tamanho="grande" />
        <p className="mt-4 text-sm text-suave">Relacionamento com pacientes</p>
        {desenvolvimento && (
          <p className="mt-6 rounded-lg bg-dourado-claro px-3.5 py-2.5 text-xs text-dourado-escuro">
            Modo de desenvolvimento: entre só com o e-mail (sem senha).
          </p>
        )}
        <FormularioLogin desenvolvimento={desenvolvimento} />
      </div>
    </main>
  );
}
