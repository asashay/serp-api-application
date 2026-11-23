import { test } from "node:test"
import assert from "node:assert/strict"
import { handleSearch, parseQuery, reserveSearchSlot } from "../../worker/search.mjs"

test("validates and decodes exactly one query parameter", () => {
  assert.equal(parseQuery(new URLSearchParams("q=coffee+%26+tea")), "coffee & tea")
  for (const query of ["", "q=++", "q=1&q=2", "q=rails&foo=bar", "q=%00", "q=%ff", "q=" + "a".repeat(201)]) {
    assert.equal(parseQuery(new URLSearchParams(query)), null, query)
  }
})

test("reserves exactly one search across concurrent calls and allows retry at expiry", async () => {
  const storage = new Map()
  storage.put = storage.set.bind(storage)
  const reserve = async (now) => reserveSearchSlot(storage, now).retryAfter
  assert.deepEqual(await Promise.all([reserve(1000), reserve(1000)]), [0, 10])
  assert.equal(await reserve(10999), 1)
  assert.equal(await reserve(11000), 0)
})

test("shares one slot between public and playground routes", async () => {
  const storage = new Map()
  storage.put = storage.set.bind(storage)
  let fetched = 0
  const env = {
    SEARCH_GATE: { getByName(name) {
      assert.equal(name, "global")
      return { reserve: () => reserveSearchSlot(storage, Date.now()) }
    } },
    BROWSER: { quickAction() {
      fetched += 1
      return Response.json({ success: true, result: "<main>Google results</main>" })
    } },
    RAILS: { getByName: () => ({ async fetch(request) {
      assert.equal(new URL(request.url).pathname, "/internal/search")
      const payload = await request.json()
      assert.equal(payload.html, "<main>Google results</main>")
      assert.equal(payload.preview, true)
      return Response.json({ organic_results: [] }, { headers: { "X-Search-Response": "1" } })
    } }) },
  }

  const send = (path, method = "GET") => {
    const url = new URL(path, "https://example.com")
    return handleSearch(new Request(url, { method }), url, env)
  }
  assert.equal((await send("/search.json")).status, 400)
  assert.equal((await send("/search.json?q=rails", "HEAD")).status, 405)
  assert.equal((await send("/search.json", "OPTIONS")).status, 204)
  const [accepted, denied] = await Promise.all([
    send("/playground/search?q=rails"), send("/search.json?q=rails"),
  ])
  assert.equal(accepted.status, 200)
  assert.ok(Number(accepted.headers.get("x-search-cooldown-ms")) > 0)
  assert.deepEqual(await accepted.json(), { organic_results: [] })
  assert.equal(denied.status, 429)
  assert.equal(denied.headers.get("retry-after"), "10")
  assert.equal(denied.headers.get("access-control-allow-origin"), "*")
  assert.equal(denied.headers.get("cache-control"), "no-store")
  assert.equal(fetched, 1)
})

test("normalizes framework errors to the public JSON error contract", async () => {
  const url = new URL("https://example.com/search.json?q=rails")
  const env = {
    SEARCH_GATE: { getByName: () => ({ reserve: () => ({ retryAfter: 0, nextSearchAt: Date.now() + 10_000 }) }) },
    BROWSER: { quickAction: () => new Response("<main>Results</main>") },
    RAILS: { getByName: () => ({ fetch: () => Response.json({
      status: 500, error: "Internal Server Error",
    }, { status: 500 }) }) },
  }
  const response = await handleSearch(new Request(url), url, env)
  const body = await response.json()
  assert.equal(response.status, 503)
  assert.equal(body.error.code, "search_unavailable")
  assert.equal(body.request_id, response.headers.get("x-request-id"))
})
