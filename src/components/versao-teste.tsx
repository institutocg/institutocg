"use client";

import { FlaskConical, RotateCcw } from "lucide-react";
import Link from "next/link";
import { useState, useTransition } from "react";
import { recomecarVersaoTeste } from "@/app/(app)/configuracoes/acoes";
import { avisar } from "@/components/avisos";
import { Dialogo } from "@/components/dialogo";

export function FaixaVersaoTeste({ admin }: { admin: boolean }) {
  return (
    <div
      role="note"
      aria-label="Versão de teste"
      className="flex flex-wrap items-center justify-center gap-x-2 gap-y-1 bg-importante-claro px-4 py-2 text-center text-xs text-importante"
    >
      <FlaskConical className="size-3.5 shrink-0" aria-hidden />
      <strong className="font-semibold tracking-wide uppercase">Versão de teste</strong>
      <span>Pacientes e telefones fictícios — não cadastre dados reais e não envie mensagens aos pacientes de exemplo.</span>
      {admin && (
        <Link href="/configuracoes#versao-teste" className="font-medium underline">
          Recomeçar com dados de exemplo
        </Link>
      )}
    </div>
  );
}

export function RecomecarVersaoTeste() {
  const [aberto, setAberto] = useState(false);
  const [enviando, iniciar] = useTransition();
  return (
    <>
      <button
        type="button"
        onClick={() => setAberto(true)}
        className="inline-flex items-center gap-1.5 rounded-lg border border-importante/40 px-3.5 py-2 text-sm font-medium text-importante hover:bg-importante-claro"
      >
        <RotateCcw className="size-4" /> Recomeçar com dados de exemplo
      </button>
      <Dialogo aberto={aberto} aoFechar={() => setAberto(false)} titulo="Recomeçar a versão de teste?">
        <p className="text-sm text-suave">
          Tudo o que foi feito nos testes será apagado: pacientes cadastrados, tarefas, agenda, mensagens editadas,
          pagamentos e configurações. Os pacientes de exemplo voltam, com datas a partir de hoje. Os logins continuam os
          mesmos.
        </p>
        <div className="mt-6 flex justify-end gap-2">
          <button type="button" onClick={() => setAberto(false)} className="rounded-lg px-4 py-2 text-sm text-suave hover:bg-fundo">
            Cancelar
          </button>
          <button
            type="button"
            disabled={enviando}
            onClick={() =>
              iniciar(async () => {
                const r = await recomecarVersaoTeste();
                if (r.ok) {
                  setAberto(false);
                  avisar(r.mensagem ?? "Pronto.");
                } else avisar(r.erro, "erro");
              })
            }
            className="rounded-lg bg-importante px-4 py-2 text-sm font-medium text-white disabled:opacity-60"
          >
            {enviando ? "Recomeçando…" : "Apagar e recomeçar"}
          </button>
        </div>
      </Dialogo>
    </>
  );
}
