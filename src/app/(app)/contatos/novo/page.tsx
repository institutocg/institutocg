import { ArrowLeft, CircleCheck, History, UserRoundPlus } from "lucide-react";
import Link from "next/link";
import { FormularioPaciente } from "@/components/contatos/formulario-paciente";
import { comoUsuaria } from "@/lib/db";
import { carregarOpcoes } from "@/modules/contatos/servidor";
import { exigirSessao } from "@/modules/sessao/sessao";
import { salvarCadastro } from "../acoes";

export const metadata = { title: "Novo paciente · Instituto CG" };

type Tipo = "novo_contato" | "paciente_antigo";

export default async function NovoPaciente({
  searchParams,
}: {
  searchParams: Promise<{ tipo?: string; salvo?: string; id?: string }>;
}) {
  const sessao = await exigirSessao();
  const busca = await searchParams;
  const tipo: Tipo | null =
    busca.tipo === "novo_contato" || busca.tipo === "paciente_antigo" ? busca.tipo : null;

  if (!tipo) {
    return (
      <div className="mx-auto max-w-3xl px-4 py-8 sm:px-8 lg:py-12">
        <Voltar />
        <h1 className="mt-6 font-titulo text-4xl">Novo paciente</h1>
        <p className="mt-2 text-suave">Quem é?</p>
        <div className="mt-8 grid gap-4 sm:grid-cols-2">
          <Escolha
            href="/contatos/novo?tipo=novo_contato"
            icone={<UserRoundPlus className="size-7" strokeWidth={1.5} />}
            titulo="Novo contato"
            texto="Alguém que está conhecendo a clínica agora: mandou mensagem, ligou, veio por indicação ou anúncio."
          />
          <Escolha
            href="/contatos/novo?tipo=paciente_antigo"
            icone={<History className="size-7" strokeWidth={1.5} />}
            titulo="Paciente antigo"
            texto="Alguém que já foi atendido na clínica. Registre o último atendimento e o que já fez para podermos resgatá-lo."
          />
        </div>
      </div>
    );
  }

  const { opcoes, antigos } = await comoUsuaria(sessao.usuarioId, async (db) => ({
    opcoes: await carregarOpcoes(db, sessao.clinicaId),
    antigos: Number(
      (await db.query<{ n: string }>("select count(*) as n from public.pessoas where tipo_cadastro = 'paciente_antigo'")).rows[0].n,
    ),
  }));

  return (
    <div className="mx-auto max-w-3xl px-4 py-8 sm:px-8 lg:py-12">
      <Link href="/contatos/novo" className="inline-flex items-center gap-1.5 text-sm text-suave hover:text-grafite">
        <ArrowLeft className="size-4" /> Trocar tipo de cadastro
      </Link>
      <h1 className="mt-6 font-titulo text-4xl">{tipo === "novo_contato" ? "Novo contato" : "Paciente antigo"}</h1>
      <p className="mt-2 text-suave">
        {tipo === "novo_contato"
          ? "Depois de salvar, o sistema cria a tarefa de primeiro contato e coloca a pessoa no funil."
          : `Recadastramento de pacientes antigos · ${antigos} ${antigos === 1 ? "cadastrado" : "cadastrados"} até agora.`}
      </p>

      {busca.salvo && (
        <div role="status" className="mt-6 flex items-center gap-3 rounded-xl border border-rotina/30 bg-rotina-claro px-4 py-3 text-sm">
          <CircleCheck className="size-4 shrink-0 text-rotina" />
          <p>
            <strong>{busca.salvo}</strong> foi salvo.{" "}
            {busca.id && (
              <Link href={`/contatos/${busca.id}`} className="text-dourado-escuro underline underline-offset-4">
                Abrir ficha
              </Link>
            )}{" "}
            Pode cadastrar o próximo.
          </p>
        </div>
      )}

      <div className="mt-8">
        <FormularioPaciente
          key={busca.id ?? "novo"}
          tipo={tipo}
          modo="novo"
          opcoes={opcoes}
          acao={salvarCadastro}
          usuarioId={sessao.usuarioId}
          cancelarHref="/contatos"
        />
      </div>
    </div>
  );
}

function Voltar() {
  return (
    <Link href="/contatos" className="inline-flex items-center gap-1.5 text-sm text-suave hover:text-grafite">
      <ArrowLeft className="size-4" /> Contatos
    </Link>
  );
}

function Escolha({ href, icone, titulo, texto }: { href: string; icone: React.ReactNode; titulo: string; texto: string }) {
  return (
    <Link
      href={href}
      className="group rounded-2xl border border-borda bg-superficie p-6 transition hover:border-dourado hover:shadow-sm"
    >
      <span className="text-dourado">{icone}</span>
      <h2 className="mt-4 font-titulo text-2xl group-hover:text-dourado-escuro">{titulo}</h2>
      <p className="mt-2 text-sm text-suave">{texto}</p>
    </Link>
  );
}
