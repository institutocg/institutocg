import { notFound } from "next/navigation";
import { z } from "zod";
import { BarraImpressao } from "@/components/prontuario/imprimir";
import { comoUsuaria } from "@/lib/db";
import { carregarDadosReceituario, carregarReceita } from "@/modules/prontuario/servidor";
import { agruparPorUso, dataPorExtenso, USOS, type DadosReceituario, type Receita } from "@/modules/receitas/receitas";
import { exigirSessao } from "@/modules/sessao/sessao";
import { SemAcessoProntuario } from "../../../(app)/prontuario/sem-acesso";

export const metadata = { title: "Receita · Instituto CG" };

interface Paciente {
  nome: string;
  endereco: string | null;
  cidade: string | null;
}

/** Linha para preencher à mão (campos do comprador/fornecedor). */
function Linha({ rotulo }: { rotulo: string }) {
  return (
    <div className="flex items-end gap-1.5 text-[8.5pt]">
      <span className="shrink-0 text-[#6b6358]">{rotulo}</span>
      <span className="h-[5mm] flex-1 border-b border-[#bfb3a0]" />
    </div>
  );
}

function Via({
  r,
  paciente,
  dados,
  via,
}: {
  r: Receita;
  paciente: Paciente;
  dados: { clinica: string } & DadosReceituario;
  via: string | null;
}) {
  const especial = r.tipo === "controle_especial";
  const assinatura = [r.profissional_especialidade, r.profissional_cro].filter(Boolean).join(" · ");
  const contato = [dados.endereco, dados.telefone, dados.rodape].filter(Boolean).join("  ·  ");
  return (
    <section className="folha mx-auto flex min-h-[297mm] w-[210mm] flex-col bg-white px-[18mm] pt-[16mm] pb-[12mm] text-[#2b2620] shadow-[0_2px_18px_rgba(0,0,0,0.08)] print:shadow-none">
      {/* Cabeçalho */}
      <header className="flex items-end justify-between gap-6">
        <div>
          <p className="font-titulo text-[24pt] leading-none font-semibold tracking-wide">{dados.clinica}</p>
          <span className="mt-[2.5mm] block h-px w-[18mm] bg-[#b08d57]" />
          <p className="mt-[2mm] text-[8pt] tracking-[0.28em] text-[#8a6a3a] uppercase">Odontologia</p>
        </div>
        <div className="text-right text-[9pt] leading-snug">
          <p className="font-titulo text-[13pt] font-semibold">{r.profissional}</p>
          {assinatura && <p className="text-[#6b6358]">{assinatura}</p>}
        </div>
      </header>
      <div className="mt-[5mm] h-[0.6mm] bg-gradient-to-r from-[#b08d57] via-[#d9c39b] to-transparent" />

      <div className="mt-[7mm] flex items-baseline justify-between">
        <h1 className="text-[10pt] font-semibold tracking-[0.35em] text-[#8a6a3a] uppercase">
          {especial ? "Receituário de controle especial" : "Receituário"}
        </h1>
        {via && <p className="text-[8.5pt] tracking-wide text-[#6b6358] uppercase">{via}</p>}
      </div>

      {especial && (
        <div className="mt-[4mm] rounded-[1.5mm] border border-[#d9cdb8] px-[4mm] py-[2.5mm] text-[8.5pt] leading-relaxed">
          <p className="mb-[1mm] text-[7.5pt] font-semibold tracking-[0.2em] text-[#8a6a3a] uppercase">Identificação do emitente</p>
          <p>
            <strong>{r.profissional}</strong>
            {r.profissional_cro && ` · ${r.profissional_cro}`}
          </p>
          {dados.endereco && <p>{dados.endereco}</p>}
          <p>{[dados.cidade, dados.telefone].filter(Boolean).join(" · ")}</p>
        </div>
      )}

      <div className="mt-[6mm] text-[10.5pt]">
        <p>
          <span className="text-[#6b6358]">Paciente: </span>
          <strong className="font-semibold">{paciente.nome}</strong>
        </p>
        {especial && (
          <p className="mt-[1mm] text-[9.5pt]">
            <span className="text-[#6b6358]">Endereço: </span>
            {[paciente.endereco, paciente.cidade].filter(Boolean).join(" — ") || "________________________________________________"}
          </p>
        )}
      </div>

      {/* Prescrição */}
      <div className="mt-[7mm] space-y-[6mm]">
        {agruparPorUso(r.itens).map((g) => (
          <div key={g.uso}>
            <p className="font-titulo text-[12pt] text-[#8a6a3a] italic">{USOS[g.uso]}</p>
            <ol className="mt-[2.5mm] space-y-[4mm]">
              {g.itens.map((i) => (
                <li key={i.n} className="text-[10.5pt]">
                  <div className="flex items-baseline gap-[2mm]">
                    <span className="w-[5mm] shrink-0 font-semibold">{i.n}.</span>
                    <span className="font-semibold">{i.medicamento}</span>
                    <span className="mx-[1mm] flex-1 translate-y-[-1mm] border-b border-dotted border-[#bfb3a0]" />
                    <span className="shrink-0">{i.quantidade}</span>
                  </div>
                  {i.posologia && <p className="mt-[1mm] pl-[7mm] leading-snug text-[#3d372f]">{i.posologia}</p>}
                </li>
              ))}
            </ol>
          </div>
        ))}
      </div>

      {r.orientacoes && (
        <div className="mt-[7mm] border-l-2 border-[#d9c39b] pl-[4mm] text-[9.5pt] leading-snug">
          <p className="mb-[1mm] text-[7.5pt] font-semibold tracking-[0.2em] text-[#8a6a3a] uppercase">Orientações</p>
          <p className="whitespace-pre-line">{r.orientacoes}</p>
        </div>
      )}

      <div className="flex-1" />

      {/* Data e assinatura */}
      <p className="mt-[10mm] text-right text-[10pt]">
        {dados.cidade ? `${dados.cidade}, ` : ""}
        {dataPorExtenso(r.data)}.
      </p>
      <div className="mt-[16mm] ml-auto w-[75mm] text-center text-[9pt] leading-snug">
        <div className="mb-[1.5mm] border-t border-[#2b2620]" />
        <p className="font-semibold">{r.profissional}</p>
        {assinatura && <p className="text-[#6b6358]">{assinatura}</p>}
      </div>

      {especial && (
        <div className="mt-[8mm] grid grid-cols-2 gap-[4mm]">
          <div className="space-y-[2mm] rounded-[1.5mm] border border-[#d9cdb8] px-[3.5mm] py-[2.5mm]">
            <p className="text-[7.5pt] font-semibold tracking-[0.2em] text-[#8a6a3a] uppercase">Identificação do comprador</p>
            <Linha rotulo="Nome:" />
            <div className="grid grid-cols-2 gap-[2mm]">
              <Linha rotulo="RG:" />
              <Linha rotulo="Órg. emissor:" />
            </div>
            <Linha rotulo="Endereço:" />
            <div className="grid grid-cols-[2fr_1fr] gap-[2mm]">
              <Linha rotulo="Cidade:" />
              <Linha rotulo="UF:" />
            </div>
            <Linha rotulo="Telefone:" />
          </div>
          <div className="flex flex-col justify-between rounded-[1.5mm] border border-[#d9cdb8] px-[3.5mm] py-[2.5mm]">
            <p className="text-[7.5pt] font-semibold tracking-[0.2em] text-[#8a6a3a] uppercase">Identificação do fornecedor</p>
            <div className="space-y-[2mm]">
              <Linha rotulo="Data:" />
              <div className="pt-[8mm]">
                <div className="border-t border-[#bfb3a0]" />
                <p className="mt-[1mm] text-center text-[7.5pt] text-[#6b6358]">Assinatura do farmacêutico</p>
              </div>
            </div>
          </div>
        </div>
      )}

      {contato && (
        <footer className="mt-[8mm]">
          <div className="h-px bg-gradient-to-r from-transparent via-[#b08d57] to-transparent" />
          <p className="mt-[2.5mm] text-center text-[8pt] tracking-wide text-[#6b6358]">{contato}</p>
        </footer>
      )}
    </section>
  );
}

export default async function ImprimirReceita({
  params,
  searchParams,
}: {
  params: Promise<{ receitaId: string }>;
  searchParams: Promise<{ imprimir?: string }>;
}) {
  const sessao = await exigirSessao();
  if (!sessao.podeVerProntuario) return <SemAcessoProntuario />;
  const { receitaId } = await params;
  const { imprimir } = await searchParams;
  if (!z.uuid().safeParse(receitaId).success) notFound();

  const d = await comoUsuaria(sessao.usuarioId, async (db) => {
    const r = await carregarReceita(db, receitaId);
    if (!r) return null;
    const paciente = (
      await db.query<Paciente>(
        `select nome,
                nullif(concat_ws(', ', nullif(concat_ws(' ', logradouro, numero), ''), nullif(complemento, ''), nullif(bairro, '')), '') as endereco,
                nullif(concat_ws(' - ', nullif(cidade, ''), nullif(uf, '')), '') as cidade
           from public.pessoas where id = $1`,
        [r.pessoa_id],
      )
    ).rows[0];
    const dados = await carregarDadosReceituario(db, sessao.clinicaId);
    return { r, paciente, dados };
  });
  if (!d) notFound();

  const vias = d.r.vias === 2 ? ["1ª via · Farmácia", "2ª via · Paciente"] : [null];
  return (
    <div className="min-h-screen bg-[#ece7df] print:bg-white">
      <style>{`@page { size: A4; margin: 0; } @media print { .folha { break-after: page; } .folha:last-child { break-after: auto; } }`}</style>
      <BarraImpressao
        voltar={`/prontuario/${d.r.pessoa_id}#receitas`}
        repetir={`/prontuario/${d.r.pessoa_id}/receita/nova?repetir=${d.r.id}`}
        automatico={imprimir === "1"}
      />
      <div className="space-y-8 py-8 print:space-y-0 print:py-0">
        {vias.map((v, i) => (
          <Via key={i} r={d.r} paciente={d.paciente} dados={d.dados} via={v} />
        ))}
      </div>
    </div>
  );
}
