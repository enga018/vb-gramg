/* Shared, conservative Edge Function request helper for VBGRAMG.
 * No persistent cache and no automatic retries: financial writes must never be replayed.
 */
(function () {
  "use strict";

  const inFlightReads = new Map();

  function clientReady() {
    if (!window.VBGRAMG_SUPABASE_READY) {
      return Promise.reject(new Error("Shared Supabase client has not been initialised."));
    }
    return window.VBGRAMG_SUPABASE_READY;
  }

  async function request(functionName, options) {
    const settings = options || {};
    const body = settings.body || {};
    const timeoutMs = Number.isFinite(settings.timeoutMs) ? settings.timeoutMs : 30000;
    const deduplicate = settings.deduplicate === true;
    const key = deduplicate ? functionName + ":" + JSON.stringify(body) : null;

    if (key && inFlightReads.has(key)) return inFlightReads.get(key);

    const operation = (async () => {
      const client = await clientReady();
      let timeoutId;
      try {
        const result = await Promise.race([
          client.functions.invoke(functionName, { body }),
          new Promise((_, reject) => {
            timeoutId = window.setTimeout(
              () => reject(new Error(functionName + " request timed out after " + Math.round(timeoutMs / 1000) + " seconds.")),
              timeoutMs
            );
          })
        ]);
        if (result.error) throw new Error(result.error.message || ("Request to " + functionName + " failed."));
        if (!result.data) throw new Error("The " + functionName + " service returned an empty response.");
        if (result.data.error) throw new Error(String(result.data.error));
        return result.data;
      } finally {
        if (timeoutId) window.clearTimeout(timeoutId);
      }
    })();

    if (key) inFlightReads.set(key, operation);
    try {
      return await operation;
    } finally {
      if (key && inFlightReads.get(key) === operation) inFlightReads.delete(key);
    }
  }

  async function invoke(functionName, options) {
    try {
      return { data: await request(functionName, options), error: null };
    } catch (error) {
      return { data: null, error };
    }
  }

  window.VBGRAMGData = Object.freeze({ request, invoke });
})();
