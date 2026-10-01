import { CircleCheck, Coffee } from "lucide-react";
import type { ReactNode } from "react";
import { CartaoAcao } from "@/components/painel/cartao-acao";
import { formatarDataLonga, saudacao } from "@/lib/datas";
import { carregarPainel, type Motivo } from "@/modules/painel/consultas";
import { fraseResumo, rotuloData, type Cartao, type Grupo } from "@/modules/painel/painel";
import { exigirSessao } from "@/modules/sessao/sessao";

export const metadata = { title: "Hoje · Instituto CG" };

const GRUPOS: { grupo: Grupo; titulo: string; ponto: string; vazio: string; descricao: string }[] = [
  {
    grupo: "urgente",
    titulo: "Urgente",
    ponto: "bg-urgente",
    vazio: "Nada urgente hoje.",
    descricao: "Novos contatos, retornos combinados para hoje e quem desmarcou.",
  },
  {
    grupo: "importante",
    titulo: "Importante",
    ponto: "bg-importante",
    vazio: "Nenhum follow-up importante para hoje.",
    descricao: "Follow-ups, orçamentos enviados, interessados e pagamentos do dia.",
  },
  {
    grupo: "rotina",
    titulo: "Rotina",
    ponto: "bg-rotina",
    vazio: "Nenhuma tarefa de rotina hoje.",
    descricao: "Confirmações, reativações e contatos programados.",
  },
];

export default async function PaginaHoje() {
  const sessao = await exigirSessao();
  const { painel, motivos } = await carregarPainel(sessao);
  // "Júlia Andrade" → "Júlia"; "Dra. Cristina" → "Dra. Cristina" (o título vem com o nome).
  const partes = sessao.nome.split(" ");
  const nome = /^(dra?|sra?)\.?$/i.test(partes[0]) && partes[1] ? `${partes[0]} ${partes[1]}` : partes[0];
  const nadaHoje = painel.resumo.totalHoje === 0;

  return (
    <div className="mx-auto max-w-4xl px-4 py-8 sm:px-8 lg:py-12">
      <header>
        <p className="text-sm text-suave">{maiuscula(formatarDataLonga(painel.hoje))}</p>
        <p className="mt-1 font-titulo text-3xl text-grafite sm:text-4xl">
          {saudacao()}, {nome}.
        </p>
        <p className="mt-2 text-suave">{fraseResumo(painel)}</p>
      </header>

      <section aria-labelledby="titulo-hoje" className="mt-10">
        <h1 id="titulo-hoje" className="text-xs font-semibold tracking-[0.18em] text-dourado-escuro uppercase">
          O que eu tenho que fazer hoje?
        </h1>

        {nadaHoje ? (
          <div className="mt-4 flex flex-col items-center rounded-2xl border border-borda bg-superficie px-6 py-14 text-center">
            <CircleCheck className="size-10 text-rotina" strokeWidth={1.5} />
            <p className="mt-4 font-titulo text-2xl">Tudo em dia</p>
            <p className="mt-1 max-w-sm text-sm text-suave">
              Não há nenhuma ação para hoje. Quando algo acontecer — um novo contato, uma desmarcação, um pagamento —
              a tarefa aparece aqui automaticamente.
            </p>
          </div>
        ) : (
          <div className="mt-4 space-y-8">
            {painel.atrasadas.length > 0 && (
              <Bloco
                id="atrasadas"
                titulo="Atrasadas"
                ponto="bg-urgente"
                contador={painel.atrasadas.length}
                descricao="Deveriam ter sido feitas antes. Comece por aqui."
                destaque
              >
                <Lista cartoes={painel.atrasadas} motivos={motivos} mostrarGrupo />
              </Bloco>
            )}
            {GRUPOS.map((g) => (
              <Bloco
                key={g.grupo}
                id={g.grupo}
                titulo={g.titulo}
                ponto={g.ponto}
                contador={painel.doDia[g.grupo].length}
                descricao={g.descricao}
              >
                {painel.doDia[g.grupo].length > 0 ? (
                  <Lista cartoes={painel.doDia[g.grupo]} motivos={motivos} />
                ) : (
                  <p className="rounded-xl border border-dashed border-borda px-4 py-3 text-sm text-sutil">{g.vazio}</p>
                )}
              </Bloco>
            ))}
          </div>
        )}
      </section>

      <section aria-labelledby="titulo-proximos" className="mt-14">
        <h2 id="titulo-proximos" className="text-xs font-semibold tracking-[0.18em] text-dourado-escuro uppercase">
          Próximos dias
        </h2>
        {painel.proximos.length === 0 ? (
          <div className="mt-4 flex items-center gap-3 rounded-xl border border-dashed border-borda px-4 py-3 text-sm text-sutil">
            <Coffee className="size-4" /> Nada programado para os próximos 7 dias.
          </div>
        ) : (
          <div className="mt-4 space-y-6">
            {painel.proximos.map(({ dia, cartoes }) => (
              <div key={dia}>
                <h3 className="mb-2 text-sm font-medium text-suave">
                  {maiuscula(rotuloData(dia, painel.hoje))} · {cartoes.length} {cartoes.length === 1 ? "ação" : "ações"}
                </h3>
                <Lista cartoes={cartoes} motivos={motivos} compacto mostrarGrupo />
              </div>
            ))}
          </div>
        )}
      </section>

    </div>
  );
}

function maiuscula(texto: string) {
  return texto.charAt(0).toUpperCase() + texto.slice(1);
}

function Bloco({
  id,
  titulo,
  ponto,
  contador,
  descricao,
  destaque,
  children,
}: {
  id: string;
  titulo: string;
  ponto: string;
  contador: number;
  descricao: string;
  destaque?: boolean;
  children: ReactNode;
}) {
  return (
    <section
      aria-labelledby={`bloco-${id}`}
      className={destaque ? "rounded-2xl border border-urgente/25 bg-urgente-claro/60 p-3 sm:p-4" : undefined}
    >
      <div className="mb-3 flex items-baseline gap-2.5 px-1">
        <span className={`size-2.5 translate-y-[-1px] rounded-full ${ponto}`} aria-hidden />
        <h2 id={`bloco-${id}`} className="font-titulo text-2xl text-grafite">
          {titulo}
        </h2>
        <span className="text-sm text-sutil">({contador})</span>
        <p className="ml-auto hidden text-xs text-sutil md:block">{descricao}</p>
      </div>
      {children}
    </section>
  );
}

function Lista({
  cartoes,
  motivos,
  compacto,
  mostrarGrupo,
}: {
  cartoes: Cartao[];
  motivos: Motivo[];
  compacto?: boolean;
  mostrarGrupo?: boolean;
}) {
  return (
    <div className="space-y-3">
      {cartoes.map((c) => (
        <CartaoAcao key={c.id} cartao={c} motivos={motivos} compacto={compacto} mostrarGrupo={mostrarGrupo} />
      ))}
    </div>
  );
}
