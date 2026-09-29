import { Search } from "lucide-react";
import Link from "next/link";
import { BotaoNovoPaciente } from "@/components/menu";
import { comoUsuaria } from "@/lib/db";
import { formatarTelefone } from "@/lib/telefone";
import { FILTROS, listarContatos, type Filtro } from "@/modules/contatos/servidor";
import { rotuloData } from "@/modules/painel/painel";
import { exigirSessao } from "@/modules/sessao/sessao";

export const metadata = { title: "Contatos · Instituto CG" };

const REL: Record<string, { rotulo: string; classe: string }> = {
  lead: { rotulo: "Novo contato", classe: "bg-dourado-claro text-dourado-escuro" },
  paciente_ativo: { rotulo: "Paciente ativo", classe: "bg-rotina-claro text-rotina" },
  paciente_inativo: { rotulo: "Inativo", classe: "bg-importante-claro text-importante" },
};

export default async function Contatos({ searchParams }: { searchParams: Promise<{ q?: string; f?: string }> }) {
  const sessao = await exigirSessao();
  const { q = "", f } = await searchParams;
  const filtro: Filtro = f && f in FILTROS ? (f as Filtro) : "todos";

  const { linhas, hoje } = await comoUsuaria(sessao.usuarioId, async (db) => ({
    linhas: await listarContatos(db, sessao.clinicaId, filtro, q),
    hoje: (await db.query<{ hoje: string }>("select public.hoje_clinica($1) as hoje", [sessao.clinicaId])).rows[0].hoje,
  }));

  const link = (novoFiltro: Filtro) => {
    const p = new URLSearchParams();
    if (q) p.set("q", q);
    if (novoFiltro !== "todos") p.set("f", novoFiltro);
    const s = p.toString();
    return `/contatos${s ? `?${s}` : ""}`;
  };

  return (
    <div className="mx-auto max-w-5xl px-4 py-8 sm:px-8 lg:py-12">
      <div className="flex flex-wrap items-end justify-between gap-4">
        <div>
          <h1 className="font-titulo text-4xl">Contatos</h1>
          <p className="mt-1 text-suave">Leads e pacientes em um só lugar.</p>
        </div>
        <div className="hidden lg:block">
          <BotaoNovoPaciente compacto />
        </div>
      </div>

      <form role="search" className="mt-6 flex gap-2">
        {filtro !== "todos" && <input type="hidden" name="f" value={filtro} />}
        <label className="relative flex-1">
          <span className="sr-only">Buscar por nome, telefone ou e-mail</span>
          <Search className="pointer-events-none absolute top-1/2 left-3 size-4 -translate-y-1/2 text-sutil" />
          <input
            name="q"
            defaultValue={q}
            placeholder="Buscar por nome, telefone ou e-mail"
            className="w-full rounded-lg border border-borda-forte bg-superficie py-2.5 pr-3 pl-9 text-sm outline-none focus:border-dourado"
          />
        </label>
        <button className="rounded-lg bg-grafite px-4 text-sm font-medium text-white hover:bg-black">Buscar</button>
      </form>

      <nav aria-label="Filtros" className="mt-4 flex gap-2 overflow-x-auto pb-1">
        {(Object.keys(FILTROS) as Filtro[]).map((k) => (
          <Link
            key={k}
            href={link(k)}
            aria-current={k === filtro ? "page" : undefined}
            className={`shrink-0 rounded-full border px-3 py-1 text-sm ${
              k === filtro ? "border-dourado bg-dourado-claro font-medium text-dourado-escuro" : "border-borda bg-superficie text-suave hover:border-dourado"
            }`}
          >
            {FILTROS[k]}
          </Link>
        ))}
      </nav>

      <p className="mt-4 text-xs text-sutil">
        {linhas.length} {linhas.length === 1 ? "contato" : "contatos"}
        {q && ` para “${q}”`}
      </p>

      {linhas.length === 0 ? (
        <div className="mt-3 rounded-2xl border border-dashed border-borda-forte px-6 py-12 text-center">
          <p className="font-titulo text-2xl">Nenhum contato encontrado</p>
          <p className="mt-1 text-sm text-suave">Confira a busca ou cadastre um novo paciente.</p>
          <div className="mt-4 flex justify-center">
            <BotaoNovoPaciente compacto />
          </div>
        </div>
      ) : (
        <ul className="mt-3 divide-y divide-borda overflow-hidden rounded-2xl border border-borda bg-superficie">
          {linhas.map((l) => {
            const rel = REL[l.relacionamento];
            return (
              <li key={l.id}>
                <Link href={`/contatos/${l.id}`} className="grid gap-1 px-5 py-3.5 transition hover:bg-fundo sm:grid-cols-[1.4fr_1.2fr_1.4fr] sm:items-center sm:gap-4">
                  <div className="min-w-0">
                    <p className="truncate font-medium">{l.nome}</p>
                    <p className="text-xs text-sutil">{l.whatsapp_e164 ? formatarTelefone(l.whatsapp_e164) : "—"}</p>
                  </div>
                  <div className="flex flex-wrap items-center gap-1.5 text-sm">
                    <span className={`rounded-full px-2 py-0.5 text-xs ${rel.classe}`}>{rel.rotulo}</span>
                    {l.etapa_atual && <span className="text-xs text-suave">{l.etapa_atual}</span>}
                    {l.procedimento_interesse && <span className="text-xs text-dourado-escuro">· {l.procedimento_interesse}</span>}
                  </div>
                  <div className="text-sm">
                    {l.proxima_acao ? (
                      <>
                        <p className="truncate">{l.proxima_acao}</p>
                        <p className={`text-xs ${l.proxima_acao_em! < hoje ? "text-urgente" : "text-sutil"}`}>
                          {rotuloData(l.proxima_acao_em!, hoje)}
                        </p>
                      </>
                    ) : (
                      <p className="text-xs text-sutil">Sem próxima ação</p>
                    )}
                  </div>
                </Link>
              </li>
            );
          })}
        </ul>
      )}
    </div>
  );
}
