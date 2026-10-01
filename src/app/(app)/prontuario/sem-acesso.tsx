import { Lock } from "lucide-react";

export function SemAcessoProntuario() {
  return (
    <div className="px-4 py-10 sm:px-8">
      <h1 className="font-titulo text-4xl">Prontuário</h1>
      <p className="mt-3 flex items-center gap-2 text-suave">
        <Lock className="size-4" /> O prontuário tem dados de saúde do paciente. Seu acesso não inclui o prontuário — fale com a administradora.
      </p>
    </div>
  );
}
