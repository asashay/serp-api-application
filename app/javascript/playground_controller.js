import { Controller } from "@hotwired/stimulus"

const tokenPattern = /"(?:\\.|[^"\\])*"(?=\s*:)|"(?:\\.|[^"\\])*"|\b(?:true|false|null)\b|-?\d+(?:\.\d+)?(?:e[+-]?\d+)?/gi

export default class extends Controller {
  static targets = [
    "query", "submit", "status", "comparison", "source", "summary", "json", "url", "open", "copyStatus",
    "page", "pageEmpty", "location", "pagePanel", "pageLoading", "elapsed",
  ]

  static values = { origin: String }

  connect() {
    this.notice = ""
    this.countdownUntil = 0
    this.highlightJson(this.jsonTarget.textContent.trim())
    this.updateIntegration()
  }

  disconnect() {
    this.request?.abort()
    clearInterval(this.timer)
    clearInterval(this.elapsedTimer)
    clearTimeout(this.copyTimer)
  }

  async search(event) {
    event.preventDefault()
    if (this.request || Date.now() < this.countdownUntil) return

    const query = this.queryTarget.value.trim()
    if (!query || [...query].length > 200) {
      this.notice = "Enter a query with 1 to 200 characters."
      this.renderStatus({ error: true })
      return
    }

    const request = new AbortController()
    this.request = request
    this.notice = "Fetching Google results…"
    this.renderStatus()
    this.comparisonTarget.setAttribute("aria-busy", "true")
    this.showLoading(true)

    try {
      const params = this.searchParams(query)
      const response = await fetch(`/playground/search?${params}`, { signal: request.signal })
      const cooldownMs = Number(response.headers.get("X-Search-Cooldown-Ms"))
      const availableAt = Date.now() + cooldownMs
      const result = await response.json()

      if (response.status === 429 && result.error?.code !== "monthly_limit") {
        this.notice = ""
        this.startCooldown(Date.now() + 1000 * (Number(response.headers.get("Retry-After")) || 10), { retry: true })
        return
      }
      if (!response.ok) {
        this.notice = result.error?.message || "Live search is temporarily unavailable."
        if (cooldownMs > 0) this.startCooldown(availableAt, { error: true })
        else this.renderStatus({ error: true })
        return
      }

      this.showResult(result)
      this.notice = ""
      if (cooldownMs > 0) this.startCooldown(availableAt)
      else this.renderStatus()
    } catch (error) {
      if (error.name === "AbortError") return
      this.notice = "The search request failed. Try again."
      this.renderStatus({ error: true })
    } finally {
      this.request = null
      if (this.element.isConnected) {
        this.showLoading(false)
        this.comparisonTarget.removeAttribute("aria-busy")
        this.updateButton()
      }
    }
  }

  showResult(result) {
    // The page preview is playground-only, so the JSON pane shows the API response without it.
    const { preview_html: previewHtml, ...response } = result
    const live = response.source === "google"
    const count = response.organic_results.length
    this.showPage(previewHtml)
    this.highlightJson(JSON.stringify(response, null, 2))
    this.jsonTarget.parentElement.scrollTo(0, 0)
    this.sourceTarget.textContent = live ? "Live response" : "Saved example"
    this.sourceTarget.toggleAttribute("data-live", live)
    this.summaryTarget.textContent = [
      `${count} organic result${count === 1 ? "" : "s"}`,
      live ? `${response.elapsed_ms} ms` : null,
    ].filter(Boolean).join(" · ")
  }

  // The results panel shows a loader with the elapsed time while a search runs;
  // a failed search brings the previous page back.
  showLoading(loading) {
    clearInterval(this.elapsedTimer)
    this.pagePanelTarget.toggleAttribute("data-loading", loading)
    this.pageLoadingTarget.hidden = !loading
    if (!loading) return

    const startedAt = Date.now()
    const tick = () => {
      const seconds = Math.floor((Date.now() - startedAt) / 1000)
      this.elapsedTarget.textContent = `${String(Math.floor(seconds / 60)).padStart(2, "0")}:${String(seconds % 60).padStart(2, "0")}`
    }
    tick()
    this.elapsedTimer = setInterval(tick, 250)
  }

  // Each page gets a new frame: Chrome can leave a sandboxed frame blank when
  // its srcdoc is replaced with a large page, while a new frame shows it.
  showPage(html) {
    const frame = this.pageTarget.cloneNode(false)
    frame.srcdoc = html || ""
    frame.hidden = !html
    this.pageTarget.replaceWith(frame)
    this.pageEmptyTarget.hidden = Boolean(html)
  }

  highlightJson(json) {
    this.rawJson = json
    const fragment = document.createDocumentFragment()
    let cursor = 0
    for (const match of json.matchAll(tokenPattern)) {
      const [value] = match
      fragment.append(json.slice(cursor, match.index))
      cursor = match.index + value.length
      const span = document.createElement("span")
      span.className = value.startsWith('"') ? (/^\s*:/.test(json.slice(cursor)) ? "json-key" : "json-string") : "json-literal"
      span.textContent = value
      fragment.append(span)
    }
    fragment.append(json.slice(cursor))
    this.jsonTarget.replaceChildren(fragment)
  }

  startCooldown(until, options = {}) {
    clearInterval(this.timer)
    this.countdownUntil = until
    this.timer = setInterval(() => this.renderStatus(options), 250)
    this.renderStatus(options)
  }

  renderStatus({ error = false, retry = false } = {}) {
    const seconds = Math.ceil(Math.max(0, this.countdownUntil - Date.now()) / 1000)
    if (!seconds) clearInterval(this.timer)
    const countdown = seconds ? `${retry ? "Retry" : "Next search"} in ${seconds}s.` : ""
    const text = [this.notice, countdown].filter(Boolean).join(" ")
    if (text !== this.statusTarget.textContent) this.statusTarget.textContent = text
    this.statusTarget.toggleAttribute("data-error", error)
    this.updateButton()
  }

  updateButton() {
    this.submitTarget.disabled = Boolean(this.request) || Date.now() < this.countdownUntil
    this.submitTarget.textContent = this.request ? "Searching…" : "Run search"
  }

  // q, plus location when one is chosen ("Any location" sends none).
  searchParams(query) {
    const params = new URLSearchParams({ q: query })
    if (this.locationTarget.value) params.set("location", this.locationTarget.value)
    return params
  }

  updateIntegration() {
    const url = new URL("/search.json", this.originValue)
    url.search = this.searchParams(this.queryTarget.value.trim()).toString()
    this.urlTarget.textContent = url.href
    this.openTarget.href = url.href
  }

  copyJson(event) { return this.copy(this.rawJson, "JSON copied.", event.currentTarget) }
  copyUrl() { return this.copy(this.openTarget.href, "URL copied.") }
  copyCurl() { return this.copy(`curl '${this.openTarget.href}'`, "curl command copied.") }

  async copy(value, successMessage, button) {
    clearTimeout(this.copyTimer)
    this.resetCopyFeedback()
    try {
      await navigator.clipboard.writeText(value)
      this.copyStatusTarget.textContent = successMessage
      if (button) {
        this.copyButton = button
        button.textContent = "Copied"
      }
    } catch {
      this.copyStatusTarget.textContent = "Clipboard unavailable. Select the text to copy it."
    }
    this.copyTimer = setTimeout(() => this.resetCopyFeedback(), 3000)
  }

  resetCopyFeedback() {
    if (this.copyButton) this.copyButton.textContent = "Copy JSON"
    this.copyButton = null
    this.copyStatusTarget.textContent = ""
  }
}
