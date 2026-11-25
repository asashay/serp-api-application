import { test } from "node:test"
import assert from "node:assert/strict"
import { handleSearch, LOCATIONS, parseLocation, parseQuery, reserveSearchSlot } from "../../worker/search.mjs"

function storage() {
  const map = new Map()
  map.put = map.set.bind(map)
  return map
}

test("validates and decodes exactly one query parameter", () => {
  assert.equal(parseQuery(new URLSearchParams("q=coffee+%26+tea")), "coffee & tea")
  assert.equal(parseQuery(new URLSearchParams({ q: "https://example.com/" })), "https://example.com/")
  for (const query of ["", "q=++", "q=1&q=2", "q=rails&foo=bar", "q=%00", "q=%ff", "q=" + "a".repeat(201)]) {
    assert.equal(parseQuery(new URLSearchParams(query)), null, query)
  }
})

test("accepts one optional location from the shared list", () => {
  assert.equal(LOCATIONS.length, 2)
  assert.ok(LOCATIONS.includes("Austin, Texas, United States"))
  assert.equal(parseQuery(new URLSearchParams("q=matcha&location=Austin%2C+Texas%2C+United+States")), "matcha")
  assert.equal(parseQuery(new URLSearchParams("q=matcha&location=a&location=b")), null)
  assert.equal(parseLocation(new URLSearchParams("q=matcha")), undefined)
  assert.equal(parseLocation(new URLSearchParams({ q: "matcha", location: "Paris, Ile-de-France, France" })),
    "Paris, Ile-de-France, France")
  for (const location of ["", "Austin", "austin, texas, united states", "cr.us;city.austin"]) {
    assert.equal(parseLocation(new URLSearchParams({ q: "matcha", location })), null, location)
  }
})

test("rejects an unknown location before reserving and forwards a known one", async () => {
  let reservations = 0
  const bodies = []
  const url = (location) => `/search.json?${new URLSearchParams({ q: "matcha", location })}`
  const send = sender({
    SEARCH_GATE: { getByName: () => ({ reserve: () => { reservations++; return { retryAfter: 0, nextSearchAt: Date.now() } } }) },
    RAILS: { getByName: () => ({ async fetch(request) {
      bodies.push(await request.json())
      return Response.json({ organic_results: [] }, { headers: { "X-Search-Response": "1" } })
    } }) },
  })

  const unknown = await send(url("Mars"))
  assert.equal(unknown.status, 400)
  assert.equal((await unknown.json()).error.code, "invalid_location")
  assert.equal(reservations, 0)

  assert.equal((await send(url("Austin, Texas, United States"))).status, 200)
  assert.equal((await send("/search.json?q=matcha")).status, 200)
  assert.equal(bodies[0].location, "Austin, Texas, United States")
  assert.equal("location" in bodies[1], false)
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
      assert.equal(payload.query, "blog/getting started")
      assert.equal("path" in payload, false)
      assert.equal(payload.preview, true)
      assert.ok(request.headers.has("X-Request-Id"))
      return Response.json({ organic_results: [] }, { headers: { "X-Search-Response": "1" } })
    } }) },
  })

  assert.equal((await send("/search.json")).status, 400)
  assert.equal((await send("/search.json?q=rails&q=ruby")).status, 400)
  assert.equal((await send("/search.json?q=rails", "HEAD")).status, 405)
  assert.equal((await send("/search.json", "OPTIONS")).status, 204)
  assert.equal(reservations, 0)

  const [accepted, denied] = await Promise.all([
    send("/playground/search?q=blog%2Fgetting+started"), send("/search.json?q=rails"),
  ])
  assert.equal(accepted.status, 200)
  assert.ok(Number(accepted.headers.get("x-search-cooldown-ms")) > 0)
  assert.deepEqual(await accepted.json(), { organic_results: [] })
  assert.equal(denied.status, 429)
  assert.equal(denied.headers.get("retry-after"), "10")
  assert.equal(denied.headers.get("access-control-allow-origin"), "*")
  assert.equal(denied.headers.get("cache-control"), "no-store")
  assert.equal(captures, 1)
})

test("asks Rails for a page preview only for the playground", async () => {
  const previews = []
  const send = sender({
    SEARCH_GATE: { getByName: () => ({ reserve: () => ({ retryAfter: 0, nextSearchAt: Date.now() }) }) },
    RAILS: { getByName: () => ({ async fetch(request) {
      previews.push((await request.json()).preview)
      return Response.json({ organic_results: [] }, { headers: { "X-Search-Response": "1" } })
    } }) },
  })

  assert.equal((await send("/search.json?q=rails")).status, 200)
  assert.equal((await send("/playground/search?q=rails")).status, 200)
  assert.deepEqual(previews, [false, true])
})

test("preserves typed capture errors and normalizes framework errors", async () => {
  const send = (response) => sender({
    SEARCH_GATE: { getByName: () => ({ reserve: () => ({ retryAfter: 0, nextSearchAt: Date.now() + 10_000 }) }) },
    RAILS: { getByName: () => ({ fetch: () => response }) },
  })("/search.json?q=missing")

  const challenge = await send(Response.json({ error: { code: "upstream_challenge" } }, {
    status: 502, headers: { "X-Search-Response": "1" },
  }))
  assert.equal(challenge.status, 502)
  assert.equal((await challenge.json()).error.code, "upstream_challenge")

  const broken = await send(Response.json({ status: 500 }, { status: 500 }))
  const body = await broken.json()
  assert.equal(broken.status, 503)
  assert.equal(body.error.code, "search_unavailable")
  assert.equal(body.request_id, broken.headers.get("x-request-id"))
})

test("logs the renderer's timing summary without forwarding it", async () => {
  const summary = "render outcome=challenge attempts=5 total_ms=41000 | attempt 1 outcome=challenge challenge_at=load"
  const logged = []
  const original = console.log
  console.log = (entry) => logged.push(entry)
  try {
    const response = await sender({
      SEARCH_GATE: { getByName: () => ({ reserve: () => ({ retryAfter: 0, nextSearchAt: Date.now() }) }) },
      RAILS: { getByName: () => ({ fetch: () => Response.json({ error: { code: "upstream_challenge" } }, {
        status: 502, headers: { "X-Search-Response": "1", "X-Render-Log": summary },
      }) }) },
    })("/search.json?q=rails")

    assert.equal(response.status, 502)
    assert.equal(response.headers.get("X-Render-Log"), null)
  } finally {
    console.log = original
  }
  assert.equal(logged.length, 1)
  assert.equal(logged[0].render, summary)
  assert.equal(logged[0].status, 502)
  assert.match(logged[0].request_id, /^[0-9a-f-]{36}$/)
})

test("logs an admitted search even when Rails sent no renderer summary", async () => {
  const logged = []
  const original = console.log
  console.log = (entry) => logged.push(entry)
  try {
    await sender({
      SEARCH_GATE: { getByName: () => ({ reserve: () => ({ retryAfter: 0, nextSearchAt: Date.now() }) }) },
      RAILS: { getByName: () => ({ fetch: () => Response.json({ error: { code: "upstream_unavailable" } }, {
        status: 503, headers: { "X-Search-Response": "1" },
      }) }) },
    })("/search.json?q=rails")
  } finally {
    console.log = original
  }
  assert.equal(logged.length, 1)
  assert.equal(logged[0].status, 503)
  assert.equal(logged[0].render, null)
})
