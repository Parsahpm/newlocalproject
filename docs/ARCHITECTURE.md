# OmniBook — architecture notes

## Why the pieces are where they are

**Postgres holds the truth about time.** Availability and double-booking are the
only genuinely hard problems in a booking product, and both are concurrency
problems. They are solved in the database — `omnibook.create_booking` takes a
row lock on the slot and does the claim, the client upsert, the booking insert
and the message queue write in one transaction — rather than in application
code, where two Workers racing on the same slot would both win.

**The Edge Function is a thin, validated boundary.** It holds the service-role
key, validates and length-caps input, maps Postgres error codes to HTTP status
codes, and does nothing else clever.

**The Cloudflare Worker is the front door.** It serves the static site and
proxies `/api/*` to the Edge Function. That buys same-origin API calls (no CORS
preflight on every booking), edge caching of read-only routes, and one place to
hang security headers and rate limits.

## Data model

```
providers ──┬── services ──┐
            │              │
            └── slots ─────┤        (slot.service_id → services.id)
                           │
clients ────────────── bookings ──── whatsapp_dispatches
                           │
leads (standalone: landing-page capture)
```

- `slots` carries `unique (provider_id, starts_at)` — a provider physically
  cannot have two appointments starting at the same instant.
- `bookings.slot_id` is `unique` — a slot maps to at most one booking, enforced
  by the database rather than by convention.
- `whatsapp_dispatches` is an append-only log of every message the bot composed.
  It doubles as the outbound queue once the Cloud API sender exists.
- Money is stored as integer cents. Never floats.

## Request flow: claiming a slot

```
POST /api/bookings { slot_id, whatsapp, full_name }
   │
   ├─ Worker: no cache (POST), forwards with X-Forwarded-For
   │
   ├─ Edge Function: UUID + phone-shape validation, then rpc create_booking
   │
   └─ Postgres, one transaction:
        SELECT … FOR UPDATE on the slot      ← serialises concurrent callers
        reject if booked / past
        upsert client by whatsapp_number
        insert booking (reference OB-XXXXXXXX)
        mark slot booked
        queue the WhatsApp confirmation
```

Error codes surface deliberately:

| Postgres | HTTP | Meaning |
|----------|------|---------|
| `23505`  | 409  | Slot was claimed by someone else first |
| `P0002`  | 404  | Slot does not exist |
| `22023`  | 400  | Bad input, or slot in the past |

## Caching

The Worker caches GET routes at the edge with short TTLs, because availability
goes stale fast:

| Route            | TTL |
|------------------|-----|
| `/slots`         | 10s |
| `/stats`         | 15s |
| `/providers`     | 30s |
| `/providers/:id` | 30s |

Writes are always `no-store`. Responses carry `X-Cache: HIT|MISS|BYPASS`.

## Rate limiting (to add before real traffic)

The API is deliberately unauthenticated, so throttling belongs at the edge.
In the Cloudflare dashboard: **Security → WAF → Rate limiting rules**

- Match: `http.request.uri.path contains "/api/"`
- Characteristic: client IP
- Suggested: 60 requests / minute, then block for 10 minutes
- Tighter on writes: `http.request.method eq "POST"` → 10 / minute

## The WhatsApp sender (not yet built)

Today the confirmation text is composed and written to
`omnibook.whatsapp_dispatches` with `delivered_at` stamped optimistically. To
make it real:

1. Register a WhatsApp Business number, get `WHATSAPP_PHONE_NUMBER_ID` and a
   permanent `WHATSAPP_ACCESS_TOKEN`.
2. Add a Supabase scheduled function (or a Worker cron) that selects rows where
   `delivered_at is null`, POSTs each to
   `https://graph.facebook.com/v21.0/{phone_number_id}/messages`, and stamps
   `delivered_at` on a 200.
3. Change `create_booking` to insert with `delivered_at = null` so the queue
   reflects reality rather than intent.
4. Add an inbound webhook route to the Edge Function for the `1` / `2` replies,
   verified against `WHATSAPP_VERIFY_TOKEN`, mapping replies to
   confirm / reschedule transitions on `bookings.status`.

Template messages must be pre-approved by Meta before they can be sent outside
a 24-hour customer service window — budget review time for that.

## Frontend data strategy

`web/index.html` ships with an embedded snapshot of the catalog and renders it
immediately, then upgrades to live API data on load. If the API is unreachable
the page still renders completely and the header chip reads "Preview data"
instead of "Live data". That keeps the page useful in sandboxed previews where
cross-origin fetch is blocked, and means a cold API never yields a blank page.
