import { Lock } from "lucide-react";
import {
  BotaoEncerrar,
  NovaCampanha,
} from "@/components/campanhas/nova-campanha";
import { comoUsuaria } from "@/lib/db";
import {
  SEGMENTOS,
  taxa,
  type CampanhaResumo,
} from "@/modules/campanhas/campanhas";
import { exigirSessao } from "@/modules/sessao/sessao";

export const metadata = { title: "Campanhas · Instituto CG" };

const br = (d: string) => d.split("-").reverse().join("/");

export default async function Campanhas() {
  const sessao = await exigirSessao();
  const admin = sessao.papel === "admin";
  const dados = await comoUsuaria(sessao.usuarioId, async (db) => {
    // Uma consulta de cada vez: a conexão (transação) é compartilhada.
    const campanhas = await db.query<CampanhaResumo>(
      `select id, nome, segmento, meses, procedimento, limite_dia, inicia_em, encerrada_em, criado_em,
                pessoas::int, contatadas::int, a_contatar::int, para_hoje::int, responderam::int, agendaram::int,
                fecharam::int, primeiro_contato, ultimo_contato
           from public.v_campanhas where clinica_id = $1 order by criado_em desc`,
      [sessao.clinicaId],
    );
    const procedimentos = await db.query<{ id: string; nome: string }>(
      "select id, nome from public.procedimentos where clinica_id = $1 and ativo order by ordem, nome",
      [sessao.clinicaId],
    );
    const extra = await db.query<{ hoje: string; limite: number }>(
      `select public.hoje_clinica(id) as hoje, coalesce((configuracoes ->> 'limite_reativacao_dia')::int, 10) as limite
           from public.clinicas where id = $1`,
      [sessao.clinicaId],
    );
    return {
      campanhas: campanhas.rows,
      procedimentos: procedimentos.rows,
      ...extra.rows[0],
    };
  });

  return (
    <div className="mx-auto max-w-5xl px-4 py-8 sm:px-8 lg:py-10">
      <h1 className="font-titulo text-4xl">Campanhas</h1>
      <p className="mt-1 max-w-2xl text-suave">
        Reative pacientes antigos em lotes pequenos: o sistema distribui os
        contatos em dias úteis e sugere a mensagem. Cada envio continua sendo
        seu — nada sai sozinho pelo WhatsApp.
      </p>

      <div className="mt-8 grid gap-6 lg:grid-cols-[1fr_18rem]">
        <div>
          {admin ? (
            <NovaCampanha
              procedimentos={dados.procedimentos}
              hoje={dados.hoje}
              limitePadrao={dados.limite}
            />
          ) : (
            <p className="flex items-center gap-2 rounded-lg bg-fundo px-3.5 py-2.5 text-sm text-suave">
              <Lock className="size-4" /> Somente a administradora cria
              campanhas. Os contatos aparecem para você em “Hoje”.
            </p>
          )}
        </div>
        <aside className="rounded-xl bg-dourado-claro p-4 text-sm text-dourado-escuro sm:p-5">
          <p className="font-semibold">Boas práticas</p>
          <ul className="mt-2 list-disc space-y-1.5 pl-4">
            <li>Personalize: cite o nome e o tratamento que a pessoa fez.</li>
            <li>
              Ofereça algo concreto (uma revisão, um horário), não uma promoção
              genérica.
            </li>
            <li>Poucos contatos por dia rendem conversas melhores.</li>
            <li>
              Evite datas comemorativas lotadas; terças e quartas costumam
              responder melhor.
            </li>
            <li>
              Respeite quem não quer contato: essas pessoas nunca entram na
              lista.
            </li>
          </ul>
        </aside>
      </div>

      <section aria-labelledby="lista-campanhas" className="mt-10">
        <h2 id="lista-campanhas" className="font-titulo text-2xl">
          Campanhas criadas
        </h2>
        {dados.campanhas.length === 0 ? (
          <p className="mt-3 text-sm text-sutil">Nenhuma campanha ainda.</p>
        ) : (
          <ul className="mt-4 grid gap-3">
            {dados.campanhas.map((c) => {
              const progresso = c.pessoas
                ? Math.round((c.contatadas / c.pessoas) * 100)
                : 0;
              return (
                <li
                  key={c.id}
                  aria-label={c.nome}
                  className="rounded-xl border border-borda bg-superficie p-4 sm:p-5"
                >
                  <div className="flex flex-wrap items-start justify-between gap-3">
                    <div>
                      <div className="flex flex-wrap items-center gap-2">
                        <h3 className="font-semibold">{c.nome}</h3>
                        <span
                          className={`rounded-full px-2 py-0.5 text-[11px] font-medium ${
                            c.encerrada_em
                              ? "bg-fundo text-sutil ring-1 ring-borda"
                              : "bg-rotina-claro text-rotina"
                          }`}
                        >
                          {c.encerrada_em
                            ? "Encerrada"
                            : c.a_contatar
                              ? "Em andamento"
                              : "Concluída"}
                        </span>
                      </div>
                      <p className="text-xs text-sutil">
                        {SEGMENTOS[c.segmento].rotulo}
                        {c.procedimento ? ` · ${c.procedimento}` : ""} · há mais
                        de {c.meses} meses · até {c.limite_dia} por dia
                        {c.primeiro_contato && c.ultimo_contato
                          ? ` · ${br(c.primeiro_contato)}${c.ultimo_contato !== c.primeiro_contato ? ` a ${br(c.ultimo_contato)}` : ""}`
                          : ""}
                      </p>
                    </div>
                    {admin && !c.encerrada_em && c.a_contatar > 0 && (
                      <BotaoEncerrar id={c.id} nome={c.nome} />
                    )}
                  </div>

                  <div
                    className="mt-3 h-1.5 overflow-hidden rounded-full bg-fundo"
                    role="progressbar"
                    aria-label="Contatos feitos"
                    aria-valuemin={0}
                    aria-valuemax={100}
                    aria-valuenow={progresso}
                  >
                    <div
                      className="h-full bg-dourado"
                      style={{ width: `${progresso}%` }}
                    />
                  </div>
                  <dl className="mt-3 grid grid-cols-3 gap-3 text-sm sm:grid-cols-6">
                    {[
                      ["Pessoas", c.pessoas],
                      ["Contatadas", c.contatadas],
                      ["A contatar", c.a_contatar],
                      [
                        "Responderam",
                        `${c.responderam} (${taxa(c.responderam, c.contatadas)})`,
                      ],
                      ["Agendaram", c.agendaram],
                      ["Fecharam", c.fecharam],
                    ].map(([rotulo, valor]) => (
                      <div key={rotulo as string}>
                        <dt className="text-xs text-sutil">{rotulo}</dt>
                        <dd className="font-medium">{valor}</dd>
                      </div>
                    ))}
                  </dl>
                </li>
              );
            })}
          </ul>
        )}
      </section>
    </div>
  );
}
