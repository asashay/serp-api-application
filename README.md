# Search Lab

Search Lab is a small Google Search API: it renders a real Google results page in a browser behind a residential proxy and returns structured JSON in a SerpApi-style shape. I built it as a work sample for SerpApi's [Senior Fullstack Engineer](https://serpapi.com/careers/senior-fullstack-engineer) role, to show Ruby on Rails, JavaScript, proxies, challenge handling and browser automation working together in one deployed product.

**[Open the playground](https://serp-api-demo.alexoliynyk.me/)**: run a search, see the captured page (with links disabled) next to the JSON, and copy the request as curl.

```sh
# Saved example: no quota, no proxy traffic
curl -sS 'https://serp-api-demo.alexoliynyk.me/example.json'

# Live search from any location
curl -sS 'https://serp-api-demo.alexoliynyk.me/search.json?q=best+matcha+bar'
```

## What it does

- **Live Google results as JSON.** Each result has `position`, `title`, `link`, `snippet`, and, when Google shows them, `redirect_link`, `displayed_link`, `source`, `favicon`, `date` and `snippet_highlighted_words`. The response also has `search_metadata`, `search_parameters`, `search_information` and `pagination`, using SerpApi's field names.
- **Locations.** Searches run from any location by default. The optional `location` runs one from Austin or Paris instead. The exit IP is in that city, and Google gets the matching `gl` and `uule`.
- **A side-by-side playground.** The captured page is shown in a sandboxed frame, stripped of scripts and links, next to the JSON the parser produced from it. You can check every field against what Google showed.
- **A shared budget.** The public API and the playground share one live search every 10–15 seconds and 400 per month, enforced before any proxy traffic is spent.

## Architecture

![Search Lab architecture: a Cloudflare Worker validates the request and reserves an attempt in the SearchGate Durable Object, then forwards it to a container where Rails builds the Google URL and parses results, a Python renderer drives a warm Firefox, and a CONNECT guard sends Google-only traffic through the DataImpulse residential gateway.](docs/architecture.svg)

A live search follows one path:

1. **Cloudflare Worker** (`worker/`). It validates `q` and `location`, then asks the **SearchGate** Durable Object to reserve an attempt. SearchGate is a single global object, so the cooldown and monthly cap are atomic. Rejected requests spend nothing.
2. **Rails 8** (`app/`). Rails runs in a Cloudflare Container that is kept warm. It builds the Google URL (`hl`, `gl`, `uule`) and asks the local renderer for the page. It parses the HTML with Nokogiri into the public JSON. For the playground, it also returns a sanitized copy of the page.
3. **Python renderer** (`renderer/`). It drives Invisible Playwright Firefox in the same container, reachable only over loopback. Each capture gets a fresh browser context, and the browser stays warm, so there is no cold start per request.
4. **CONNECT guard.** All browser traffic goes through a local proxy that only opens tunnels to Google hosts and adds the DataImpulse credentials. The browser never sees them.
5. **DataImpulse → Google.** Every attempt uses a new proxy session, so a retry gets a new residential IP, optionally in the requested city.

The stack:

| Layer | Technology |
| --- | --- |
| Edge, rate limits | Cloudflare Workers, Durable Objects (SQLite storage) |
| API, parsing, playground | Ruby 3.4, Rails 8.1, Puma, Nokogiri, Stimulus, Propshaft |
| Rendering | Python 3, aiohttp, Invisible Playwright Firefox |
| Network | DataImpulse residential proxy, local CONNECT guard |
| Hosting | One Cloudflare Container (linux/amd64, 1 GiB) running Rails and the renderer under supervisord |
| Tests | Minitest, Node test runner, Python unittest, Playwright, RuboCop, Brakeman, bundler-audit |

## Problems worth a closer look

- **Challenges and slow IPs.** The renderer recognizes Google's challenge pages (HTTP 403/429, the `/sorry/` URL or a captcha). It also gives each exit IP 12 seconds to deliver the HTML. It checks for a challenge again just before capturing, since Google's scripts can add one while the page loads. In either case it retries on a new IP, up to five attempts, as long as the 60-second deadline leaves room for another. If no attempt gets through, the API returns a clear 502 or 504 instead of an empty result.
- **Waiting only for what matters.** The results are in Google's HTML, so a capture starts once the page is parsed. It then allows a few seconds for Google's scripts to fill in the result images, rather than waiting for every subresource through the proxy. Each attempt logs how long every step took, without queries or URLs.
- **Opaque result links.** Google now links results through `/goto` URLs. Inside the page, the renderer follows each redirect without navigating, one at a time and within a time budget, and records the destination. When it can't, `link` falls back to Google's URL, which still works in a browser.
- **Consent dialogs.** European exit IPs get a cookie consent modal over the results. The renderer removes the dialog and its backdrop, and unlocks scrolling, in the page itself. It never posts a choice to Google.
- **Location.** Google trusts the `uule` parameter more than IP geolocation. Search Lab sends both: a `uule` built from the canonical place name, and an exit IP in the same city. Austin and Paris were confirmed on Google's own results page. Other cities were dropped when the proxy's city targeting didn't place them reliably.
- **Showing untrusted HTML safely.** The preview keeps Google's inline styles. It removes scripts, embedded documents, link destinations, form targets and event handlers. It adds a CSP that allows only inline styles and `data:` images and fonts, and is shown in a frame with `sandbox=""`.
- **Cost control.** Invalid queries and unknown locations are rejected before quota is reserved. City targeting costs twice the standard proxy rate, so only two locations are offered.

## Quality

`bin/ci` runs lint, security checks (Brakeman, bundler-audit, npm audit), and the Rails, Worker, renderer and browser test suites. The HTML parser, the renderer client and the HTTP contract are tested on their own. Parser tests use real captured Google pages, so they need no browser or network. Every milestone was checked by an independent reviewer session against written acceptance criteria before moving on.

## Limitations and next steps

- One container runs one capture at a time. That fits the demo's budget; scaling would mean a pool of renderer instances behind the same gate.
- Results are not cached. SerpApi-style caching of identical searches would save proxy traffic and speed up repeats.
- Only the first page of organic results is parsed. Ads, local packs, "People also ask" and other blocks are not.
- Google changes its markup often. The parser fails loudly (502 `unknown_layout`) rather than returning partial data, and the saved real pages make regressions quick to reproduce.

## Development

Setup, the full API contract, local live search, deployment and project conventions are in [AGENTS.md](AGENTS.md).
