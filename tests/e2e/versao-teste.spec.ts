import { expect, test, type Page } from "@playwright/test";
import { recriarBanco } from "./banco";

test.describe.configure({ mode: "serial" });
test.beforeAll(recriarBanco);

async function entrar(page: Page, email: string) {
  await page.goto("/login");
  await expect(page.getByText("Versão de teste", { exact: false }).first()).toBeVisible();
  await page.getByLabel("E-mail").fill(email);
  await page.getByRole("button", { name: "Entrar" }).click();
  await page.waitForURL(/\/hoje$/);
}

test("faixa de versão de teste em todas as telas", async ({ page }) => {
  await entrar(page, "secretaria@institutocg.local");
  const faixa = page.getByRole("note", { name: "Versão de teste" });
  await expect(faixa).toContainText("Pacientes e telefones fictícios");
  await expect(faixa.getByRole("link", { name: "Recomeçar com dados de exemplo" })).toHaveCount(0);
  await page.goto("/contatos?q=maria silva");
  await page.getByRole("link", { name: /Maria Silva/ }).click();
  await expect(faixa).toBeVisible();
  await page.goto("/configuracoes");
  await expect(page.getByText("Somente a administradora pode recomeçar os dados de exemplo.")).toBeVisible();
});

test("administradora recomeça com os dados de exemplo", async ({ page }) => {
  await entrar(page, "dona@institutocg.local");
  await page.goto("/contatos/novo?tipo=novo_contato");
  await page.getByLabel(/^Nome completo/).fill("Paciente Criada no Teste");
  await page.getByLabel(/^WhatsApp/).fill("(11) 95555-0000");
  await page.getByLabel(/^Como conheceu/).selectOption({ label: "Google" });
  await page.getByRole("button", { name: "Salvar" }).click();
  await expect(page).toHaveURL(/\/contatos\/[0-9a-f-]+\?novo=1$/);
  await page.goto("/contatos?q=paciente criada");
  await expect(page.getByRole("link", { name: /Paciente Criada no Teste/ })).toBeVisible();

  await page.getByRole("note", { name: "Versão de teste" }).getByRole("link", { name: "Recomeçar com dados de exemplo" }).click();
  await expect(page).toHaveURL(/\/configuracoes#versao-teste$/);
  await page.getByRole("button", { name: "Recomeçar com dados de exemplo" }).click();
  const janela = page.getByRole("dialog", { name: "Recomeçar a versão de teste?" });
  await expect(janela).toContainText("Os logins continuam os mesmos");
  await janela.getByRole("button", { name: "Apagar e recomeçar" }).click();
  await expect(page.getByRole("status").filter({ hasText: "dados de exemplo foram recriados" })).toBeVisible();

  await page.goto("/contatos?q=paciente criada");
  await expect(page.getByRole("link", { name: /Paciente Criada no Teste/ })).toHaveCount(0);
  await page.goto("/contatos?q=beatriz");
  await expect(page.getByRole("link", { name: /Beatriz Almeida/ })).toBeVisible();
  await page.goto("/hoje");
  await expect(page.getByRole("article").first()).toBeVisible();
});
