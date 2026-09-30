import { LogOut } from "lucide-react";
import { Avisos } from "@/components/avisos";
import { Marca } from "@/components/marca";
import { BotaoNovoPaciente, Menu } from "@/components/menu";
import { comoUsuaria } from "@/lib/db";
import { contarARecuperar } from "@/modules/agenda/servidor";
import { exigirSessao } from "@/modules/sessao/sessao";
import { sair } from "../(auth)/login/acoes";

export default async function LayoutInterno({ children }: LayoutProps<"/">) {
  const sessao = await exigirSessao();
  const aRecuperar = await comoUsuaria(sessao.usuarioId, (db) => contarARecuperar(db, sessao.clinicaId));

  return (
    <div className="min-h-screen lg:flex">
      <aside className="border-b border-borda bg-superficie lg:sticky lg:top-0 lg:flex lg:h-screen lg:w-60 lg:shrink-0 lg:flex-col lg:border-r lg:border-b-0">
        <div className="flex items-center justify-between gap-3 px-5 py-4 lg:block lg:px-6 lg:py-7">
          <Marca />
          <div className="flex items-center gap-3 lg:hidden">
            <BotaoNovoPaciente compacto />
            <form action={sair}>
              <button className="flex items-center text-suave" aria-label="Sair">
                <LogOut className="size-4" />
              </button>
            </form>
          </div>
        </div>
        <div className="hidden px-4 pb-5 lg:block">
          <BotaoNovoPaciente />
        </div>
        <Menu aRecuperar={aRecuperar} />
        <div className="hidden border-t border-borda px-6 py-5 lg:block">
          <p className="text-sm font-medium">{sessao.nome}</p>
          <p className="text-xs text-sutil">{sessao.clinicaNome}</p>
          <form action={sair} className="mt-3">
            <button className="flex items-center gap-1.5 text-xs text-suave hover:text-grafite">
              <LogOut className="size-3.5" /> Sair
            </button>
          </form>
        </div>
      </aside>
      <main className="min-w-0 flex-1">{children}</main>
      <Avisos />
    </div>
  );
}
