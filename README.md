# Search Lab

Search Lab turns a rendered Google results page into structured JSON. Enter a search query to capture Google through the live renderer and inspect its organic results. The starting example is a saved results capture and uses no live slot. [Hosted playground](https://serp-api-demo.alexoliynyk.me/)

```sh
curl -sS 'https://serp-api-demo.alexoliynyk.me/example.json'
curl -i 'https://serp-api-demo.alexoliynyk.me/search.json?q=best+matcha+bar'
```

## Architecture

Every live request follows one path:

```text
Browser or API client
  │  GET /search.json?q=…  or  GET /playground/search?q=…
  ▼
Cloudflare Worker (worker/)                 validates the query, reserves an attempt
  │  SearchGate Durable Object              10–15 s cooldown + 400 captures per UTC month
  ▼
Cloudflare Container, 1 GiB, linux/amd64    one instance, kept warm
  ├─ Rails / Puma :3000 (app/)              builds the Google URL, parses results, returns JSON
  │     │  POST http://127.0.0.1:3800/render
  │     ▼
  └─ Python renderer :3800 (renderer/)      warm Invisible Playwright Firefox
        │  fresh browser context per capture
        ▼
     Local CONNECT proxy :3801              only allows Google and its static origins
        │  authenticated CONNECT
        ▼
     DataImpulse Premium gateway  ──►  https://www.google.com/search?q=…&hl=en
```

| Component | Location | Responsibility |
| --- | --- | --- |
| Worker | `worker/index.mjs`, `worker/search.mjs` | Routes public traffic and validates `q` before spending quota. Reserves attempts through `SearchGate`. Starts the container with the proxy secrets. Runs the five-minute readiness check. |
| SearchGate | `worker/index.mjs`, `worker/search.mjs` | One global Durable Object. Atomically enforces the cooldown and the monthly cap. |
| Rails | `app/controllers/capture_controller.rb`, `app/services/google_search/` | `GoogleSearch::Query` maps the query to a Google search URL. `PageCapture::Renderer` calls the loopback renderer. `GoogleSearch::Parser` extracts organic results and `GoogleSearch::Response` builds the public JSON. |
| Renderer | `renderer/server.py`, `renderer/capture.js` | Keeps one Firefox process running. Runs one capture at a time with a 30-second deadline. Blocks navigation and subresources outside the Google allowlist. Removes Google's cookie consent dialog and resolves `/goto` result links in the page. Returns the rendered DOM without scripts, embedded documents or external stylesheets; inline styles stay for the playground preview. Caps output at 5 MiB. |
| Proxy guard | `renderer/proxy.py` | Accepts only authorized Google and static-origin CONNECT tunnels from Firefox and forwards them to DataImpulse with the account credentials. |
| Process supervisor | `renderer/supervisord.conf` | Runs Puma and the renderer side by side. Restarts either one if it exits. Blanks the proxy secrets for Puma. |
| Playground | `app/views/playground/`, `app/javascript/playground_controller.js` | Search box, a sandboxed link-free copy of the results page, and the JSON response. Starts from a saved capture (`test/fixtures/google_search/example.html`) that uses no quota. |

Design choices:

- **One container.** Rails and Firefox share an instance so the renderer is reachable only over loopback. The container restarts as a unit when the image or `RENDERER_CONFIG_VERSION` changes. A freshly started container holds requests until Firefox answers its health check.
- **Defense in depth on destinations.** Rails builds a fixed Google search URL. The Playwright route filter, CONNECT guard, and final-URL check restrict traffic to the authorized Google origins.
- **Quota is spent only on admitted attempts.** Invalid queries and rate-limited requests consume nothing. An admitted capture counts even if it fails. A capture that arrives while another is running waits within its own deadline.
- **Logs carry no content.** Rails tags its log lines with the request ID and filters `q`, `query`, and `html`. The renderer logs only browser error codes and proxy status codes, never URLs, HTML, or credentials.
- **Parsing is independent.** `GoogleSearch::Parser` reads saved HTML without network or browser dependencies, recognizes challenge and zero-result pages, unwraps Google redirect links, and caps output at ten organic results. Its tests use trimmed captures of real result pages in `test/fixtures/google_search/live/`.

## API

`GET /search.json?q=…` accepts one search query from 1 to 200 characters after trimming. An optional `location` runs the search from one of two places, through an exit IP in that city, and sets Google's country (`gl`):

| `location` | `gl` |
| --- | --- |
| `Austin, Texas, United States` | `us` |
| `Paris, Ile-de-France, France` | `fr` |

Any other value returns 400 `invalid_location` before using quota. Without `location`, the search uses any exit IP. The list lives in `config/locations.json`, which the Worker, Rails and the renderer share. City-targeted DataImpulse traffic is billed at twice the standard rate.

 The API returns `query`, `organic_results`, `request_id`, `elapsed_ms`, and `source`. The live source is `google`. The saved example uses `fixture`.

Each organic result has a numeric `position` plus `title`, `link`, and `snippet` (null when Google shows none). These fields appear when Google shows them:

- `redirect_link`: Google's own link for the result. Google now links results through an opaque `/goto` URL. The renderer reads each destination from Google's redirect, so `link` is the destination. When that fails, `link` and `redirect_link` are both the Google URL, which still opens the page in a browser.
- `displayed_link` (the breadcrumb Google shows), `source` (the site name), `favicon` (usually a `data:` image), and `date`.
- `snippet_highlighted_words`: the words Google highlights in the snippet.

The response also describes the search:

- `search_metadata`: `id` (the request ID), `status`, `created_at`, `processed_at`, `google_url`, and `total_time_taken` in seconds.
- `search_parameters`: `engine`, `q`, `google_domain`, `hl`, and `device`, plus `location_requested`, `location_used` and `gl` for a search with a location. Every capture asks google.com for English desktop results.
- `search_information`: `query_displayed`, `total_results`, and `time_taken_displayed`, when Google shows its result count.
- `pagination`: `current`, `next`, and `other_pages` (page number to Google search URL), when Google shows page links.

The public API and playground share a 10–15 second cooldown and 400 admitted captures per UTC calendar month. Failed captures use their reserved attempt. Error responses include `error.code`, `error.message`, and `request_id`. Google challenges return 502, unrecognized result markup returns 502, and upstream timeouts return 504. Rate and monthly limits return 429 with `Retry-After`. The renderer has a 30-second deadline and a 5 MiB output limit. A local run can raise the deadline with `RENDER_TIMEOUT_SECONDS`.

## Run locally

Install the Ruby version in `.ruby-version`, Node 24, and Python 3.11 or later.

```sh
bundle install
npm ci
npx playwright install chromium
bin/ci
bin/rails server
```

Open [the local playground](http://localhost:3000/). Local Rails serves the saved example for `best matcha bar`, a page the renderer captured from Google, kept as returned. The automated suites use fixtures and mocked upstream requests. The production image targets Linux x86-64.

```sh
docker buildx build --platform linux/amd64 --load -t serp-api-demo .
docker run --rm --platform linux/amd64 -p 3000:3000 serp-api-demo
```

### Live search locally

The renderer's Firefox build exists only for Linux x86-64, so live search runs in the production image. Put the DataImpulse values in `.env.renderer` (gitignored and excluded from the image):

```sh
DATAIMPULSE_SERVER=http://gw.dataimpulse.com:823
DATAIMPULSE_USERNAME=…
DATAIMPULSE_PASSWORD=…
```

Then start the image with live search turned on:

```sh
docker run --rm --platform linux/amd64 -p 3000:3000 --env-file .env.renderer \
  -e LOCAL_LIVE_SEARCH=1 -e RENDER_TIMEOUT_SECONDS=120 serp-api-demo
```

- `LOCAL_LIVE_SEARCH=1` sends `/search.json` and `/playground/search` through the renderer for any query. It has no cooldown or monthly cap, so each search uses DataImpulse traffic.
- `RENDER_TIMEOUT_SECONDS` raises the 30-second render deadline, for example under x86 emulation on Apple silicon. Values that are not a number above 30 keep 30.
- A capture that meets a Google challenge retries from a new DataImpulse session (a new exit IP), up to three attempts within the deadline.

## Deploy

Authenticate Wrangler for the Workers Paid account and configure the three secrets with `wrangler secret put`. Use the proxy gateway, username, and password from the DataImpulse Premium dashboard.

- `DATAIMPULSE_SERVER` is the HTTP(S) proxy gateway URL, including its port.
- `DATAIMPULSE_USERNAME` and `DATAIMPULSE_PASSWORD` are the proxy credentials.

Run `bin/ci`, then publish the container image and Worker with `npm run deploy`. A Worker-only deploy is available with `npm run deploy:worker` when the container image is unchanged. Update the custom domain and `PUBLIC_ORIGIN` in Wrangler when deploying to a different hostname.

Puma and Firefox share one 1 GiB Cloudflare Container. A five-minute scheduled check keeps the container active with its 15-minute idle timeout and checks the local Firefox connection. The Worker replaces the running container when the image changes. After rotating proxy secrets, increment `RENDERER_CONFIG_VERSION` and deploy the Worker to restart the container with the new credentials. Correlate requests by `X-Request-Id` and check combined memory in Cloudflare container metrics after a live capture.

Font licenses for [Inter](vendor/licenses/inter.txt) and [IBM Plex Mono](vendor/licenses/ibm-plex-mono.txt) are included.
