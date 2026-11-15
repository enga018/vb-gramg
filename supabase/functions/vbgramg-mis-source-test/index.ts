import "jsr:@supabase/functions-js/edge-runtime.d.ts";

const REPORT_URL = "https://vbgramgrep.dord.gov.in/VBGRAMG/writereaddata/citizen_out/panchregpeople_2207001005_eng2627.html";
const corsHeaders = {
  "Access-Control-Allow-Origin": "https://enga018.github.io",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type",
  "Access-Control-Allow-Methods": "POST, OPTIONS",
  "Vary": "Origin",
};

Deno.serve(async (req: Request) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: corsHeaders });
  if (req.method !== "POST") {
    return Response.json({ error: "Use POST" }, { status: 405, headers: corsHeaders });
  }

  try {
    const response = await fetch(REPORT_URL, {
      method: "GET",
      redirect: "follow",
      headers: { "User-Agent": "VBGRAMG-MIS-Reader/1.0", "Accept": "text/html" },
      signal: AbortSignal.timeout(30000),
    });
    if (!response.ok) {
      return Response.json({
        fetchSucceeded: false,
        httpStatus: response.status,
        error: "The official government report returned HTTP " + response.status + ".",
        databaseChanged: false,
      }, { status: 502, headers: corsHeaders });
    }

    const html = await response.text();
    const bytesReceived = new TextEncoder().encode(html).length;
    const title = html.match(/<title[^>]*>([\\s\\S]*?)<\\/title>/i)?.[1]?.replace(/<[^>]*>/g, "").trim() ?? null;
    const reportHeadingFound = /Registration Application Register/i.test(html);
    const villageNameFound = /NEW\\s*SERCHHIP\\s*North/i.test(html);
    if (bytesReceived > 8_000_000 || !reportHeadingFound || !villageNameFound || !/<table[\\s>]/i.test(html)) {
      return Response.json({
        fetchSucceeded: false,
        httpStatus: response.status,
        title,
        reportHeadingFound,
        villageNameFound,
        bytesReceived,
        error: "The retrieved page failed report validation.",
        databaseChanged: false,
      }, { status: 422, headers: corsHeaders });
    }

    return Response.json({
      fetchSucceeded: true,
      httpStatus: response.status,
      finalUrl: response.url,
      contentType: response.headers.get("content-type"),
      bytesReceived,
      title,
      reportHeadingFound,
      villageNameFound,
      tableRowTags: (html.match(/<tr\\b/gi) ?? []).length,
      html,
      databaseChanged: false,
    }, { headers: { ...corsHeaders, "Cache-Control": "no-store" } });
  } catch (error) {
    return Response.json({
      fetchSucceeded: false,
      error: error instanceof Error ? error.message : "Unknown fetch error",
      databaseChanged: false,
    }, { status: 502, headers: corsHeaders });
  }
});
