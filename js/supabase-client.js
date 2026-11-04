/* Shared Supabase client bootstrap for VBGRAMG.
 * Uses the public publishable key only. Protected data remains behind authenticated Edge Functions.
 */
(function () {
  "use strict";

  const SUPABASE_URL = "https://trtzhafgvqosjwrgckty.supabase.co";
  const SUPABASE_PUBLISHABLE_KEY = "sb_publishable_IzELPnGRMeGamS8jQva55w_hJaL44rb";
  const CDN_URLS = [
    "https://cdn.jsdelivr.net/npm/@supabase/supabase-js@2",
    "https://unpkg.com/@supabase/supabase-js@2"
  ];

  function loadLibrary(url) {
    return new Promise((resolve, reject) => {
      const script = document.createElement("script");
      const timeout = window.setTimeout(() => {
        script.remove();
        reject(new Error("Supabase library loading timed out."));
      }, 12000);
      script.src = url;
      script.async = true;
      script.onload = () => {
        window.clearTimeout(timeout);
        if (window.supabase && typeof window.supabase.createClient === "function") resolve();
        else reject(new Error("Supabase library loaded without its client API."));
      };
      script.onerror = () => {
        window.clearTimeout(timeout);
        script.remove();
        reject(new Error("Could not load Supabase library from " + url));
      };
      document.head.appendChild(script);
    });
  }

  async function ensureLibrary() {
    if (window.supabase && typeof window.supabase.createClient === "function") return;
    let lastError;
    for (const url of CDN_URLS) {
      try {
        await loadLibrary(url);
        return;
      } catch (error) {
        lastError = error;
      }
    }
    throw lastError || new Error("Supabase library is unavailable.");
  }

  window.VBGRAMG_SUPABASE_READY = ensureLibrary().then(() => {
    if (!window.vbgramgSupabase) {
      window.vbgramgSupabase = window.supabase.createClient(
        SUPABASE_URL,
        SUPABASE_PUBLISHABLE_KEY
      );
    }
    return window.vbgramgSupabase;
  });
})();
