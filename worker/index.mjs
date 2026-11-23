import { DurableObject } from "cloudflare:workers"
import { handleSearch, PLAYGROUND_SEARCH, PUBLIC_SEARCH, reserveSearchSlot } from "./search.mjs"

export class SearchGate extends DurableObject {
  reserve() {
    return reserveSearchSlot(this.ctx.storage.kv, Date.now())
  }
}

export class RailsContainer extends DurableObject {
  async fetch(request) {
    this.starting ??= this.waitForRails().finally(() => { this.starting = undefined })
    await this.starting

    const url = new URL(request.url)
    url.protocol = "http:"
    url.host = "rails.internal"
    const forwarded = new Request(url, request)
    forwarded.headers.delete("Host")
    return this.ctx.container.getTcpPort(3000).fetch(forwarded)
  }

  async waitForRails() {
    const container = this.ctx.container
    if (!container.running) {
      container.start({
        image: container.images.base,
        instance: "basic",
        enableInternet: false,
        env: { CLOUDFLARE_CONTAINER: "1" },
      })
    }
    await container.setInactivityTimeout(60_000)

    const port = container.getTcpPort(3000)
    for (let attempt = 0; attempt < 75; attempt++) {
      try {
        const response = await port.fetch("http://rails.internal/up", { signal: AbortSignal.timeout(1000) })
        await response.body?.cancel()
        if (response.ok) return
      } catch {
        // Puma can refuse connections while Rails boots.
      }
      await scheduler.wait(200)
    }
    throw new Error("Rails container did not become ready")
  }
}

export default {
  async fetch(request, env) {
    const url = new URL(request.url)
    if (url.pathname === PUBLIC_SEARCH || url.pathname === PLAYGROUND_SEARCH) {
      return handleSearch(request, url, env)
    }
    if (!["GET", "HEAD"].includes(request.method) ||
        !(["/", "/up", "/example.json"].includes(url.pathname) || url.pathname.startsWith("/assets/"))) {
      return new Response("Not found", { status: 404 })
    }
    try {
      return await env.RAILS.getByName("rails").fetch(request)
    } catch (error) {
      console.error({ outcome: "container_unavailable", type: error?.name })
      return new Response("The playground is temporarily unavailable.", { status: 503 })
    }
  },
}
