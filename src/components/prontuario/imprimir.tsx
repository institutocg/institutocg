"use client";

import { ArrowLeft, Printer, Repeat } from "lucide-react";
import Link from "next/link";
import { useEffect } from "react";

/** Barra da tela de impressão (não sai no papel). Abre a impressão sozinha logo após emitir. */
export function BarraImpressao({ voltar, repetir, automatico }: { voltar: string; repetir: string; automatico: boolean }) {
  useEffect(() => {
    if (!automatico) return;
    const t = setTimeout(() => window.print(), 600);
    return () => clearTimeout(t);
  }, [automatico]);
  return (
    <div className="sticky top-0 z-10 flex flex-wrap items-center justify-between gap-2 border-b border-borda bg-superficie/95 px-4 py-3 backdrop-blur print:hidden">
      <Link href={voltar} className="inline-flex items-center gap-1.5 text-sm text-suave hover:text-grafite">
        <ArrowLeft className="size-4" /> Voltar ao prontuário
      </Link>
      <div className="flex gap-2">
        <Link href={repetir} className="inline-flex items-center gap-1.5 rounded-lg border border-borda-forte px-3.5 py-2 text-sm hover:border-dourado">
          <Repeat className="size-4" /> Repetir receita
        </Link>
        <button
          type="button"
          onClick={() => window.print()}
          className="inline-flex items-center gap-1.5 rounded-lg bg-dourado px-4 py-2 text-sm font-medium text-white hover:bg-dourado-escuro"
        >
          <Printer className="size-4" /> Imprimir
        </button>
      </div>
    </div>
  );
}
