import { BrowserRunError, fetchGoogleHtml } from "./browser-run.mjs"

export const PUBLIC_SEARCH = "/search.json"
export const PLAYGROUND_SEARCH = "/playground/search"
const SEARCH_INTERVAL_MS = 10_000

export function parseQuery(searchParams) {
  const pairs = [...searchParams]
  if (pairs.length !== 1 || pairs[0][0] !== "q") return null

  const query = pairs[0][1].replace(/^[\p{White_Space}]+|[\p{White_Space}]+$/gu, "")
  const length = [...query].length
  return length >= 1 && length <= 200 && !/[\p{Cc}\uFFFD]/u.test(query) ? query : null
}

// SQLite-backed Durable Object KV is synchronous. The read and write happen in
// one event turn, so another request cannot reserve between them.
export function reserveSearchSlot(storage, now) {
  const nextSearchAt = storage.get("nextSearchAt") ?? 0
  if (now < nextSearchAt) return Math.ceil((nextSearchAt - now) / 1000)

  storage.put("nextSearchAt", now + SEARCH_INTERVAL_MS)
  return 0
}

export async function handleSearch(request, url, env) {
  const requestId = crypto.randomUUID()
  const isPublic = url.pathname === PUBLIC_SEARCH
  const headers = new Headers({ "Cache-Control": "no-store", "X-Request-Id": requestId })
  if (isPublic) {
    headers.set("Access-Control-Allow-Origin", "*")
    headers.set("Access-Control-Expose-Headers", "Retry-After, X-Request-Id")
    if (request.method === "OPTIONS") {
      headers.set("Access-Control-Allow-Methods", "GET, OPTIONS")
      return new Response(null, { status: 204, headers })
    }
  }

  const fail = (code, message, status) => Response.json(
    { error: { code, message }, request_id: requestId },
    { status, headers },
  )
  if (request.method !== "GET") {
    headers.set("Allow", isPublic ? "GET, OPTIONS" : "GET")
    return fail("method_not_allowed", "Use GET to run a search.", 405)
  }
  const query = parseQuery(url.searchParams)
  if (!query) return fail("invalid_query", "Provide one search query (1 to 200 characters).", 400)

  const startedAt = Date.now()
  try {
    const retryAfter = await env.SEARCH_GATE.getByName("global").reserve()
    if (retryAfter > 0) {
      headers.set("Retry-After", String(retryAfter))
      return fail("rate_limited", "The demo allows one live search every 10 seconds.", 429)
    }

    const html = await fetchGoogleHtml(env.BROWSER, query)
    const upstream = await env.RAILS.getByName("rails").fetch(new Request("http://rails.internal/internal/search", {
      method: "POST",
      headers: { "Content-Type": "application/json", "X-Request-Id": requestId },
      body: JSON.stringify({ query, html, preview: !isPublic, elapsed_ms: Date.now() - startedAt }),
    }))
    if (upstream.headers.get("X-Search-Response") !== "1" ||
        !upstream.headers.get("Content-Type")?.startsWith("application/json")) {
      await upstream.body?.cancel()
      return fail("search_unavailable", "The search API is temporarily unavailable.", 503)
    }

    headers.set("Content-Type", "application/json; charset=utf-8")
    return new Response(upstream.body, { status: upstream.status, headers })
  } catch (error) {
    const elapsed_ms = Date.now() - startedAt
    if (error instanceof BrowserRunError) {
      console.warn({ request_id: requestId, outcome: error.code, elapsed_ms })
      return fail(error.code, error.message, error.status)
    }
    console.error({ request_id: requestId, outcome: "search_unavailable", elapsed_ms, type: error?.name })
    return fail("search_unavailable", "The search API is temporarily unavailable.", 503)
  }
}
