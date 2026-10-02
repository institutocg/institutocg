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

function daquiA(dias: number) {
  return new Date(Date.now() + dias * 86_400_000).toLocaleDateString("sv-SE", { timeZone: "America/Sao_Paulo" });
}
const br = (d: string) => `${d.slice(8, 10)}/${d.slice(5, 7)}`;
const tile = (page: Page, rotulo: string) => page.locator("dl > div").filter({ hasText: rotulo });

test("visão do mês: recebido, previsto, pendente, atrasado e vendido", async ({ page }) => {
  await entrar(page);
  await page.getByRole("navigation", { name: "Menu principal" }).getByRole("link", { name: "Financeiro" }).click();
  await expect(page.getByRole("heading", { name: "Financeiro", level: 1 })).toBeVisible();
  for (const r of ["Recebido no mês", "Previsto no mês", "Pendente", "Atrasado", "Vendido no mês"]) {
    await expect(tile(page, r)).toBeVisible();
  }
  await expect(tile(page, "Atrasado")).toContainText("R$ 800,00");
  const paulo = page.getByRole("list", { name: "Atrasados" }).getByRole("listitem", { name: "Paulo Ribeiro — R$ 800,00" });
  await expect(paulo).toContainText("Vencido há 5 dias");
  await expect(paulo).toContainText("Atrasado");
});

test("filtrar a visão financeira por procedimento", async ({ page }) => {
  await entrar(page);
  await page.goto("/financeiro");
  const quadro = page.getByRole("table", { name: "Financeiro por procedimento" });
  await expect(quadro.getByRole("row", { name: /Facetas\/lentes em resina/ })).toContainText("R$ 10.800,00"); // em aberto
  await expect(quadro.getByRole("row", { name: /Sem procedimento informado/ })).toContainText("R$ 800,00"); // atrasado (saldo anterior)

  await page.getByLabel("Procedimento", { exact: true }).selectOption({ label: "Facetas/lentes em resina" });
  await expect(page).toHaveURL(/procedimento=/);
  await expect(page.getByText("Mostrando apenas Facetas/lentes em resina.")).toBeVisible();
  await expect(tile(page, "Atrasado")).toContainText("R$ 0,00");
  await expect(page.getByText("Nenhum pagamento atrasado.")).toBeVisible();
  await expect(page.getByRole("list", { name: "Lista de negociações" }).getByRole("listitem")).toHaveCount(1);
  await expect(page.getByRole("listitem", { name: "Ana Costa — Facetas/lentes em resina" })).toBeVisible();
  await expect(quadro).toHaveCount(0);

  await page.getByRole("link", { name: "Ver todos os procedimentos" }).click();
  await expect(tile(page, "Atrasado")).toContainText("R$ 800,00");
  await quadro.getByRole("link", { name: "Facetas/lentes em resina" }).click();
  await expect(page.getByText("Mostrando apenas Facetas/lentes em resina.")).toBeVisible();
});

test("registrar negociação com entrada em data futura cria os lembretes", async ({ page }) => {
  await entrar(page);
  await page.goto("/financeiro");
  await page.getByRole("button", { name: "Registrar negociação" }).click();
  const j = page.getByRole("dialog");
  await j.getByLabel("Paciente").fill("fernanda");
  await j.getByRole("list", { name: "Pacientes encontrados" }).getByRole("button", { name: /Fernanda Lopes/ }).click();
  await j.getByLabel("Procedimento").fill("Facetas de porcelana");
  await j.getByLabel("Valor", { exact: true }).fill("5.000");
  await j.getByLabel("Valor da entrada").fill("2.000");
  await j.getByLabel("Data da entrada").fill(daquiA(9));
  await j.getByLabel("Forma da entrada").selectOption({ label: "PIX" });
  await j.getByLabel("Forma de pagamento").selectOption({ label: "Transferência" });
  await j.getByLabel("Parcelas").fill("3");
  await j.getByLabel("1º vencimento").fill(daquiA(40));
  await j.getByLabel("Observações (opcional)").fill("Combinado na consulta");
  await expect(j.getByText("Valor final R$ 5.000,00 · entrada R$ 2.000,00 · 3x de R$ 1.000,00")).toBeVisible();
  await j.getByRole("button", { name: "Registrar", exact: true }).click();
  await expect(page.getByRole("status").filter({ hasText: "Negociação registrada" })).toContainText("4 pagamentos e 4 lembretes no painel");

  const fernanda = page.getByRole("listitem", { name: "Fernanda Lopes — Facetas de porcelana" });
  await expect(fernanda).toContainText("Pendente");
  await expect(fernanda).toContainText("Entrada R$ 2.000,00 + 3x R$ 1.000,00");
  await fernanda.locator("summary").click();
  await expect(fernanda).toContainText("Observações: Combinado na consulta");
  await expect(fernanda.getByRole("listitem", { name: "Fernanda Lopes — R$ 2.000,00" })).toContainText(`Vence em ${br(daquiA(9))}`);
  await expect(fernanda.getByRole("listitem", { name: "Fernanda Lopes — R$ 2.000,00" })).toContainText("PIX");
});

test("cartão parcelado entra como pago, sem lembretes", async ({ page }) => {
  await entrar(page);
  await page.goto("/financeiro");
  await page.getByRole("button", { name: "Registrar negociação" }).click();
  const j = page.getByRole("dialog");
  await j.getByLabel("Paciente").fill("tiago");
  await j.getByRole("list", { name: "Pacientes encontrados" }).getByRole("button", { name: /Tiago Moreira/ }).click();
  await j.getByLabel("Valor", { exact: true }).fill("9.000");
  await j.getByLabel("Forma de pagamento").selectOption({ label: "Cartão parcelado" });
  await j.getByLabel("Parcelas").fill("10");
  await expect(j.getByText("Cartão é recebido na hora")).toBeVisible();
  await j.getByRole("button", { name: "Registrar", exact: true }).click();
  await expect(page.getByRole("status").filter({ hasText: "Negociação registrada e quitada." })).toBeVisible();
  await page.getByRole("navigation", { name: "Filtrar por status" }).getByRole("link", { name: "Pago", exact: true }).click();
  await expect(page.getByRole("listitem", { name: /^Tiago Moreira/ })).toContainText("Pago");
  await expect(tile(page, "Recebido no mês")).toContainText("R$ 9.000,00");
});

test("pagamento parcial e nova data combinada", async ({ page }) => {
  await entrar(page);
  await page.goto("/financeiro");
  const ana = page.getByRole("list", { name: "Previstos" }).getByRole("listitem", { name: "Ana Costa — R$ 2.700,00" }).first();
  await ana.getByRole("button", { name: "Marcar como pago" }).click();
  const j = page.getByRole("dialog", { name: "Confirmar pagamento" });
  await j.getByRole("radio", { name: "Só uma parte" }).click();
  await j.getByLabel("Valor recebido").fill("1.000");
  await j.getByRole("button", { name: "Confirmar pagamento" }).click();
  await expect(page.getByRole("status").filter({ hasText: "Pagamento parcial registrado." })).toContainText("Saldo de R$ 1.700,00");
  await expect(page.getByRole("list", { name: "Previstos" }).getByRole("listitem", { name: "Ana Costa — R$ 1.700,00" })).toContainText(
    "Parcialmente pago",
  );

  const paulo = page.getByRole("list", { name: "Atrasados" }).getByRole("listitem", { name: "Paulo Ribeiro — R$ 800,00" });
  await paulo.getByRole("button", { name: "Mudar data" }).click();
  const d = page.getByRole("dialog", { name: "Mudar a data prevista" });
  await d.getByLabel("Nova data").fill(daquiA(5));
  await d.getByLabel("Observação (opcional)").fill("Pediu para pagar na semana que vem");
  await d.getByRole("button", { name: "Salvar nova data" }).click();
  await expect(page.getByRole("status").filter({ hasText: "O lembrete acompanha." })).toBeVisible();
  await expect(page.getByText("Nenhum pagamento atrasado.")).toBeVisible();
  await expect(tile(page, "Atrasado")).toContainText("R$ 0,00");

  // No painel, o lembrete da Ana mostra o saldo.
  await page.getByRole("navigation", { name: "Menu principal" }).getByRole("link", { name: "Hoje" }).click();
  const card = page.getByRole("article", { name: "Ana Costa — R$ 1.700,00" });
  await expect(card).toContainText("Pagamento previsto");
  await expect(card.getByRole("link", { name: "Ver paciente" })).toBeVisible();
});

test("ficha do paciente: registrar negociação abre o financeiro com o paciente", async ({ page }) => {
  await entrar(page);
  await page.goto("/contatos?q=ana costa");
  await page.getByRole("link", { name: /Ana Costa/ }).click();
  await page.getByRole("link", { name: "Registrar negociação" }).click();
  await expect(page).toHaveURL(/\/financeiro\?nova=/);
  await expect(page.getByRole("dialog").getByText("Ana Costa")).toBeVisible();
});

test("celular: financeiro cabe na tela", async ({ page }) => {
  await page.setViewportSize({ width: 390, height: 844 });
  await entrar(page);
  await page.goto("/financeiro");
  const sobra = await page.evaluate(() => document.documentElement.scrollWidth - window.innerWidth);
  expect(sobra).toBeLessThanOrEqual(0);
});
