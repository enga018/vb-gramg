#!/usr/bin/env python3
"""Read-only Selenium diagnostics for the official VBGRAMG registration register.

This script only navigates the portal and saves HTML/JSON diagnostics. It never
contacts Supabase or modifies active MIS. It does not bypass CAPTCHA, bot
protection, or use supplied session cookies.
"""
from __future__ import annotations

import json
import re
from datetime import datetime, timezone
from pathlib import Path
from urllib.parse import urlencode

from selenium import webdriver
from selenium.common.exceptions import TimeoutException, WebDriverException
from selenium.webdriver.chrome.options import Options
from selenium.webdriver.common.by import By
from selenium.webdriver.support.ui import Select, WebDriverWait

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


def snapshot(driver, label):
    try:
        WebDriverWait(driver, 12).until(
            lambda d: d.execute_script("return document.readyState") in ("interactive", "complete")
        )
    except TimeoutException:
        pass
    data = driver.execute_script("""return (() => {
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
    })()""")
    data["label"] = label
    data["capturedAtUtc"] = datetime.now(timezone.utc).isoformat()
    (OUT / f"{label}.json").write_text(json.dumps(data, ensure_ascii=False, indent=2), encoding="utf-8")
    (OUT / f"{label}.html").write_text(driver.page_source, encoding="utf-8")
    return data


def all_windows_and_frames(driver):
    """Yield each available top-level window/frame, restoring the default frame after each."""
    original = driver.current_window_handle
    for handle in list(driver.window_handles):
        try:
            driver.switch_to.window(handle)
            driver.switch_to.default_content()
            yield driver, driver.current_url
            frames = driver.find_elements(By.CSS_SELECTOR, "iframe,frame")
            for frame in frames:
                try:
                    driver.switch_to.default_content()
                    driver.switch_to.frame(frame)
                    yield driver, driver.current_url
                except WebDriverException:
                    continue
        except WebDriverException:
            continue
    try:
        driver.switch_to.window(original)
        driver.switch_to.default_content()
    except WebDriverException:
        pass


def click_text_any_frame(driver, pattern, timeout=3):
    rx = re.compile(pattern, re.I)
    for _, frame_url in all_windows_and_frames(driver):
        try:
            candidates = driver.find_elements(By.CSS_SELECTOR, "a,button,input[type=button],input[type=submit],[onclick]")
            for el in candidates:
                text = " ".join(filter(None, [el.text, el.get_attribute("value"), el.get_attribute("title")]))
                if rx.search(text) and el.is_displayed() and el.is_enabled():
                    before = driver.current_url
                    driver.execute_script("arguments[0].click()", el)
                    try:
                        WebDriverWait(driver, timeout).until(lambda d: d.current_url != before)
                    except TimeoutException:
                        pass
                    return {"clicked": pattern, "frameUrl": frame_url, "urlAfterClick": driver.current_url}
        except WebDriverException:
            continue
    try:
        driver.switch_to.default_content()
    except WebDriverException:
        pass
    return None


def select_village_any_frame(driver):
    for _, frame_url in all_windows_and_frames(driver):
        try:
            for sel_el in driver.find_elements(By.TAG_NAME, "select"):
                try:
                    select = Select(sel_el)
                    matches = [o.text.strip() for o in select.options if VILLAGE.casefold() in o.text.casefold()]
                    if matches:
                        select.select_by_visible_text(matches[0])
                        return {"selectedVillage": matches[0], "frameUrl": frame_url}
                except WebDriverException:
                    continue
        except WebDriverException:
            continue
    try:
        driver.switch_to.default_content()
    except WebDriverException:
        pass
    return None


def main():
    pages, actions = [], []
    options = Options()
    options.add_argument("--headless=new")
    options.add_argument("--no-sandbox")
    options.add_argument("--disable-dev-shm-usage")
    options.add_argument("--window-size=1440,1200")
    options.add_argument("--lang=en-US")
    driver = webdriver.Chrome(options=options)  # Selenium Manager resolves ChromeDriver.
    driver.set_page_load_timeout(45)
    driver.set_script_timeout(20)

    try:
        for label, url in [("public-home", PUBLIC_HOME), ("reporting-entry", START_URL)]:
            try:
                driver.get(url)
                pages.append(snapshot(driver, label))
            except Exception as exc:
                pages.append({"label": label, "requestedUrl": url, "error": f"{type(exc).__name__}: {exc}"})

        action = select_village_any_frame(driver)
        if action:
            actions.append(action)
            pages.append(snapshot(driver, "after-village-selection"))
        action = click_text_any_frame(driver, r"R1\.?\s*Job Card|Job Card")
        if action:
            actions.append(action)
            pages.append(snapshot(driver, "after-job-card"))
        action = click_text_any_frame(driver, r"Registration Application Register")
        if action:
            actions.append(action)
            pages.append(snapshot(driver, "after-registration-register"))

        # Inspect frames and windows for the final report URL after navigation.
        for handle in list(driver.window_handles):
            try:
                driver.switch_to.window(handle)
                driver.switch_to.default_content()
                for frame in [None] + driver.find_elements(By.CSS_SELECTOR, "iframe,frame"):
                    try:
                        driver.switch_to.default_content()
                        if frame is not None:
                            driver.switch_to.frame(frame)
                        if "panchregpeople_" in driver.current_url:
                            report = {
                                "label": "registration-report",
                                "finalUrl": driver.current_url,
                                "title": driver.title,
                                "bodyText": driver.find_element(By.TAG_NAME, "body").text[:2000],
                                "tableCount": len(driver.find_elements(By.TAG_NAME, "table")),
                                "tableRowCounts": driver.execute_script("return [...document.querySelectorAll('table')].map(t=>t.rows.length)")
                            }
                            pages.append(report)
                            (OUT / "registration-report.html").write_text(driver.page_source, encoding="utf-8")
                    except WebDriverException:
                        continue
            except WebDriverException:
                continue

        # Direct navigation is diagnostic only; it does not replace portal navigation.
        try:
            driver.switch_to.default_content()
            driver.get(DIRECT_REGISTER_URL)
            pages.append(snapshot(driver, "direct-register-diagnostic"))
        except Exception as exc:
            pages.append({"label": "direct-register-diagnostic", "error": f"{type(exc).__name__}: {exc}"})
    finally:
        driver.quit()

    report = {
        "mode": "selenium-cloud-diagnostics-only",
        "target": {"village": VILLAGE, "district": "SERCHHIP", "state": "MIZORAM",
                   "block": "serchhip", "financialYear": "2026-2027"},
        "capturedAtUtc": datetime.now(timezone.utc).isoformat(),
        "actions": actions, "pages": pages,
        "activeMisUpdated": False, "supabaseContacted": False,
        "nextStep": "Review diagnostics. Payload URL cache validation is not yet wired in because the original VBA's exact payload-validation routine has not been inspected."
    }
    (OUT / "portal-diagnostics.json").write_text(json.dumps(report, ensure_ascii=False, indent=2), encoding="utf-8")
    print(json.dumps({
        "mode": report["mode"], "actions": actions,
        "pages": [{"label": x.get("label"), "finalUrl": x.get("finalUrl"),
                   "title": x.get("title"), "bodyText": x.get("bodyText", "")[:350],
                   "error": x.get("error"), "tableCount": x.get("tableCount"),
                   "tableRowCounts": x.get("tableRowCounts")} for x in pages],
        "activeMisUpdated": False, "supabaseContacted": False
    }, ensure_ascii=False, indent=2))


if __name__ == "__main__":
    main()
