"use client";

import { CalendarDays, Megaphone, Plus, Settings, SquareKanban, Sun, Users, Wallet } from "lucide-react";
import Link from "next/link";
import { usePathname } from "next/navigation";

const MENU = [
  { rotulo: "Hoje", href: "/hoje", icone: Sun, pronto: true },
  { rotulo: "Contatos", href: "/contatos", icone: Users, pronto: true },
  { rotulo: "Funil", href: "/funil", icone: SquareKanban, pronto: true },
  { rotulo: "Campanhas", href: "/campanhas", icone: Megaphone, pronto: true },
  { rotulo: "Agenda", href: "#", icone: CalendarDays, pronto: false },
  { rotulo: "Financeiro", href: "#", icone: Wallet, pronto: false },
  { rotulo: "Configurações", href: "/configuracoes", icone: Settings, pronto: true },
];

export function BotaoNovoPaciente({ compacto = false }: { compacto?: boolean }) {
  return (
    <Link
      href="/contatos/novo"
      className={`inline-flex items-center justify-center gap-1.5 rounded-lg bg-dourado font-medium tracking-wide text-white uppercase shadow-sm transition hover:bg-dourado-escuro ${
        compacto ? "px-3 py-2 text-xs" : "w-full px-4 py-2.5 text-sm"
      }`}
    >
      <Plus className="size-4" /> Novo paciente
    </Link>
  );
}

export function Menu() {
  const caminho = usePathname();
  return (
    <nav aria-label="Menu principal" className="flex gap-1 overflow-x-auto px-3 pb-3 lg:flex-1 lg:flex-col">
      {MENU.map(({ rotulo, href, icone: Icone, pronto }) => {
        if (!pronto) {
          return (
            <span
              key={rotulo}
              className="flex shrink-0 cursor-default items-center gap-3 rounded-lg px-3 py-2 text-sm text-sutil"
              title="Em breve"
            >
              <Icone className="size-4" /> {rotulo}
              <span className="ml-auto hidden text-[10px] tracking-wide uppercase lg:inline">em breve</span>
            </span>
          );
        }
        const ativo = caminho === href || caminho.startsWith(`${href}/`);
        return (
          <Link
            key={rotulo}
            href={href}
            aria-current={ativo ? "page" : undefined}
            className={`flex shrink-0 items-center gap-3 rounded-lg px-3 py-2 text-sm transition ${
              ativo ? "bg-dourado-claro font-medium text-dourado-escuro" : "text-suave hover:bg-fundo hover:text-grafite"
            }`}
          >
            <Icone className="size-4" /> {rotulo}
          </Link>
        );
      })}
    </nav>
  );
}
