/* Shared MIS import parsing and matching helpers. UI and Supabase workflows stay in mis-import.html. */
(function () {
  "use strict";
    function parsePastedTable(raw) {
      const text = String(raw || '').replace(/\r/g, '').trim();
      if (!text) return [];
      const lines = text.split('\n').filter(line => line.trim().length > 0);
      const delimiter = lines.some(line => line.includes('\t')) ? '\t' : lines.some(line => line.includes('|')) ? '|' : ',';
      return lines.map(line => {
        if (delimiter === '\t') return line.split('\t').map(cell => cell.trim());
        if (delimiter === '|') {
          const cells = line.split('|').map(cell => cell.trim());
          if (cells.length && cells[0] === '') cells.shift();
          if (cells.length && cells[cells.length - 1] === '') cells.pop();
          return cells;
        }
        const cells = []; let cell = '', quoted = false;
        for (let i = 0; i < line.length; i++) {
          const ch = line[i];
          if (ch === '"' && line[i + 1] === '"' && quoted) { cell += '"'; i++; }
          else if (ch === '"') quoted = !quoted;
          else if (ch === ',' && !quoted) { cells.push(cell.trim()); cell = ''; }
          else cell += ch;
        }
        cells.push(cell.trim()); return cells;
      });
    }

    const normText = value => String(value == null ? '' : value).replace(/\u00a0/g, ' ').replace(/&amp;/gi, '&').replace(/\s+/g, ' ').trim();
    const headerKey = value => normText(value).toLowerCase().replace(/&/g, ' and ').replace(/[^a-z0-9]+/g, ' ').replace(/\s+/g, ' ').trim();
    function findColumn(header, aliases) {
      const keys=header.map(headerKey);
      let index=keys.findIndex(k=>aliases.includes(k));
      if(index>=0)return index;
      return keys.findIndex(k=>aliases.some(alias=>k.includes(alias)||alias.includes(k)));
    }
    function isDeletedRow(row, idx) {
      const household = idx.household >= 0 ? normText(row[idx.household]) : '';
      const name = idx.name >= 0 ? normText(row[idx.name]) : '';
      const remarks = idx.remarks >= 0 ? normText(row[idx.remarks]) : '';
      return household.includes('*') || name.includes('*') || /\bdeleted\b/i.test(remarks);
    }
    function cleanName(value) { return normText(value).replace(/\*/g,'').normalize('NFKC').toLocaleLowerCase().replace(/[^\p{L}\p{N}]+/gu,' ').trim(); }

    const normText = value => String(value == null ? '' : value).replace(/\u00a0/g, ' ').replace(/&amp;/gi, '&').replace(/\s+/g, ' ').trim();
    const headerKey = value => normText(value).toLowerCase().replace(/&/g, ' and ').replace(/[^a-z0-9]+/g, ' ').replace(/\s+/g, ' ').trim();
    function findColumn(header, aliases) {
      const keys=header.map(headerKey);
      let index=keys.findIndex(k=>aliases.includes(k));
      if(index>=0)return index;
      return keys.findIndex(k=>aliases.some(alias=>k.includes(alias)||alias.includes(k)));
    }
    function isDeletedRow(row, idx) {
      const household = idx.household >= 0 ? normText(row[idx.household]) : '';
      const name = idx.name >= 0 ? normText(row[idx.name]) : '';
      const remarks = idx.remarks >= 0 ? normText(row[idx.remarks]) : '';
      return household.includes('*') || name.includes('*') || /\bdeleted\b/i.test(remarks);
    }
    function cleanName(value) { return normText(value).replace(/\*/g,'').normalize('NFKC').toLocaleLowerCase().replace(/[^\p{L}\p{N}]+/gu,' ').trim(); }

  window.VBGRAMGMISImport = Object.freeze({
    parsePastedTable, normText, headerKey, findColumn, isDeletedRow, cleanName
  });
})();
