# Search Lab: development guide

Search Lab renders a Google results page in a warm Firefox behind a residential proxy and returns SerpApi-style JSON. [README.md](README.md) is the public overview for reviewers. This file has the detail needed to work on the project.

## Project conventions

Use the Rails conventions for controllers, views and Minitest. Keep the public HTTP contract, page renderer client and HTML parsers independently testable. Run `bin/ci` before publishing.

After each substantial milestone, use the installed `review-agent` skill in a fresh reviewer session. Provide the base and head commits, the acceptance criteria and the test commands. Resolve actionable findings, rerun the affected checks and ask the reviewer to verify the fixes before proceeding.

Working rules:

- **Live searches cost money.** Each one uses DataImpulse traffic, and city-targeted traffic is billed at twice the standard rate. Use the saved fixtures and mocked upstreams. Don't run live searches or location checks unless the person you are working with asks for them.
- **Keep the proxy credentials secret.** They live in the gitignored `.env.renderer` locally and in Wrangler secrets in production. Never print, log or commit them. When you inspect `.env.renderer`, mask the values.
- **Logs carry no content.** Never log queries, URLs, HTML or credentials.

## Request path

```text
Browser or API client
  │  GET /search.json?q=…&location=…  or  GET /playground/search?q=…
  ▼
Cloudflare Worker (worker/)                 validates q and location, reserves an attempt
  │  SearchGate Durable Object              10–15 s cooldown + 400 captures per UTC month
  ▼
Cloudflare Container, 1 GiB, linux/amd64    one instance, kept warm
  ├─ Rails / Puma :3000 (app/)              builds the Google URL, parses results, returns JSON
  │     │  POST http://127.0.0.1:3800/render  {url, location}
  │     ▼
  └─ Python renderer :3800 (renderer/)      warm Invisible Playwright Firefox
        │  fresh browser context per capture
        ▼
     Local CONNECT proxy :3801              only allows Google and its static origins
        │  authenticated CONNECT, username carries city + session id
        ▼
     DataImpulse gateway  ──►  https://www.google.com/search?q=…&hl=en[&gl=…&uule=…]
```

[docs/architecture.svg](docs/architecture.svg) is the same path as a diagram, used by the README. Update it when a component or hop changes.

## Components

| Component | Location | Responsibility |
| --- | --- | --- |
| Worker | `worker/index.mjs`, `worker/search.mjs` | Routes public traffic. Validates `q` and `location` before spending quota. Reserves attempts through `SearchGate`. Forwards admitted searches to Rails at `POST /capture` with `{query, location, elapsed_ms, preview}`. Starts the container with the proxy secrets and runs the five-minute readiness check. |
| SearchGate | `worker/index.mjs`, `worker/search.mjs` | One global Durable Object. Atomically enforces the cooldown and the monthly cap. |
| Locations | `config/locations.json` | The only list of places. The Worker validates names against it, Rails takes `gl` and the `uule` name from it, and the renderer takes the DataImpulse targeting (`cr.us;city.austin`) from it. |
| Rails | `app/controllers/capture_controller.rb`, `app/services/google_search/` | `Query` parses the request and builds the Google URL. `Location` loads the locations and computes `uule`. `PageCapture::Renderer` calls the loopback renderer. `Parser` extracts organic results, search information and pagination. `Response` builds the public JSON. `Preview` sanitizes the page for the playground. `Example` serves the saved capture. |
| Renderer | `renderer/server.py` and modules beside it | Keeps one Firefox process running and runs one capture at a time. `attempts.py` retries challenges on a fresh proxy session. `consent.js` / `consent.py` remove Google's consent dialog. `links.py` resolves `/goto` links. `capture.js` serializes the DOM without scripts, embedded documents or external stylesheets; inline styles stay. `locations.py` maps a location name to proxy targeting. `timings.py` builds the per-step timing log lines. |
| Proxy guard | `renderer/proxy.py` | Accepts only Google and static-origin CONNECT tunnels from Firefox. Forwards them to DataImpulse, adding the credentials and a per-attempt `sessid`. |
| Process supervisor | `renderer/supervisord.conf` | Runs Puma and the renderer side by side. Restarts either one if it exits. Blanks the proxy secrets for Puma. |
| Playground | `app/views/playground/`, `app/javascript/playground_controller.js`, `app/assets/stylesheets/application.css` | Search box, location select, a sandboxed link-free copy of the results page, a loading indicator, and the JSON response. Starts from the saved capture, which uses no quota. |

### Design choices

- **One container.** Rails and Firefox share an instance, so the renderer is reachable only over loopback. The container restarts as a unit when the image or `RENDERER_CONFIG_VERSION` changes. A freshly started container holds requests until Firefox answers its health check.
- **Destinations are checked in depth.** Rails builds a fixed Google search URL. The Playwright route filter, the CONNECT guard and the final-URL check restrict traffic to the authorized Google origins.
- **Quota is spent only on admitted attempts.** Invalid queries, unknown locations and rate-limited requests consume nothing. An admitted capture counts even if it fails. A capture that arrives while another is running waits within its own deadline.
- **The page is ready when its HTML is parsed.** Google sends the results in the HTML, so an attempt waits for `domcontentloaded`, capped at 12 seconds. It then waits up to 4 more seconds for the full load, because Google's scripts fill in most result images (inline `data:` URIs) while the page loads. A slow subresource costs at most those 4 seconds (logged as `loaded=no`) instead of the whole deadline.
- **Challenges and slow IPs retry on a new IP.** A capture that meets a challenge (HTTP 403/429, a `/sorry/` URL or a captcha), or whose exit IP doesn't deliver the HTML within 12 seconds, retries from a new DataImpulse session. It makes up to five attempts, while at least a third of the deadline remains. The renderer checks for a challenge twice: when the HTML is parsed, and again just before capturing, because Google's scripts can swap in a CAPTCHA or redirect to `/sorry/` while the page loads. Rails' parser uses the same selector, so a challenge reaches the API only when every attempt met one. When every attempt was slow, the API returns 504 `upstream_timeout`. (The 12- and 4-second waits scale with `RENDER_TIMEOUT_SECONDS`.)
- **`/goto` links are resolved in the page.** The renderer fetches each `/goto` URL with `redirect: "manual"`, one at a time with a short gap, and reads the `Location` header from the response event. It rewrites the link and keeps the original in `data-goto`. It stops when the time budget (a sixth of the deadline) runs out.
- **The consent dialog is removed, not answered.** `consent.js` removes the dialog, its full-screen backdrop and `aria-hidden`/`inert`, and unlocks scrolling. Nothing is posted to `consent.google.com`.
- **Logs carry no content.** Rails tags its log lines with the request ID and filters `q`, `query` and `html`. The renderer logs only browser error codes, proxy status codes and step timings.
- **Every render logs its timings.** Each attempt logs one line, `attempt N outcome=… context_ms load_ms google_status loaded images_ms consent_ms links_resolved links_ms serialize_ms kib close_ms total_ms`, with `challenge_at=load|capture` when Google challenged the attempt, and the request ends with `render outcome=… queue_ms attempts_ms attempts located total_ms`. When a timeout or error interrupts an attempt or the render, `stopped_in` names the step. A successful attempt closes its browser context after answering, so the close never turns a captured page into a timeout; the next capture waits for it. To see where a slow search spent its time, search the container logs for `render outcome=timeout`. `renderer/timings.py` builds these lines.
- **Parsing is independent.** `GoogleSearch::Parser` reads saved HTML without network or browser dependencies, recognizes challenge and zero-result pages, unwraps Google redirect links, and caps output at ten organic results. Its tests use real captured pages.

## API contract

`GET /search.json?q=…` takes exactly one `q` (1–200 characters after trimming, no control characters) and at most one `location`. Any other parameter returns 400.

| `location` | `gl` | Proxy targeting |
| --- | --- | --- |
| `Austin, Texas, United States` | `us` | `cr.us;city.austin` |
| `Paris, Ile-de-France, France` | `fr` | `cr.fr;city.paris` |

Any other value returns 400 `invalid_location` before using quota. Without `location`, the search uses any exit IP and sends no `gl` or `uule`. The `uule` value is `w+CAIQICI`, a base64-alphabet character for the byte length of the canonical name, then the canonical name in base64. Both locations were confirmed on Google's results page. San Francisco, Seattle and New York were tried and dropped because DataImpulse city targeting placed them unreliably; Barcelona was never confirmed.

The response has `query`, `search_metadata`, `search_parameters`, `search_information`, `organic_results`, `pagination`, `request_id`, `elapsed_ms` and `source` (`google` live, `fixture` for the saved example). Empty sections are omitted.

- `search_metadata`: `id` (the request ID), `status`, `created_at`, `processed_at`, `google_url` and `total_time_taken` in seconds.
- `search_parameters`: `engine`, `q`, `google_domain`, `hl` and `device`, plus `location_requested`, `location_used` and `gl` for a search with a location. Every capture asks google.com for English desktop results.
- `search_information`: `query_displayed`, `total_results` and `time_taken_displayed`, when Google shows its result count.
- `organic_results`: `position`, `title`, `link`, `snippet` (null when Google shows none), and when present `redirect_link`, `displayed_link`, `source`, `favicon` (usually a `data:` image), `date` and `snippet_highlighted_words`. When a `/goto` link could not be resolved, `link` and `redirect_link` are both the Google URL.
- `pagination`: `current`, `next` and `other_pages` (page number to Google search URL), when Google shows page links.

The playground endpoint `GET /playground/search` returns the same JSON plus `preview_html`, the sanitized page. The public API never includes it.

Errors have `error.code`, `error.message` and `request_id`:

| Status | Code | When |
| --- | --- | --- |
| 400 | `invalid_query`, `invalid_location` | Bad parameters, before quota |
| 429 | `rate_limited`, `monthly_limit` | With `Retry-After` |
| 502 | `upstream_challenge` | Every attempt met a challenge |
| 502 | `unknown_layout` | The parser recognized no results |
| 503 | `upstream_unavailable`, `search_unavailable` | The renderer or container is not ready |
| 504 | `upstream_timeout` | The 30-second deadline passed, or every exit IP was too slow |

The public API and playground share a 10–15 second cooldown and 400 admitted captures per UTC calendar month. The renderer has a 30-second deadline and a 5 MiB output limit; the preview is capped at 2 MiB.

## Run locally

Install the Ruby version in `.ruby-version`, Node 24, and Python 3.11 or later (the renderer uses `asyncio.timeout`).

```sh
bundle install
npm ci
npx playwright install chromium
bin/ci
bin/rails server
```

Open [the local playground](http://localhost:3000/). Without live search, Rails serves the saved example: `best matcha bar` from Austin (`test/fixtures/google_search/example.html`, a page the renderer captured, kept as returned). Other queries return 422 `fixture_query_unavailable`.

### Live search locally

The renderer's Firefox build exists only for Linux x86-64, so live search runs in the production image. On Apple silicon, run it under x86-64 emulation (for example a Colima profile with `--arch x86_64`).

Put the DataImpulse values in `.env.renderer`, which is gitignored and excluded from the image by the allowlist in `.dockerignore`:

```sh
DATAIMPULSE_SERVER=http://gw.dataimpulse.com:823
DATAIMPULSE_USERNAME=…
DATAIMPULSE_PASSWORD=…
```

Then build and start the image with live search turned on:

```sh
docker buildx build --platform linux/amd64 --load -t serp-api-demo .
docker run --rm --platform linux/amd64 -p 3000:3000 --env-file .env.renderer \
  -e LOCAL_LIVE_SEARCH=1 -e RENDER_TIMEOUT_SECONDS=120 serp-api-demo
```

- `LOCAL_LIVE_SEARCH=1` sends `/search.json` and `/playground/search` through the renderer for any query. There is no cooldown or monthly cap, so every search uses proxy traffic.
- `RENDER_TIMEOUT_SECONDS` raises the 30-second render deadline, for example under emulation. Rails and the renderer read it the same way: values that are not a finite number above 30 keep 30.

## Tests

`bin/ci` runs everything, in this order:

```sh
bundle exec rubocop --cache false
bundle exec brakeman --no-pager --quiet
bundle exec bundler-audit check --update
npm audit --audit-level=high
bin/rails zeitwerk:check
bin/rails test                                                   # Minitest: requests and services
npm run test:worker                                              # Node test runner: worker/
python3 -B -m unittest discover -s test/renderer -p '*_test.py'  # renderer modules
npm run test:browser                                             # Playwright: playground, consent.js, capture.js
```

- Parser tests (`test/services/google_search_parser_test.rb`) run standalone against `test/fixtures/google_search/`. The `live/` fixtures are trimmed real captures of `/goto` link layouts.
- Renderer tests mock the browser and the proxy; nothing reaches the network. `server_test.py` runs the render flow against a fake browser and checks its timing logs; it uses stand-ins for aiohttp and invisible-playwright when they are not installed.
- Browser tests run the playground against Rails and fulfill live searches with routed responses.

## Deploy

Authenticate Wrangler for the Workers Paid account and set three secrets with `wrangler secret put`, using the gateway, username and password from the DataImpulse dashboard:

- `DATAIMPULSE_SERVER`: the HTTP(S) proxy gateway URL, including its port.
- `DATAIMPULSE_USERNAME` and `DATAIMPULSE_PASSWORD`: the proxy credentials.

Run `bin/ci`, then publish the container image and Worker with `npm run deploy`. Docker must be able to build a linux/amd64 image. When the image is unchanged, `npm run deploy:worker` deploys the Worker alone. To deploy to a different hostname, update the custom domain and `PUBLIC_ORIGIN` in `wrangler.jsonc`.

To check a deploy without spending proxy traffic, use `/`, `/example.json` and a request with an unknown `location`, which returns 400 before quota.

Puma and Firefox share one 1 GiB Cloudflare Container. A five-minute scheduled check keeps the container active against its 15-minute idle timeout and checks the local Firefox connection. The Worker replaces the running container when the image changes. After rotating proxy secrets, increment `RENDERER_CONFIG_VERSION` and deploy the Worker to restart the container with the new credentials. Correlate requests by `X-Request-Id`, and check combined memory in Cloudflare container metrics after a live capture.

Font licenses for [Inter](vendor/licenses/inter.txt) and [IBM Plex Mono](vendor/licenses/ibm-plex-mono.txt) are included.
