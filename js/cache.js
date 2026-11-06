/* Shared, in-memory data cache for VBGRAMG.
 *
 * This module stores completed read results only. It does not intercept requests,
 * persist data to browser storage, retry requests, or cache mutations.
 *
 * Load after js/supabase-client.js. Pages opt in explicitly through
 * window.VBGRAMGCache.get/set/getOrLoad/invalidate.
 */
(function () {
  "use strict";

  const DEFAULT_TTL_MS = 30 * 1000;
  const MAX_ENTRIES = 200;
  const entries = new Map();
  const inFlightReads = new Map();
  const keyVersions = new Map();
  let userEpoch = 0;
  let activeUserId = null;
  let authSubscription = null;

  function now() {
    return Date.now();
  }

  function namespaceKey(userId, key) {
    return String(userId) + "::" + String(key);
  }

  function cloneValue(value) {
    if (typeof structuredClone === "function") return structuredClone(value);
    if (value === undefined) return undefined;
    if (value === null || typeof value !== "object") return value;
    return JSON.parse(JSON.stringify(value));
  }

  function removeExpired() {
    const timestamp = now();
    for (const [key, entry] of entries) {
      if (!entry || entry.expiresAt <= timestamp) entries.delete(key);
    }
  }

  function trimEntries() {
    removeExpired();
    while (entries.size > MAX_ENTRIES) {
      const oldestKey = entries.keys().next().value;
      if (oldestKey === undefined) break;
      entries.delete(oldestKey);
    }
  }

  function setUser(userId) {
    const nextUserId = userId == null || userId === "" ? null : String(userId);
    if (nextUserId === activeUserId) return;
    // Never allow one authenticated account to see another account's cache.
    userEpoch++;
    entries.clear();
    inFlightReads.clear();
    keyVersions.clear();
    activeUserId = nextUserId;
  }

  function bumpKeyVersion(fullKey) {
    keyVersions.set(fullKey, (keyVersions.get(fullKey) || 0) + 1);
  }

  function getUserId() {
    return activeUserId;
  }

  function get(key) {
    if (!activeUserId || key == null || key === "") {
      return { hit: false, value: undefined };
    }
    const fullKey = namespaceKey(activeUserId, key);
    const entry = entries.get(fullKey);
    if (!entry) return { hit: false, value: undefined };
    if (entry.expiresAt <= now()) {
      entries.delete(fullKey);
      return { hit: false, value: undefined };
    }
    // Refresh insertion order for simple LRU eviction.
    entries.delete(fullKey);
    entries.set(fullKey, entry);
    return { hit: true, value: cloneValue(entry.value) };
  }

  function set(key, value, ttlMs) {
    if (!activeUserId) return false;
    if (key == null || key === "") throw new Error("A cache key is required.");
    const ttl = Number.isFinite(ttlMs) ? Math.max(0, ttlMs) : DEFAULT_TTL_MS;
    if (ttl === 0) {
      invalidate(key);
      return false;
    }
    const fullKey = namespaceKey(activeUserId, key);
    if (inFlightReads.has(fullKey)) bumpKeyVersion(fullKey);
    inFlightReads.delete(fullKey);
    entries.delete(fullKey);
    entries.set(fullKey, {
      value: cloneValue(value),
      expiresAt: now() + ttl
    });
    trimEntries();
    return true;
  }

  async function getOrLoad(key, loader, ttlMs) {
    if (typeof loader !== "function") throw new Error("A cache loader function is required.");
    const cached = get(key);
    if (cached.hit) return cached.value;
    if (!activeUserId) return loader();

    const userAtStart = activeUserId;
    const epochAtStart = userEpoch;
    const fullKey = namespaceKey(userAtStart, key);
    if (inFlightReads.has(fullKey)) return cloneValue(await inFlightReads.get(fullKey));
    const versionAtStart = keyVersions.get(fullKey) || 0;

    const operation = Promise.resolve().then(loader).then(value => {
      // A request started by one account must not populate another account's cache.
      if (activeUserId === userAtStart &&
          userEpoch === epochAtStart &&
          (keyVersions.get(fullKey) || 0) === versionAtStart &&
          inFlightReads.get(fullKey) === operation) {
        set(key, value, ttlMs);
      }
      return value;
    });
    inFlightReads.set(fullKey, operation);
    try {
      return await operation;
    } finally {
      if (inFlightReads.get(fullKey) === operation) {
        inFlightReads.delete(fullKey);
        keyVersions.delete(fullKey);
      }
    }
  }

  function invalidate(key) {
    if (!activeUserId || key == null) return;
    const fullKey = namespaceKey(activeUserId, key);
    if (inFlightReads.has(fullKey)) bumpKeyVersion(fullKey);
    entries.delete(fullKey);
    inFlightReads.delete(fullKey);
  }

  function invalidatePrefix(prefix) {
    if (!activeUserId) return;
    const start = namespaceKey(activeUserId, prefix);
    for (const key of entries.keys()) {
      if (key.startsWith(start)) entries.delete(key);
    }
    for (const key of inFlightReads.keys()) {
      if (key.startsWith(start)) {
        bumpKeyVersion(key);
        inFlightReads.delete(key);
      }
    }
  }

  function clear() {
    if (!activeUserId) return;
    const start = String(activeUserId) + "::";
    for (const key of entries.keys()) {
      if (key.startsWith(start)) entries.delete(key);
    }
    for (const key of inFlightReads.keys()) {
      if (key.startsWith(start)) {
        bumpKeyVersion(key);
        inFlightReads.delete(key);
      }
    }
  }

  function clearAll() {
    userEpoch++;
    entries.clear();
    inFlightReads.clear();
    keyVersions.clear();
    activeUserId = null;
  }

  async function connectAuth() {
    try {
      const client = await window.VBGRAMG_SUPABASE_READY;
      if (!client || !client.auth) return;
      const { data, error } = await client.auth.getSession();
      if (!error) setUser(data && data.session && data.session.user ? data.session.user.id : null);
      if (authSubscription) authSubscription.unsubscribe();
      const result = client.auth.onAuthStateChange((event, session) => {
        const nextId = session && session.user ? session.user.id : null;
        if (event === "SIGNED_OUT" || !nextId) {
          clearAll();
        } else {
          setUser(nextId);
        }
      });
      authSubscription = result && result.data ? result.data.subscription : null;
    } catch (_) {
      // Cache is an optional optimization. If auth cannot be resolved, it stays disabled.
      clearAll();
    }
  }

  window.VBGRAMGCache = Object.freeze({
    get,
    set,
    getOrLoad,
    invalidate,
    invalidatePrefix,
    clear,
    clearAll,
    setUser,
    getUserId,
    get size() {
      removeExpired();
      return entries.size;
    }
  });

  if (window.VBGRAMG_SUPABASE_READY) connectAuth();
})();
