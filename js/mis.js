/* Shared MIS domain helpers.
 * Pure transformations only: database access and UI rendering remain in the page/server.
 */
(function () {
  "use strict";

  function normalize(value) {
    return String(value == null ? "" : value).trim();
  }

  function applicantStableKey(groupKey, values, nameIndex, applicantNoIndex, uniqueIdIndex) {
    const uniqueId = normalize(uniqueIdIndex >= 0 ? values[uniqueIdIndex] : "");
    if (uniqueId) return "uid:" + uniqueId.toLocaleLowerCase();
    const fallback = [
      groupKey,
      normalize(applicantNoIndex >= 0 ? values[applicantNoIndex] : ""),
      normalize(nameIndex >= 0 ? values[nameIndex] : "")
    ].map(value => value.toLocaleLowerCase());
    return "fallback:" + JSON.stringify(fallback);
  }

  function buildJobCards(rows, headers) {
    const jobIndex = headers.findIndex(h => /^(job card number|jobcard number)$/i.test(h.trim()));
    const fallbackIndex = headers.findIndex(h => /^jc no\.?$/i.test(h.trim()));
    const householdIndex = headers.findIndex(h => /head of household/i.test(h));
    const nameIndex = headers.findIndex(h => /name of applicant|applicant name/i.test(h));
    const applicantNoIndex = headers.findIndex(h => /applicant no/i.test(h));
    const uniqueIdIndex = headers.findIndex(h => /^unique id$/i.test(h.trim()));
    const keyIndex = jobIndex >= 0 ? jobIndex : fallbackIndex;
    const groups = new Map();

    rows.forEach((row, index) => {
      const values = row.values || [];
      const key = normalize(keyIndex >= 0 ? values[keyIndex] : "") || "(Job card number missing)";
      if (!groups.has(key)) {
        groups.set(key, {
          key,
          household: normalize(householdIndex >= 0 ? values[householdIndex] : ""),
          applicants: [],
          firstRow: index
        });
      }
      const group = groups.get(key);
      if (!group.household && householdIndex >= 0) {
        group.household = normalize(values[householdIndex]);
      }
      group.applicants.push({
        name: normalize(nameIndex >= 0 ? values[nameIndex] : ""),
        number: normalize(applicantNoIndex >= 0 ? values[applicantNoIndex] : ""),
        selectionKey: applicantStableKey(key, values, nameIndex, applicantNoIndex, uniqueIdIndex),
        values,
        rowNumber: row.rowNumber
      });
    });

    return Array.from(groups.values());
  }

  function filterJobCards(jobCards, selectedApplicants, query, filter) {
    const q = String(query || "").trim().toLocaleLowerCase();
    return jobCards.filter(group => {
      const hasSelection = selectedApplicants.has(group.key);
      if (filter === "selected" && !hasSelection) return false;
      if (filter === "none" && hasSelection) return false;
      return !q || [
        group.key,
        group.household,
        ...group.applicants.flatMap(applicant => [
          applicant.name,
          applicant.number,
          ...applicant.values.map(normalize)
        ])
      ].some(value => String(value || "").toLocaleLowerCase().includes(q));
    });
  }

  function getSummary(jobCards, totalApplicants, selectedApplicants) {
    const validJobCards = jobCards.filter(group => group.key !== "(Job card number missing)");
    const selectedCount = validJobCards.filter(group => selectedApplicants.has(group.key)).length;
    return {
      totalJobCards: validJobCards.length,
      totalApplicants,
      totalDemand: selectedCount,
      totalUnwilling: validJobCards.length - selectedCount
    };
  }

  window.VBGRAMGMIS = Object.freeze({
    normalize,
    buildJobCards,
    filterJobCards,
    getSummary
  });
})();
