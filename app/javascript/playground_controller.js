import { Controller } from "@hotwired/stimulus"

const tokenPattern = /"(?:\\.|[^"\\])*"(?=\s*:)|"(?:\\.|[^"\\])*"|\b(?:true|false|null)\b|-?\d+(?:\.\d+)?(?:e[+-]?\d+)?/gi

export default class extends Controller {
  static targets = [
    "query", "submit", "status", "comparison", "source", "summary", "preview", "json",
    "previewLabel", "tab", "panel", "url", "open", "copyStatus",
  ]

  static values = { origin: String }

  connect() {
    this.notice = ""
    this.countdownUntil = 0
    this.mobile = matchMedia("(max-width: 620px)")
    this.syncPanels = this.syncPanels.bind(this)
    this.mobile.addEventListener("change", this.syncPanels)
    this.syncPanels()
    this.highlightJson(this.jsonTarget.textContent.trim())
    this.updateIntegration()
  }

  disconnect() {
    this.mobile.removeEventListener("change", this.syncPanels)
    this.request?.abort()
    clearInterval(this.timer)
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
    const startedAt = Date.now()
    this.request = request
    this.notice = "Fetching Google results…"
    this.renderStatus()
    this.comparisonTarget.setAttribute("aria-busy", "true")

    try {
      const params = new URLSearchParams({ q: query })
      const response = await fetch(`/playground/search?${params}`, { signal: request.signal })
      const result = await response.json()

      if (response.status === 429) {
        this.notice = ""
        this.startCooldown(Date.now() + 1000 * (Number(response.headers.get("Retry-After")) || 10))
        return
      }
      if (!response.ok) {
        this.notice = result.error?.message || "Live search is temporarily unavailable."
        if (result.error?.code?.startsWith("upstream_") || result.error?.code === "unknown_layout") {
          this.startCooldown(startedAt + 10_000, true)
        }
        this.renderStatus({ error: true })
        return
      }

      this.showResult(result)
      this.notice = ""
      if (result.response.source === "google") this.startCooldown(startedAt + 10_000)
      else this.renderStatus()
    } catch (error) {
      if (error.name === "AbortError") return
      this.notice = "The search request failed. Try again."
      this.renderStatus({ error: true })
    } finally {
      this.request = null
      if (this.element.isConnected) {
        this.comparisonTarget.removeAttribute("aria-busy")
        this.updateButton()
      }
    }
  }

  showResult({ response, preview_html: html }) {
    const live = response.source === "google"
    const count = response.organic_results.length
    this.previewTarget.srcdoc = html
    this.highlightJson(JSON.stringify(response, null, 2))
    this.jsonTarget.parentElement.scrollTo(0, 0)
    this.sourceTarget.textContent = live ? "Live response" : "Saved example"
    this.previewLabelTarget.textContent = live ? "Page preview" : "Fixture preview"
    this.sourceTarget.toggleAttribute("data-live", live)
    this.summaryTarget.textContent = [
      `${count} organic result${count === 1 ? "" : "s"}`,
      live ? `${response.elapsed_ms} ms` : null,
    ].filter(Boolean).join(" · ")
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

  startCooldown(until, error = false) {
    clearInterval(this.timer)
    this.countdownUntil = until
    this.timer = setInterval(() => this.renderStatus({ error }), 250)
    this.renderStatus({ error })
  }

  renderStatus({ error = false } = {}) {
    const seconds = Math.ceil(Math.max(0, this.countdownUntil - Date.now()) / 1000)
    if (!seconds) clearInterval(this.timer)
    const countdown = seconds ? `Retry in ${seconds}s.` : ""
    const text = [this.notice, countdown].filter(Boolean).join(" ")
    if (text !== this.statusTarget.textContent) this.statusTarget.textContent = text
    this.statusTarget.toggleAttribute("data-error", error)
    this.updateButton()
  }

  updateButton() {
    this.submitTarget.disabled = Boolean(this.request) || Date.now() < this.countdownUntil
    this.submitTarget.textContent = this.request ? "Searching…" : "Run search"
  }

  updateIntegration() {
    const url = new URL("/search.json", this.originValue)
    url.search = new URLSearchParams({ q: this.queryTarget.value.trim() }).toString()
    this.urlTarget.textContent = url.href
    this.openTarget.href = url.href
  }

  selectTab(event) {
    this.setTab(event.currentTarget)
  }

  navigateTabs(event) {
    if (!["ArrowLeft", "ArrowRight", "Home", "End"].includes(event.key)) return
    event.preventDefault()
    const current = this.tabTargets.indexOf(event.target)
    const index = { Home: 0, End: this.tabTargets.length - 1 }[event.key] ?? (current + 1) % this.tabTargets.length
    const tab = this.tabTargets[index]
    this.setTab(tab)
    tab.focus()
  }

  setTab(selected) {
    this.comparisonTarget.dataset.activeTab = selected.id === "tab-json" ? "json" : "html"
    this.tabTargets.forEach((tab) => {
      tab.ariaSelected = String(tab === selected)
      tab.tabIndex = tab === selected ? 0 : -1
    })
  }

  syncPanels() {
    this.panelTargets.forEach((panel) => {
      const label = panel.id.endsWith("html") ? "html" : "json"
      panel.setAttribute("aria-labelledby", this.mobile.matches ? `tab-${label}` : `heading-${label}`)
      if (this.mobile.matches) panel.setAttribute("role", "tabpanel")
      else panel.removeAttribute("role")
    })
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
