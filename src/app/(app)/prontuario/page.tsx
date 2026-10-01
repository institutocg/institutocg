import { ChevronRight, Search } from "lucide-react";
import Link from "next/link";
import { BotaoAbrirProntuario } from "@/components/prontuario/plano";
import { comoUsuaria } from "@/lib/db";
import { exigirSessao } from "@/modules/sessao/sessao";
import { SemAcessoProntuario } from "./sem-acesso";

export const metadata = { title: "Prontuário · Instituto CG" };

const br = (d: string) => d.split("-").reverse().join("/");
const TIPO: Record<string, string> = {
  avaliacao: "Avaliação",
  apresentacao_orcamento: "Retorno para decisão",
  procedimento: "Procedimento",
  retorno: "Retorno",
  manutencao: "Manutenção",
};

export default async function Prontuarios({ searchParams }: { searchParams: Promise<{ q?: string }> }) {
  const sessao = await exigirSessao();
  if (!sessao.podeVerProntuario) return <SemAcessoProntuario />;
  const q = ((await searchParams).q ?? "").trim().slice(0, 60);

  const d = await comoUsuaria(sessao.usuarioId, async (db) => {
    const achados =
      q.length >= 2
        ? (await db.query<{ id: string; nome: string; procedimento: string | null }>("select id, nome, procedimento from public.buscar_pacientes($1, $2)", [sessao.clinicaId, q]))
            .rows
        : [];
    const hoje = await db.query<{ id: string; pessoa_id: string; pessoa_nome: string; horario: string; tipo: string; procedimento: string | null; profissional: string | null; status: string; ficha: string | null }>(
      `select g.id, g.pessoa_id, g.pessoa_nome, g.horario, g.tipo, g.procedimento, g.profissional, g.status,
              (select a.id from public.atendimentos a where a.agendamento_id = g.id) as ficha
         from public.v_agenda g
        where g.clinica_id = $1 and g.dia = public.hoje_clinica($1) and g.status in ('agendado', 'confirmado', 'compareceu')
        order by g.horario`,
      [sessao.clinicaId],
    );
    const recentes = await db.query<{ id: string; pessoa_id: string; nome: string; numero: number; data: string; procedimento: string | null; profissional: string | null; status: string }>(
      `select a.id, a.pessoa_id, p.nome, a.numero, a.data, a.procedimento, a.profissional, a.status
         from public.v_atendimentos a join public.pessoas p on p.id = a.pessoa_id
        where a.clinica_id = $1 order by a.data desc, a.numero desc limit 15`,
      [sessao.clinicaId],
    );
    return { achados, hoje: hoje.rows, recentes: recentes.rows };
  });

  return (
    <div className="mx-auto max-w-5xl px-4 py-8 sm:px-8 lg:py-10">
      <h1 className="font-titulo text-4xl">Prontuário</h1>
      <p className="mt-1 text-suave">Um prontuário por paciente, com todas as consultas, o odontograma e o plano de tratamento.</p>

      <form action="/prontuario" className="mt-6 max-w-lg">
        <label className="block">
          <span className="text-sm text-suave">Buscar paciente</span>
          <span className="relative mt-1.5 block">
            <Search className="pointer-events-none absolute top-1/2 left-3 size-4 -translate-y-1/2 text-sutil" />
            <input
              name="q"
              defaultValue={q}
              placeholder="Nome ou telefone"
              className="w-full rounded-lg border border-borda-forte bg-superficie py-2 pr-3 pl-9 text-sm outline-none focus:border-dourado"
            />
          </span>
        </label>
      </form>
      {q.length >= 2 && (
        <ul aria-label="Pacientes encontrados" className="mt-3 max-w-lg divide-y divide-borda rounded-xl border border-borda bg-superficie">
          {d.achados.length === 0 && <li className="px-4 py-3 text-sm text-sutil">Nenhum paciente encontrado.</li>}
          {d.achados.map((p) => (
            <li key={p.id}>
              <Link href={`/prontuario/${p.id}`} className="flex items-center justify-between gap-2 px-4 py-2.5 hover:bg-fundo">
                <span>
                  <span className="font-medium">{p.nome}</span>
                  {p.procedimento && <span className="block text-xs text-sutil">{p.procedimento}</span>}
                </span>
                <ChevronRight className="size-4 text-sutil" />
              </Link>
            </li>
          ))}
        </ul>
      )}

      <section aria-labelledby="hoje" className="mt-10">
        <h2 id="hoje" className="font-titulo text-2xl">
          Consultas de hoje
        </h2>
        {d.hoje.length === 0 ? (
          <p className="mt-2 text-sm text-sutil">Nenhuma consulta na agenda hoje.</p>
        ) : (
          <ul aria-label="Consultas de hoje" className="mt-3 divide-y divide-borda rounded-xl border border-borda bg-superficie">
            {d.hoje.map((c) => (
              <li key={c.id} aria-label={`${c.horario} ${c.pessoa_nome}`} className="flex flex-wrap items-center justify-between gap-3 px-4 py-3">
                <div>
                  <p className="font-medium">
                    <span className="mr-2 text-sm tabular-nums text-suave">{c.horario}</span>
                    {c.pessoa_nome}
                  </p>
                  <p className="text-xs text-sutil">
                    {[TIPO[c.tipo] ?? c.tipo, c.procedimento, c.profissional, c.status === "compareceu" ? "compareceu" : null].filter(Boolean).join(" · ")}
                  </p>
                </div>
                <BotaoAbrirProntuario agendamentoId={c.id} />
              </li>
            ))}
          </ul>
        )}
      </section>

      <section aria-labelledby="recentes" className="mt-10">
        <h2 id="recentes" className="font-titulo text-2xl">
          Últimos atendimentos
        </h2>
        {d.recentes.length === 0 ? (
          <p className="mt-2 text-sm text-sutil">Nenhum atendimento registrado ainda.</p>
        ) : (
          <ul aria-label="Últimos atendimentos" className="mt-3 divide-y divide-borda rounded-xl border border-borda bg-superficie">
            {d.recentes.map((a) => (
              <li key={a.id}>
                <Link href={`/prontuario/${a.pessoa_id}/consulta/${a.id}`} className="flex items-center justify-between gap-3 px-4 py-2.5 hover:bg-fundo">
                  <span>
                    <span className="font-medium">{a.nome}</span>
                    <span className="block text-xs text-sutil">
                      Consulta {String(a.numero).padStart(2, "0")} · {br(a.data)}
                      {a.procedimento ? ` · ${a.procedimento}` : ""}
                      {a.profissional ? ` · ${a.profissional}` : ""}
                      {a.status === "em_andamento" ? " · em andamento" : ""}
                    </span>
                  </span>
                  <ChevronRight className="size-4 text-sutil" />
                </Link>
              </li>
            ))}
          </ul>
        )}
      </section>
    </div>
  );
}
