import { DurableObject } from "cloudflare:workers"
import { handleSearch, PLAYGROUND_SEARCH, PUBLIC_SEARCH, reserveSearchSlot } from "./search.mjs"

const SEARCH_JITTER_MS = 5_000
const CONTAINER_IDLE_MS = 15 * 60_000

export class SearchGate extends DurableObject {
  reserve() {
    return this.ctx.storage.transactionSync(() =>
      reserveSearchSlot(this.ctx.storage.kv, Date.now(), Math.floor(Math.random() * SEARCH_JITTER_MS)),
    )
  }
}

export class RailsContainer extends DurableObject {
  constructor(ctx, env) {
    super(ctx, env)
    if (ctx.container.running) {
      void ctx.blockConcurrencyWhile(() => ctx.container.setInactivityTimeout(CONTAINER_IDLE_MS))
    }
  }

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
    const image = container.images.base
    const configVersion = this.env.RENDERER_CONFIG_VERSION
    const running = container.running ? await container.inspect() : null
    if (running?.image && (running.image !== image || running.labels?.rendererConfig !== configVersion)) {
      await container.destroy("Replacing the Rails renderer configuration")
    }
    const starting = !container.running
    if (starting) {
      const proxy = Object.fromEntries(
        ["DATAIMPULSE_SERVER", "DATAIMPULSE_USERNAME", "DATAIMPULSE_PASSWORD"]
          .filter((key) => this.env[key]).map((key) => [key, this.env[key]]),
      )
      container.start({
        image,
        labels: { rendererConfig: configVersion },
        instance: { vcpu: 2, memoryMib: 8192, diskMb: 16000 },
        enableInternet: true,
        env: { CLOUDFLARE_CONTAINER: "1", PUBLIC_ORIGIN: this.env.PUBLIC_ORIGIN, ...proxy },
      })
    }
    await container.setInactivityTimeout(CONTAINER_IDLE_MS)

    const port = container.getTcpPort(3000)
    if (!await poll(port, "/up", 75)) throw new Error("Rails container did not become ready")
    // Firefox launches alongside Puma. After a fresh start, hold requests until it
    // is listening so the first admitted capture does not fail and waste quota.
    if (starting && !await poll(port, "/internal/renderer-health", 150)) {
      console.warn({ outcome: "renderer_not_ready" })
    }
  }
}

async function poll(port, path, attempts) {
  for (let attempt = 0; attempt < attempts; attempt++) {
    try {
      const response = await port.fetch(`http://rails.internal${path}`, { signal: AbortSignal.timeout(1000) })
      await response.body?.cancel()
      if (response.ok) return true
    } catch {
      // Puma and the renderer refuse connections while they boot.
    }
    await scheduler.wait(200)
  }
  return false
}

export default {
  async scheduled(_event, env) {
    const response = await env.RAILS.getByName("rails").fetch(new Request("http://rails.internal/internal/renderer-health"))
    await response.body?.cancel()
    if (!response.ok) throw new Error("The renderer failed its readiness check")
  },

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
