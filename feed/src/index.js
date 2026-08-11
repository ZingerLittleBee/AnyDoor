import appcast from "./appcast.xml";

const headers = {
  "Cache-Control": "public, max-age=300, must-revalidate",
  "Content-Type": "application/xml; charset=utf-8",
  "X-Content-Type-Options": "nosniff",
};

export default {
  async fetch(request) {
    const url = new URL(request.url);
    if (url.pathname !== "/appcast.xml" || !["GET", "HEAD"].includes(request.method)) {
      return new Response("Not Found", { status: 404 });
    }
    return new Response(request.method === "HEAD" ? null : appcast, { headers });
  },
};
