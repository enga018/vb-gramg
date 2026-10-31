#!/usr/bin/env python3
"""Local, read-only VBGRAMG MIS fetch service for Windows desktop.

Binds only to 127.0.0.1. Opens a separate visible Brave profile.
Never logs or persists the supplied Payload URL. Does not contact Supabase.
"""
from __future__ import annotations
import json, os, re, shutil, threading, time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from urllib.parse import urlsplit
from selenium import webdriver
from selenium.common.exceptions import TimeoutException, WebDriverException
from selenium.webdriver.chrome.options import Options
from selenium.webdriver.common.by import By
from selenium.webdriver.support.ui import WebDriverWait

HOST, PORT = "127.0.0.1", 8765
ALLOWED_ORIGINS = {"https://enga018.github.io", "http://localhost:8000", "http://127.0.0.1:8000"}
BRAVE_PROFILE = Path(os.environ.get("LOCALAPPDATA", str(Path.home()))) / "VBGRAMG" / "BraveMISProfile"
FETCH_LOCK = threading.Lock()
MAX_BODY = 12000

def find_brave():
    candidates = [
        os.environ.get("BRAVE_PATH", ""),
        r"C:\Program Files\BraveSoftware\Brave-Browser\Application\brave.exe",
        r"C:\Program Files (x86)\BraveSoftware\Brave-Browser\Application\brave.exe",
        str(Path.home() / "AppData/Local/BraveSoftware/Brave-Browser/Application/brave.exe"),
    ]
    for candidate in candidates:
        if candidate and Path(candidate).is_file():
            return candidate
    found = shutil.which("brave") or shutil.which("brave-browser")
    if found:
        return found
    raise RuntimeError("Brave Browser was not found. Install Brave or set BRAVE_PATH.")

def validate_payload_url(value):
    parsed = urlsplit(value)
    if parsed.scheme != "https" or parsed.hostname != "vbgramgrep.dord.gov.in" or not parsed.path.endswith("/VBGRAMG/IndexFrame.aspx") or not parsed.query:
        raise ValueError("Enter the official VBGRAMG Village Council Payload URL (HTTPS IndexFrame.aspx).")

def visible_brave_driver():
    options = Options()
    options.binary_location = find_brave()
    options.add_argument(f"--user-data-dir={BRAVE_PROFILE}")
    options.add_argument("--profile-directory=Default")
    options.add_argument("--window-size=1440,1000")
    options.add_argument("--lang=en-US")
    options.add_argument("--no-first-run")
    options.add_argument("--no-default-browser-check")
    # Deliberately no headless flag.
    return webdriver.Chrome(options=options)

def wait_ready(driver, seconds=25):
    try:
        WebDriverWait(driver, seconds).until(lambda d: d.execute_script("return document.readyState") in ("interactive", "complete"))
    except TimeoutException:
        pass

def contexts(driver):
    for handle in list(driver.window_handles):
        try:
            driver.switch_to.window(handle)
            driver.switch_to.default_content()
            yield
            for frame in driver.find_elements(By.CSS_SELECTOR, "iframe,frame"):
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

def click_visible_text(driver, pattern, timeout=12):
    regex = re.compile(pattern, re.I)
    for _ in contexts(driver):
        try:
            candidates = driver.find_elements(By.CSS_SELECTOR, "a,button,input[type=button],input[type=submit],[onclick],[role=button]")
            for element in candidates:
                label = " ".join(filter(None, [element.text, element.get_attribute("value"), element.get_attribute("title"), element.get_attribute("aria-label")]))
                if regex.search(label) and element.is_displayed() and element.is_enabled():
                    driver.execute_script("arguments[0].scrollIntoView({block:'center'});", element)
                    driver.execute_script("arguments[0].click();", element)
                    wait_ready(driver, timeout)
                    return {"matched": label[:180]}
        except WebDriverException:
            continue
    return {"error": "Could not find a matching visible portal control."}

def collect_report(driver):
    found = []
    for _ in contexts(driver):
        try:
            body = driver.find_element(By.TAG_NAME, "body").text
            if "Unauthorized" in body or '"code":"401"' in body or '"code": "401"' in body:
                return {"ok": False, "stage": "portal-access", "message": "The portal returned Unauthorized (401). No report was retrieved."}
            title, current_url = driver.title, driver.current_url
            for table in driver.find_elements(By.TAG_NAME, "table"):
                rows = []
                for tr in table.find_elements(By.CSS_SELECTOR, "tr"):
                    cells = [c.text.strip() for c in tr.find_elements(By.CSS_SELECTOR, "th,td")]
                    if cells and any(cells):
                        rows.append(cells)
                if rows:
                    found.append({"title": title, "urlPath": urlsplit(current_url).path, "rows": rows})
        except WebDriverException:
            continue
    if not found:
        return {"ok": False, "stage": "report-extraction", "message": "Portal opened, but no HTML table was detected. Check the visible Brave window."}
    report = max(found, key=lambda item: len(item["rows"]))
    return {"ok": True, "report": report, "tableCount": len(found)}

def fetch_report(payload_url):
    driver = None
    try:
        driver = visible_brave_driver()
        driver.set_page_load_timeout(60)
        driver.get(payload_url)
        wait_ready(driver, 35)
        initial_text = driver.find_element(By.TAG_NAME, "body").text[:1200]
        if "Unauthorized" in initial_text or '"code":"401"' in initial_text:
            return {"ok": False, "stage": "portal-access", "message": "The portal returned Unauthorized (401). No report was retrieved."}
        first = click_visible_text(driver, r"R1\s*\.?\s*Job\s*Card\s*/\s*Registration")
        if first.get("error"):
            return {"ok": False, "stage": "navigation", "message": "Village page opened, but the Job Card/Registration menu was not found.", "detail": first}
        second = click_visible_text(driver, r"Registration\s+Application\s+Register")
        if second.get("error"):
            return {"ok": False, "stage": "navigation", "message": "Registration menu opened, but Registration Application Register was not found.", "detail": second}
        time.sleep(3)
        for handle in list(driver.window_handles):
            try:
                driver.switch_to.window(handle)
                wait_ready(driver, 20)
            except WebDriverException:
                pass
        result = collect_report(driver)
        if result.get("ok"):
            result["navigation"] = [first, second]
        return result
    except Exception as exc:
        return {"ok": False, "stage": "browser", "message": f"Brave/Selenium failed: {type(exc).__name__}. Check the desktop service window."}
    finally:
        if driver:
            try:
                driver.quit()
            except Exception:
                pass

class Handler(BaseHTTPRequestHandler):
    server_version = "VBGRAMGLocal/1.0"
    def log_message(self, fmt, *args):
        return
    def send_json(self, status, payload, origin=None):
        body = json.dumps(payload, ensure_ascii=False).encode("utf-8")
        self.send_response(status)
        self.send_header("Content-Type", "application/json; charset=utf-8")
        self.send_header("Content-Length", str(len(body)))
        self.send_header("Cache-Control", "no-store")
        self.send_header("X-Content-Type-Options", "nosniff")
        if origin in ALLOWED_ORIGINS:
            self.send_header("Access-Control-Allow-Origin", origin)
            self.send_header("Vary", "Origin")
        self.end_headers()
        self.wfile.write(body)
    def do_OPTIONS(self):
        origin = self.headers.get("Origin", "")
        if origin not in ALLOWED_ORIGINS:
            self.send_json(403, {"ok": False, "message": "Origin not allowed."})
            return
        self.send_response(204)
        self.send_header("Access-Control-Allow-Origin", origin)
        self.send_header("Access-Control-Allow-Methods", "GET, POST, OPTIONS")
        self.send_header("Access-Control-Allow-Headers", "Content-Type")
        self.send_header("Access-Control-Max-Age", "300")
        self.end_headers()
    def do_GET(self):
        origin = self.headers.get("Origin", "")
        if self.path != "/health":
            self.send_json(404, {"ok": False, "message": "Not found."}, origin)
            return
        if origin and origin not in ALLOWED_ORIGINS:
            self.send_json(403, {"ok": False, "message": "Origin not allowed."})
            return
        self.send_json(200, {"ok": True, "service": "VBGRAMG desktop MIS fetcher"}, origin)
    def do_POST(self):
        origin = self.headers.get("Origin", "")
        if origin not in ALLOWED_ORIGINS:
            self.send_json(403, {"ok": False, "message": "Request origin not allowed."})
            return
        if self.path != "/fetch":
            self.send_json(404, {"ok": False, "message": "Not found."}, origin)
            return
        if self.headers.get("Content-Type", "").split(";")[0].strip().lower() != "application/json":
            self.send_json(415, {"ok": False, "message": "JSON request required."}, origin)
            return
        try:
            size = int(self.headers.get("Content-Length", "0"))
            if size <= 0 or size > MAX_BODY:
                raise ValueError("Invalid request size.")
            data = json.loads(self.rfile.read(size))
            payload_url = str(data.get("payloadUrl", "")).strip()
            validate_payload_url(payload_url)
        except Exception as exc:
            self.send_json(400, {"ok": False, "message": str(exc)}, origin)
            return
        if not FETCH_LOCK.acquire(blocking=False):
            self.send_json(409, {"ok": False, "message": "A MIS fetch is already running."}, origin)
            return
        try:
            result = fetch_report(payload_url)
            self.send_json(200 if result.get("ok") else 502, result, origin)
        finally:
            payload_url = ""
            FETCH_LOCK.release()

def main():
    BRAVE_PROFILE.mkdir(parents=True, exist_ok=True)
    print(f"VBGRAMG desktop MIS service listening on http://{HOST}:{PORT}")
    print("Keep this window open while fetching. Press Ctrl+C to stop.")
    ThreadingHTTPServer((HOST, PORT), Handler).serve_forever()

if __name__ == "__main__":
    main()
