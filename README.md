# Search Lab

Search Lab shows how a rendered web page becomes structured JSON. The playground keeps its Google Search API labels. Enter a path such as `/` or `blog/my-post` to capture the corresponding LingoRep page. The starting example is a saved homepage capture and uses no live slot. [Hosted playground](https://serp-api-demo.alexoliynyk.me/)

```sh
curl -sS 'https://serp-api-demo.alexoliynyk.me/example.json'
curl -i 'https://serp-api-demo.alexoliynyk.me/search.json?q=%2F'
```

## Architecture

Every live request follows one path:

```text
Browser or API client
  │  GET /search.json?q=…  or  GET /playground/search?q=…
  ▼
Cloudflare Worker (worker/)                 validates the path, reserves an attempt
  │  SearchGate Durable Object              10–15 s cooldown + 400 captures per UTC month
  ▼
Cloudflare Container, 1 GiB, linux/amd64    one instance, kept warm
  ├─ Rails / Puma :3000 (app/)              builds the URL, parses the HTML, returns JSON
  │     │  POST http://127.0.0.1:3800/render
  │     ▼
  └─ Python renderer :3800 (renderer/)      warm Invisible Playwright Firefox
        │  fresh browser context per capture
        ▼
     Local CONNECT proxy :3801              only allows lingorep.com:443
        │  authenticated CONNECT
        ▼
     DataImpulse Premium gateway  ──►  https://lingorep.com/<path>
```

| Component | Location | Responsibility |
| --- | --- | --- |
| Worker | `worker/index.mjs`, `worker/search.mjs` | Routes public traffic and validates `q` as a LingoRep path before spending quota. Reserves attempts through `SearchGate`. Starts the container with the proxy secrets. Runs the five-minute readiness check. |
| SearchGate | `worker/index.mjs`, `worker/search.mjs` | One global Durable Object. Atomically enforces the cooldown and the monthly cap. |
| Rails | `app/controllers/capture_controller.rb`, `app/services/page_capture/` | `PageCapture::Path` maps the query to `https://lingorep.com/<encoded path>`. `PageCapture::Renderer` calls the loopback renderer. `PageCapture::Document` extracts the URL, title, description, and headings. |
| Renderer | `renderer/server.py`, `renderer/capture.js` | Keeps one Firefox process running. Runs one capture at a time with a 30-second deadline. Blocks navigation and subresources outside LingoRep. Returns the rendered DOM without scripts or styles. Caps output at 5 MiB. |
| Proxy guard | `renderer/proxy.py` | Accepts only `CONNECT lingorep.com:443` from Firefox and forwards it to DataImpulse with the account credentials. |
| Process supervisor | `renderer/supervisord.conf` | Runs Puma and the renderer side by side. Restarts either one if it exits. Blanks the proxy secrets for Puma. |
| Playground | `app/views/playground/`, `app/javascript/playground_controller.js` | Search box plus a single JSON pane. Starts from a saved capture (`test/fixtures/page_capture/lingorep.html`) that uses no quota. |

Design choices:

- **One container.** Rails and Firefox share an instance so the renderer is reachable only over loopback. The container restarts as a unit when the image or `RENDERER_CONFIG_VERSION` changes. A freshly started container holds requests until Firefox answers its health check.
- **Defense in depth on destinations.** The Worker, Rails, the Playwright route filter, the CONNECT guard, and the final-URL check each restrict traffic to `https://lingorep.com`.
- **Quota is spent only on admitted attempts.** Invalid paths and rate-limited requests consume nothing. An admitted capture counts even if it fails. A capture that arrives while another is running waits within its own deadline.
- **Logs carry no content.** Rails tags its log lines with the request ID and filters `q`, `path`, and `html`. The renderer logs only browser error codes and proxy status codes, never URLs, HTML, or credentials.
- **Google parsing is parked.** `GoogleSearch::Parser` and its fixture and test remain under `app/services/google_search` for a future source of Google results HTML. Nothing in the live path calls it.

## API

`GET /search.json?q=…` accepts one LingoRep path from 1 to 200 characters after trimming. Use `/` for the homepage. The API returns `url`, `title`, `description`, `headings`, `request_id`, `elapsed_ms`, and `source`. Each heading has a numeric `level` and `text`. The live source is `lingorep`. The saved example uses `fixture`.

The public API and playground share a 10–15 second cooldown and 400 admitted captures per UTC calendar month. Failed captures use their reserved attempt. Error responses include `error.code`, `error.message`, and `request_id`. A missing LingoRep page returns 404. Rate and monthly limits return 429 with `Retry-After`. The renderer has a 30-second deadline and a 5 MiB output limit.

## Run locally

Install the Ruby version in `.ruby-version`, Node 24, and Python 3.11 or later.

```sh
bundle install
npm ci
npx playwright install chromium
bin/ci
bin/rails server
```

Open [the local playground](http://localhost:3000/). Local Rails serves the saved example for `/`. The automated suites use fixtures and mocked upstream requests. The production image targets Linux x86-64.

```sh
docker buildx build --platform linux/amd64 --load -t serp-api-demo .
docker run --rm --platform linux/amd64 -p 3000:3000 serp-api-demo
```

## Deploy

Authenticate Wrangler for the Workers Paid account and configure the three secrets with `wrangler secret put`. Use the proxy gateway, username, and password from the DataImpulse Premium dashboard.

- `DATAIMPULSE_SERVER` is the HTTP(S) proxy gateway URL, including its port.
- `DATAIMPULSE_USERNAME` and `DATAIMPULSE_PASSWORD` are the proxy credentials.

Run `bin/ci`, then publish the container image and Worker with `npm run deploy`. A Worker-only deploy is available with `npm run deploy:worker` when the container image is unchanged. Update the custom domain and `PUBLIC_ORIGIN` in Wrangler when deploying to a different hostname.

Puma and Firefox share one 1 GiB Cloudflare Container. A five-minute scheduled check keeps the container active with its 15-minute idle timeout and checks the local Firefox connection. The Worker replaces the running container when the image changes. After rotating proxy secrets, increment `RENDERER_CONFIG_VERSION` and deploy the Worker to restart the container with the new credentials. Correlate requests by `X-Request-Id` and check combined memory in Cloudflare container metrics after a live capture.

Font licenses for [Inter](vendor/licenses/inter.txt) and [IBM Plex Mono](vendor/licenses/ibm-plex-mono.txt) are included.
