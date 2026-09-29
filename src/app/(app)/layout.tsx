import { CalendarDays, LogOut, SquareKanban, Settings, Sun, Users, Wallet } from "lucide-react";
import Link from "next/link";
import { Marca } from "@/components/marca";
import { exigirSessao } from "@/modules/sessao/sessao";
import { sair } from "../(auth)/login/acoes";

const MENU = [
  { rotulo: "Hoje", href: "/hoje", icone: Sun, pronto: true },
  { rotulo: "Agenda", href: "#", icone: CalendarDays, pronto: false },
  { rotulo: "Contatos", href: "#", icone: Users, pronto: false },
  { rotulo: "Funil", href: "#", icone: SquareKanban, pronto: false },
  { rotulo: "Financeiro", href: "#", icone: Wallet, pronto: false },
  { rotulo: "Configurações", href: "#", icone: Settings, pronto: false },
];

export default async function LayoutInterno({ children }: LayoutProps<"/">) {
  const sessao = await exigirSessao();

  return (
    <div className="min-h-screen lg:flex">
      <aside className="border-b border-borda bg-superficie lg:sticky lg:top-0 lg:flex lg:h-screen lg:w-60 lg:flex-col lg:border-r lg:border-b-0">
        <div className="flex items-center justify-between px-5 py-4 lg:block lg:px-6 lg:py-7">
          <Marca />
          <form action={sair} className="lg:hidden">
            <button className="flex items-center gap-1.5 text-sm text-suave" aria-label="Sair">
              <LogOut className="size-4" /> Sair
            </button>
          </form>
        </div>
        <nav aria-label="Menu principal" className="flex gap-1 overflow-x-auto px-3 pb-3 lg:flex-1 lg:flex-col lg:px-3">
          {MENU.map(({ rotulo, href, icone: Icone, pronto }) =>
            pronto ? (
              <Link
                key={rotulo}
                href={href}
                aria-current="page"
                className="flex shrink-0 items-center gap-3 rounded-lg bg-dourado-claro px-3 py-2 text-sm font-medium text-dourado-escuro"
              >
                <Icone className="size-4" /> {rotulo}
              </Link>
            ) : (
              <span
                key={rotulo}
                className="flex shrink-0 cursor-default items-center gap-3 rounded-lg px-3 py-2 text-sm text-sutil"
                title="Em breve"
              >
                <Icone className="size-4" /> {rotulo}
                <span className="ml-auto hidden text-[10px] tracking-wide uppercase lg:inline">em breve</span>
              </span>
            ),
          )}
        </nav>
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
    </div>
  );
}
