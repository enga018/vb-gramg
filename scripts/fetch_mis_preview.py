#!/usr/bin/env python3
"""Fetch New Serchhip North's VBGRAMG applicant register with Selenium.

This mirrors the working VBA navigation flow. Preview-only: no Supabase writes.
"""
from __future__ import annotations

import csv
import json
import sys
import time
import traceback
from datetime import datetime, timezone
from pathlib import Path
from urllib.parse import urlencode

from selenium import webdriver
from selenium.webdriver.chrome.options import Options
from selenium.webdriver.support.ui import WebDriverWait

# Fixed target: New Serchhip North, Serchhip block/district, Mizoram, FY 2026-2027.
VILLAGE = "New Serchhip North"
STATE_NAME = "MIZORAM"
STATE_CODE = "22"
DISTRICT_NAME = "SERCHHIP"
DISTRICT_CODE = "07"
BLOCK_NAME = "serchhip"
BLOCK_CODE = "001"
FINANCIAL_YEAR = "2026-2027"

REPORTING_BASE = "https://vbgramgrep.dord.gov.in/VBGRAMG/"
START_URL = REPORTING_BASE + "Progofficer/PoIndexFrame.aspx?" + urlencode({
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


def write_json(name: str, value: dict) -> None:
    (OUT / name).write_text(
        json.dumps(value, ensure_ascii=False, indent=2), encoding="utf-8"
    )


def click_text(driver, text: str, timeout: int = 20) -> None:
    """Find visible text and click its link or nearest clickable element."""
    WebDriverWait(driver, timeout).until(
        lambda d: d.execute_script(
            "const q = arguments[0].toLowerCase().replace(/\\s+/g,' ').trim();"
            "return [...document.querySelectorAll('a,button,[onclick],td,span,div')].some("
            "e => {const t=(e.innerText||e.textContent||'').toLowerCase().replace(/\\s+/g,' ').trim();"
            "const r=e.getBoundingClientRect(); return t.includes(q) && r.width>0 && r.height>0;});",
            text,
        )
    )
    result = driver.execute_script(
        """
        const q = arguments[0].toLowerCase().replace(/\\s+/g,' ').trim();
        const all = [...document.querySelectorAll('a,button,[onclick],td,span,div')];
        // Prefer the smallest visible matching element to avoid clicking a whole page container.
        const matches = all.filter(e => {
          const t=(e.innerText||e.textContent||'').toLowerCase().replace(/\\s+/g,' ').trim();
          const r=e.getBoundingClientRect();
          return t.includes(q) && r.width>0 && r.height>0;
        }).sort((a,b) => {
          const ar=a.getBoundingClientRect(), br=b.getBoundingClientRect();
          return (ar.width*ar.height)-(br.width*br.height);
        });
        const e=matches[0];
        if (!e) return 'NOT_FOUND';
        const a=e.closest('a');
        const target=a || e;
        target.click();
        return 'CLICKED:' + target.tagName + ':' + (target.innerText||target.textContent||'').trim().slice(0,100);
        """,
        text,
    )
    if not result or result == "NOT_FOUND":
        raise RuntimeError(f"Could not find/click '{text}'.")
    print(f"Clicked {text}: {result}", file=sys.stderr)


def wait_for_url_fragment(driver, fragment: str, timeout: int = 30) -> None:
    WebDriverWait(driver, timeout).until(
        lambda d: fragment.lower() in d.current_url.lower()
        or fragment.lower() in (d.execute_script("return document.body ? document.body.innerText : ''") or "").lower()
    )


def main() -> int:
    options = Options()
    options.add_argument("--headless=new")
    options.add_argument("--no-sandbox")
    options.add_argument("--disable-dev-shm-usage")
    options.add_argument("--disable-gpu")
    options.add_argument("--window-size=1440,1200")
    options.add_argument("--lang=en-US")

    driver = None
    try:
        driver = webdriver.Chrome(options=options)
        driver.set_page_load_timeout(60)
        driver.get(START_URL)
        time.sleep(3)
        print(
            f"Start page: title={driver.title!r}, url={driver.current_url!r}, "
            f"text={(driver.find_element('tag name', 'body').text or '')[:500]!r}",
            file=sys.stderr,
        )

        # Match the VBA flow: select village, then R1.Job Card, then the report.
        click_text(driver, VILLAGE, timeout=25)
        time.sleep(3)
        click_text(driver, "R1.Job Card", timeout=20)
        time.sleep(2)
        click_text(driver, "Registration Application Register", timeout=20)

        WebDriverWait(driver, 30).until(
            lambda d: "panchregpeople_" in d.current_url.lower()
        )
        WebDriverWait(driver, 30).until(
            lambda d: d.execute_script(
                "const t=document.getElementsByTagName('table');"
                "return t.length>=5 && t[4].rows.length>10;"
            )
        )
        time.sleep(2)

        table = driver.find_elements("css selector", "table")[4]
        rows = []
        for tr in table.find_elements("css selector", "tr"):
            values = [
                cell.text.replace("\t", " ").replace("\n", " ").strip()
                for cell in tr.find_elements("css selector", "th,td")
            ]
            if any(values):
                rows.append(values)

        if len(rows) < 10:
            raise RuntimeError(f"Only {len(rows)} rows found in the expected fifth table.")
        (OUT / "mis-preview.html").write_text(driver.page_source, encoding="utf-8")
        with (OUT / "mis-preview.tsv").open("w", encoding="utf-8", newline="") as f:
            csv.writer(f, delimiter="\t", lineterminator="\n").writerows(rows)

        metadata = {
            "mode": "preview-only",
            "village": VILLAGE,
            "district": DISTRICT_NAME,
            "block": BLOCK_NAME,
            "state": STATE_NAME,
            "financialYear": FINANCIAL_YEAR,
            "startUrl": START_URL,
            "sourceUrl": driver.current_url,
            "pageTitle": driver.title or "",
            "fetchedAtUtc": datetime.now(timezone.utc).isoformat(),
            "tableRowCount": len(rows),
            "firstRows": rows[:5],
            "activeMisUpdated": False,
            "note": "Preview only; this script does not write to Supabase or modify active MIS.",
        }
        write_json("mis-preview.json", metadata)
        print(json.dumps(metadata, ensure_ascii=False, indent=2))
        return 0
    except Exception as exc:
        diagnostic = {
            "mode": "failure-diagnostics-only",
            "village": VILLAGE,
            "district": DISTRICT_NAME,
            "block": BLOCK_NAME,
            "state": STATE_NAME,
            "financialYear": FINANCIAL_YEAR,
            "startUrl": START_URL,
            "capturedAtUtc": datetime.now(timezone.utc).isoformat(),
            "exceptionType": type(exc).__name__,
            "exception": str(exc) or repr(exc),
            "traceback": traceback.format_exc(),
            "currentUrl": None,
            "pageTitle": None,
            "readyState": None,
            "pageTextExcerpt": None,
            "tableCount": None,
            "tableRowCounts": None,
            "activeMisUpdated": False,
        }
        if driver is not None:
            for key, script in (
                ("currentUrl", "return location.href"),
                ("pageTitle", "return document.title"),
                ("readyState", "return document.readyState"),
                ("pageTextExcerpt", "return (document.body ? document.body.innerText : '').slice(0,3000)"),
                ("tableCount", "return document.getElementsByTagName('table').length"),
                ("tableRowCounts", "return [...document.getElementsByTagName('table')].map(t=>t.rows.length)"),
            ):
                try:
                    diagnostic[key] = driver.execute_script(script)
                except Exception as detail_exc:
                    diagnostic[key] = f"{type(detail_exc).__name__}: {detail_exc}"
            try:
                (OUT / "mis-failure.html").write_text(driver.page_source, encoding="utf-8")
            except Exception:
                pass
            try:
                driver.save_screenshot(str(OUT / "mis-failure.png"))
            except Exception:
                pass
        write_json("mis-failure.json", diagnostic)
        print(json.dumps(diagnostic, ensure_ascii=False, indent=2), file=sys.stderr)
        return 1
    finally:
        if driver is not None:
            try:
                driver.quit()
            except Exception:
                pass


if __name__ == "__main__":
    raise SystemExit(main())
