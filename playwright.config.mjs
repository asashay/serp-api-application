import { defineConfig } from "@playwright/test"

export default defineConfig({
  testDir: "./test/browser",
  use: {
    baseURL: "http://127.0.0.1:3177",
    launchOptions: process.env.CHROME_PATH ? { executablePath: process.env.CHROME_PATH } : {},
  },
  webServer: {
    command: "bin/rails server -b 127.0.0.1 -p 3177 -P tmp/pids/playwright.pid",
    url: "http://127.0.0.1:3177/up",
  },
})
