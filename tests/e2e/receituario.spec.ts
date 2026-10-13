import { expect, test, type Page } from "@playwright/test";
import { recriarBanco } from "./banco";

test.describe.configure({ mode: "serial" });
test.beforeAll(recriarBanco);

async function entrar(page: Page, email = "dona@institutocg.local") {
  await page.goto("/login");
  await page.getByLabel("E-mail").fill(email);
  await page.getByRole("button", { name: "Entrar" }).click();
  await page.waitForURL(/\/hoje$/);
}

async function abrirRenata(page: Page) {
  await page.goto("/prontuario?q=renata");
  await page.getByRole("list", { name: "Pacientes encontrados" }).getByRole("link", { name: /Renata Alves/ }).click();
  await expect(page.getByRole("heading", { name: "Renata Alves", level: 1 })).toBeVisible();
}

test("configurações: CRO da dentista e dados do receituário", async ({ page }) => {
  await entrar(page);
  await page.goto("/configuracoes");
  const cristina = page.getByRole("listitem", { name: "Dra. Cristina" });
  await cristina.getByPlaceholder("CRO-SP 00000").fill("CRO-SP 98765");
  await cristina.getByRole("button", { name: "Salvar" }).click();
  await expect(page.getByRole("status").filter({ hasText: "Dentista atualizada." })).toBeVisible();
  await page.getByLabel("Telefone / WhatsApp").fill("(11) 98888-7777");
  await page.getByRole("button", { name: "Salvar dados do receituário" }).click();
  await expect(page.getByRole("status").filter({ hasText: "Dados do receituário salvos." })).toBeVisible();
});

test("receita simples a partir de um modelo: emite, guarda e imprime em 2 vias", async ({ page }) => {
  await entrar(page);
  await abrirRenata(page);
  await expect(page.getByText("Nenhuma receita emitida.")).toBeVisible();
  await page.getByRole("link", { name: "Nova receita" }).first().click();
  await expect(page.getByRole("heading", { name: "Nova receita" })).toBeVisible();

  await page.getByLabel("Começar de um modelo").selectOption({ label: "Pós-extração (exemplo)" });
  const meds = page.getByRole("region", { name: "Medicamentos" });
  await expect(meds.getByRole("listitem")).toHaveCount(2);
  await meds.getByRole("button", { name: "Adicionar medicamento" }).click();
  const terceiro = meds.getByRole("listitem", { name: "Medicamento 3" });
  await terceiro.getByLabel("Medicamento e dose").fill("Amoxicilina 500 mg");
  await terceiro.getByLabel("Quantidade").fill("21 cápsulas");
  await terceiro.getByLabel("Como usar").fill("Tomar 1 cápsula de 8 em 8 horas, por 7 dias.");
  await page.getByLabel("Imprimir em 2 vias (ex.: antibiótico)").check();
  await page.getByLabel("Guardar também como modelo, para usar de novo").check();
  await page.getByLabel("Nome do modelo").fill("Extração com antibiótico");
  await page.getByRole("button", { name: "Emitir e imprimir" }).click();

  await page.waitForURL(/\/receita\/[0-9a-f-]+\?imprimir=1$/);
  const folhas = page.locator("section.folha");
  await expect(folhas).toHaveCount(2);
  await expect(folhas.first()).toContainText("1ª via · Farmácia");
  await expect(folhas.nth(1)).toContainText("2ª via · Paciente");
  const f = folhas.first();
  await expect(f).toContainText("Receituário");
  await expect(f).toContainText("Renata Alves");
  await expect(f).toContainText("Uso oral");
  await expect(f).toContainText("Uso tópico");
  await expect(f).toContainText("Amoxicilina 500 mg");
  await expect(f).toContainText("Dra. Cristina");
  await expect(f).toContainText("CRO-SP 98765");
  await expect(f).toContainText("(11) 98888-7777");
  await expect(page.getByRole("button", { name: "Imprimir" })).toBeVisible();

  await page.getByRole("link", { name: "Voltar ao prontuário" }).click();
  const lista = page.getByRole("list", { name: "Receitas emitidas" });
  await expect(lista.getByRole("listitem")).toHaveCount(1);
  await expect(lista).toContainText("Dipirona 500 mg, Digluconato de clorexidina 0,12%, Amoxicilina 500 mg");
});

test("repetir e controle especial: 2 vias com comprador e fornecedor", async ({ page }) => {
  await entrar(page);
  await abrirRenata(page);
  await page.getByRole("list", { name: "Receitas emitidas" }).getByRole("link", { name: "Repetir" }).click();
  await expect(page.getByRole("heading", { name: "Repetir receita" })).toBeVisible();
  await expect(page.getByRole("region", { name: "Medicamentos" }).getByRole("listitem")).toHaveCount(3);
  await page.getByRole("button", { name: "Tirar o medicamento 3" }).click();
  await page.getByRole("button", { name: "Tirar o medicamento 2" }).click();
  await page.getByLabel("Medicamento e dose").fill("Tramadol 50 mg");
  await page.getByRole("radio", { name: "Controle especial" }).click();
  await page.getByRole("button", { name: "Emitir e imprimir" }).click();

  await page.waitForURL(/\/receita\//);
  const folhas = page.locator("section.folha");
  await expect(folhas).toHaveCount(2);
  await expect(folhas.first()).toContainText("Receituário de controle especial");
  await expect(folhas.first()).toContainText("Identificação do emitente");
  await expect(folhas.first()).toContainText("Identificação do comprador");
  await expect(folhas.first()).toContainText("Assinatura do farmacêutico");
});

test("o modelo novo aparece; sem medicamento não emite", async ({ page }) => {
  await entrar(page);
  await abrirRenata(page);
  await page.getByRole("link", { name: "Nova receita" }).first().click();
  await expect(page.getByLabel("Começar de um modelo").locator("option", { hasText: "Extração com antibiótico" })).toHaveCount(1);
  await page.getByRole("button", { name: "Emitir e imprimir" }).click();
  await expect(page.getByRole("alert").filter({ hasText: "Inclua ao menos um medicamento." })).toBeVisible();
});

test("secretária sem acesso ao prontuário não vê receitas", async ({ page }) => {
  await entrar(page, "secretaria@institutocg.local");
  await page.goto("/prontuario");
  await expect(page.getByText(/não inclui o prontuário/)).toBeVisible();
});
