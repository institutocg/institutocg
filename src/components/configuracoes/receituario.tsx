"use client";

import { useState, useTransition } from "react";
import { salvarDadosReceituario } from "@/app/(app)/configuracoes/acoes";
import { avisar } from "@/components/avisos";
import type { DadosReceituario } from "@/modules/receitas/receitas";

const CAMPO =
  "mt-1.5 w-full rounded-lg border border-borda-forte bg-superficie px-3 py-2 text-sm outline-none focus:border-dourado disabled:bg-fundo";

/** Dados impressos no cabeçalho e no rodapé das receitas. */
export function DadosDoReceituario({ dados, podeEditar }: { dados: DadosReceituario; podeEditar: boolean }) {
  const [v, setV] = useState({
    endereco: dados.endereco ?? "",
    telefone: dados.telefone ?? "",
    cidade: dados.cidade ?? "",
    rodape: dados.rodape ?? "",
  });
  const [pendente, iniciar] = useTransition();
  const campo = (k: keyof typeof v, rotulo: string, exemplo: string, max: number) => (
    <label className="block">
      <span className="text-sm text-suave">{rotulo}</span>
      <input value={v[k]} disabled={!podeEditar} maxLength={max} placeholder={exemplo} onChange={(e) => setV({ ...v, [k]: e.target.value })} className={CAMPO} />
    </label>
  );
  return (
    <div className="rounded-xl border border-borda bg-superficie p-4 sm:p-5">
      <div className="grid gap-4 sm:grid-cols-2">
        {campo("endereco", "Endereço do consultório", "Rua, número, sala — bairro", 200)}
        {campo("telefone", "Telefone / WhatsApp", "(11) 0000-0000", 60)}
        {campo("cidade", "Cidade (aparece antes da data)", "São Paulo - SP", 80)}
        {campo("rodape", "Rodapé (opcional)", "Ex.: @institutocg · site", 200)}
      </div>
      {podeEditar && (
        <button
          type="button"
          disabled={pendente}
          onClick={() =>
            iniciar(async () => {
              const r = await salvarDadosReceituario(v);
              avisar(r.ok ? r.mensagem : r.erro, r.ok ? undefined : "erro");
            })
          }
          className="mt-4 rounded-lg bg-dourado px-4 py-2 text-sm font-medium text-white hover:bg-dourado-escuro disabled:opacity-50"
        >
          {pendente ? "Salvando…" : "Salvar dados do receituário"}
        </button>
      )}
    </div>
  );
}
