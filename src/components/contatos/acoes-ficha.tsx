"use client";

import { LifeBuoy, Plus } from "lucide-react";
import { useState, useTransition } from "react";
import { abrirNegociacaoAcao, criarResgate } from "@/app/(app)/contatos/acoes";
import { avisar } from "@/components/avisos";

export function BotaoResgate({ pessoaId, rotulo }: { pessoaId: string; rotulo: string }) {
  const [pendente, iniciar] = useTransition();
  return (
    <button
      type="button"
      disabled={pendente}
      onClick={() =>
        iniciar(async () => {
          const r = await criarResgate(pessoaId);
          if (r.ok) avisar(r.mensagem);
          else avisar(r.erro, "erro");
        })
      }
      className="inline-flex items-center gap-1.5 rounded-lg bg-dourado px-3.5 py-2 text-sm font-medium text-white hover:bg-dourado-escuro disabled:opacity-50"
    >
      <LifeBuoy className="size-4" /> {pendente ? "Criando…" : rotulo}
    </button>
  );
}

export function AbrirNegociacao({
  pessoaId,
  procedimentos,
}: {
  pessoaId: string;
  procedimentos: { id: string; nome: string }[];
}) {
  const [procedimento, setProcedimento] = useState("");
  const [pendente, iniciar] = useTransition();
  return (
    <div className="flex flex-wrap items-end gap-2">
      <label className="min-w-48 flex-1">
        <span className="text-xs text-sutil">Interesse</span>
        <select
          value={procedimento}
          onChange={(e) => setProcedimento(e.target.value)}
          className="mt-1 w-full rounded-lg border border-borda-forte bg-superficie px-3 py-2 text-sm outline-none focus:border-dourado"
        >
          <option value="">Ainda não definido</option>
          {procedimentos.map((p) => (
            <option key={p.id} value={p.id}>
              {p.nome}
            </option>
          ))}
        </select>
      </label>
      <button
        type="button"
        disabled={pendente}
        onClick={() =>
          iniciar(async () => {
            const r = await abrirNegociacaoAcao(pessoaId, procedimento || null);
            if (r.ok) avisar(r.mensagem);
            else avisar(r.erro, "erro");
          })
        }
        className="inline-flex items-center gap-1.5 rounded-lg border border-borda-forte px-3.5 py-2 text-sm font-medium hover:border-dourado disabled:opacity-50"
      >
        <Plus className="size-4" /> {pendente ? "Abrindo…" : "Abrir negociação"}
      </button>
    </div>
  );
}
