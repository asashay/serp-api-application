const MAX_HTML_BYTES = 5 * 1024 * 1024

export class BrowserRunError extends Error {
  constructor(code, status, message) {
    super(message)
    this.code = code
    this.status = status
  }
}

export async function fetchGoogleHtml(browser, query) {
  const url = new URL("https://www.google.com/search")
  url.search = new URLSearchParams({ q: query, hl: "en" }).toString()

  let response
  try {
    response = await browser.quickAction("content", {
      url: url.href,
      gotoOptions: { timeout: 8_000 },
    })
  } catch {
    throw unavailable()
  }

  if (response.status === 504) {
    throw new BrowserRunError("upstream_timeout", 504, "Google results took too long to load.")
  }
  if (response.headers.get("x-browser-rendering-target-status") === "429") {
    throw new BrowserRunError("upstream_challenge", 502, "Google returned a challenge page.")
  }
  if (response.status === 422) {
    const failure = parseJson(await readBounded(response))
    if (Array.isArray(failure?.errors) && failure.errors.some((error) =>
      typeof error?.message === "string" && /timeout|timed out/i.test(error.message))) {
      throw new BrowserRunError("upstream_timeout", 504, "Google results took too long to load.")
    }
  }
  if (!response.ok) throw unavailable()

  const body = await readBounded(response)
  if (!body.trim()) throw unavailable()
  if (response.headers.get("Content-Type")?.includes("application/json")) {
    const payload = parseJson(body)
    if (payload?.success && typeof payload.result === "string" && payload.result.trim()) return payload.result
    throw unavailable()
  }
  if (!body.trimStart().startsWith("<")) throw unavailable()
  return body
}

function parseJson(body) {
  try { return JSON.parse(body) } catch { return null }
}

async function readBounded(response) {
  if (!response.body) throw unavailable()

  const reader = response.body.getReader()
  const decoder = new TextDecoder()
  let bytes = 0
  let html = ""
  try {
    for (;;) {
      const { done, value } = await reader.read()
      if (done) return html + decoder.decode()
      bytes += value.byteLength
      if (bytes > MAX_HTML_BYTES) {
        await reader.cancel()
        throw unavailable()
      }
      html += decoder.decode(value, { stream: true })
    }
  } catch {
    throw unavailable()
  } finally {
    reader.releaseLock()
  }
}

function unavailable() {
  return new BrowserRunError("upstream_unavailable", 503, "Live search is temporarily unavailable.")
}
