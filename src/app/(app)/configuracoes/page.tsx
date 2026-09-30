import { Lock } from "lucide-react";
import {
  EditarLimites,
  EditarRegra,
} from "@/components/configuracoes/editar-regra";
import { comoUsuaria } from "@/lib/db";
import {
  AUTOMATICAS,
  descreverRegra,
  exemplo,
  GRUPOS,
  ROTULO_PRIORIDADE,
  type Regra,
} from "@/modules/regras/regras";
import { carregarRegras } from "@/modules/regras/servidor";
import { Dentistas, type Dentista } from "@/components/configuracoes/dentistas";
import { exigirSessao } from "@/modules/sessao/sessao";

export const metadata = { title: "Configurações · Instituto CG" };

export default async function Configuracoes() {
  const sessao = await exigirSessao();
  const admin = sessao.papel === "admin";
  const { regras, limites, dentistas } = await comoUsuaria(sessao.usuarioId, async (db) => {
    const r = await carregarRegras(db, sessao.clinicaId);
    const d = await db.query<Dentista>(
      `select p.id, p.nome, p.cor, p.ativo,
              (select count(*)::int from public.agendamentos a
                where a.profissional_id = p.id and a.status in ('agendado', 'confirmado') and a.inicio >= now()) as consultas_futuras
         from public.profissionais p where p.clinica_id = $1 order by p.ativo desc, p.criado_em`,
      [sessao.clinicaId],
    );
    return { ...r, dentistas: d.rows };
  });
  const porSituacao = new Map(regras.map((r) => [r.situacao, r]));

  return (
    <div className="mx-auto max-w-5xl px-4 py-8 sm:px-8 lg:py-10">
      <h1 className="font-titulo text-4xl">Configurações</h1>
      <p className="mt-1 max-w-2xl text-suave">
        Regras de follow-up: para cada situação, o sistema sabe o que fazer,
        quando e com qual mensagem. Nenhuma mensagem é enviada sozinha — o CRM
        sugere, e você decide quando enviar.
      </p>
      {!admin && (
        <p className="mt-4 flex items-center gap-2 rounded-lg bg-fundo px-3.5 py-2.5 text-sm text-suave">
          <Lock className="size-4" /> Somente a administradora altera as regras.
          Você pode consultá-las aqui.
        </p>
      )}

      {GRUPOS.map((g) => (
        <section
          key={g.titulo}
          aria-labelledby={`grupo-${g.titulo}`}
          className="mt-10"
        >
          <h2 id={`grupo-${g.titulo}`} className="font-titulo text-2xl">
            {g.titulo}
          </h2>
          <p className="text-sm text-sutil">{g.descricao}</p>
          <ul className="mt-4 grid gap-3">
            {g.situacoes.map((s) => {
              const r = porSituacao.get(s);
              if (!r) return null;
              return <CartaoRegra key={r.id} regra={r} admin={admin} />;
            })}
          </ul>
        </section>
      ))}

      <details className="mt-10 rounded-xl border border-borda bg-superficie p-4 sm:p-5">
        <summary className="cursor-pointer font-medium text-dourado-escuro">
          Passos automáticos entre os casos
        </summary>
        <p className="mt-1 text-sm text-sutil">
          Funcionam sozinhos e raramente precisam de ajuste: conduzir quem
          respondeu para a avaliação, confirmar a consulta 1 dia útil antes e o
          contato de quem entra em “Reativação”.
        </p>
        <ul className="mt-4 grid gap-3">
          {AUTOMATICAS.map((s) => {
            const r = porSituacao.get(s);
            return r ? (
              <CartaoRegra key={r.id} regra={r} admin={admin} />
            ) : null;
          })}
        </ul>
      </details>

      <section aria-labelledby="dentistas" className="mt-10">
        <h2 id="dentistas" className="font-titulo text-2xl">
          Dentistas da agenda
        </h2>
        <p className="text-sm text-sutil">
          Quem atende na clínica. Cada dentista tem uma cor na agenda, e horários
          só entram em conflito com a mesma dentista.
        </p>
        <div className="mt-4 rounded-xl border border-borda bg-superficie px-4 sm:px-5">
          <Dentistas dentistas={dentistas} podeEditar={admin} />
        </div>
      </section>

      <section aria-labelledby="limites" className="mt-10">
        <h2 id="limites" className="font-titulo text-2xl">
          Limites de contato
        </h2>
        <p className="text-sm text-sutil">
          Para a clínica nunca parecer insistente.
        </p>
        <div className="mt-4 rounded-xl border border-borda bg-superficie p-4 sm:p-5">
          <EditarLimites
            limite={limites.limiteReativacaoDia}
            intervalo={limites.intervaloMinContatoDias}
            podeEditar={admin}
          />
        </div>
      </section>
    </div>
  );
}

function CartaoRegra({ regra: r, admin }: { regra: Regra; admin: boolean }) {
  return (
    <li
      aria-label={r.nome}
      className="rounded-xl border border-borda bg-superficie p-4 sm:p-5"
    >
      <div className="flex flex-wrap items-start justify-between gap-3">
        <div className="min-w-0 flex-1">
          <div className="flex flex-wrap items-center gap-2">
            <h3 className="font-semibold">{r.nome}</h3>
            <span
              className={`rounded-full px-2 py-0.5 text-[11px] font-medium ${
                r.ativa
                  ? "bg-rotina-claro text-rotina"
                  : "bg-fundo text-sutil ring-1 ring-borda"
              }`}
            >
              {r.ativa ? "Ligada" : "Desligada"}
            </span>
            {r.ativa && (
              <span className="text-xs text-sutil">
                Prioridade {ROTULO_PRIORIDADE[r.prioridade].toLowerCase()}
              </span>
            )}
          </div>
          <p className="text-xs text-sutil">{r.quando}</p>
        </div>
        {admin && <EditarRegra regra={r} />}
      </div>
      <p className="mt-2 text-sm text-grafite">
        <span className="text-suave">Tarefa:</span> {exemplo(r.titulo_modelo)}
      </p>
      <p className="mt-1 text-sm text-suave">{descreverRegra(r)}</p>
      {r.mensagem && (
        <details className="mt-2 text-sm">
          <summary className="cursor-pointer text-dourado-escuro">
            Ver mensagem sugerida
          </summary>
          <p className="mt-2 rounded-lg bg-fundo px-3.5 py-2.5 whitespace-pre-line text-suave">
            {exemplo(r.mensagem)}
          </p>
        </details>
      )}
    </li>
  );
}
