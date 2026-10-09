"use client";

import Link from "next/link";
import { useActionState } from "react";
import { definirNovaSenha, type EstadoSenha } from "../senha-acoes";

const CAMPO = "mt-1.5 w-full rounded-lg border border-borda-forte bg-superficie px-3.5 py-2.5 text-grafite outline-none focus:border-dourado";

export function FormularioNovaSenha() {
  const [estado, acao, enviando] = useActionState<EstadoSenha, FormData>(definirNovaSenha, {});
  if (estado.ok) {
    return (
      <div className="mt-8 space-y-5">
        <p role="status" className="rounded-lg bg-rotina-claro px-3.5 py-3 text-sm text-rotina">{estado.ok}</p>
        <Link href="/hoje" className="block w-full rounded-lg bg-grafite px-4 py-2.5 text-center font-medium text-white hover:bg-black">
          Ir para o sistema
        </Link>
      </div>
    );
  }
  return (
    <form action={acao} className="mt-8 space-y-5">
      <label className="block">
        <span className="text-sm text-suave">Nova senha</span>
        <input name="senha" type="password" required minLength={8} autoComplete="new-password" className={CAMPO} />
        <span className="mt-1 block text-xs text-sutil">Pelo menos 8 caracteres. Use letras e números.</span>
      </label>
      <label className="block">
        <span className="text-sm text-suave">Repita a nova senha</span>
        <input name="confirmacao" type="password" required minLength={8} autoComplete="new-password" className={CAMPO} />
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
        {enviando ? "Salvando…" : "Salvar nova senha"}
      </button>
    </form>
  );
}
