/* Shared, session-persistent data cache for VBGRAMG.
 *
 * Stores completed read results only. It does not intercept requests, retry
 * requests, or cache mutations. sessionStorage lets opt-in reads survive
 * same-tab navigation and reloads; closing the tab ends the storage session.
 *
 * Load after js/supabase-client.js. Pages must call setUser(user.id) only
 * after their approved-user access check succeeds.
 */
(function () {
  "use strict";

  const DEFAULT_TTL_MS = 30 * 1000;
  const MAX_ENTRIES = 200;
  const STORAGE_PREFIX = "vbgramg-cache:v1:";
  const ACTIVE_USER_KEY = STORAGE_PREFIX + "active-user";
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

  function storageKey(userId, key) {
    return STORAGE_PREFIX + encodeURIComponent(String(userId)) + ":" + encodeURIComponent(String(key));
  }

  function userStoragePrefix(userId) {
    return STORAGE_PREFIX + encodeURIComponent(String(userId)) + ":";
  }

  function getStorage() {
    try {
      return window.sessionStorage || null;
    } catch (_) {
      return null;
    }
  }

  function cloneValue(value) {
    if (typeof structuredClone === "function") return structuredClone(value);
    if (value === undefined) return undefined;
    if (value === null || typeof value !== "object") return value;
    return JSON.parse(JSON.stringify(value));
  }

  function readStored(userId, key) {
    const storage = getStorage();
    if (!storage) return null;
    const id = storageKey(userId, key);
    try {
      const raw = storage.getItem(id);
      if (!raw) return null;
      const record = JSON.parse(raw);
      if (!record || record.version !== 1 || !Number.isFinite(record.expiresAt) ||
          record.expiresAt <= now() || !Object.prototype.hasOwnProperty.call(record, "value")) {
        storage.removeItem(id);
        return null;
      }
      return record;
    } catch (_) {
      try { storage.removeItem(id); } catch (_) {}
      return null;
    }
  }

  function removeExpiredMemory() {
    const timestamp = now();
    for (const [key, entry] of entries) {
      if (!entry || entry.expiresAt <= timestamp) entries.delete(key);
    }
  }

  function trimMemory() {
    removeExpiredMemory();
    while (entries.size > MAX_ENTRIES) {
      const oldestKey = entries.keys().next().value;
      if (oldestKey === undefined) break;
      entries.delete(oldestKey);
    }
  }

  function trimPersistent(userId) {
    const storage = getStorage();
    if (!storage) return [];
    const prefix = userStoragePrefix(userId);
    const records = [];
    try {
      for (let i = storage.length - 1; i >= 0; i--) {
        const id = storage.key(i);
        if (!id || !id.startsWith(prefix)) continue;
        let record = null;
        try { record = JSON.parse(storage.getItem(id)); } catch (_) {}
        if (!record || record.version !== 1 || !Number.isFinite(record.expiresAt) ||
            record.expiresAt <= now()) {
          storage.removeItem(id);
        } else {
          records.push({ id, touchedAt: Number(record.touchedAt) || 0 });
        }
      }
      records.sort((a, b) => a.touchedAt - b.touchedAt);
      while (records.length >= MAX_ENTRIES) {
        const oldest = records.shift();
        if (oldest) storage.removeItem(oldest.id);
      }
    } catch (_) {}
    return records;
  }

  function persist(userId, key, value, expiresAt) {
    const storage = getStorage();
    if (!storage) return false;
    let serialized;
    try {
      serialized = JSON.stringify({
        version: 1,
        expiresAt,
        touchedAt: now(),
        value
      });
    } catch (_) {
      return false;
    }
    const id = storageKey(userId, key);
    trimPersistent(userId);
    try {
      storage.setItem(id, serialized);
      return true;
    } catch (_) {
      // A large MIS response or a nearly-full session can exceed browser quota.
      // Evict older cache entries and retry a small bounded number of times.
      for (let attempt = 0; attempt < 3; attempt++) {
        const records = trimPersistent(userId);
        if (!records.length) break;
        try {
          storage.setItem(id, serialized);
          return true;
        } catch (_) {}
      }
      return false;
    }
  }

  function clearPersistentUser(userId) {
    const storage = getStorage();
    if (!storage) return;
    const prefix = userStoragePrefix(userId);
    try {
      for (let i = storage.length - 1; i >= 0; i--) {
        const id = storage.key(i);
        if (id && id.startsWith(prefix)) storage.removeItem(id);
      }
    } catch (_) {}
  }

  function clearPersistentAll() {
    const storage = getStorage();
    if (!storage) return;
    try {
      for (let i = storage.length - 1; i >= 0; i--) {
        const id = storage.key(i);
        if (id && id.startsWith(STORAGE_PREFIX)) storage.removeItem(id);
      }
    } catch (_) {}
  }

  function setUser(userId) {
    const nextUserId = userId == null || userId === "" ? null : String(userId);
    if (nextUserId === activeUserId) return;
    const storage = getStorage();
    let storedUserId = null;
    try { storedUserId = storage && storage.getItem(ACTIVE_USER_KEY); } catch (_) {}
    // On reload activeUserId starts empty. Preserve the same user's session
    // cache, but discard it if a different account was last approved in this tab.
    if (activeUserId && activeUserId !== nextUserId) {
      clearAll();
    } else if (storedUserId && storedUserId !== nextUserId) {
      clearPersistentAll();
    }
    userEpoch++;
    entries.clear();
    inFlightReads.clear();
    keyVersions.clear();
    activeUserId = nextUserId;
    try {
      if (storage) {
        if (nextUserId) storage.setItem(ACTIVE_USER_KEY, nextUserId);
        else storage.removeItem(ACTIVE_USER_KEY);
      }
    } catch (_) {}
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
    if (entry && entry.expiresAt > now()) {
      entries.delete(fullKey);
      entries.set(fullKey, entry);
      return { hit: true, value: cloneValue(entry.value) };
    }
    if (entry) entries.delete(fullKey);

    const stored = readStored(activeUserId, key);
    if (!stored) return { hit: false, value: undefined };
    const restored = { value: stored.value, expiresAt: stored.expiresAt };
    entries.set(fullKey, restored);
    trimMemory();
    // Refresh persistent LRU timestamp without extending the original expiry.
    persist(activeUserId, key, restored.value, restored.expiresAt);
    return { hit: true, value: cloneValue(restored.value) };
  }

  function set(key, value, ttlMs, fromLoader) {
    if (!activeUserId) return false;
    if (key == null || key === "") throw new Error("A cache key is required.");
    const ttl = Number.isFinite(ttlMs) ? Math.max(0, ttlMs) : DEFAULT_TTL_MS;
    if (ttl === 0) {
      invalidate(key);
      return false;
    }
    const fullKey = namespaceKey(activeUserId, key);
    if (!fromLoader) {
      if (inFlightReads.has(fullKey)) bumpKeyVersion(fullKey);
      inFlightReads.delete(fullKey);
    }
    const expiresAt = now() + ttl;
    entries.delete(fullKey);
    entries.set(fullKey, { value: cloneValue(value), expiresAt });
    trimMemory();
    persist(activeUserId, key, value, expiresAt);
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
      if (activeUserId === userAtStart &&
          userEpoch === epochAtStart &&
          (keyVersions.get(fullKey) || 0) === versionAtStart &&
          inFlightReads.get(fullKey) === operation) {
        set(key, value, ttlMs, true);
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
    const storage = getStorage();
    try { if (storage) storage.removeItem(storageKey(activeUserId, key)); } catch (_) {}
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
    const storage = getStorage();
    const storedPrefix = userStoragePrefix(activeUserId) + encodeURIComponent(String(prefix));
    if (storage) {
      try {
        for (let i = storage.length - 1; i >= 0; i--) {
          const id = storage.key(i);
          if (id && id.startsWith(storedPrefix)) storage.removeItem(id);
        }
      } catch (_) {}
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
    clearPersistentUser(activeUserId);
  }

  function clearAll() {
    userEpoch++;
    entries.clear();
    inFlightReads.clear();
    keyVersions.clear();
    activeUserId = null;
    clearPersistentAll();
  }

  async function connectAuth() {
    try {
      const client = await window.VBGRAMG_SUPABASE_READY;
      if (!client || !client.auth) return;
      if (authSubscription) authSubscription.unsubscribe();
      const result = client.auth.onAuthStateChange((event, session) => {
        const nextId = session && session.user ? String(session.user.id) : null;
        // Pages enable the cache only after vbgramg-app-access approves the user.
        // Auth changes clear the cache; they never grant cache access by themselves.
        if (event === "SIGNED_OUT" || !nextId || (activeUserId && nextId !== activeUserId)) {
          clearAll();
        }
      });
      authSubscription = result && result.data ? result.data.subscription : null;
    } catch (_) {
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
      removeExpiredMemory();
      return entries.size;
    }
  });

  if (window.VBGRAMG_SUPABASE_READY) connectAuth();
})();
