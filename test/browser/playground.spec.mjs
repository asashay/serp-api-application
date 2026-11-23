import { expect, test } from "@playwright/test"

test("shows matching HTML and JSON at desktop, tablet and mobile widths", async ({ page }, info) => {
  for (const width of [1440, 768, 390]) {
    await page.setViewportSize({ width, height: 900 })
    await page.goto("/")
    await expect(page.getByRole("heading", { name: "Google Search API" })).toBeVisible()
    await expect(page.getByLabel("Search query")).toHaveValue("Ruby on Rails guides")
    await expect(page.getByText("Saved example", { exact: true })).toBeVisible()
    const frame = page.frameLocator("iframe")
    await expect(frame.getByRole("heading", { name: "Ruby on Rails Guides", exact: true })).toBeVisible()
    const json = page.getByLabel("Search response JSON")

    if (width === 390) {
      await expect(json).toBeHidden()
      const html = page.getByRole("tab", { name: "HTML" })
      await html.focus()
      await html.press("ArrowRight")
      await expect(page.getByRole("tab", { name: "JSON" })).toBeFocused()
      await expect(json).toBeVisible()
      await page.getByRole("tab", { name: "JSON" }).press("Home")
    } else {
      await expect(json).toBeVisible()
      await expect(json).toContainText("Ruby on Rails Guides")
      const first = await frame.getByRole("heading", { name: "Ruby on Rails Guides", exact: true }).boundingBox()
      expect(first.y).toBeLessThan(900)
    }

    await page.getByLabel("Search query").fill("a".repeat(200))
    expect(await page.evaluate(() => document.documentElement.scrollWidth)).toBe(width)
    await page.getByLabel("Search query").fill("Ruby on Rails guides")
    await page.screenshot({ path: info.outputPath(`playground-${width}.png`), fullPage: true })
  }
})

test("uses one response for both panes and keeps it when a new request is denied", async ({ page }) => {
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
      await route.fulfill({ status: 200, json: {
        response: {
          query: "coffee & tea", elapsed_ms: 881, source: "google",
          organic_results: [{ position: 1, title: "Live result", link: "https://example.org", snippet: null }],
        },
        preview_html: "<h3>Live result</h3>",
      } })
    } else {
      await route.fulfill({ status: 502, json: { error: {
        code: "upstream_challenge", message: "Google returned a challenge page.",
      } } })
    }
  })

  await search.click()
  await expect(page.getByText("Retry in 1s.", { exact: true })).toBeVisible()
  await expect(search).toBeEnabled()
  await search.click()
  await expect(page.getByText("Live response", { exact: true })).toBeVisible()
  await expect(page.frameLocator("iframe").getByRole("heading", { name: "Live result" })).toBeVisible()
  await expect(page.getByLabel("Search response JSON")).toContainText("Live result")
  await expect(page.getByText("1 organic result · 881 ms")).toBeVisible()

  await expect(search).toBeEnabled({ timeout: 12_000 })
  await search.click()
  await expect(page.getByText(/Google returned a challenge page/)).toBeVisible()
  await expect(page.frameLocator("iframe").getByRole("heading", { name: "Live result" })).toBeVisible()
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
  expect(JSON.parse(copied).query).toBe("Ruby on Rails guides")
})
