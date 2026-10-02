"use client";

import { CampoProcedimento } from "@/components/procedimento";
import { CircleCheck, LifeBuoy, Plus } from "lucide-react";
import { useState, useTransition } from "react";
import { abrirNegociacaoAcao, concluirTratamento, criarResgate } from "@/app/(app)/contatos/acoes";
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
        <CampoProcedimento
          value={procedimento}
          onChange={setProcedimento}
          sugestoes={procedimentos}
          placeholder="Ainda não definido — ou escreva"
          className="mt-1 w-full rounded-lg border border-borda-forte bg-superficie px-3 py-2 text-sm outline-none focus:border-dourado"
        />
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

/** "Concluir tratamento": a revisão fica programada (regra "Retorno após o tratamento"). */
export function ConcluirTratamento({ pessoaId, meses }: { pessoaId: string; meses: number | null }) {
  const [aberto, setAberto] = useState(false);
  const [retorno, setRetorno] = useState("");
  const [pendente, iniciar] = useTransition();
  if (!aberto) {
    return (
      <button
        type="button"
        onClick={() => setAberto(true)}
        className="inline-flex items-center gap-1.5 rounded-lg border border-borda-forte px-3.5 py-2 text-sm font-medium hover:border-dourado"
      >
        <CircleCheck className="size-4" /> Concluir tratamento
      </button>
    );
  }
  return (
    <div className="rounded-lg bg-fundo p-3">
      <p className="text-sm font-medium">Concluir tratamento</p>
      <p className="mt-1 text-xs text-suave">
        {meses
          ? `O convite para a revisão fica programado para daqui a ${meses} meses. Se preferir, escolha outra data.`
          : "Escolha quando convidar para a revisão (opcional)."}
      </p>
      <label className="mt-3 block">
        <span className="text-xs text-sutil">Data do convite de retorno</span>
        <input
          type="date"
          value={retorno}
          onChange={(e) => setRetorno(e.target.value)}
          className="mt-1 w-full rounded-lg border border-borda-forte bg-superficie px-3 py-2 text-sm outline-none focus:border-dourado"
        />
      </label>
      <div className="mt-3 flex gap-2">
        <button
          type="button"
          onClick={() => setAberto(false)}
          className="rounded-lg border border-borda-forte px-3.5 py-2 text-sm hover:border-dourado"
        >
          Cancelar
        </button>
        <button
          type="button"
          disabled={pendente}
          onClick={() =>
            iniciar(async () => {
              const r = await concluirTratamento(pessoaId, retorno || null);
              if (r.ok) {
                avisar(r.mensagem);
                setAberto(false);
              } else avisar(r.erro, "erro");
            })
          }
          className="rounded-lg bg-dourado px-3.5 py-2 text-sm font-medium text-white hover:bg-dourado-escuro disabled:opacity-50"
        >
          {pendente ? "Salvando…" : "Confirmar"}
        </button>
      </div>
    </div>
  );
}
