import {
  AlertTriangle,
  ChevronLeft,
  ChevronRight,
  LifeBuoy,
} from "lucide-react";
import Link from "next/link";
import { z } from "zod";
import {
  CartaoConsulta,
  CartaoRecuperacao,
  NovaConsulta,
} from "@/components/agenda/agenda";
import { comoUsuaria } from "@/lib/db";
import { somarDias } from "@/lib/datas";
import {
  diasDaSemana,
  inicioDaSemana,
  rotuloDia,
} from "@/modules/agenda/agenda";
import { carregarAgenda } from "@/modules/agenda/servidor";
import { exigirSessao } from "@/modules/sessao/sessao";
import type { PacienteEncontrado } from "./acoes";

export const metadata = { title: "Agenda · Instituto CG" };

const ddmm = (d: string) => `${d.slice(8, 10)}/${d.slice(5, 7)}`;

export default async function Agenda({
  searchParams,
}: {
  searchParams: Promise<{ semana?: string; novo?: string; dentista?: string }>;
}) {
  const sessao = await exigirSessao();
  const busca = await searchParams;
  const { dados, paciente } = await comoUsuaria(
    sessao.usuarioId,
    async (db) => {
      const hoje = (
        await db.query<{ hoje: string }>(
          "select public.hoje_clinica($1) as hoje",
          [sessao.clinicaId],
        )
      ).rows[0].hoje;
      const base =
        busca.semana && /^\d{4}-\d{2}-\d{2}$/.test(busca.semana)
          ? busca.semana
          : hoje;
      const dados = await carregarAgenda(
        db,
        sessao.clinicaId,
        inicioDaSemana(base),
      );
      let paciente: PacienteEncontrado | null = null;
      if (busca.novo && z.uuid().safeParse(busca.novo).success) {
        const { rows } = await db.query<PacienteEncontrado>(
          `select id, nome, coalesce(whatsapp_e164, telefone_e164) as whatsapp, tipo_cadastro,
                procedimento_interesse_id as procedimento_id, procedimento_interesse as procedimento, etapa_atual as etapa
           from public.v_contatos where id = $1`,
          [busca.novo],
        );
        paciente = rows[0] ?? null;
      }
      return { dados: { ...dados, segunda: inicioDaSemana(base) }, paciente };
    },
  );

  const { hoje, segunda, recuperacao } = dados;
  const dentista =
    dados.profissionais.find((p) => p.id === busca.dentista) ?? null;
  const consultas = dentista
    ? dados.consultas.filter((c) => c.profissional_id === dentista.id)
    : dados.consultas;
  const variasDentistas = dados.profissionais.length > 1;
  const link = (extra: Record<string, string | undefined>) => {
    const q = new URLSearchParams(
      Object.entries({
        semana: busca.semana,
        dentista: dentista?.id,
        ...extra,
      }).filter(([, v]) => v) as [string, string][],
    );
    return `/agenda${q.size ? `?${q}` : ""}`;
  };
  const dias = diasDaSemana(segunda);
  const porDia = new Map(
    dias.map((d) => [d, consultas.filter((c) => c.dia === d)]),
  );
  const doDia = consultas.filter(
    (c) =>
      c.dia === hoje && (c.status === "agendado" || c.status === "confirmado"),
  );
  const aConfirmar = consultas.filter(
    (c) => c.status === "agendado" && c.dia >= hoje,
  ).length;
  const urgentes = recuperacao.filter((r) => r.situacao !== "acompanhando");
  const acompanhando = recuperacao.filter((r) => r.situacao === "acompanhando");

  return (
    <div className="px-4 py-8 sm:px-8 lg:py-10">
      <div className="flex flex-wrap items-end justify-between gap-4">
        <div>
          <h1 className="font-titulo text-4xl">Agenda</h1>
          <p className="mt-1 text-suave">
            Hoje: {doDia.length} {doDia.length === 1 ? "consulta" : "consultas"}{" "}
            · {aConfirmar} a confirmar na semana
            {urgentes.length > 0 && (
              <span className="text-urgente">
                {" "}
                · {urgentes.length}{" "}
                {urgentes.length === 1
                  ? "paciente a recuperar"
                  : "pacientes a recuperar"}
              </span>
            )}
          </p>
          <p className="mt-1 text-xs text-sutil">
            Clique numa consulta para confirmar, registrar presença, falta,
            desmarcação, remarcação ou cancelamento.
          </p>
        </div>
        <NovaConsulta
          hoje={hoje}
          profissionais={dados.profissionais}
          procedimentos={dados.procedimentos}
          pacienteInicial={paciente}
          dentistaInicial={dentista?.id ?? null}
        />
      </div>

      {/* Pacientes a recuperar: sempre no topo, até serem resolvidos */}
      <section aria-labelledby="recuperar" className="mt-8">
        <div className="flex flex-wrap items-baseline justify-between gap-2">
          <h2
            id="recuperar"
            className="flex items-center gap-2 font-titulo text-2xl"
          >
            <LifeBuoy className="size-5 text-urgente" /> Pacientes a recuperar
          </h2>
          {dados.recuperadas30.total > 0 && (
            <p className="text-sm text-suave">
              Últimos 30 dias: {dados.recuperadas30.recuperadas} de{" "}
              {dados.recuperadas30.total} desmarcações/faltas recuperadas
            </p>
          )}
        </div>
        <p className="text-sm text-sutil">
          Quem desmarcou, faltou ou teve a consulta cancelada. Cada um tem uma
          ação de recuperação — nenhuma desmarcação fica esquecida.
        </p>
        {urgentes.length === 0 ? (
          <p className="mt-4 rounded-xl border border-borda bg-superficie px-4 py-3 text-sm text-rotina">
            Ninguém esperando recuperação agora.
          </p>
        ) : (
          <ul
            aria-label="A recuperar"
            className="mt-4 grid gap-3 lg:grid-cols-2"
          >
            {urgentes.map((r) => (
              <CartaoRecuperacao
                key={r.agendamento_id}
                r={r}
                hoje={hoje}
                profissionais={dados.profissionais}
              />
            ))}
          </ul>
        )}
        {urgentes.some((r) => r.situacao === "sem_acao") && (
          <p
            role="alert"
            className="mt-3 flex items-center gap-2 text-sm text-urgente"
          >
            <AlertTriangle className="size-4" /> Há desmarcações sem ação. A
            rotina diária cria a recuperação; você também pode remarcar agora.
          </p>
        )}
        {acompanhando.length > 0 && (
          <details className="mt-4">
            <summary className="cursor-pointer text-sm text-dourado-escuro">
              Em acompanhamento ({acompanhando.length}): já houve contato e há
              uma próxima ação
            </summary>
            <ul
              aria-label="Em acompanhamento"
              className="mt-3 grid gap-3 lg:grid-cols-2"
            >
              {acompanhando.map((r) => (
                <CartaoRecuperacao
                  key={r.agendamento_id}
                  r={r}
                  hoje={hoje}
                  profissionais={dados.profissionais}
                />
              ))}
            </ul>
          </details>
        )}
      </section>

      {/* Semana */}
      <section aria-labelledby="semana" className="mt-10">
        <div className="flex flex-wrap items-center justify-between gap-3">
          <h2 id="semana" className="font-titulo text-2xl">
            Semana de {ddmm(dias[0])} a {ddmm(dias[4])}
          </h2>
          <nav
            aria-label="Navegar entre semanas"
            className="flex items-center gap-1.5"
          >
            <Link
              href={link({ semana: somarDias(segunda, -7) })}
              className="inline-flex items-center gap-1 rounded-lg border border-borda-forte px-2.5 py-1.5 text-sm hover:border-dourado"
            >
              <ChevronLeft className="size-4" /> Anterior
            </Link>
            <Link
              href={link({ semana: undefined })}
              className="rounded-lg border border-borda-forte px-2.5 py-1.5 text-sm hover:border-dourado"
            >
              Esta semana
            </Link>
            <Link
              href={link({ semana: somarDias(segunda, 7) })}
              className="inline-flex items-center gap-1 rounded-lg border border-borda-forte px-2.5 py-1.5 text-sm hover:border-dourado"
            >
              Próxima <ChevronRight className="size-4" />
            </Link>
          </nav>
        </div>
        {variasDentistas && (
          <nav
            aria-label="Filtrar por dentista"
            className="mt-3 flex flex-wrap gap-2"
          >
            <Link
              href={link({ dentista: "" })}
              aria-current={!dentista ? "page" : undefined}
              className={`rounded-full px-3 py-1 text-sm ring-1 ${!dentista ? "bg-grafite text-white ring-grafite" : "ring-borda-forte hover:ring-dourado"}`}
            >
              Todas as dentistas
            </Link>
            {dados.profissionais.map((p) => (
              <Link
                key={p.id}
                href={link({ dentista: p.id })}
                aria-current={dentista?.id === p.id ? "page" : undefined}
                className={`inline-flex items-center gap-1.5 rounded-full px-3 py-1 text-sm ring-1 ${
                  dentista?.id === p.id
                    ? "bg-grafite text-white ring-grafite"
                    : "ring-borda-forte hover:ring-dourado"
                }`}
              >
                <span
                  className="size-2.5 rounded-full"
                  style={{ backgroundColor: p.cor }}
                  aria-hidden
                />
                {p.nome}
              </Link>
            ))}
          </nav>
        )}
        <div className="mt-4 grid gap-3 md:grid-cols-5">
          {dias.map((d) => {
            const lista = porDia.get(d) ?? [];
            return (
              <section
                key={d}
                aria-label={rotuloDia(d)}
                className={`rounded-xl border p-3 ${d === hoje ? "border-dourado bg-dourado-claro/40" : "border-borda bg-fundo"}`}
              >
                <h3 className="text-sm font-semibold capitalize">
                  {rotuloDia(d)}
                  {d === hoje && (
                    <span className="ml-1.5 text-xs font-normal text-dourado-escuro">
                      hoje
                    </span>
                  )}
                </h3>
                {lista.length === 0 ? (
                  <p className="mt-2 text-xs text-sutil">Nenhuma consulta.</p>
                ) : (
                  <div className="mt-2 grid gap-2">
                    {lista.map((c) => (
                      <CartaoConsulta
                        key={c.id}
                        consulta={c}
                        hoje={hoje}
                        motivos={dados.motivos}
                        profissionais={dados.profissionais}
                        mostrarDentista={variasDentistas && !dentista}
                      />
                    ))}
                  </div>
                )}
              </section>
            );
          })}
        </div>
      </section>
    </div>
  );
}
