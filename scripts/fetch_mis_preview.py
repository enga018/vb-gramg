#!/usr/bin/env python3
"""Fetch the known public New Serchhip North MIS report using headless Chrome.

Safety: preview-only. This script never writes to Supabase or changes active MIS.
The report URL is intentionally fixed rather than accepting arbitrary URLs.
"""
from __future__ import annotations

import csv
import json
import os
import sys
import time
from datetime import datetime, timezone
from pathlib import Path

from selenium import webdriver
from selenium.webdriver.chrome.options import Options
from selenium.webdriver.support.ui import WebDriverWait

REPORT_URL = (
    "https://vbgramgrep.dord.gov.in/VBGRAMG/writereaddata/"
    "citizen_out/panchregpeople_2207001005_eng2627.html"
)
OUT = Path("output")
OUT.mkdir(parents=True, exist_ok=True)


def main() -> int:
    options = Options()
    options.add_argument("--headless=new")
    options.add_argument("--no-sandbox")
    options.add_argument("--disable-dev-shm-usage")
    options.add_argument("--disable-gpu")
    options.add_argument("--window-size=1440,1200")
    options.add_argument("--lang=en-US")
    options.add_argument(
        "--user-agent=Mozilla/5.0 (X11; Linux x86_64) "
        "AppleWebKit/537.36 (KHTML, like Gecko) "
        "Chrome/131.0.0.0 Safari/537.36"
    )

    driver = None
    try:
        driver = webdriver.Chrome(options=options)
        driver.set_page_load_timeout(60)
        driver.get(REPORT_URL)
        WebDriverWait(driver, 45).until(
            lambda d: d.execute_script(
                "return document.readyState === 'complete'"
            )
        )
        # Some report pages render tables after document.readyState.
        WebDriverWait(driver, 20).until(
            lambda d: d.execute_script(
                "return document.querySelectorAll('table tr').length > 1"
            )
        )
        time.sleep(1)
        title = driver.title or ""
        page_text = driver.find_element("tag name", "body").text
        tables = driver.find_elements("css selector", "table")
        rows = []
        for table in tables:
            for tr in table.find_elements("css selector", "tr"):
                cells = tr.find_elements("css selector", "th, td")
                values = [cell.text.replace("\\t", " ").replace("\\n", " ").strip() for cell in cells]
                if any(values):
                    rows.append(values)

        if len(rows) < 2:
            raise RuntimeError("The page loaded but no usable table rows were found.")
        joined = " ".join(" ".join(row) for row in rows[:10]).lower()
        if not any(term in joined for term in ("job card", "jobcard", "applicant")):
            excerpt = page_text[:500].replace("\\n", " ")
            raise RuntimeError(
                "The response does not look like the expected applicant register. "
                "It may be a login/error page. Page title: "
                + title + "; page excerpt: " + excerpt
            )

        # Save the exact rendered HTML and a tab-separated preview for inspection.
        (OUT / "mis-preview.html").write_text(driver.page_source, encoding="utf-8")
        with (OUT / "mis-preview.tsv").open("w", encoding="utf-8", newline="") as f:
            writer = csv.writer(f, delimiter="\\t", lineterminator="\\n")
            writer.writerows(rows)

        metadata = {
            "mode": "preview-only",
            "sourceUrl": REPORT_URL,
            "pageTitle": title,
            "fetchedAtUtc": datetime.now(timezone.utc).isoformat(),
            "tableRowCount": len(rows),
            "firstRows": rows[:5],
            "activeMisUpdated": False,
            "note": "This preview does not write to Supabase or modify active MIS.",
        }
        (OUT / "mis-preview.json").write_text(
            json.dumps(metadata, ensure_ascii=False, indent=2), encoding="utf-8"
        )
        print(json.dumps(metadata, ensure_ascii=False, indent=2))
        return 0
    except Exception as exc:
        print(f"Headless MIS fetch failed: {exc}", file=sys.stderr)
        return 1
    finally:
        if driver is not None:
            driver.quit()


if __name__ == "__main__":
    raise SystemExit(main())
