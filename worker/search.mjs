import locations from "../config/locations.json" with { type: "json" }

export const PUBLIC_SEARCH = "/search.json"
export const LOCATIONS = locations.map(({ name }) => name)
export const PLAYGROUND_SEARCH = "/playground/search"
const SEARCH_INTERVAL_MS = 10_000
const MONTHLY_CAPTURE_LIMIT = 400

// One q and at most one location; nothing else.
export function parseQuery(searchParams) {
  const keys = [...searchParams.keys()]
  const count = (key) => keys.filter((name) => name === key).length
  if (count("q") !== 1 || count("location") > 1 || keys.some((key) => key !== "q" && key !== "location")) return null

  const query = searchParams.get("q").replace(/^[\p{White_Space}]+|[\p{White_Space}]+$/gu, "")
  const length = [...query].length
  return length >= 1 && length <= 200 && !/[\p{Cc}\uFFFD]/u.test(query) ? query : null
}

// undefined without a location, the name when it is one of config/locations.json, else null.
export function parseLocation(searchParams) {
  if (!searchParams.has("location")) return undefined
  const location = searchParams.get("location")
  return LOCATIONS.includes(location) ? location : null
}

// SQLite-backed Durable Object KV is synchronous. The read and write happen in
// one event turn, so another request cannot reserve between them. The caller
// may add jitter so the public cadence is not a metronome.
export function reserveSearchSlot(storage, now, jitterMs = 0) {
  const date = new Date(now)
  const month = date.toISOString().slice(0, 7)
  const previous = storage.get("captureMonth")
  const count = previous?.month === month ? previous.count : 0
  if (count >= MONTHLY_CAPTURE_LIMIT) {
    const resetAt = Date.UTC(date.getUTCFullYear(), date.getUTCMonth() + 1, 1)
    return { retryAfter: Math.ceil((resetAt - now) / 1000), resetAt }
  }

  const nextSearchAt = storage.get("nextSearchAt") ?? 0
  if (now < nextSearchAt) {
    return { retryAfter: Math.ceil((nextSearchAt - now) / 1000), nextSearchAt }
  }

  const reservedUntil = now + SEARCH_INTERVAL_MS + jitterMs
  storage.put("nextSearchAt", reservedUntil)
  storage.put("captureMonth", { month, count: count + 1 })
  return { retryAfter: 0, nextSearchAt: reservedUntil }
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

  let nextSearchAt
  const includeCountdown = () => {
    if (!isPublic && nextSearchAt) {
      headers.set("X-Search-Cooldown-Ms", String(Math.max(0, nextSearchAt - Date.now())))
    }
  }
  const fail = (code, message, status) => {
    includeCountdown()
    return Response.json({ error: { code, message }, request_id: requestId }, { status, headers })
  }
  if (request.method !== "GET") {
    headers.set("Allow", isPublic ? "GET, OPTIONS" : "GET")
    return fail("method_not_allowed", "Use GET to run a search.", 405)
  }
  const query = parseQuery(url.searchParams)
  if (!query) return fail("invalid_query", "Provide one search query (1 to 200 characters).", 400)
  const location = parseLocation(url.searchParams)
  if (location === null) return fail("invalid_location", `Use one of these locations: ${LOCATIONS.join("; ")}.`, 400)

  const startedAt = Date.now()
  try {
    const gate = env.SEARCH_GATE.getByName("global")
    const reservation = await gate.reserve()
    const { retryAfter } = reservation
    nextSearchAt = reservation.nextSearchAt
    if (retryAfter > 0) {
      headers.set("Retry-After", String(retryAfter))
      if (reservation.resetAt) {
        const reset = new Date(reservation.resetAt).toISOString().slice(0, 10)
        return fail("monthly_limit", `The monthly capture limit resets on ${reset} UTC.`, 429)
      }
      return fail("rate_limited", "The demo allows one live search about every 10 seconds.", 429)
    }

    const upstream = await env.RAILS.getByName("rails").fetch(new Request("http://rails.internal/internal/capture", {
      method: "POST",
      headers: { "Content-Type": "application/json", "X-Request-Id": requestId },
      // Only the playground shows the captured page next to the JSON.
      body: JSON.stringify({ query, location, elapsed_ms: Date.now() - startedAt, preview: !isPublic }),
    }))
    if (upstream.headers.get("X-Search-Response") !== "1" ||
        !upstream.headers.get("Content-Type")?.startsWith("application/json")) {
      await upstream.body?.cancel()
      return fail("search_unavailable", "The search API is temporarily unavailable.", 503)
    }

    headers.set("Content-Type", "application/json; charset=utf-8")
    includeCountdown()
    return new Response(upstream.body, { status: upstream.status, headers })
  } catch (error) {
    const elapsed_ms = Date.now() - startedAt
    console.error({ request_id: requestId, outcome: "search_unavailable", elapsed_ms, type: error?.name })
    return fail("search_unavailable", "The search API is temporarily unavailable.", 503)
  }
}
