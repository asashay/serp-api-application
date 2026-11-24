export const PUBLIC_SEARCH = "/search.json"
export const PLAYGROUND_SEARCH = "/playground/search"
const SEARCH_INTERVAL_MS = 10_000
const MONTHLY_CAPTURE_LIMIT = 400

export function parseQuery(searchParams) {
  const pairs = [...searchParams]
  if (pairs.length !== 1 || pairs[0][0] !== "q") return null

  const query = pairs[0][1].replace(/^[\p{White_Space}]+|[\p{White_Space}]+$/gu, "")
  const length = [...query].length
  return length >= 1 && length <= 200 && !/[\p{Cc}\uFFFD]/u.test(query) ? query : null
}

export function capturePath(searchParams) {
  const path = parseQuery(searchParams)
  if (!path || /^(?:\/\/|[a-z][a-z\d+.-]*:)|[\\?#%]/iu.test(path)) return null
  if (path.split("/").some((segment) => segment === "." || segment === "..")) return null
  return path
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
  const path = capturePath(url.searchParams)
  if (!path) return fail("invalid_query", "Enter a LingoRep page path (1 to 200 characters).", 400)

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
      body: JSON.stringify({ path, elapsed_ms: Date.now() - startedAt }),
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
