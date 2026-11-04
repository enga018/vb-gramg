/* Shared FTO import domain helpers.
 * Pure parsing and normalization only. UI, duplicate lookup, and financial writes
 * remain in the page / authenticated Supabase Edge Functions.
 */
(function () {
  "use strict";

  const JOB_CARD_PATTERN = /\bMZ-\d{2}-(?:\d{3}-){2,3}\d{3}\/\d+(?:-[A-Z]+)?\b/i;

  function parsePastedTable(raw) {
    const text = String(raw || "").replace(/\r/g, "").trim();
    if (!text) return [];
    const lines = text.split("\n").filter(line => line.trim().length > 0);
    const delimiter = lines.some(line => line.includes("\t")) ? "\t" : lines.some(line => line.includes("|")) ? "|" : ",";
    const parsed = lines.map(line => {
      let cells;
      if (delimiter === "|") {
        cells = line.split("|").map(cell => cell.trim());
        if (cells.length && cells[0] === "") cells.shift();
        if (cells.length && cells[cells.length - 1] === "") cells.pop();
      } else if (delimiter === "\t") {
        cells = line.split("\t").map(cell => cell.trim());
      } else {
        cells = [];
        let cell = "", quoted = false;
        for (let i = 0; i < line.length; i++) {
          const ch = line[i];
          if (ch === '"' && line[i + 1] === '"' && quoted) { cell += '"'; i++; }
          else if (ch === '"') quoted = !quoted;
          else if (ch === "," && !quoted) { cells.push(cell.trim()); cell = ""; }
          else cell += ch;
        }
        cells.push(cell.trim());
      }
      return cells;
    });
    if (delimiter === "\t") {
      const merged = [];
      for (const cells of parsed) {
        const continuation = (cells[0] || "").startsWith("(") && merged.length && merged[merged.length - 1].length === 3;
        if (continuation) {
          const previous = merged[merged.length - 1];
          previous[2] += "\n" + cells[0];
          previous.push(...cells.slice(1));
        } else merged.push(cells);
      }
      return merged;
    }
    return parsed;
  }

  function isHeaderOrSeparator(row) {
    const normalized = row.map(cell => cell.replace(/\*\*/g, "").replace(/<br\s*\/?>/gi, " ").replace(/\s+/g, " ").trim().toLowerCase());
    if (normalized.some(cell => cell.includes("block name")) && normalized.some(cell => cell.includes("job card no"))) return true;
    return normalized.length > 0 && normalized.every(cell => /^:?-+:?$/.test(cell));
  }

  function jobCardFromRow(row) {
    const text = String(row[2] || "").replace(/<br\s*\/?>/gi, " ").replace(/[\r\n]+/g, " ").replace(/\s+/g, " ").trim();
    const match = text.match(JOB_CARD_PATTERN);
    return match ? match[0].toUpperCase() : "";
  }

  function villageFromRow(row) {
    let text = String(row[2] || "").replace(/<br\s*\/?>/gi, " ").replace(/[\r\n]+/g, " ").trim();
    const jobCard = text.match(JOB_CARD_PATTERN);
    if (jobCard) text = text.replace(jobCard[0], " ");
    return text.replace(/[()\[\]{}]/g, " ").replace(/\s+/g, " ").replace(/^[\s,;:.-]+|[\s,;:.-]+$/g, "").trim();
  }

  function normalizeVillage(value) {
    return String(value || "").toUpperCase().replace(/[^A-Z0-9 ]/g, " ").replace(/\s+/g, " ").trim();
  }

  function parseAmount(value) {
    const cleaned = String(value || "").replace(/[₹,\s]/g, "").replace(/[^\d.-]/g, "");
    const amount = Number(cleaned);
    return Number.isFinite(amount) && amount > 0 ? amount : 0;
  }

  function periodToDate(value) {
    const text = String(value || "").trim();
    return /^\d{4}-\d{2}-01$/.test(text) ? text : "";
  }

  function rawStatus(row) {
    const value = String(row[12] || "").replace(/<br\s*\/?>/gi, " ").trim().toLowerCase();
    return value === "processed" ? "processed" : value === "rejected" ? "rejected" : value === "" ? "blank" : "other";
  }

  function bytesToHex(bytes) {
    return [...new Uint8Array(bytes)].map(byte => byte.toString(16).padStart(2, "0")).join("");
  }

  async function sha256(value) {
    return bytesToHex(await crypto.subtle.digest("SHA-256", new TextEncoder().encode(value)));
  }

  window.VBGRAMGFTO = Object.freeze({
    parsePastedTable,
    isHeaderOrSeparator,
    jobCardFromRow,
    villageFromRow,
    normalizeVillage,
    parseAmount,
    periodToDate,
    rawStatus,
    bytesToHex,
    sha256
  });
})();
