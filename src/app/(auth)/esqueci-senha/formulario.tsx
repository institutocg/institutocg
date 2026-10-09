"use client";

import { useActionState } from "react";
import { pedirNovaSenha, type EstadoSenha } from "../senha-acoes";

export function FormularioEsqueci() {
  const [estado, acao, enviando] = useActionState<EstadoSenha, FormData>(pedirNovaSenha, {});
  if (estado.ok) {
    return (
      <p role="status" className="mt-8 rounded-lg bg-rotina-claro px-3.5 py-3 text-sm text-rotina">
        {estado.ok}
      </p>
    );
  }
  return (
    <form action={acao} className="mt-8 space-y-5">
      <label className="block">
        <span className="text-sm text-suave">E-mail</span>
        <input
          name="email"
          type="email"
          required
          autoComplete="email"
          className="mt-1.5 w-full rounded-lg border border-borda-forte bg-superficie px-3.5 py-2.5 text-grafite outline-none focus:border-dourado"
        />
      </label>
      {estado.erro && (
        <p role="alert" className="rounded-lg bg-urgente-claro px-3.5 py-2.5 text-sm text-urgente">
          {estado.erro}
        </p>
      )}
      <button
        type="submit"
        disabled={enviando}
        className="w-full rounded-lg bg-grafite px-4 py-2.5 font-medium text-white transition hover:bg-black disabled:opacity-60"
      >
        {enviando ? "Enviando…" : "Enviar link"}
      </button>
    </form>
  );
}
