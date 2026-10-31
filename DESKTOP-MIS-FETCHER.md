# VBGRAMG desktop MIS fetcher (first-stage prototype)

This is a Windows-only, read-only companion service. It is separate from the existing Excel MIS importer and does not update Supabase or active MIS data.

## Requirements
- Windows 10/11
- Brave Browser installed
- Python 3.11 or newer (enable the Python launcher, py)
- Internet access for Selenium Manager to obtain a compatible driver on first run

## Start
1. Download/clone this repository.
2. Double-click start-mis-desktop-service.bat.
3. Keep the black service window open.
4. The service binds only to 127.0.0.1:8765.
5. It launches a separate visible Brave window with its own profile under %LOCALAPPDATA%\VBGRAMG\BraveMISProfile. It does not reuse your normal Brave profile.

## Security and current scope
- The Payload URL is submitted to localhost and held only in process memory.
- It is not printed, logged, or written to disk.
- Only the VBGRAMG GitHub Pages origin and localhost development origins are accepted.
- The service does not call Supabase and does not modify active MIS.
- The report is returned in memory as table rows.
- This first stage is intended for controlled testing. Website UI integration and full report-field mapping are separate follow-up work.
- Stop the service with Ctrl+C in its window.

## Troubleshooting
- If Brave is installed in a non-standard location, set BRAVE_PATH to the full brave.exe path before starting the service.
- If Selenium Manager cannot obtain a driver, update Brave and ensure the PC can access the internet.
- If the government portal returns 401, refresh the Payload URL in your normal browser and retry. Do not share the URL or logs containing it.
