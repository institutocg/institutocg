import Link from "next/link";
import { comoUsuaria } from "@/lib/db";
import { formatarMoedaCompacta } from "@/lib/moeda";
import { carregarFunil } from "@/modules/contatos/servidor";
import { rotuloData } from "@/modules/painel/painel";
import { exigirSessao } from "@/modules/sessao/sessao";

export const metadata = { title: "Funil · Instituto CG" };

export default async function Funil() {
  const sessao = await exigirSessao();
  const { etapas, cartoes, hoje } = await comoUsuaria(sessao.usuarioId, async (db) => ({
    ...(await carregarFunil(db, sessao.clinicaId)),
    hoje: (await db.query<{ hoje: string }>("select public.hoje_clinica($1) as hoje", [sessao.clinicaId])).rows[0].hoje,
  }));

  return (
    <div className="px-4 py-8 sm:px-8 lg:py-12">
      <h1 className="font-titulo text-4xl">Funil</h1>
      <p className="mt-1 text-suave">
        {cartoes.length} {cartoes.length === 1 ? "negociação em andamento" : "negociações em andamento"}. Clique em um cartão para abrir a ficha.
      </p>

      <div className="mt-8 flex gap-4 overflow-x-auto pb-4">
        {etapas.map((e) => {
          const daEtapa = cartoes.filter((c) => c.etapa_id === e.id);
          const total = daEtapa.reduce((s, c) => s + (c.valor_estimado_centavos ?? 0), 0);
          const pausada = e.tipo !== "aberta";
          return (
            <section
              key={e.id}
              aria-label={e.nome}
              className={`flex w-64 shrink-0 flex-col rounded-2xl border border-borda ${pausada ? "bg-fundo" : "bg-superficie/60"}`}
            >
              <header className="border-b border-borda px-4 py-3">
                <div className="flex items-center gap-2">
                  <span className="size-2.5 rounded-full" style={{ background: e.cor }} aria-hidden />
                  <h2 className="text-sm font-semibold">{e.nome}</h2>
                  <span className="ml-auto text-xs text-sutil">{daEtapa.length}</span>
                </div>
                {total > 0 && <p className="mt-0.5 text-xs text-sutil">{formatarMoedaCompacta(total)} estimados</p>}
              </header>
              <div className="flex-1 space-y-2 p-2.5">
                {daEtapa.length === 0 && <p className="px-2 py-3 text-center text-xs text-sutil">Vazio</p>}
                {daEtapa.map((c) => {
                  const parado = c.sla_dias !== null && c.dias_na_etapa > c.sla_dias;
                  return (
                    <Link
                      key={c.id}
                      href={`/contatos/${c.pessoa_id}`}
                      className={`block rounded-xl border bg-superficie p-3 text-sm transition hover:border-dourado hover:shadow-sm ${
                        parado ? "border-importante/50" : "border-borda"
                      }`}
                    >
                      <p className="font-medium">{c.nome}</p>
                      {c.procedimento && <p className="text-xs text-dourado-escuro">{c.procedimento}</p>}
                      <p className={`mt-1 text-xs ${parado ? "text-importante" : "text-sutil"}`}>
                        {c.dias_na_etapa === 0 ? "Entrou hoje" : `Há ${c.dias_na_etapa} ${c.dias_na_etapa === 1 ? "dia" : "dias"} nesta etapa`}
                        {c.valor_estimado_centavos ? ` · ${formatarMoedaCompacta(c.valor_estimado_centavos)}` : ""}
                      </p>
                      {c.proxima_acao && (
                        <p className="mt-2 border-t border-borda pt-2 text-xs text-suave">
                          → {c.proxima_acao}
                          <span className={c.proxima_acao_em! < hoje ? " text-urgente" : ""}> · {rotuloData(c.proxima_acao_em!, hoje).toLowerCase()}</span>
                        </p>
                      )}
                    </Link>
                  );
                })}
              </div>
            </section>
          );
        })}
      </div>
    </div>
  );
}
