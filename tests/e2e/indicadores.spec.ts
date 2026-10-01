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

const quadro = (page: Page, rotulo: string) =>
  page.locator("dl > div").filter({ has: page.locator("dt").getByText(rotulo, { exact: true }) });

test("indicadores: leads, conversão, funil, origem, procedimentos, perdas e reativação", async ({ page }) => {
  await entrar(page);
  await page.getByRole("navigation", { name: "Menu principal" }).getByRole("link", { name: "Indicadores" }).click();
  await expect(page.getByRole("heading", { name: "Indicadores", level: 1 })).toBeVisible();
  await expect(page.getByRole("navigation", { name: "Período" }).getByRole("link", { name: "Este mês" })).toHaveAttribute("aria-current", "page");

  await page.getByRole("navigation", { name: "Período" }).getByRole("link", { name: "Últimos 90 dias" }).click();
  await expect(page).toHaveURL(/periodo=90d/);
  for (const s of ["Leads", "Conversão", "Funil", "Origem", "Procedimentos", "Perdas", "Reativação"]) {
    await expect(page.getByRole("heading", { name: s, level: 2 })).toBeVisible();
  }
  for (const r of ["Novos leads", "Convertidos", "Em negociação", "Sem resposta", "Perdidos"]) {
    await expect(quadro(page, r)).toBeVisible();
  }
  await expect(quadro(page, "Novos leads")).toContainText("11");

  const conversao = page.getByRole("list", { name: "Conversão" });
  for (const passo of ["Novos leads", "Agendaram consulta", "Chegaram à consulta", "Receberam orçamento", "Fecharam"]) {
    await expect(conversao.getByRole("listitem", { name: new RegExp(`^${passo}:`) })).toBeVisible();
  }
  await expect(page.getByRole("list", { name: "Pessoas por etapa" }).getByRole("listitem")).toHaveCount(10);

  const origem = page.getByRole("list", { name: "Leads por origem" });
  for (const o of ["Instagram", "Indicação", "Google", "WhatsApp", "Paciente antigo", "Outro"]) {
    await expect(origem.getByRole("listitem", { name: new RegExp(`^${o}:`) })).toBeVisible();
  }
  const perdas = page.getByRole("list", { name: "Perdas por motivo" });
  for (const g of ["Preço", "Desistiu", "Não respondeu", "Escolheu outro local", "Adiou", "Outro"]) {
    await expect(perdas.getByRole("listitem", { name: new RegExp(`^${g}:`) })).toBeVisible();
  }
  await expect(perdas.getByRole("listitem", { name: "Preço: 1" })).toBeVisible();
  for (const r of ["Pacientes elegíveis", "Pacientes reativados", "Responderam", "Agendaram", "Fecharam"]) {
    await expect(quadro(page, r)).toBeVisible();
  }
  // Gestão da clínica, não competição: nada de ranking de pessoas da equipe.
  await expect(page.getByRole("main")).not.toContainText(/ranking|Júlia Andrade/i);
});

test("filtro por período (datas livres) e por procedimento", async ({ page }) => {
  await entrar(page);
  await page.goto("/indicadores?periodo=90d");
  await page.getByLabel("Procedimento", { exact: true }).selectOption({ label: "Facetas de porcelana" });
  await page.getByRole("button", { name: "Aplicar" }).click();
  await expect(page).toHaveURL(/procedimento=/);
  await expect(page.getByText("apenas Facetas de porcelana")).toBeVisible();
  await expect(quadro(page, "Novos leads")).toContainText("3");

  await page.getByRole("link", { name: "Ver todos os procedimentos" }).click();
  await page.getByLabel("De", { exact: true }).fill("2020-01-01");
  await page.getByLabel("Até", { exact: true }).fill("2020-01-31");
  await page.getByRole("button", { name: "Aplicar" }).click();
  await expect(page.getByText("Período: 01 a 31 de jan de 2020")).toBeVisible();
  await expect(quadro(page, "Novos leads")).toContainText("0");
  await expect(page.getByText("Nenhum lead neste período.").first()).toBeVisible();
  await expect(page.getByText("Nenhuma perda neste período.")).toBeVisible();
});

test("celular: indicadores cabem na tela", async ({ page }) => {
  await page.setViewportSize({ width: 390, height: 844 });
  await entrar(page);
  await page.goto("/indicadores?periodo=ano");
  const sobra = await page.evaluate(() => document.documentElement.scrollWidth - window.innerWidth);
  expect(sobra).toBeLessThanOrEqual(0);
});
