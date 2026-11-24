import { expect, test } from "@playwright/test"
import { readFileSync } from "node:fs"

test("shows the API response at desktop, tablet and mobile widths", async ({ page }, info) => {
  for (const width of [1440, 768, 390]) {
    await page.setViewportSize({ width, height: 900 })
    await page.goto("/")
    await expect(page.getByRole("heading", { name: "Google Search API" })).toBeVisible()
    await expect(page.getByLabel("Search query")).toHaveValue("/")
    await expect(page.getByText("Saved example", { exact: true })).toBeVisible()
    await expect(page.locator("iframe")).toHaveCount(0)
    const json = page.getByLabel("Search response JSON")
    await expect(json).toBeVisible()
    await expect(json).toContainText("Improve your spoken English with every conversation.")
    expect((await json.boundingBox()).y).toBeLessThan(900)

    await page.getByLabel("Search query").fill("a".repeat(200))
    expect(await page.evaluate(() => document.documentElement.scrollWidth)).toBe(width)
    await page.getByLabel("Search query").fill("/")
    await page.screenshot({ path: info.outputPath(`playground-${width}.png`), fullPage: true })
  }
})

test("shows the live response and keeps it when a new request fails", async ({ page }) => {
  await page.goto("/")
  const query = page.getByLabel("Search query")
  const search = page.getByRole("button", { name: "Run search" })
  await query.fill("coffee & tea")
  await expect(page.getByRole("link", { name: "Open JSON" })).toHaveAttribute("href", /\?q=coffee\+%26\+tea$/)

  let requests = 0
  await page.route("**/playground/search?*", async (route) => {
    expect(new URL(route.request().url()).searchParams.get("q")).toBe("coffee & tea")
    requests += 1
    await expect(page.getByRole("button", { name: "Searching…" })).toBeDisabled()
    if (requests === 1) {
      await route.fulfill({ status: 429, headers: { "Retry-After": "1" }, json: {} })
    } else if (requests === 2) {
      await route.fulfill({ status: 200, headers: { "X-Search-Cooldown-Ms": "2000" }, json: {
        url: "https://lingorep.com/coffee%20%26%20tea", elapsed_ms: 881, source: "lingorep",
        headings: [{ level: 3, text: "Live result" }],
      } })
    } else {
      await route.fulfill({ status: 404, headers: { "X-Search-Cooldown-Ms": "2000" }, json: { error: {
        code: "page_not_found", message: "That page could not be found.",
      } } })
    }
  })

  await search.click()
  await expect(page.getByText("Retry in 1s.", { exact: true })).toBeVisible()
  await expect(search).toBeEnabled()
  await search.click()
  await expect(page.getByText("Live response", { exact: true })).toBeVisible()
  await expect(page.getByLabel("Search response JSON")).toContainText("Live result")
  await expect(page.getByText("1 heading · 881 ms")).toBeVisible()
  await expect(page.getByText("Next search in 2s.", { exact: true })).toBeVisible()

  await expect(search).toBeEnabled({ timeout: 12_000 })
  await search.click()
  await expect(page.getByText(/That page could not be found.*Next search in/)).toBeVisible()
  await expect(page.getByLabel("Search response JSON")).toContainText("Live result")
})

test("copies JSON and the correctly encoded public request", async ({ context, page }) => {
  await context.grantPermissions(["clipboard-read", "clipboard-write"])
  await page.goto("/")
  await page.getByLabel("Search query").fill("coffee & tea")
  await page.getByRole("button", { name: "Copy curl" }).click()
  await expect(page.getByText("curl command copied.")).toBeVisible()
  expect(await page.evaluate(() => navigator.clipboard.readText()))
    .toBe("curl 'http://127.0.0.1:3177/search.json?q=coffee+%26+tea'")

  await page.getByRole("button", { name: "Copy JSON" }).click()
  await expect(page.getByRole("button", { name: "Copied", exact: true })).toBeVisible()
  const copied = await page.evaluate(() => navigator.clipboard.readText())
  expect(JSON.parse(copied).url).toBe("https://lingorep.com/")
})

test("the renderer serializes JavaScript-created content without scripts or styles", async ({ page }) => {
  const source = readFileSync(new URL("../../renderer/capture.js", import.meta.url), "utf8")
  await page.setContent(`
    <link rel="stylesheet" href="data:text/css,h2%7Bcolor%3Argb(45%2C67%2C89)%7D">
    <main></main>
    <script>document.querySelector("main").innerHTML = "<h2>Rendered heading</h2>"</script>
  `)
  const capture = Function("return " + source)()
  const document = await page.evaluate(capture)
  expect(document.html).toContain("<h2>Rendered heading</h2>")
  expect(document.html).not.toMatch(/<script|<link/)
  expect(document.url).toBe(page.url())
})
