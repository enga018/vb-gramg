#!/usr/bin/env python3
"""Cloud-hosted Playwright diagnostics for the official VBGRAMG MIS register.

This is read-only: it only navigates the public portal and saves diagnostics.
It never contacts Supabase or changes active MIS. It does not use stealth,
CAPTCHA bypasses, or supplied session cookies.
"""
from __future__ import annotations

import json
import re
from datetime import datetime, timezone
from pathlib import Path
from urllib.parse import urlencode

from playwright.sync_api import sync_playwright, TimeoutError as PlaywrightTimeoutError

VILLAGE = "New Serchhip North"
REPORTING_ROOT = "https://vbgramgrep.dord.gov.in/VBGRAMG/"
PUBLIC_HOME = "https://vbgramg.dord.gov.in/vbgramg/home.aspx"
START_URL = REPORTING_ROOT + "Progofficer/PoIndexFrame.aspx?" + urlencode({
    "flag_debited": "S", "lflag": "eng", "District_Code": "2207",
    "district_name": "SERCHHIP", "state_name": "MIZORAM", "state_Code": "22",
    "finyear": "2026-2027", "check": "1", "block_name": "serchhip",
    "Block_Code": "2207001",
})
DIRECT_REGISTER_URL = REPORTING_ROOT + "writereaddata/citizen_out/panchregpeople_2207001005_eng2627.html"
OUT = Path("output")
OUT.mkdir(parents=True, exist_ok=True)


def inspect(page, label):
    try:
        page.wait_for_load_state("domcontentloaded", timeout=15000)
    except PlaywrightTimeoutError:
        pass
    try:
        page.wait_for_timeout(1500)
        data = page.evaluate("""() => {
          const norm = s => (s || '').replace(/\\s+/g, ' ').trim();
          return {
            finalUrl: location.href, title: document.title || '',
            readyState: document.readyState,
            bodyText: norm(document.body?.innerText || '').slice(0,5000),
            links: [...document.querySelectorAll('a[href]')].map(a => ({
              text: norm(a.innerText || a.textContent).slice(0,180), href:a.href
            })).filter(x => /job card|registration application|register|new serchhip north|panchregpeople/i.test(x.text+' '+x.href)).slice(0,100),
            frames: [...document.querySelectorAll('iframe,frame')].map(f => ({
              name:f.name||'', title:f.title||'', src:f.src||''
            })).slice(0,50),
            selects: [...document.querySelectorAll('select')].map(s => ({
              name:s.name||'', id:s.id||'',
              options:[...s.options].map(o=>({text:norm(o.text),value:o.value})).slice(0,100)
            })).slice(0,30),
            tableCount: document.querySelectorAll('table').length,
            tableRowCounts: [...document.querySelectorAll('table')].map(t=>t.rows.length).slice(0,30)
          };
        }""")
        data["label"] = label
        data["capturedAtUtc"] = datetime.now(timezone.utc).isoformat()
        (OUT / f"{label}.json").write_text(json.dumps(data, ensure_ascii=False, indent=2), encoding="utf-8")
        (OUT / f"{label}.html").write_text(page.content(), encoding="utf-8")
        return data
    except Exception as exc:
        return {"label": label, "url": page.url, "error": f"{type(exc).__name__}: {exc}"}


def all_frames(page):
    return [frame for frame in page.frames]


def click_text_any_frame(page, pattern, timeout=4000):
    rx = re.compile(pattern, re.I)
    for frame in all_frames(page):
        for locator in [frame.get_by_role("link", name=rx), frame.get_by_role("button", name=rx),
                        frame.get_by_text(rx, exact=False)]:
            try:
                if locator.count() and locator.first.is_visible():
                    locator.first.click(timeout=timeout)
                    page.wait_for_timeout(1500)
                    return {"clicked": pattern, "frameUrl": frame.url}
            except Exception:
                continue
    return None


def select_village_any_frame(page):
    for frame in all_frames(page):
        try:
            selects = frame.locator("select")
            for i in range(selects.count()):
                sel = selects.nth(i)
                options = sel.locator("option").all_text_contents()
                match = next((x.strip() for x in options if VILLAGE.casefold() in x.casefold()), None)
                if match:
                    sel.select_option(label=match, timeout=5000)
                    page.wait_for_timeout(1500)
                    return {"selectedVillage": match, "frameUrl": frame.url}
        except Exception:
            pass
    return None


def main():
    pages = []
    actions = []
    with sync_playwright() as p:
        browser = p.chromium.launch()
        context = browser.new_context(viewport={"width": 1440, "height": 1200}, locale="en-US")
        page = context.new_page()
        page.set_default_timeout(5000)
        for label, url in [("public-home", PUBLIC_HOME), ("reporting-entry", START_URL)]:
            try:
                response = page.goto(url, wait_until="domcontentloaded", timeout=45000)
                pages.append({"label": label, "httpStatus": response.status if response else None, **inspect(page, label)})
            except Exception as exc:
                pages.append({"label": label, "requestedUrl": url, "error": f"{type(exc).__name__}: {exc}"})
        # Attempt the same visible portal navigation a user performs.
        action = select_village_any_frame(page)
        if action:
            actions.append(action)
            pages.append(inspect(page, "after-village-selection"))
        action = click_text_any_frame(page, r"R1\\.\\s*Job Card|R1\\s*Job Card|Job Card")
        if action:
            actions.append(action)
            pages.append(inspect(page, "after-job-card"))
        action = click_text_any_frame(page, r"Registration Application Register")
        if action:
            actions.append(action)
            pages.append(inspect(page, "after-registration-register"))
        # Capture the page that contains the report, if navigation succeeded.
        report_frame = next((f for f in page.frames if "panchregpeople_" in f.url), None)
        if report_frame:
            try:
                pages.append({"label":"registration-report-frame", "finalUrl":report_frame.url,
                              "title":report_frame.title(),
                              "bodyText":report_frame.locator("body").inner_text()[:2000],
                              "tableCount":report_frame.locator("table").count(),
                              "tableRowCounts":report_frame.locator("table").evaluate_all("(ts)=>ts.map(t=>t.rows.length)")})
                (OUT / "registration-report.html").write_text(report_frame.content(), encoding="utf-8")
            except Exception as exc:
                pages.append({"label":"registration-report-frame","error":str(exc)})
        # Direct URL is diagnostic only; it is not treated as a substitute for portal navigation.
        try:
            response = page.goto(DIRECT_REGISTER_URL, wait_until="domcontentloaded", timeout=30000)
            pages.append({"label":"direct-register-diagnostic","httpStatus":response.status if response else None,
                          **inspect(page, "direct-register-diagnostic")})
        except Exception as exc:
            pages.append({"label":"direct-register-diagnostic","error":f"{type(exc).__name__}: {exc}"})
        browser.close()

    report = {
        "mode":"playwright-cloud-diagnostics-only",
        "target":{"village":VILLAGE,"district":"SERCHHIP","state":"MIZORAM","block":"serchhip","financialYear":"2026-2027"},
        "capturedAtUtc":datetime.now(timezone.utc).isoformat(),
        "actions":actions,"pages":pages,
        "activeMisUpdated":False,"supabaseContacted":False,
        "nextStep":"Review the saved HTML/JSON. A successful fetch requires the report to load through the portal navigation and a registration table to be present."
    }
    (OUT / "portal-diagnostics.json").write_text(json.dumps(report, ensure_ascii=False, indent=2), encoding="utf-8")
    print(json.dumps({"mode":report["mode"],"actions":actions,
        "pages":[{"label":x.get("label"),"httpStatus":x.get("httpStatus"),"finalUrl":x.get("finalUrl"),
                  "title":x.get("title"),"bodyText":x.get("bodyText","")[:350],"error":x.get("error"),
                  "tableCount":x.get("tableCount"),"tableRowCounts":x.get("tableRowCounts")} for x in pages],
        "activeMisUpdated":False,"supabaseContacted":False},ensure_ascii=False,indent=2))


if __name__ == "__main__":
    main()
