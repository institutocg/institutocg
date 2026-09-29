import { Marca } from "@/components/marca";
import { sair } from "../login/acoes";

export const metadata = { title: "Acesso pendente · Instituto CG" };

export default function SemAcesso() {
  return (
    <main className="flex min-h-screen items-center justify-center px-4">
      <div className="w-full max-w-sm rounded-2xl border border-borda bg-superficie p-8 text-center">
        <div className="flex justify-center">
          <Marca tamanho="grande" />
        </div>
        <h1 className="mt-8 font-titulo text-2xl">Seu acesso ainda não foi liberado</h1>
        <p className="mt-3 text-sm text-suave">
          Peça à administradora da clínica para liberar o seu usuário. Assim que ela fizer isso, é só entrar de novo.
        </p>
        <form action={sair} className="mt-8">
          <button className="text-sm text-dourado-escuro underline underline-offset-4">Voltar para o login</button>
        </form>
      </div>
    </main>
  );
}
