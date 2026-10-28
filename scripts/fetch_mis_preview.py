#!/usr/bin/env python3
"""Diagnose official VBGRAMG portal navigation from a hosted headless browser.

Diagnostic-only: this script does not attempt to bypass access controls and never
writes to Supabase or changes active MIS.
"""
from __future__ import annotations

import json
import time
import traceback
from datetime import datetime, timezone
from pathlib import Path
from urllib.parse import urlencode

from selenium import webdriver
from selenium.webdriver.chrome.options import Options
from selenium.common.exceptions import WebDriverException

VILLAGE = "New Serchhip North"
STATE_NAME = "MIZORAM"
STATE_CODE = "22"
DISTRICT_NAME = "SERCHHIP"
DISTRICT_CODE = "07"
BLOCK_NAME = "serchhip"
BLOCK_CODE = "001"
FINANCIAL_YEAR = "2026-2027"

PUBLIC_HOME = "https://vbgramg.dord.gov.in/vbgramg/home.aspx"
PUBLIC_REPORT_INDEX = "https://vbgramgrep.dord.gov.in/VBGRAMG/MISreport.aspx"
PUBLIC_GLANCE_REPORT = "https://vbgramg.dord.gov.in/vbgramg/vbgramg_ataglance/At_a_glance.aspx"
REPORTING_ROOT = "https://vbgramgrep.dord.gov.in/VBGRAMG/"
START_URL = REPORTING_ROOT + "Progofficer/PoIndexFrame.aspx?" + urlencode({
    "flag_debited": "S",
    "lflag": "eng",
    "District_Code": DISTRICT_CODE,
    "district_name": DISTRICT_NAME,
    "state_name": STATE_NAME,
    "state_Code": STATE_CODE,
    "finyear": FINANCIAL_YEAR,
    "check": "1",
    "block_name": BLOCK_NAME,
    "Block_Code": BLOCK_CODE,
})
OUT = Path("output")
OUT.mkdir(parents=True, exist_ok=True)


def inspect_page(driver, label: str, url: str) -> dict:
    record = {"label": label, "requestedUrl": url, "capturedAtUtc": datetime.now(timezone.utc).isoformat()}
    try:
        driver.get(url)
        time.sleep(3)
        record.update(driver.execute_script("""
          const norm = s => (s || '').replace(/\\s+/g, ' ').trim();
          const links = [...document.querySelectorAll('a[href]')].map(a => ({
            text: norm(a.innerText || a.textContent).slice(0,180),
            href: a.href
          })).filter(x => /vbgramg|vbgramgrep|panchregpeople|progofficer|report|register|job card/i.test(x.text + ' ' + x.href)).slice(0,100);
          const frames = [...document.querySelectorAll('iframe,frame')].map(f => ({
            tag: f.tagName, name: f.name || '', title: f.title || '', src: f.src || ''
          })).slice(0,50);
          const forms = [...document.forms].map(f => ({
            action: f.action || '', method: (f.method || 'get').toUpperCase(),
            fields: [...f.querySelectorAll('input,select,button')].map(e => ({
              tag:e.tagName, type:e.type || '', name:e.name || '', id:e.id || '',
              text:norm(e.innerText || e.value).slice(0,80)
            })).slice(0,80)
          })).slice(0,20);
          return {
            finalUrl: location.href,
            title: document.title || '',
            readyState: document.readyState,
            bodyText: norm(document.body ? document.body.innerText : '').slice(0,4000),
            links, frames, forms,
            tableCount: document.querySelectorAll('table').length,
            tableRowCounts: [...document.querySelectorAll('table')].map(t => t.rows.length).slice(0,30)
          };
        """))
        filename = label.lower().replace(" ", "-") + ".html"
        (OUT / filename).write_text(driver.page_source, encoding="utf-8")
    except Exception as exc:
        record["error"] = f"{type(exc).__name__}: {exc}"
        try:
            record["finalUrl"] = driver.current_url
            record["title"] = driver.title
            record["bodyText"] = driver.find_element("tag name", "body").text[:4000]
            (OUT / (label.lower().replace(" ", "-") + ".html")).write_text(driver.page_source, encoding="utf-8")
        except Exception:
            pass
    print(f"Checked {label}: {record.get('finalUrl', record.get('error', 'no result'))}")
    return record


def main() -> int:
    options = Options()
    options.add_argument("--headless=new")
    options.add_argument("--no-sandbox")
    options.add_argument("--disable-dev-shm-usage")
    options.add_argument("--disable-gpu")
    options.add_argument("--window-size=1440,1200")
    options.add_argument("--lang=en-US")
    driver = None
    results = []
    try:
        driver = webdriver.Chrome(options=options)
        driver.set_page_load_timeout(60)
        # Visit the public entry page first and record official navigation links.
        results.append(inspect_page(driver, "public-home", PUBLIC_HOME))
        results.append(inspect_page(driver, "public-report-index", PUBLIC_REPORT_INDEX))
        results.append(inspect_page(driver, "public-glance-report", PUBLIC_GLANCE_REPORT))
        # Compare the reporting host root with the specific VBA-style entry URL.
        results.append(inspect_page(driver, "reporting-root", REPORTING_ROOT))
        results.append(inspect_page(driver, "reporting-entry", START_URL))

        report = {
            "mode": "portal-diagnostics-only",
            "target": {
                "village": VILLAGE, "state": STATE_NAME, "stateCode": STATE_CODE,
                "district": DISTRICT_NAME, "districtCode": DISTRICT_CODE,
                "block": BLOCK_NAME, "blockCode": BLOCK_CODE,
                "financialYear": FINANCIAL_YEAR,
            },
            "capturedAtUtc": datetime.now(timezone.utc).isoformat(),
            "pages": results,
            "activeMisUpdated": False,
            "supabaseContacted": False,
            "nextStep": "Compare public report endpoints against the homepage. If all official endpoints return the same 401 from GitHub Actions, stop hosted retries and use an officially supported access method; do not add credentials or cookies to the repository.",
        }
        (OUT / "portal-diagnostics.json").write_text(json.dumps(report, ensure_ascii=False, indent=2), encoding="utf-8")
        print(json.dumps({
            "mode": report["mode"],
            "pages": [{
                "label": p["label"], "finalUrl": p.get("finalUrl"),
                "title": p.get("title"), "bodyText": p.get("bodyText", "")[:300],
                "relevantLinks": p.get("links", [])[:12], "frames": p.get("frames", [])[:8],
                "error": p.get("error")
            } for p in results],
            "activeMisUpdated": False, "supabaseContacted": False
        }, ensure_ascii=False, indent=2))
        return 0
    except Exception as exc:
        failure = {
            "mode": "portal-diagnostics-error",
            "capturedAtUtc": datetime.now(timezone.utc).isoformat(),
            "exceptionType": type(exc).__name__,
            "exception": str(exc),
            "traceback": traceback.format_exc(),
            "activeMisUpdated": False,
            "supabaseContacted": False,
        }
        (OUT / "portal-diagnostics-error.json").write_text(json.dumps(failure, indent=2), encoding="utf-8")
        print(json.dumps(failure, indent=2))
        return 1
    finally:
        if driver is not None:
            try:
                driver.quit()
            except WebDriverException:
                pass


if __name__ == "__main__":
    raise SystemExit(main())
