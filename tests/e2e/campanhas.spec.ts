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

test("só os tipos escolhidos aparecem, em três grupos", async ({ page }) => {
  await entrar(page);
  await page.goto("/campanhas");
  const vendas = page.getByRole("radiogroup", { name: "Trazer de volta" });
  const rel = page.getByRole("radiogroup", { name: "Relacionamento e cuidado" });
  const meu = page.getByRole("radiogroup", { name: "Do seu jeito" });
  await expect(vendas.getByRole("radio")).toHaveText([/Demonstrou interesse e não fez/, /Não vem à clínica há um tempo/, /Quem fez um procedimento/]);
  await expect(rel.getByRole("radio")).toHaveText([/Aniversário \(no dia\)/, /Avaliação no Google e indicação/, /Pacientes especiais/]);
  await expect(meu.getByRole("radio")).toHaveText([/Criar a minha campanha/]);
  await expect(page.getByText("Campanhas de época")).toHaveCount(0);
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

test("interesse: o procedimento é opcional", async ({ page }) => {
  await entrar(page);
  await page.goto("/campanhas");
  await page.getByRole("radio", { name: /Demonstrou interesse e não fez/ }).click();
  await expect(page.getByRole("combobox", { name: /^Procedimento \(opcional\)/ })).toHaveValue("");
  await page.getByRole("button", { name: "Ver quem entra" }).click();
  await expect(page.getByText(/pessoas? selecionadas?|Ninguém se encaixa/)).toBeVisible();
});

test("criar a minha campanha: escreve tudo e escolhe os pacientes", async ({ page }) => {
  await entrar(page);
  await page.goto("/campanhas");
  await page.getByRole("radio", { name: /Criar a minha campanha/ }).click();
  await page.getByLabel("Nome da campanha").fill("Indique um amigo");
  await page.getByLabel("Público-alvo").fill("Pacientes que vieram mais de 3 vezes");
  await page.getByLabel("Oferta (opcional)").fill("Indique um amigo e ganhe um mimo especial.");
  await expect(page.getByText(/Prévia · .*Indique um amigo e ganhe um mimo especial\./)).toBeVisible();

  const lista = page.getByRole("list", { name: "Pacientes para escolher" });
  await expect(lista.getByRole("listitem").first()).toBeVisible();
  await expect(page.getByText("0 pacientes escolhidos")).toBeVisible();
  await expect(page.getByRole("button", { name: "Criar campanha" })).toBeDisabled();

  await page.getByLabel("Organizar por").selectOption({ label: "Mais vindas à clínica" });
  await lista.getByRole("checkbox").first().check();
  await lista.getByRole("checkbox").nth(1).check();
  await expect(page.getByText("2 pacientes escolhidos")).toBeVisible();
  await page.getByRole("button", { name: "Criar campanha" }).click();
  await expect(page.getByRole("status").filter({ hasText: "Campanha criada: 2 contatos programados" })).toBeVisible();
  await expect(page.getByText("Indique um amigo").first()).toBeVisible();
});
