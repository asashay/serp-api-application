import { test } from "node:test"
import assert from "node:assert/strict"
import { fetchGoogleHtml } from "../../worker/browser-run.mjs"

test("retrieves Google HTML and correctly encodes the search query", async () => {
  const browser = {
    async quickAction(action, options) {
      assert.equal(action, "content")
      assert.equal(new URL(options.url).hostname, "www.google.com")
      assert.equal(new URL(options.url).searchParams.get("q"), "coffee & tea")
      assert.equal(options.gotoOptions.timeout, 8_000)
      return new Response("<main>results</main>", { headers: { "Content-Type": "text/html" } })
    },
  }
  assert.equal(await fetchGoogleHtml(browser, "coffee & tea"), "<main>results</main>")
})

test("accepts the Browser Run response envelope", async () => {
  const browser = { quickAction: () => Response.json({ success: true, result: "<main>results</main>" }) }
  assert.equal(await fetchGoogleHtml(browser, "rails"), "<main>results</main>")
})

test("distinguishes timeout, challenge and service failure", async () => {
  const request = (response) => fetchGoogleHtml({ quickAction: () => response }, "rails")
  await assert.rejects(request(new Response(null, { status: 504 })), { code: "upstream_timeout" })
  await assert.rejects(request(new Response(null, {
    status: 422, headers: { "x-browser-rendering-target-status": "429" },
  })), { code: "upstream_challenge" })
  await assert.rejects(request(new Response(null, { status: 503 })), { code: "upstream_unavailable" })
})
