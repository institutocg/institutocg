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

const menu = (page: Page) => page.getByRole("navigation", { name: "Menu principal" });

/** Campo do formulário pelo início do rótulo (o asterisco de obrigatório fica de fora). */
const campo = (page: Page, rotulo: string) => page.getByLabel(new RegExp(`^${rotulo}`));

test("+ Novo paciente pergunta quem é", async ({ page }) => {
  await entrar(page);
  await page.getByRole("link", { name: "Novo paciente" }).first().click();
  await expect(page.getByRole("heading", { name: "Novo paciente" })).toBeVisible();
  await expect(page.getByRole("link", { name: /Novo contato/ })).toBeVisible();
  await expect(page.getByRole("link", { name: /Paciente antigo/ })).toBeVisible();
});

test("novo contato: erros de uma vez, depois cadastro completo com tudo automático", async ({ page }) => {
  await entrar(page);
  await page.goto("/contatos/novo?tipo=novo_contato");
  await page.getByRole("button", { name: "Salvar" }).click();
  await expect(page.getByText("Informe o nome completo.")).toBeVisible();
  await expect(page.getByText("Informe o WhatsApp ou o e-mail.")).toBeVisible();
  await expect(page.getByText("Informe como conheceu a clínica.")).toBeVisible();

  await campo(page, "Nome completo").fill("Helena Duarte");
  await campo(page, "WhatsApp").fill("(11) 98765-4321");
  await campo(page, "E-mail").fill("helena@exemplo.com");
  await campo(page, "Data de nascimento").fill("1985-06-15");
  await campo(page, "Endereço").fill("Rua Oscar Freire, 100");
  await campo(page, "Cidade").fill("São Paulo");
  await campo(page, "Como conheceu").selectOption({ label: "Instagram" });
  await campo(page, "Procedimento de interesse").selectOption({ label: "Facetas de porcelana" });
  await campo(page, "Observações").fill("Casamento em março.");
  await page.getByRole("button", { name: "Salvar" }).click();

  // 1-6: lead criado, 1º contato hoje, etapa inicial, próxima ação, responsável, no funil
  await expect(page).toHaveURL(/\/contatos\/[0-9a-f-]+\?novo=1$/);
  await expect(page.getByRole("status").filter({ hasText: "Cadastro criado" })).toContainText(
    "Já está no funil em “Novo contato”. Próxima ação: Fazer o primeiro contato com Helena — hoje.",
  );
  await expect(page.getByRole("heading", { name: "Helena Duarte", level: 1 })).toBeVisible();
  await expect(page.getByText(/^Novo contato desde \d{2}\/\d{2}\/\d{4} \(Instagram\)\.$/)).toBeVisible();
  const dados = page.getByRole("region", { name: "Dados" });
  await expect(dados.getByText("Júlia Andrade")).toBeVisible(); // responsável
  await expect(dados.getByText("15/06/1985")).toBeVisible();
  await expect(page.getByRole("region", { name: "Interesse" }).getByText("Facetas de porcelana")).toBeVisible();
  await expect(page.getByRole("region", { name: "Funil" }).locator('[aria-current="step"]')).toHaveText("Novo contato");
  await expect(page.getByRole("region", { name: "Próxima ação" }).getByText("Novo contato — via Instagram, chegou hoje")).toBeVisible();
  await expect(page.getByRole("region", { name: "Próxima ação" }).getByRole("link", { name: "Abrir paciente" })).toHaveCount(0);
  await expect(page.getByRole("region", { name: "Histórico" }).getByText("Entrou no funil: Novo contato")).toBeVisible();
  await expect(page.getByRole("region", { name: "Tarefas" }).getByText("Fazer o primeiro contato com Helena")).toBeVisible();

  // aparece no funil e no painel de hoje
  await menu(page).getByRole("link", { name: "Funil" }).click();
  await expect(page.getByRole("listitem", { name: "Novo contato", exact: true }).getByRole("link", { name: "Helena Duarte" })).toBeVisible();
  await menu(page).getByRole("link", { name: "Hoje" }).click();
  await expect(page.getByRole("region", { name: "Urgente" }).getByRole("article", { name: "Helena Duarte" })).toBeVisible();
});

test("cadastro duplicado aponta o cadastro existente", async ({ page }) => {
  await entrar(page);
  await page.goto("/contatos/novo?tipo=novo_contato");
  await campo(page, "Nome completo").fill("Outra Helena");
  await campo(page, "WhatsApp").fill("11987654321");
  await campo(page, "Como conheceu").selectOption({ label: "Google" });
  await page.getByRole("button", { name: "Salvar" }).click();
  const alerta = page.getByRole("alert").filter({ hasText: "Já existe um cadastro" });
  await expect(alerta).toContainText("Helena Duarte");
  await expect(campo(page, "Nome completo")).toHaveValue("Outra Helena"); // o que foi digitado é mantido
  await alerta.getByRole("link", { name: "Abrir o cadastro existente" }).click();
  await expect(page.getByRole("heading", { name: "Helena Duarte", level: 1 })).toBeVisible();
});

test("paciente antigo: faixa de tempo, tratamentos, salvar e cadastrar o próximo", async ({ page }) => {
  await entrar(page);
  await page.goto("/contatos/novo?tipo=paciente_antigo");
  await expect(page.getByText("4 cadastrados até agora")).toBeVisible(); // Paulo, Sofia, Gabriela e Heitor (dados fictícios)
  await expect(campo(page, "Como conheceu")).toHaveCount(0); // não se pergunta para paciente antigo

  await campo(page, "Nome completo").fill("Roberto Nunes");
  await campo(page, "WhatsApp").fill("(11) 97777-1111");
  await page.getByRole("radio", { name: "1 a 2 anos" }).click();
  await page.getByRole("checkbox", { name: "Manutenção e limpeza" }).click();
  await page.getByRole("checkbox", { name: "Clareamento dental" }).click();
  await expect(page.getByRole("checkbox", { name: "Clareamento dental" })).toHaveAttribute("aria-checked", "true");
  await page.getByRole("button", { name: "Salvar e cadastrar o próximo" }).click();

  const salvo = page.getByRole("status").filter({ hasText: "foi salvo" });
  await expect(salvo).toContainText("Roberto Nunes foi salvo.");
  await expect(page.getByText("5 cadastrados até agora")).toBeVisible();
  await expect(campo(page, "Nome completo")).toHaveValue(""); // formulário limpo para o próximo

  // A ficha mostra o histórico na clínica e sugere o resgate
  await salvo.getByRole("link", { name: "Abrir ficha" }).click();
  await expect(page.getByRole("heading", { name: "Roberto Nunes", level: 1 })).toBeVisible();
  await expect(
    page.getByText("Paciente antigo, sem atendimento recente — último atendimento há 1 a 2 anos; já fez", { exact: false }),
  ).toBeVisible();
  const naClinica = page.getByRole("region", { name: "Na clínica" });
  await expect(naClinica.getByText("Há 1 a 2 anos")).toBeVisible();
  await expect(naClinica.getByText("Manutenção e limpeza")).toBeVisible();
  await expect(page.getByRole("region", { name: "Próxima ação" }).getByText("Nenhuma ação pendente.")).toBeVisible();

  await naClinica.getByRole("button", { name: "Criar tarefa de manutenção" }).click();
  await expect(page.getByRole("status").filter({ hasText: "Tarefa criada" })).toContainText("Lembrar Roberto da manutenção");
  await expect(page.getByRole("region", { name: "Próxima ação" }).getByText("Convidar para agendar a manutenção.")).toBeVisible();
  await expect(naClinica.getByText("Resgate já programado")).toBeVisible();
});

test("paciente antigo com interesse e mês lembrado abre negociação", async ({ page }) => {
  await entrar(page);
  await page.goto("/contatos/novo?tipo=paciente_antigo");
  await campo(page, "Nome completo").fill("Cláudia Reis");
  await campo(page, "E-mail").fill("claudia@exemplo.com");
  await page.getByLabel("Mês e ano do último atendimento").fill("2025-11");
  await campo(page, "Procedimento de interesse").selectOption({ label: "Clareamento dental" });
  await page.getByRole("button", { name: "Salvar e abrir ficha" }).click();
  await expect(page.getByRole("heading", { name: "Cláudia Reis", level: 1 })).toBeVisible();
  await expect(page.getByRole("region", { name: "Funil" }).locator('[aria-current="step"]')).toHaveText("Em contato");
  await expect(page.getByRole("region", { name: "Próxima ação" }).getByText("Demonstrou interesse em clareamento dental")).toBeVisible();
  await expect(page.getByRole("region", { name: "Na clínica" }).getByText("nov/2025")).toBeVisible();
});

test("editar dados", async ({ page }) => {
  await entrar(page);
  await page.goto("/contatos?q=roberto");
  await page.getByRole("link", { name: /Roberto Nunes/ }).click();
  await page.getByRole("link", { name: "Editar dados" }).click();
  await expect(campo(page, "Nome completo")).toHaveValue("Roberto Nunes");
  await expect(page.getByRole("radio", { name: "1 a 2 anos" })).toHaveAttribute("aria-checked", "true");
  await campo(page, "Cidade").fill("Santo André");
  await page.getByRole("button", { name: "Salvar alterações" }).click();
  await expect(page.getByRole("status").filter({ hasText: "Alterações salvas." })).toBeVisible();
  await expect(page.getByRole("region", { name: "Dados" }).getByText("Santo André / SP")).toBeVisible();
  await expect(page.getByRole("region", { name: "Histórico" }).getByText("Cadastrado como paciente antigo")).toBeVisible();
});

test("abrir negociação para quem não tem nenhuma em andamento", async ({ page }) => {
  await entrar(page);
  await page.goto("/contatos/novo?tipo=paciente_antigo");
  await campo(page, "Nome completo").fill("Denise Prado");
  await campo(page, "WhatsApp").fill("(11) 96666-2222");
  await page.getByRole("radio", { name: "Mais de 2 anos" }).click();
  await page.getByRole("button", { name: "Salvar e abrir ficha" }).click();
  const proxima = page.getByRole("region", { name: "Próxima ação" });
  await expect(proxima.getByText("Tem interesse em algum tratamento?")).toBeVisible();
  await proxima.getByLabel("Interesse").selectOption({ label: "Implantes" });
  await proxima.getByRole("button", { name: "Abrir negociação" }).click();
  await expect(page.getByRole("status").filter({ hasText: "Negociação aberta" })).toBeVisible();
  await expect(proxima.getByRole("article")).toContainText("Implantes");
  await expect(page.getByRole("region", { name: "Funil" }).locator('[aria-current="step"]')).toHaveText("Em contato");
});

test("lista de contatos: busca sem acento, filtros e estado vazio", async ({ page }) => {
  await entrar(page);
  await menu(page).getByRole("link", { name: "Contatos" }).click();
  await page.getByPlaceholder("Buscar por nome, telefone ou e-mail").fill("claudia");
  await page.getByRole("button", { name: "Buscar" }).click();
  await expect(page.getByRole("link", { name: /Cláudia Reis/ })).toBeVisible();
  await expect(page.getByText("1 contato para “claudia”")).toBeVisible();

  await page.goto("/contatos?q=98765");
  await expect(page.getByRole("link", { name: /Helena Duarte/ })).toBeVisible(); // busca por telefone

  await page.goto("/contatos?f=antigos");
  for (const nome of ["Roberto Nunes", "Cláudia Reis", "Paulo Ribeiro", "Sofia Martins"]) {
    await expect(page.getByRole("link", { name: new RegExp(nome) })).toBeVisible();
  }
  await expect(page.getByRole("link", { name: /Helena Duarte/ })).toHaveCount(0);

  await page.goto("/contatos?q=ninguem-com-esse-nome");
  await expect(page.getByText("Nenhum contato encontrado")).toBeVisible();
});

test("ficha com financeiro: negociação, valores e parcelas", async ({ page }) => {
  await entrar(page);
  await page.goto("/contatos?q=ana costa");
  await page.getByRole("link", { name: /Ana Costa/ }).click();
  const fin = page.getByRole("region", { name: "Financeiro" });
  await expect(fin.getByText("Negociação fechada", { exact: false })).toBeVisible();
  await expect(fin.getByText("R$ 12.000,00").first()).toBeVisible();
  await expect(fin.getByText("Total R$ 12.500,00 − desconto R$ 500,00 · Parcelado em 4x · PIX")).toBeVisible();
  await expect(fin.getByRole("row", { name: /Entrada/ })).toContainText("Paga");
  await expect(fin.getByRole("row", { name: /1 de 4/ })).toContainText("Vence hoje");
  await expect(page.getByRole("region", { name: "Próxima ação" }).getByText("Pagamento previsto hoje")).toBeVisible();
  // Paciente ativo, pagando o tratamento: não é oportunidade de resgate.
  await expect(page.getByText("Oportunidade de resgate")).toHaveCount(0);
});

test("celular: formulário e ficha cabem na tela", async ({ page }) => {
  await page.setViewportSize({ width: 390, height: 844 });
  await entrar(page);
  for (const url of ["/contatos/novo?tipo=paciente_antigo", "/contatos?f=antigos", "/funil"]) {
    await page.goto(url);
    await page.waitForLoadState("networkidle");
    const sobra = await page.evaluate(() => document.documentElement.scrollWidth - window.innerWidth);
    expect(sobra, url).toBeLessThanOrEqual(0);
  }
});
