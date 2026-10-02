import { expect, test, type Page } from "@playwright/test";
import { recriarBanco } from "./banco";

test.describe.configure({ mode: "serial" });
test.beforeAll(recriarBanco);

async function entrar(page: Page) {
  await page.goto("/login");
  await page.getByLabel("E-mail").fill("dona@institutocg.local");
  await page.getByRole("button", { name: "Entrar" }).click();
  await page.waitForURL(/\/hoje$/);
}

test("os tipos de campanha aparecem em dois grupos", async ({ page }) => {
  await entrar(page);
  await page.goto("/campanhas");
  const vendas = page.getByRole("radiogroup", { name: "Trazer de volta" });
  const rel = page.getByRole("radiogroup", { name: "Relacionamento e cuidado" });
  for (const r of ["Avaliação que não aconteceu", "Quem se interessou por um procedimento", "Desmarcou e não remarcou", "Pacientes sem atendimento"]) {
    await expect(vendas.getByRole("radio", { name: new RegExp(r) })).toBeVisible();
  }
  for (const r of ["Tratamento pendente", "Aniversário", "Avaliação no Google e indicação", "Pacientes especiais"]) {
    await expect(rel.getByRole("radio", { name: new RegExp(r) })).toBeVisible();
  }
});

test("aniversário: parabéns programado para o dia, sem oferta", async ({ page }) => {
  await entrar(page);
  await page.goto("/campanhas");
  await page.getByRole("radio", { name: /^Aniversário/ }).click();
  await page.getByRole("button", { name: "Ver quem entra" }).click();
  const lista = page.getByRole("list", { name: "Pessoas da campanha" });
  await expect(lista).toContainText("Gabriela Rocha");
  await expect(lista).toContainText("Heitor Campos");
  await expect(page.getByText("Cada parabéns fica para o dia do aniversário")).toBeVisible();
  await page.getByLabel("Nome da campanha").fill("Parabéns do mês");
  await expect(page.getByLabel("Mensagem sugerida")).toHaveValue(/^Feliz aniversário, \{\{nome\}\}!/);
  await page.getByRole("button", { name: "Criar campanha" }).click();
  await expect(page.getByRole("status").filter({ hasText: "Campanha criada: 2 contatos programados" })).toBeVisible();
});

test("campanha de época preenche nome e mensagem e pede o procedimento", async ({ page }) => {
  await entrar(page);
  await page.goto("/campanhas");
  await page.getByRole("button", { name: /Sorriso para as festas/ }).click();
  await expect(page.getByRole("radio", { name: /Quem se interessou por um procedimento/ })).toHaveAttribute("aria-checked", "true");
  await page.getByRole("button", { name: "Ver quem entra" }).click();
  await expect(page.getByRole("alert").filter({ hasText: "Escolha o procedimento." })).toBeVisible();
  await page.getByRole("combobox", { name: /^Procedimento/ }).selectOption({ label: "Facetas de porcelana" });
  await page.getByRole("button", { name: "Ver quem entra" }).click();
  await expect(page.getByText(/pessoas? selecionadas?|Ninguém se encaixa/)).toBeVisible();
});
