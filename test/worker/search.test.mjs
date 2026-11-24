import { test } from "node:test"
import assert from "node:assert/strict"
import { capturePath, handleSearch, parseQuery, reserveSearchSlot } from "../../worker/search.mjs"

function storage() {
  const map = new Map()
  map.put = map.set.bind(map)
  return map
}

test("validates and decodes exactly one query parameter", () => {
  assert.equal(parseQuery(new URLSearchParams("q=coffee+%26+tea")), "coffee & tea")
  for (const query of ["", "q=++", "q=1&q=2", "q=rails&foo=bar", "q=%00", "q=%ff", "q=" + "a".repeat(201)]) {
    assert.equal(parseQuery(new URLSearchParams(query)), null, query)
  }
})

test("accepts a path and rejects destinations and traversal", () => {
  for (const path of ["/", "blog/coffee & tea", "/docs/getting started"]) {
    assert.equal(capturePath(new URLSearchParams({ q: path })), path)
  }
  for (const path of ["https://elsewhere.example/", "//elsewhere.example", "a/../b", "/./b", "%2e%2e", "a?b", "a#b", "a\\b"]) {
    assert.equal(capturePath(new URLSearchParams({ q: path })), null, path)
  }
})

test("reserves exactly one search across concurrent calls and allows retry at expiry", async () => {
  const data = storage()
  const reserve = async (now) => reserveSearchSlot(data, now).retryAfter
  assert.deepEqual(await Promise.all([reserve(1000), reserve(1000)]), [0, 10])
  assert.equal(await reserve(10999), 1)
  assert.equal(await reserve(11000), 0)
})

test("extends the reserved window by the requested jitter", () => {
  const data = storage()
  assert.equal(reserveSearchSlot(data, 1000, 4000).retryAfter, 0)
  assert.equal(reserveSearchSlot(data, 11000).retryAfter, 4)
  assert.equal(reserveSearchSlot(data, 15000).retryAfter, 0)
})

test("caps admitted captures at 400 and resets at UTC month rollover", () => {
  const data = storage()
  const start = Date.UTC(2026, 10, 1)
  const reset = Date.UTC(2026, 11, 1)
  for (let index = 0; index < 400; index++) {
    assert.equal(reserveSearchSlot(data, start + index * 10_000).retryAfter, 0)
    assert.equal(reserveSearchSlot(data, start + index * 10_000).retryAfter > 0, true)
  }
  assert.deepEqual(reserveSearchSlot(data, reset - 1), { retryAfter: 1, resetAt: reset })
  assert.equal(reserveSearchSlot(data, reset).retryAfter, 0)
  assert.deepEqual(data.get("captureMonth"), { month: "2026-12", count: 1 })
})

function sender(env) {
  return (path, method = "GET") => {
    const url = new URL(path, "https://example.com")
    return handleSearch(new Request(url, { method }), url, env)
  }
}

test("validates before reserving and shares one slot between public and playground routes", async () => {
  const data = storage()
  let reservations = 0
  let captures = 0
  const send = sender({
    SEARCH_GATE: { getByName(name) {
      assert.equal(name, "global")
      return { reserve() { reservations++; return reserveSearchSlot(data, Date.now()) } }
    } },
    RAILS: { getByName: () => ({ async fetch(request) {
      captures++
      assert.equal(new URL(request.url).pathname, "/internal/capture")
      const payload = await request.json()
      assert.equal(payload.path, "blog/getting started")
      assert.equal("preview" in payload, false)
      assert.ok(request.headers.has("X-Request-Id"))
      return Response.json({ headings: [] }, { headers: { "X-Search-Response": "1" } })
    } }) },
  })

  assert.equal((await send("/search.json")).status, 400)
  assert.equal((await send("/search.json?q=https%3A%2F%2Fexample.com")).status, 400)
  assert.equal((await send("/search.json?q=rails", "HEAD")).status, 405)
  assert.equal((await send("/search.json", "OPTIONS")).status, 204)
  assert.equal(reservations, 0)

  const [accepted, denied] = await Promise.all([
    send("/playground/search?q=blog%2Fgetting+started"), send("/search.json?q=rails"),
  ])
  assert.equal(accepted.status, 200)
  assert.ok(Number(accepted.headers.get("x-search-cooldown-ms")) > 0)
  assert.deepEqual(await accepted.json(), { headings: [] })
  assert.equal(denied.status, 429)
  assert.equal(denied.headers.get("retry-after"), "10")
  assert.equal(denied.headers.get("access-control-allow-origin"), "*")
  assert.equal(denied.headers.get("cache-control"), "no-store")
  assert.equal(captures, 1)
})

test("preserves typed capture errors and normalizes framework errors", async () => {
  const send = (response) => sender({
    SEARCH_GATE: { getByName: () => ({ reserve: () => ({ retryAfter: 0, nextSearchAt: Date.now() + 10_000 }) }) },
    RAILS: { getByName: () => ({ fetch: () => response }) },
  })("/search.json?q=missing")

  const missing = await send(Response.json({ error: { code: "page_not_found" } }, {
    status: 404, headers: { "X-Search-Response": "1" },
  }))
  assert.equal(missing.status, 404)
  assert.equal((await missing.json()).error.code, "page_not_found")

  const broken = await send(Response.json({ status: 500 }, { status: 500 }))
  const body = await broken.json()
  assert.equal(broken.status, 503)
  assert.equal(body.error.code, "search_unavailable")
  assert.equal(body.request_id, broken.headers.get("x-request-id"))
})
