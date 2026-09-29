import { defineConfig, devices } from "@playwright/test";

/**
 * Testes de tela contra o banco local (scripts/banco-local.sh) com dados
 * fictícios recriados a cada execução. Uso: npm run test:e2e
 */
const PORTA = 3100;

export default defineConfig({
  testDir: "tests/e2e",
  fullyParallel: false,
  workers: 1,
  timeout: 60_000,
  expect: { timeout: 10_000 },
  reporter: [["list"]],
  use: {
    baseURL: `http://localhost:${PORTA}`,
    locale: "pt-BR",
    timezoneId: "America/Sao_Paulo",
    launchOptions: process.env.PLAYWRIGHT_CHROMIUM ? { executablePath: process.env.PLAYWRIGHT_CHROMIUM } : {},
    ...devices["Desktop Chrome"],
    viewport: { width: 1280, height: 900 },
  },
  webServer: {
    command: `npx next dev -p ${PORTA}`,
    url: `http://localhost:${PORTA}/login`,
    reuseExistingServer: true,
    timeout: 120_000,
    env: {
      AUTH_MODO: "desenvolvimento",
      DATABASE_URL: "postgres://postgres@localhost:54330/postgres",
    },
  },
});
