/**
 * OmniBook edge gateway — Cloudflare Worker.
 *
 * Serves the static site from ./web and proxies /api/* to the Supabase Edge
 * Function. Fronting the API here buys three things:
 *
 *   1. Same-origin API calls, so the browser makes no CORS preflight.
 *   2. Edge caching of the read-only catalog routes.
 *   3. One place to attach security headers and (via a WAF rule) rate limits.
 *
 * The upstream URL is configured in wrangler.jsonc as API_ORIGIN.
 */

interface Env {
  ASSETS: Fetcher;
  API_ORIGIN: string;
}

/** GET routes that are safe to cache at the edge, with their TTLs in seconds. */
const CACHEABLE: Array<[RegExp, number]> = [
  [/^\/providers\/?$/, 30],
  [/^\/providers\/[a-z0-9-]+$/i, 30],
  [/^\/stats\/?$/, 15],
  [/^\/slots\/?$/, 10],
];

const SECURITY_HEADERS: Record<string, string> = {
  "X-Content-Type-Options": "nosniff",
  "Referrer-Policy": "strict-origin-when-cross-origin",
  "X-Frame-Options": "SAMEORIGIN",
  "Permissions-Policy": "geolocation=(), microphone=(), camera=()",
};

function ttlFor(path: string): number | null {
  for (const [pattern, ttl] of CACHEABLE) {
    if (pattern.test(path)) return ttl;
  }
  return null;
}

function withHeaders(res: Response, extra: Record<string, string> = {}): Response {
  const out = new Response(res.body, res);
  for (const [k, v] of Object.entries({ ...SECURITY_HEADERS, ...extra })) {
    out.headers.set(k, v);
  }
  return out;
}

export default {
  async fetch(request: Request, env: Env, ctx: ExecutionContext): Promise<Response> {
    const url = new URL(request.url);

    if (!url.pathname.startsWith("/api/")) {
      // Anything that is not an API call is a static asset.
      return withHeaders(await env.ASSETS.fetch(request));
    }

    const apiPath = url.pathname.slice("/api".length) || "/";
    const upstream = new URL(env.API_ORIGIN.replace(/\/$/, "") + apiPath + url.search);

    if (request.method === "OPTIONS") {
      return withHeaders(new Response(null, { status: 204 }), {
        "Access-Control-Allow-Origin": url.origin,
        "Access-Control-Allow-Methods": "GET, POST, OPTIONS",
        "Access-Control-Allow-Headers": "content-type",
        "Access-Control-Max-Age": "86400",
      });
    }

    const ttl = request.method === "GET" ? ttlFor(apiPath) : null;
    const cache = caches.default;
    const cacheKey = new Request(upstream.toString(), { method: "GET" });

    if (ttl !== null) {
      const hit = await cache.match(cacheKey);
      if (hit) return withHeaders(hit, { "X-Cache": "HIT" });
    }

    let res: Response;
    try {
      res = await fetch(upstream.toString(), {
        method: request.method,
        headers: {
          "Content-Type": request.headers.get("Content-Type") ?? "application/json",
          // Pass the caller's IP upstream for logging and abuse handling.
          "X-Forwarded-For": request.headers.get("CF-Connecting-IP") ?? "",
        },
        body: request.method === "GET" || request.method === "HEAD" ? undefined : await request.text(),
      });
    } catch {
      return withHeaders(
        Response.json({ error: "The booking service is unreachable. Please try again." }, { status: 502 }),
      );
    }

    const body = await res.text();
    const out = new Response(body, {
      status: res.status,
      headers: {
        "Content-Type": "application/json",
        "Cache-Control": ttl !== null && res.ok ? `public, max-age=${ttl}` : "no-store",
      },
    });

    if (ttl !== null && res.ok) {
      ctx.waitUntil(cache.put(cacheKey, out.clone()));
    }

    return withHeaders(out, { "X-Cache": ttl !== null ? "MISS" : "BYPASS" });
  },
} satisfies ExportedHandler<Env>;
