// Cloudflare Worker for https://app.heyvedu.com/download.
// Redirects to the DMG named in the Sparkle appcast, so the link always follows the
// latest release without changes. Needs an R2 bucket binding named BUCKET (bucket
// "heyvedu"). Setup steps: docs/RELEASING.md, "Website download link".

const FEED_KEY = "updates/appcast.xml";
const DMG_PREFIX = "https://app.heyvedu.com/updates/";
const FALLBACK = "https://heyvedu.com/#requirements";

function redirect(location) {
  // Never cache the redirect: it changes with every release.
  return new Response(null, { status: 302, headers: { Location: location, "Cache-Control": "no-store" } });
}

export default {
  async fetch(request, env) {
    if (request.method !== "GET" && request.method !== "HEAD") {
      return new Response("Method not allowed", { status: 405, headers: { Allow: "GET, HEAD" } });
    }
    const feed = await env.BUCKET.get(FEED_KEY);
    if (!feed) return redirect(FALLBACK);
    const match = (await feed.text()).match(/<enclosure\b[^>]*\burl="([^"]+)"/);
    const url = match?.[1];
    // Only redirect to a DMG in our own updates folder.
    if (!url || !url.startsWith(DMG_PREFIX) || !url.endsWith(".dmg")) return redirect(FALLBACK);
    return redirect(url);
  },
};
