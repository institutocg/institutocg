import { expect, test, type Page } from "@playwright/test";
import { recriarBanco } from "./banco";

test.describe.configure({ mode: "serial" });
test.beforeAll(recriarBanco);

async function entrar(page: Page) {
  await page.goto("/login");
  await page.getByLabel("E-mail").fill("secretaria@institutocg.local");
  await page.getByRole("button", { name: "Entrar" }).click();
  await page.waitForURL(/\/hoje$/);
}

const coluna = (page: Page, nome: string) => page.getByRole("listitem", { name: nome, exact: true });
const cartao = (page: Page, nome: string) => page.getByRole("article", { name: nome, exact: true });
const janela = (page: Page) => page.getByRole("dialog");

function daquiA(dias: number) {
  return new Date(Date.now() + dias * 86_400_000).toLocaleDateString("sv-SE", { timeZone: "America/Sao_Paulo" });
}

async function mover(page: Page, nome: string, etapa: string) {
  await page.getByRole("button", { name: `Mover ${nome}` }).click();
  await janela(page).getByLabel("Etapa").selectOption({ label: etapa });
  await expect(janela(page).getByText("Sugestão do sistema").or(janela(page).getByText("Registrar valores agora")).first()).toBeVisible();
}

test("quadro com todas as etapas e cartões completos", async ({ page }) => {
  await entrar(page);
  await page.goto("/funil");
  const nomes = await page.getByRole("listitem").evaluateAll((els) => els.map((e) => e.getAttribute("aria-label")));
  expect(nomes).toEqual([
    "Novo contato", "Em contato", "Avaliação agendada", "Consulta realizada",
    "Desmarcou", "Sem resposta", "Reativação", "Fechou", "Não fechou",
  ]);

  const maria = coluna(page, "Consulta realizada").getByRole("article", { name: "Maria Silva" });
  await expect(maria.getByText("Facetas de porcelana", { exact: true })).toBeVisible();
  await expect(maria.getByText("R$ 14.000")).toBeVisible(); // valor potencial (orçamento)
  await expect(maria.getByText("1º contato")).toBeVisible();
  await expect(maria.getByText("Última interação")).toBeVisible();
  await expect(maria.getByText("Retomar com Maria depois da consulta")).toBeVisible();

  await expect(coluna(page, "Desmarcou").getByRole("article", { name: "Carla Mendes" })).toBeVisible();
  await expect(coluna(page, "Sem resposta").getByRole("article", { name: "Tiago Moreira" })).toBeVisible();
  await expect(coluna(page, "Reativação").getByRole("article", { name: "Sofia Martins" })).toBeVisible();
  await expect(coluna(page, "Fechou").getByRole("article", { name: "Ana Costa" })).toBeVisible();
  const vera = coluna(page, "Não fechou").getByRole("article", { name: "Vera Albuquerque" });
  await expect(vera.getByText("Valor alto")).toBeVisible();
  await expect(vera.getByText("Retomar conversa com Vera sobre facetas de porcelana")).toBeVisible();

  await expect(page.getByText(/negociações em andamento/)).toBeVisible();
  await expect(cartao(page, "João Lima").getByText(/Atrasada há 2 dias/)).toBeVisible();
});

test("arrastar para outra etapa: sugestão editável", async ({ page }) => {
  await entrar(page);
  await page.goto("/funil");
  await cartao(page, "Beatriz Almeida").dragTo(coluna(page, "Em contato"));
  await expect(janela(page)).toContainText("Mover para “Em contato”");
  await expect(janela(page).getByLabel("O que fazer")).toHaveValue("Conduzir Beatriz para a avaliação");
  await janela(page).getByLabel("O que fazer").fill("Ligar para Beatriz depois das 18h");
  await janela(page).getByLabel("Quando").fill(daquiA(2));
  await janela(page).getByLabel("Observação (opcional)").fill("Respondeu pelo Instagram");
  await janela(page).getByRole("button", { name: "Mover" }).click();
  await expect(page.getByRole("status").filter({ hasText: "Beatriz foi para “Em contato”" })).toContainText(
    "Próxima ação: Ligar para Beatriz depois das 18h",
  );
  const beatriz = coluna(page, "Em contato").getByRole("article", { name: "Beatriz Almeida" });
  await expect(beatriz.getByText("Ligar para Beatriz depois das 18h")).toBeVisible();
});

test("não fechou: exige motivo e agenda uma retomada leve", async ({ page }) => {
  await entrar(page);
  await page.goto("/funil");
  await mover(page, "Maria Silva", "Não fechou");
  await janela(page).getByRole("button", { name: "Mover" }).click();
  await expect(janela(page).getByRole("alert")).toHaveText("Escolha o motivo.");
  await janela(page).getByLabel("Motivo").selectOption({ label: "Valor alto" });
  await expect(janela(page).getByText(/contato leve em 30 dias/)).toBeVisible();
  await janela(page).getByRole("button", { name: "Mover" }).click();
  await expect(page.getByRole("status").filter({ hasText: "Maria foi para “Não fechou”" })).toContainText("Retomar conversa com Maria");
  await expect(coluna(page, "Não fechou").getByRole("article", { name: "Maria Silva" })).toBeVisible();

  await page.getByRole("navigation", { name: "Menu principal" }).getByRole("link", { name: "Hoje" }).click();
  await expect(page.getByRole("article", { name: "Maria Silva" })).toHaveCount(0); // nenhuma mensagem até a data
});

test("recusar a ação automática deixa o cartão sinalizado", async ({ page }) => {
  await entrar(page);
  await page.goto("/funil");
  await mover(page, "João Lima", "Consulta realizada");
  await expect(janela(page).getByText(/Regra “Saiu da consulta sem fechar”: ação em 3 dias; sem resposta, mais 2 tentativas \(após 4, 7 dias\)/)).toBeVisible();
  await janela(page).getByLabel("Criar a próxima ação").uncheck();
  await janela(page).getByRole("button", { name: "Mover" }).click();
  await expect(page.getByRole("status").filter({ hasText: "João foi para" })).toContainText("Nenhuma ação programada.");
  await expect(coluna(page, "Consulta realizada").getByRole("article", { name: "João Lima" }).getByText("Sem próxima ação")).toBeVisible();
});

test("desmarcou: contato para remarcar no dia seguinte", async ({ page }) => {
  await entrar(page);
  await page.goto("/funil");
  await mover(page, "Rafael Gomes", "Desmarcou");
  await expect(janela(page).getByLabel("O que fazer")).toHaveValue("Entrar em contato com Rafael para remarcar");
  await expect(janela(page).getByText(/Regra “Desmarcou ou faltou”: ação no dia seguinte/)).toBeVisible();
  await janela(page).getByRole("button", { name: "Mover" }).click();
  await expect(coluna(page, "Desmarcou").getByRole("article", { name: "Rafael Gomes" })).toBeVisible();
  await page.goto("/hoje");
  await expect(page.getByRole("region", { name: "Próximos dias" }).getByRole("article", { name: "Rafael Gomes" })).toContainText(
    "Entrar em contato com Rafael para remarcar",
  );
});

test("fechou: registra valores e cria os lembretes de pagamento", async ({ page }) => {
  await entrar(page);
  await page.goto("/funil");
  await mover(page, "Luiza Prado", "Fechou");
  const j = janela(page);
  await j.getByLabel("Valor do tratamento").fill("22.000");
  await j.getByLabel("Entrada").fill("2.000");
  await j.getByLabel("Parcelas").fill("4");
  await j.getByLabel("Forma de pagamento").selectOption({ label: "PIX" });
  await j.getByLabel("1º vencimento").fill(daquiA(30));
  await expect(j.getByText(/Valor final R\$ 22\.000,00 · entrada R\$ 2\.000,00 · 4x de R\$ 5\.000,00/)).toBeVisible();
  await j.getByRole("button", { name: "Mover" }).click();
  await expect(page.getByRole("status").filter({ hasText: "Luiza foi para “Fechou”" })).toContainText(
    "Parcelas e lembretes de pagamento criados.",
  );
  await coluna(page, "Fechou").getByRole("link", { name: "Luiza Prado" }).click();
  const fin = page.getByRole("region", { name: "Financeiro" });
  await expect(fin.getByRole("row", { name: /Entrada/ })).toContainText("R$ 2.000,00");
  await expect(fin.getByRole("row", { name: /4 de 4/ })).toContainText("R$ 5.000,00");
});

test("não fechou → Reativação abre uma nova negociação", async ({ page }) => {
  await entrar(page);
  await page.goto("/funil");
  await mover(page, "Vera Albuquerque", "Reativação");
  await janela(page).getByRole("button", { name: "Mover" }).click();
  await expect(coluna(page, "Reativação").getByRole("article", { name: "Vera Albuquerque" })).toBeVisible();
  await expect(coluna(page, "Não fechou").getByRole("article", { name: "Vera Albuquerque" })).toHaveCount(0);
});

test("avaliação agendada com data: confirmação automática", async ({ page }) => {
  await entrar(page);
  await page.goto("/funil");
  await mover(page, "Fernanda Lopes", "Avaliação agendada");
  await janela(page).getByLabel("Data e horário da avaliação").fill(`${daquiA(9)}T09:30`);
  await expect(janela(page).getByText("A confirmação fica marcada para a véspera (dia útil).")).toBeVisible();
  await janela(page).getByRole("button", { name: "Mover" }).click();
  await expect(janela(page).getByRole("alert")).toHaveText("Escolha a dentista.");
  await janela(page).getByLabel("Dentista").selectOption({ label: "Dra. Paula Reis" });
  await janela(page).getByRole("button", { name: "Mover" }).click();
  await expect(page.getByRole("status").filter({ hasText: "Fernanda foi para" })).toContainText("Confirmar a avaliação de Fernanda");
});

test("filtros por procedimento e nome", async ({ page }) => {
  await entrar(page);
  await page.goto("/funil");
  await page.getByLabel("Procedimento").selectOption({ label: "Implantes" });
  await page.getByRole("button", { name: "Filtrar" }).click();
  await expect(page.getByRole("article")).toHaveCount(2); // João e Tiago
  await page.goto("/funil?q=vera");
  await expect(page.getByRole("article")).toHaveCount(1);
  await page.getByRole("link", { name: "Limpar" }).click();
  await expect(page.getByRole("article").first()).toBeVisible();
});

test("toda ação automática pode ser editada ou recusada", async ({ page }) => {
  await entrar(page);
  const sofia = page.getByRole("article", { name: "Sofia Martins" });
  await sofia.getByRole("button", { name: "Editar ação" }).click();
  const j = janela(page);
  await j.getByLabel("O que fazer").fill("Convidar Sofia para a revisão anual");
  await j.getByLabel("Data").fill(daquiA(3));
  await j.getByLabel("Mensagem sugerida").fill("Olá, Sofia! Que tal marcarmos sua revisão?");
  await j.getByRole("button", { name: "Salvar" }).click();
  await expect(page.getByRole("status").filter({ hasText: "Ação atualizada." })).toBeVisible();
  const proximos = page.getByRole("region", { name: "Próximos dias" });
  await expect(proximos.getByRole("article", { name: "Sofia Martins" })).toContainText("Convidar Sofia para a revisão anual");

  await page.getByRole("article", { name: "Marcos Tavares" }).getByRole("button", { name: "Editar ação" }).click();
  await janela(page).getByRole("button", { name: "Não fazer esta ação" }).click();
  await janela(page).getByLabel("Motivo (opcional)").fill("Já conversamos pessoalmente");
  await janela(page).getByRole("button", { name: "Cancelar a ação" }).click();
  await expect(page.getByRole("status").filter({ hasText: "Ação cancelada" })).toBeVisible();
  await expect(page.getByRole("article", { name: "Marcos Tavares" })).toHaveCount(0);

  // Lembretes de pagamento não podem ser recusados (saem sozinhos ao pagar).
  await page.getByRole("article", { name: "Paulo Ribeiro — R$ 800,00" }).getByRole("button", { name: "Editar ação" }).click();
  await expect(janela(page).getByRole("button", { name: "Não fazer esta ação" })).toHaveCount(0);
  await expect(janela(page).getByLabel("Data")).toBeDisabled();
});

test("celular: o funil rola dentro do quadro, sem rolagem lateral da página", async ({ page }) => {
  await page.setViewportSize({ width: 390, height: 844 });
  await entrar(page);
  await page.goto("/funil");
  const sobra = await page.evaluate(() => document.documentElement.scrollWidth - window.innerWidth);
  expect(sobra).toBeLessThanOrEqual(0);
  await page.getByRole("button", { name: "Mover Beatriz Almeida" }).click();
  await expect(janela(page)).toBeVisible();
});
