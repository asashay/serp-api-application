import { expect, test } from "@playwright/test"
import { readFileSync } from "node:fs"

test("shows the API response at desktop, tablet and mobile widths", async ({ page }, info) => {
  for (const width of [1440, 768, 390]) {
    await page.setViewportSize({ width, height: 900 })
    await page.goto("/")
    await expect(page.getByRole("heading", { name: "Google Search API" })).toBeVisible()
    await expect(page.getByLabel("Search query")).toHaveValue("best matcha bar")
    await expect(page.getByText("Saved example", { exact: true })).toBeVisible()
    await expect(page.locator("iframe.page-frame")).toBeVisible()
    const json = page.getByLabel("Search response JSON")
    await expect(json).toBeVisible()
    await expect(json).toContainText("The 9 Best Matcha in Houston | MyBestHouston")
    expect((await json.boundingBox()).y).toBeLessThan(900)

    await page.getByLabel("Search query").fill("a".repeat(200))
    expect(await page.evaluate(() => document.documentElement.scrollWidth)).toBe(width)
    await page.getByLabel("Search query").fill("best matcha bar")
    await page.screenshot({ path: info.outputPath(`playground-${width}.png`), fullPage: true })
  }
})

test("shows the saved page with links that go nowhere", async ({ page }) => {
  await page.goto("/")
  const frame = page.locator("iframe.page-frame")
  await expect(frame).toHaveAttribute("sandbox", "")
  const preview = page.frameLocator("iframe.page-frame")
  const title = preview.getByRole("heading", { name: "The 9 Best Matcha in Houston | MyBestHouston" })
  await expect(title).toBeVisible()
  await expect(preview.locator("[href]")).toHaveCount(0)
  await expect(preview.locator("script")).toHaveCount(0)
  expect(await title.evaluate((node) => getComputedStyle(node.closest("a")).pointerEvents)).toBe("none")

  const popups = []
  page.context().on("page", (popup) => popups.push(popup))
  await title.click({ force: true })
  await page.waitForTimeout(300)
  expect(page.url()).toMatch(/\/$/)
  // The sandboxed frame has an opaque origin, so only Playwright can read its address.
  expect((await (await frame.elementHandle()).contentFrame()).url()).toBe("about:srcdoc")
  expect(await frame.evaluate((node) => {
    try { return node.contentWindow.document && "readable" } catch { return "isolated" }
  })).toBe("isolated")
  expect(popups).toHaveLength(0)
})

test("shows the live response and keeps it when a new request fails", async ({ page }) => {
  await page.goto("/")
  const query = page.getByLabel("Search query")
  const search = page.getByRole("button", { name: "Run search" })
  await query.fill("coffee & tea")
  await expect(page.getByRole("link", { name: "Open JSON" })).toHaveAttribute("href", /\?q=coffee\+%26\+tea&location=Austin%2C\+Texas%2C\+United\+States$/)

  let requests = 0
  await page.route("**/playground/search?*", async (route) => {
    expect(new URL(route.request().url()).searchParams.get("q")).toBe("coffee & tea")
    requests += 1
    await expect(page.getByRole("button", { name: "Searching…" })).toBeDisabled()
    await expect(page.getByRole("status", { name: "Rendering Google results" })).toBeVisible()
    await expect(page.locator("iframe.page-frame")).toBeHidden()
    if (requests === 1) {
      await route.fulfill({ status: 429, headers: { "Retry-After": "1" }, json: {} })
    } else if (requests === 2) {
      await route.fulfill({ status: 200, headers: { "X-Search-Cooldown-Ms": "2000" }, json: {
        query: "coffee & tea", elapsed_ms: 881, source: "google",
        organic_results: [{ position: 1, title: "Live result", link: "https://example.com/", snippet: null }],
        preview_html: "<!doctype html><html><body><div id='rso'><h3>Live page</h3></div></body></html>",
      } })
    } else {
      await route.fulfill({ status: 502, headers: { "X-Search-Cooldown-Ms": "2000" }, json: { error: {
        code: "upstream_challenge", message: "Google returned a challenge page.",
      } } })
    }
  })

  await search.click()
  await expect(page.getByText("Retry in 1s.", { exact: true })).toBeVisible()
  await expect(search).toBeEnabled()
  await search.click()
  await expect(page.getByText("Live response", { exact: true })).toBeVisible()
  await expect(page.getByLabel("Search response JSON")).toContainText("Live result")
  await expect(page.getByText("1 organic result · 881 ms")).toBeVisible()
  await expect(page.getByRole("status", { name: "Rendering Google results" })).toBeHidden()
  await expect(page.frameLocator("iframe.page-frame").getByRole("heading", { name: "Live page" })).toBeVisible()
  await expect(page.getByLabel("Search response JSON")).not.toContainText("preview_html")
  await expect(page.getByText("Next search in 2s.", { exact: true })).toBeVisible()

  await expect(search).toBeEnabled({ timeout: 12_000 })
  await search.click()
  await expect(page.getByText(/Google returned a challenge page.*Next search in/)).toBeVisible()
  await expect(page.getByLabel("Search response JSON")).toContainText("Live result")
})

test("searches from a chosen location", async ({ page }) => {
  await page.goto("/")
  const location = page.getByLabel("Location")
  await expect(location).toHaveValue("Austin, Texas, United States")
  await expect(location.locator("option")).toHaveText([
    "Any location", "Austin, United States", "Paris, France",
  ])

  await location.selectOption({ label: "Paris, France" })
  await expect(page.getByRole("link", { name: "Open JSON" }))
    .toHaveAttribute("href", /\?q=best\+matcha\+bar&location=Paris%2C\+Ile-de-France%2C\+France$/)

  let requested
  await page.route("**/playground/search?*", async (route) => {
    requested = new URL(route.request().url()).searchParams
    await route.fulfill({ status: 200, json: { query: "best matcha bar", source: "google", elapsed_ms: 1, organic_results: [] } })
  })
  await page.getByRole("button", { name: "Run search" }).click()
  await expect(page.getByText("Live response", { exact: true })).toBeVisible()
  expect(requested.get("location")).toBe("Paris, Ile-de-France, France")

  await location.selectOption("")
  await expect(page.getByRole("link", { name: "Open JSON" })).toHaveAttribute("href", /\?q=best\+matcha\+bar$/)
})

test("copies JSON and the correctly encoded public request", async ({ context, page }) => {
  await context.grantPermissions(["clipboard-read", "clipboard-write"])
  await page.goto("/")
  await page.getByLabel("Search query").fill("coffee & tea")
  await page.getByRole("button", { name: "Copy curl" }).click()
  await expect(page.getByText("curl command copied.")).toBeVisible()
  expect(await page.evaluate(() => navigator.clipboard.readText()))
    .toBe("curl 'http://127.0.0.1:3177/search.json?q=coffee+%26+tea&location=Austin%2C+Texas%2C+United+States'")

  await page.getByRole("button", { name: "Copy JSON" }).click()
  await expect(page.getByRole("button", { name: "Copied", exact: true })).toBeVisible()
  const copied = await page.evaluate(() => navigator.clipboard.readText())
  expect(JSON.parse(copied).organic_results[0].link).toBe("https://mybesthouston.com/matcha/")
})

test("the renderer removes Google's consent dialog and unlocks the results", async ({ page }) => {
  const source = readFileSync(new URL("../../renderer/consent.js", import.meta.url), "utf8")
  const remove = Function("return " + source)()
  await page.setViewportSize({ width: 1000, height: 700 })
  await page.setContent(`
    <style>.locked { overflow: hidden } .layer { position: fixed; inset: 0 }</style>
    <body class="locked">
      <div id="main" aria-hidden="true"><div id="rso"><h3>Result</h3><div style="height: 2000px"></div></div></div>
      <div id="backdrop" class="layer" style="background: #0008"></div>
      <div role="dialog" aria-modal="true"><div class="layer"><button>Accept all</button><button> Reject all </button></div></div>
      <div id="toolbar" style="position: fixed; top: 0; width: 100px; height: 40px"></div>
    </body>
  `)

  expect(await page.evaluate(remove)).toBe(true)
  await expect(page.getByRole("button", { name: "Reject all" })).toHaveCount(0)
  await expect(page.locator("#backdrop")).toHaveCount(0)
  await expect(page.locator("#toolbar")).toHaveCount(1)
  await expect(page.locator("#main")).not.toHaveAttribute("aria-hidden", "true")
  await expect(page.getByRole("heading", { name: "Result" })).toBeVisible()
  expect(await page.evaluate(() => getComputedStyle(document.body).overflow)).toBe("visible")

  await page.setContent(`<div role="dialog" aria-modal="true"><button>Close</button></div><div id="rso"></div>`)
  expect(await page.evaluate(remove)).toBe(false)
  await expect(page.getByRole("dialog")).toHaveCount(1)
})

test("the renderer serializes JavaScript-created content and inline styles without scripts", async ({ page }) => {
  const source = readFileSync(new URL("../../renderer/capture.js", import.meta.url), "utf8")
  await page.setContent(`
    <link rel="stylesheet" href="data:text/css,h2%7Bcolor%3Argb(45%2C67%2C89)%7D">
    <style>h2 { letter-spacing: 1px }</style>
    <main></main>
    <script>document.querySelector("main").innerHTML = "<h2>Rendered heading</h2>"</script>
  `)
  const capture = Function("return " + source)()
  const document = await page.evaluate(capture)
  expect(document.html).toContain("<h2>Rendered heading</h2>")
  expect(document.html).not.toMatch(/<script|<link/)
  expect(document.html).toContain("<style>h2 { letter-spacing: 1px }</style>")
  expect(document.url).toBe(page.url())
})
