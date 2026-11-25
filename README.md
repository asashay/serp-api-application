# Search Lab

Search Lab is a small Google Search API. It renders a real Google results page in a browser behind a residential proxy and returns SerpApi-style JSON. I built it as a work sample for SerpApi's [Senior Fullstack Engineer](https://serpapi.com/careers/senior-fullstack-engineer) role: Rails, JavaScript, proxies, challenge handling and browser automation in one deployed product.

**[Open the playground](https://serp-api-demo.alexoliynyk.me/)** to run a search and compare the captured page with the JSON parsed from it.

```sh
# Saved example: no quota, no proxy traffic
curl -sS 'https://serp-api-demo.alexoliynyk.me/example.json'

# Live search
curl -sS 'https://serp-api-demo.alexoliynyk.me/search.json?q=best+matcha+bar'
```

## What it does

- **Live Google results as JSON**, with SerpApi's field names: `organic_results`, `search_metadata`, `search_parameters`, `search_information` and `pagination`.
- **Locations.** An optional `location` runs the search from Austin or Paris, using an exit IP in that city and the matching `gl` and `uule`.
- **A side-by-side playground.** The captured page, without scripts or links, next to its JSON.
- **A shared budget.** One live search every 10–15 seconds and 400 a month, enforced before any proxy traffic is spent.

## Architecture

![Search Lab architecture: a Cloudflare Worker validates the request and reserves an attempt in the SearchGate Durable Object, then forwards it to a container where Rails builds the Google URL and parses results, a Python renderer drives a warm Firefox, and a CONNECT guard sends Google-only traffic through the DataImpulse residential gateway.](docs/architecture.svg)

1. **Cloudflare Worker** validates `q` and `location`, then reserves an attempt in the **SearchGate** Durable Object, a single global object that keeps the cooldown and monthly cap atomic.
2. **Rails 8** builds the Google URL, asks the renderer for the page and parses it with Nokogiri.
3. **Python renderer** drives a warm Invisible Playwright Firefox in the same container, with a fresh browser context per capture.
4. **CONNECT guard** opens tunnels only to Google hosts and adds the proxy credentials, which the browser never sees.
5. **DataImpulse** gives each attempt a new residential IP, in the requested city when there is one.

| Layer | Technology |
| --- | --- |
| Edge, rate limits | Cloudflare Workers, Durable Objects |
| API, parsing, playground | Ruby 3.4, Rails 8.1, Puma, Nokogiri, Stimulus |
| Rendering | Python 3, aiohttp, Invisible Playwright Firefox |
| Network | DataImpulse residential proxy, local CONNECT guard |
| Hosting | One Cloudflare Container (2 vCPU, 8 GiB) running Rails and the renderer |
| Tests | Minitest, Node test runner, Python unittest, Playwright |

## Problems worth a closer look

- **Challenges and slow IPs.** CAPTCHAs, `/sorry/` pages, 403/429s and slow IPs are retried on a new IP, up to five times in 110 seconds. Otherwise the API returns a clear 502 or 504.
- **Late challenges.** Google's scripts can swap in a challenge after the HTML loads, so the page is checked again just before capture.
- **Opaque links.** Results link through `/goto` URLs; the renderer resolves each redirect in the page without navigating.
- **Consent dialogs.** The cookie modal shown to European IPs is removed in the page, never answered.
- **Location.** Each search sends both `uule` and a city-targeted exit IP. Only cities Google confirmed are offered.
- **Untrusted HTML.** The preview has no scripts, links or embedded documents, a CSP for inline styles and `data:` images only, and a `sandbox=""` frame.
- **Content-free logs.** Each search logs step timings and page structure, never queries, URLs or HTML.

## Limitations

- One capture at a time; scaling means a pool of renderers behind the same gate.
- No caching of repeated searches.
- Only first-page organic results; ads, local packs and "People also ask" are not parsed.
- On unknown markup the parser fails loudly (502 `unknown_layout`) rather than return partial data.

## Development

`bin/ci` runs lint, security checks and the Rails, Worker, renderer and browser suites; parser tests use real captured Google pages. Setup, the API contract and deployment are in [AGENTS.md](AGENTS.md).
