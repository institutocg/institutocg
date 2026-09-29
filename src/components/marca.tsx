/** Marca provisória (o logotipo definitivo está em produção). */
export function Marca({ tamanho = "normal" }: { tamanho?: "normal" | "grande" }) {
  const grande = tamanho === "grande";
  return (
    <div className="flex flex-col leading-none">
      <span className={`font-titulo font-semibold tracking-wide text-grafite ${grande ? "text-4xl" : "text-2xl"}`}>
        Instituto CG
      </span>
      <span className={`mt-1.5 h-px bg-dourado ${grande ? "w-16" : "w-10"}`} aria-hidden />
    </div>
  );
}
