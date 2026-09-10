/**
 * OmniBook public API — Supabase Edge Function (Deno).
 *
 * Deployed with verify_jwt = false because this is the public marketplace API
 * that the unauthenticated landing page calls. It never exposes a privileged
 * operation: reads are limited to the published catalog and writes are limited
 * to creating a booking or a lead, both of which are validated below. The
 * service-role key stays server-side and is never returned to the client.
 *
 * Routes (prefix: /omnibook-api)
 *   GET  /health
 *   GET  /stats
 *   GET  /providers?category=&limit=
 *   GET  /providers/:slug
 *   GET  /slots?provider=:slug&limit=
 *   POST /bookings   { slot_id, whatsapp, full_name?, notes? }
 *   POST /leads      { business_name, contact_name?, email?, whatsapp?, category?, message? }
 */

import { createClient } from "jsr:@supabase/supabase-js@2";

const SUPABASE_URL = Deno.env.get("SUPABASE_URL")!;
const SERVICE_KEY = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!;

const db = createClient(SUPABASE_URL, SERVICE_KEY, {
  db: { schema: "omnibook" },
  auth: { persistSession: false },
});

const CORS = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type",
  "Access-Control-Allow-Methods": "GET, POST, OPTIONS",
};

const json = (body: unknown, status = 200) =>
  new Response(JSON.stringify(body), {
    status,
    headers: { ...CORS, "Content-Type": "application/json" },
  });

const fail = (message: string, status = 400) => json({ error: message }, status);

/** Trim to a maximum length, returning null for blank input. */
function clean(value: unknown, max: number): string | null {
  if (typeof value !== "string") return null;
  const trimmed = value.trim();
  if (!trimmed) return null;
  return trimmed.slice(0, max);
}

const UUID_RE = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;
const PHONE_RE = /^\+?[0-9][0-9 ()\-.]{6,24}$/;

const PROVIDER_FIELDS =
  "id, slug, display_name, headline, bio, category, specialty, city, address, rating, review_count, whatsapp_verified";

function parseLimit(raw: string | null, fallback: number, max: number): number {
  const n = Number(raw);
  if (!Number.isFinite(n) || n <= 0) return fallback;
  return Math.min(Math.floor(n), max);
}

Deno.serve(async (req: Request) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: CORS });

  const url = new URL(req.url);
  // Strip the function-name prefix so routes read naturally.
  const path = url.pathname.replace(/^\/omnibook-api/, "").replace(/\/+$/, "") || "/";

  try {
    // -- health ------------------------------------------------------------
    if (req.method === "GET" && path === "/health") {
      return json({ status: "ok", service: "omnibook-api", time: new Date().toISOString() });
    }

    // -- stats -------------------------------------------------------------
    if (req.method === "GET" && path === "/stats") {
      const [providers, openSlots, bookings] = await Promise.all([
        db.from("providers").select("*", { count: "exact", head: true }).eq("is_published", true),
        db.from("slots").select("*", { count: "exact", head: true })
          .eq("is_booked", false).gt("starts_at", new Date().toISOString()),
        db.from("bookings").select("*", { count: "exact", head: true }),
      ]);
      return json({
        providers: providers.count ?? 0,
        open_slots: openSlots.count ?? 0,
        bookings: bookings.count ?? 0,
      });
    }

    // -- provider detail ---------------------------------------------------
    const detail = path.match(/^\/providers\/([a-z0-9-]{1,64})$/i);
    if (req.method === "GET" && detail) {
      const { data: provider, error } = await db
        .from("providers")
        .select(PROVIDER_FIELDS)
        .eq("slug", detail[1])
        .eq("is_published", true)
        .maybeSingle();
      if (error) throw error;
      if (!provider) return fail("Provider not found", 404);

      const [{ data: services }, { data: slots }] = await Promise.all([
        db.from("services")
          .select("id, name, description, duration_minutes, price_cents, deposit_cents")
          .eq("provider_id", provider.id).eq("is_active", true)
          .order("price_cents"),
        db.from("slots")
          .select("id, starts_at, ends_at, service_id")
          .eq("provider_id", provider.id).eq("is_booked", false)
          .gt("starts_at", new Date().toISOString())
          .order("starts_at").limit(40),
      ]);

      return json({ provider, services: services ?? [], slots: slots ?? [] });
    }

    // -- provider list -----------------------------------------------------
    if (req.method === "GET" && path === "/providers") {
      const limit = parseLimit(url.searchParams.get("limit"), 12, 50);
      let query = db.from("providers")
        .select(PROVIDER_FIELDS)
        .eq("is_published", true)
        .order("rating", { ascending: false })
        .limit(limit);

      const category = clean(url.searchParams.get("category"), 32);
      if (category) query = query.eq("category", category);

      const { data, error } = await query;
      if (error) throw error;

      // Attach each provider's cheapest service and next open slot.
      const enriched = await Promise.all((data ?? []).map(async (p) => {
        const [{ data: service }, { data: slot }] = await Promise.all([
          db.from("services")
            .select("name, duration_minutes, price_cents")
            .eq("provider_id", p.id).eq("is_active", true)
            .order("price_cents").limit(1).maybeSingle(),
          db.from("slots")
            .select("id, starts_at")
            .eq("provider_id", p.id).eq("is_booked", false)
            .gt("starts_at", new Date().toISOString())
            .order("starts_at").limit(1).maybeSingle(),
        ]);
        return { ...p, from_service: service ?? null, next_slot: slot ?? null };
      }));

      return json({ providers: enriched });
    }

    // -- open slots --------------------------------------------------------
    if (req.method === "GET" && path === "/slots") {
      const slug = clean(url.searchParams.get("provider"), 64);
      if (!slug) return fail("A ?provider=<slug> parameter is required");

      const { data: provider } = await db
        .from("providers").select("id").eq("slug", slug).eq("is_published", true).maybeSingle();
      if (!provider) return fail("Provider not found", 404);

      const { data, error } = await db
        .from("slots")
        .select("id, starts_at, ends_at, service_id")
        .eq("provider_id", provider.id).eq("is_booked", false)
        .gt("starts_at", new Date().toISOString())
        .order("starts_at")
        .limit(parseLimit(url.searchParams.get("limit"), 20, 100));
      if (error) throw error;

      return json({ slots: data ?? [] });
    }

    // -- create booking ----------------------------------------------------
    if (req.method === "POST" && path === "/bookings") {
      const body = await req.json().catch(() => null);
      if (!body) return fail("Invalid JSON body");

      const slotId = clean(body.slot_id, 64);
      const whatsapp = clean(body.whatsapp, 32);

      if (!slotId || !UUID_RE.test(slotId)) return fail("A valid slot_id is required");
      if (!whatsapp || !PHONE_RE.test(whatsapp)) return fail("A valid WhatsApp number is required");

      const { data, error } = await db.rpc("create_booking", {
        p_slot_id: slotId,
        p_whatsapp: whatsapp,
        p_full_name: clean(body.full_name, 120),
        p_notes: clean(body.notes, 500),
      });

      if (error) {
        // 23505 = slot already claimed, P0002 = not found, 22023 = invalid input.
        const status = error.code === "23505" ? 409 : error.code === "P0002" ? 404 : 400;
        return fail(error.message, status);
      }

      const booking = Array.isArray(data) ? data[0] : data;
      return json({ booking }, 201);
    }

    // -- capture lead ------------------------------------------------------
    if (req.method === "POST" && path === "/leads") {
      const body = await req.json().catch(() => null);
      if (!body) return fail("Invalid JSON body");

      const businessName = clean(body.business_name, 160);
      if (!businessName) return fail("A business name is required");

      const email = clean(body.email, 160);
      if (email && !email.includes("@")) return fail("That email address looks invalid");

      const { error } = await db.from("leads").insert({
        business_name: businessName,
        contact_name: clean(body.contact_name, 120),
        email,
        whatsapp: clean(body.whatsapp, 32),
        category: clean(body.category, 40),
        message: clean(body.message, 1000),
        source: clean(body.source, 40) ?? "landing",
      });
      if (error) throw error;

      return json({ ok: true, message: "Thanks — our onboarding team will WhatsApp you shortly." }, 201);
    }

    return fail(`No route for ${req.method} ${path}`, 404);
  } catch (err) {
    console.error("omnibook-api error:", err);
    return fail("Internal server error", 500);
  }
});
