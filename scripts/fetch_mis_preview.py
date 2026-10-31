#!/usr/bin/env python3
"""Read-only headless navigation to the VBGRAMG Registration Application Register.

The Payload URL is supplied at workflow dispatch time and is never printed.
This script does not contact Supabase or modify active MIS data.
"""
from __future__ import annotations

import json
import os
import re
from datetime import datetime, timezone
from pathlib import Path
from urllib.parse import urlsplit

from selenium import webdriver
from selenium.common.exceptions import TimeoutException, WebDriverException
from selenium.webdriver.chrome.options import Options
from selenium.webdriver.common.by import By
from selenium.webdriver.support.ui import WebDriverWait

OUT = Path("output")
OUT.mkdir(parents=True, exist_ok=True)
PAYLOAD_URL = os.environ.get("MIS_PAYLOAD_URL", "").strip()


def snapshot(driver, label):
    try:
        WebDriverWait(driver, 18).until(
            lambda d: d.execute_script("return document.readyState") in ("interactive", "complete")
        )
    except TimeoutException:
        pass
    data = driver.execute_script("""return (() => {
      const norm = s => (s || '').replace(/\\s+/g, ' ').trim();
      return {
        finalUrl: location.href, title: document.title || '',
        readyState: document.readyState,
        bodyText: norm(document.body?.innerText || '').slice(0,8000),
        links: [...document.querySelectorAll('a[href]')].map(a => ({
          text: norm(a.innerText || a.textContent).slice(0,180), href:a.href
        })).filter(x => /job card|registration application|register|panchregpeople/i.test(x.text+' '+x.href)).slice(0,120),
        frames: [...document.querySelectorAll('iframe,frame')].map(f => ({
          name:f.name||'', title:f.title||'', src:f.src||''
        })).slice(0,50),
        tables: document.querySelectorAll('table').length,
        tableRowCounts: [...document.querySelectorAll('table')].map(t=>t.rows.length).slice(0,30)
      };
    })()""")
    data["label"] = label
    data["capturedAtUtc"] = datetime.now(timezone.utc).isoformat()
    (OUT / f"{label}.json").write_text(json.dumps(data, ensure_ascii=False, indent=2), encoding="utf-8")
    (OUT / f"{label}.html").write_text(driver.page_source, encoding="utf-8")
    return data


def each_context(driver):
    """Visit each window and its immediate frames, restoring default content."""
    for handle in list(driver.window_handles):
        try:
            driver.switch_to.window(handle)
            driver.switch_to.default_content()
            yield
            frames = driver.find_elements(By.CSS_SELECTOR, "iframe,frame")
            for frame in frames:
                try:
                    driver.switch_to.default_content()
                    driver.switch_to.frame(frame)
                    yield
                except WebDriverException:
                    continue
        except WebDriverException:
            continue
    try:
        driver.switch_to.default_content()
    except WebDriverException:
        pass


def click_text_any_context(driver, pattern, label, timeout=5):
    rx = re.compile(pattern, re.I)
    for _ in each_context(driver):
        try:
            candidates = driver.find_elements(
                By.CSS_SELECTOR, "a,button,input[type=button],input[type=submit],[onclick],[role=button]"
            )
            for element in candidates:
                text = " ".join(filter(None, [
                    element.text, element.get_attribute("value"),
                    element.get_attribute("title"), element.get_attribute("aria-label")
                ]))
                if rx.search(text) and element.is_displayed() and element.is_enabled():
                    driver.execute_script("arguments[0].scrollIntoView({block:'center'});", element)
                    driver.execute_script("arguments[0].click();", element)
                    try:
                        WebDriverWait(driver, timeout).until(
                            lambda d: d.execute_script("return document.readyState") in ("interactive", "complete")
                        )
                    except TimeoutException:
                        pass
                    return {"step": label, "matchedText": text[:200], "contextUrl": driver.current_url}
        except WebDriverException:
            continue
    try:
        driver.switch_to.default_content()
    except WebDriverException:
        pass
    return {"step": label, "matchedText": None, "error": "No matching visible control found"}


def main():
    if not PAYLOAD_URL:
        print("No Payload URL supplied. Run this workflow manually and provide the Payload URL input.")
        return

    parsed = urlsplit(PAYLOAD_URL)
    if parsed.scheme != "https" or parsed.hostname != "vbgramgrep.dord.gov.in" or "/VBGRAMG/IndexFrame.aspx" not in parsed.path:
        raise SystemExit("Payload URL rejected: expected the official VBGRAMG IndexFrame HTTPS URL.")

    pages, actions = [], []
    options = Options()
    options.add_argument("--headless=new")
    options.add_argument("--no-sandbox")
    options.add_argument("--disable-dev-shm-usage")
    options.add_argument("--window-size=1440,1200")
    options.add_argument("--lang=en-US")
    driver = webdriver.Chrome(options=options)
    driver.set_page_load_timeout(60)
    driver.set_script_timeout(25)

    try:
        driver.get(PAYLOAD_URL)
        pages.append(snapshot(driver, "village-council-entry"))

        actions.append(click_text_any_context(
            driver, r"R1\\s*\\.?\\s*Job\\s*Card\\s*/\\s*Registration",
            "expand-r1-job-card-registration"
        ))
        pages.append(snapshot(driver, "after-expanding-r1"))

        actions.append(click_text_any_context(
            driver, r"Registration\\s+Application\\s+Register",
            "open-registration-application-register", timeout=12
        ))
        pages.append(snapshot(driver, "registration-application-register"))

        # Capture any report loaded in a frame or a newly opened window.
        for _ in each_context(driver):
            try:
                current = driver.current_url
                body = driver.find_element(By.TAG_NAME, "body").text[:5000]
                if "panchregpeople" in current.lower() or "registration application register" in body.lower():
                    pages.append({
                        "label": "report-context",
                        "finalUrl": current,
                        "title": driver.title,
                        "bodyText": body,
                        "tableCount": len(driver.find_elements(By.TAG_NAME, "table")),
                        "tableRowCounts": driver.execute_script(
                            "return [...document.querySelectorAll('table')].map(t=>t.rows.length)"
                        )
                    })
                    (OUT / "report-context.html").write_text(driver.page_source, encoding="utf-8")
            except WebDriverException:
                continue
    except Exception as exc:
        pages.append({"label": "navigation-error", "error": f"{type(exc).__name__}: {exc}"})
    finally:
        driver.quit()

    report = {
        "mode": "read-only-headless-navigation",
        "target": {"village": "New Serchhip North", "district": "SERCHHIP",
                   "state": "MIZORAM", "block": "serchhip", "financialYear": "2026-2027"},
        "payloadUrlHost": parsed.hostname,
        "payloadUrlPath": parsed.path,
        "capturedAtUtc": datetime.now(timezone.utc).isoformat(),
        "actions": actions, "pages": pages,
        "activeMisUpdated": False, "supabaseContacted": False
    }
    (OUT / "portal-diagnostics.json").write_text(
        json.dumps(report, ensure_ascii=False, indent=2), encoding="utf-8"
    )
    print(json.dumps({
        "mode": report["mode"], "actions": actions,
        "pages": [{"label": p.get("label"), "finalUrl": p.get("finalUrl"),
                   "title": p.get("title"), "bodyText": p.get("bodyText", "")[:500],
                   "error": p.get("error"), "tableCount": p.get("tableCount"),
                   "tableRowCounts": p.get("tableRowCounts")} for p in pages],
        "activeMisUpdated": False, "supabaseContacted": False
    }, ensure_ascii=False, indent=2))


if __name__ == "__main__":
    main()
