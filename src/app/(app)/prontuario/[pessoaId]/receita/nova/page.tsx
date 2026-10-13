import { ArrowLeft } from "lucide-react";
import Link from "next/link";
import { notFound } from "next/navigation";
import { z } from "zod";
import { FormularioReceita, type InicialReceita } from "@/components/prontuario/receita";
import { comoUsuaria } from "@/lib/db";
import { carregarModelosReceita, carregarPaciente, carregarReceita } from "@/modules/prontuario/servidor";
import { exigirSessao } from "@/modules/sessao/sessao";
import { SemAcessoProntuario } from "../../../sem-acesso";

export const metadata = { title: "Nova receita · Instituto CG" };

const uuid = z.uuid();

export default async function NovaReceita({
  params,
  searchParams,
}: {
  params: Promise<{ pessoaId: string }>;
  searchParams: Promise<{ consulta?: string; repetir?: string }>;
}) {
  const sessao = await exigirSessao();
  if (!sessao.podeVerProntuario) return <SemAcessoProntuario />;
  const { pessoaId } = await params;
  const busca = await searchParams;
  if (!uuid.safeParse(pessoaId).success) notFound();
  const consultaId = busca.consulta && uuid.safeParse(busca.consulta).success ? busca.consulta : "";
  const repetirId = busca.repetir && uuid.safeParse(busca.repetir).success ? busca.repetir : "";

  const d = await comoUsuaria(sessao.usuarioId, async (db) => {
    const paciente = await carregarPaciente(db, pessoaId);
    if (!paciente) return null;
    const hoje = (await db.query<{ hoje: string }>("select public.hoje_clinica($1) as hoje", [sessao.clinicaId])).rows[0].hoje;
    const profissionais = await db.query<{ id: string; nome: string; cro: string | null; usuario_id: string | null }>(
      "select id, nome, cro, usuario_id from public.profissionais where clinica_id = $1 and ativo order by criado_em",
      [sessao.clinicaId],
    );
    const daConsulta = consultaId
      ? (await db.query<{ profissional_id: string | null }>(
          "select profissional_id from public.atendimentos where id = $1 and pessoa_id = $2",
          [consultaId, pessoaId],
        )).rows[0]
      : undefined;
    const modelos = await carregarModelosReceita(db, sessao.clinicaId);
    const repetir = repetirId ? await carregarReceita(db, repetirId) : null;
    return { paciente, hoje, profissionais: profissionais.rows, daConsulta, modelos, repetir };
  });
  if (!d) notFound();

  // Quem assina: a dentista da consulta, a da última receita repetida, a ligada ao login ou a primeira.
  const padrao =
    d.daConsulta?.profissional_id ??
    (d.repetir?.pessoa_id === pessoaId ? d.repetir.profissional_id : null) ??
    d.profissionais.find((p) => p.usuario_id === sessao.usuarioId)?.id ??
    d.profissionais[0]?.id ??
    "";
  const inicial: InicialReceita | null =
    d.repetir && d.repetir.pessoa_id === pessoaId
      ? { tipo: d.repetir.tipo, vias: d.repetir.vias, itens: d.repetir.itens, orientacoes: d.repetir.orientacoes ?? "" }
      : null;

  return (
    <div className="mx-auto max-w-4xl px-4 py-8 sm:px-8 lg:py-10">
      <Link href={`/prontuario/${pessoaId}#receitas`} className="inline-flex items-center gap-1.5 text-sm text-suave hover:text-grafite">
        <ArrowLeft className="size-4" /> Prontuário de {d.paciente.nome}
      </Link>
      <header className="mt-4 mb-6">
        <p className="text-[11px] font-semibold tracking-[0.12em] text-sutil uppercase">{d.paciente.nome}</p>
        <h1 className="mt-1 font-titulo text-4xl leading-tight">{inicial ? "Repetir receita" : "Nova receita"}</h1>
      </header>
      <FormularioReceita
        pessoaId={pessoaId}
        atendimentoId={consultaId}
        profissionais={d.profissionais.map(({ id, nome, cro }) => ({ id, nome, cro }))}
        profissionalPadrao={padrao}
        hoje={d.hoje}
        modelos={d.modelos}
        inicial={inicial}
      />
    </div>
  );
}
