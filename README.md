# OmniBook

WhatsApp-native appointment booking for high-demand service providers — clinics,
dental studios, salons, wellness suites and legal counsel.

Clients pick a real slot on the marketplace; the confirmation, reminders,
rescheduling and check-in code all land in the one app they already have open.

**Live preview:** https://claude.ai/code/artifact/ea340000-dcdc-4581-9b31-5a3c1ee1a538

---

## Architecture

```
Browser
   │
   ▼
Cloudflare Worker  ──► static site (./web)  [assets binding]
   │  /api/*
   ▼
Supabase Edge Function  "omnibook-api"  (Deno)
   │  service role
   ▼
Postgres 17  —  schema `omnibook`  (RLS on every table)
```

| Layer     | Technology                              | Status |
|-----------|-----------------------------------------|--------|
| Frontend  | Static HTML/CSS/JS, Plus Jakarta Sans   | Built — `web/index.html` |
| Edge      | Cloudflare Workers (assets + API proxy) | Built — needs your CF token to deploy |
| API       | Supabase Edge Function (Deno)           | **Deployed and live** |
| Database  | Supabase Postgres 17, schema `omnibook` | **Deployed, seeded, RLS verified** |
| Messaging | WhatsApp Cloud API                      | Modelled — dispatches logged, sender not yet wired |

Everything OmniBook owns lives in the `omnibook` schema. The `public` schema of
this Supabase project belongs to an unrelated application and is untouched.

---

## Live endpoints

Base URL: `https://xhbhlpegfnswhbodhbqp.supabase.co/functions/v1/omnibook-api`

| Method | Route                      | Purpose |
|--------|----------------------------|---------|
| GET    | `/health`                  | Liveness probe |
| GET    | `/stats`                   | Provider, open-slot and booking counts |
| GET    | `/providers?category=&limit=` | Catalog, with cheapest service and next open slot |
| GET    | `/providers/:slug`         | One provider with services and open slots |
| GET    | `/slots?provider=:slug`    | Open slots for a provider |
| POST   | `/bookings`                | Claim a slot — `{ slot_id, whatsapp, full_name?, notes? }` |
| POST   | `/leads`                   | Provider onboarding request |

```bash
curl https://xhbhlpegfnswhbodhbqp.supabase.co/functions/v1/omnibook-api/stats
```

Once the Worker is deployed the same API is same-origin at `/api/*`, which
removes the CORS preflight and adds edge caching.

---

## Local development

```bash
npm install
npm run dev          # wrangler dev — serves ./web and proxies /api/*
```

## Deploying

### 1. Database and API (already live)

Both are deployed against project `xhbhlpegfnswhbodhbqp`. To reapply from source:

```bash
supabase link --project-ref xhbhlpegfnswhbodhbqp
supabase db push                                      # runs supabase/migrations/*
supabase functions deploy omnibook-api --no-verify-jwt
```

### 2. Frontend + edge gateway (needs your Cloudflare credentials)

```bash
export CLOUDFLARE_API_TOKEN=...        # scope: Workers Scripts:Edit
export CLOUDFLARE_ACCOUNT_ID=...
npm run deploy
```

Wrangler prints the deployed URL, e.g. `https://omnibook.<subdomain>.workers.dev`.

To use a custom domain, add a `routes` entry to `wrangler.jsonc`:

```jsonc
"routes": [{ "pattern": "omnibook.example.com", "custom_domain": true }]
```

---

## Security model

- **Deny by default.** RLS is enabled on all seven tables. `anon` and
  `authenticated` are granted `SELECT` on the three catalog tables only
  (`providers`, `services`, `slots`) and hold no grant at all on `bookings`,
  `clients`, `leads` or `whatsapp_dispatches` — those are denied at the GRANT
  layer before RLS is consulted.
- **Writes are server-side.** Every write goes through the Edge Function using
  the service-role key, which never leaves the server. `omnibook.create_booking`
  is `SECURITY DEFINER` with `EXECUTE` revoked from `anon` and `authenticated`.
- **Bookings are atomic.** The RPC locks the slot row `FOR UPDATE`, so two
  concurrent callers cannot claim the same time; the loser gets `23505` and the
  API returns `409`.
- **The API is intentionally public** (`verify_jwt = false`) because an
  unauthenticated marketplace page calls it. It validates and length-caps every
  input. Before taking real traffic, add a Cloudflare WAF rate-limiting rule on
  `/api/*` — see `docs/ARCHITECTURE.md`.

Verified against the live database:

| Check | Result |
|-------|--------|
| `anon` reads providers / slots | allowed (5 / 225 rows) |
| `anon` inserts a lead | blocked — `42501` |
| `anon` calls `create_booking` | blocked — `42501` |
| Double-booking one slot | rejected — `23505` |

---

## Repository layout

```
web/index.html                     landing page (design system inlined)
workers/gateway/src/index.ts       Cloudflare Worker: assets + /api proxy + cache
wrangler.jsonc                     Worker + static-assets configuration
supabase/functions/omnibook-api/   Deno Edge Function (the API)
supabase/migrations/               five SQL migrations, matching the live DB
docs/ARCHITECTURE.md               data model, request flow, what is left to build
```

## Not yet built

- WhatsApp Cloud API sender. Messages are composed and written to
  `omnibook.whatsapp_dispatches`; a worker that drains that table to Meta's
  `/messages` endpoint, plus the inbound webhook for `1`/`2` replies, is the
  next piece.
- Provider dashboard and client "My bookings" screens (designs supplied).
- Auth. There is no login yet; clients are identified by WhatsApp number.
