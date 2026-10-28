#!/usr/bin/env python3
"""Fetch the New Serchhip North MIS report using headless Chrome.

Preview-only: this script never writes to Supabase or changes active MIS.
On failure, it saves browser diagnostics so the cause can be investigated.
"""
from __future__ import annotations

import csv
import json
import sys
import time
import traceback
from datetime import datetime, timezone
from pathlib import Path

from selenium import webdriver
from selenium.webdriver.chrome.options import Options
from selenium.webdriver.support.ui import WebDriverWait

PORTAL_URL = "https://vbgramg.dord.gov.in/vbgramg/home.aspx"
REPORT_PORTAL_URL = "https://vbgramgrep.dord.gov.in/VBGRAMG/IndexFrame.aspx"
REPORT_URL = (
    "https://vbgramgrep.dord.gov.in/VBGRAMG/writereaddata/"
    "citizen_out/panchregpeople_2207001005_eng2627.html"
)
OUT = Path("output")
OUT.mkdir(parents=True, exist_ok=True)


def write_json(name: str, value: dict) -> None:
    (OUT / name).write_text(
        json.dumps(value, ensure_ascii=False, indent=2), encoding="utf-8"
    )


def main() -> int:
    options = Options()
    options.add_argument("--headless=new")
    options.add_argument("--no-sandbox")
    options.add_argument("--disable-dev-shm-usage")
    options.add_argument("--disable-gpu")
    options.add_argument("--window-size=1440,1200")
    options.add_argument("--lang=en-US")
    options.add_argument("--enable-logging")
    options.add_argument("--v=1")
    options.add_argument(
        "--user-agent=Mozilla/5.0 (X11; Linux x86_64) "
        "AppleWebKit/537.36 (KHTML, like Gecko) "
        "Chrome/131.0.0.0 Safari/537.36"
    )

    driver = None
    try:
        driver = webdriver.Chrome(options=options)
        driver.set_page_load_timeout(60)
        # Start at the official public-facing VBGRAMG portal host (not the
        # separate reporting host), then visit the reporting index and report.
        # This is ordinary browser navigation only; no access controls are bypassed.
        for landing_url, label in (
            (PORTAL_URL, "official home"),
            (REPORT_PORTAL_URL, "report index"),
        ):
            try:
                driver.get(landing_url)
                body_text = driver.find_element("tag name", "body").text or ""
                print(
                    f"{label}: title={driver.title!r}, "
                    f"url={driver.current_url!r}, status text={body_text[:500]!r}",
                    file=sys.stderr,
                )
                time.sleep(3)
            except Exception as exc:
                print(
                    f"{label} navigation warning: {type(exc).__name__}: {exc}",
                    file=sys.stderr,
                )

        try:
            driver.get(REPORT_URL)
        except Exception as exc:
            # A page-load timeout may still leave a useful partial page to inspect.
            print(f"Report navigation warning: {type(exc).__name__}: {exc}", file=sys.stderr)

        WebDriverWait(driver, 45).until(
            lambda d: d.execute_script(
                "return document.readyState === 'complete' || "
                "document.readyState === 'interactive'"
            )
        )
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
                values = [
                    cell.text.replace(chr(9), " ").replace(chr(10), " ").strip()
                    for cell in cells
                ]
                if any(values):
                    rows.append(values)

        if len(rows) < 2:
            raise RuntimeError("Page loaded but no usable table rows were found.")
        joined = " ".join(" ".join(row) for row in rows[:10]).lower()
        if not any(term in joined for term in ("job card", "jobcard", "applicant")):
            excerpt = page_text[:1000].replace(chr(10), " ")
            raise RuntimeError(
                "Response does not look like the expected applicant register. "
                f"Page title: {title!r}; excerpt: {excerpt!r}"
            )

        (OUT / "mis-preview.html").write_text(driver.page_source, encoding="utf-8")
        with (OUT / "mis-preview.tsv").open("w", encoding="utf-8", newline="") as f:
            writer = csv.writer(f, delimiter=chr(9), lineterminator=chr(10))
            writer.writerows(rows)

        metadata = {
            "mode": "preview-only",
            "portalUrl": PORTAL_URL,
            "reportPortalUrl": REPORT_PORTAL_URL,
            "portalUrl": PORTAL_URL,
            "sourceUrl": REPORT_URL,
            "pageTitle": title,
            "currentUrl": driver.current_url,
            "fetchedAtUtc": datetime.now(timezone.utc).isoformat(),
            "tableRowCount": len(rows),
            "firstRows": rows[:5],
            "activeMisUpdated": False,
            "note": "This preview does not write to Supabase or modify active MIS.",
        }
        write_json("mis-preview.json", metadata)
        print(json.dumps(metadata, ensure_ascii=False, indent=2))
        return 0

    except Exception as exc:
        diagnostic = {
            "mode": "failure-diagnostics-only",
            "sourceUrl": REPORT_URL,
            "capturedAtUtc": datetime.now(timezone.utc).isoformat(),
            "exceptionType": type(exc).__name__,
            "exception": str(exc) or repr(exc),
            "traceback": traceback.format_exc(),
            "currentUrl": None,
            "pageTitle": None,
            "readyState": None,
            "pageTextExcerpt": None,
            "tableRowCount": None,
            "activeMisUpdated": False,
        }
        if driver is not None:
            for key, script in (
                ("currentUrl", "return window.location.href"),
                ("pageTitle", "return document.title"),
                ("readyState", "return document.readyState"),
                ("pageTextExcerpt", "return (document.body ? document.body.innerText : '').slice(0, 3000)"),
                ("tableRowCount", "return document.querySelectorAll('table tr').length"),
            ):
                try:
                    diagnostic[key] = driver.execute_script(script)
                except Exception as detail_exc:
                    diagnostic[key] = f"Could not capture: {type(detail_exc).__name__}: {detail_exc}"
            try:
                (OUT / "mis-failure.html").write_text(
                    driver.page_source, encoding="utf-8"
                )
            except Exception as detail_exc:
                diagnostic["htmlCaptureError"] = f"{type(detail_exc).__name__}: {detail_exc}"
            try:
                driver.save_screenshot(str(OUT / "mis-failure.png"))
            except Exception as detail_exc:
                diagnostic["screenshotCaptureError"] = f"{type(detail_exc).__name__}: {detail_exc}"

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
