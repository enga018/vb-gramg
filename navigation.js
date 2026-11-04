/* Shared sidebar navigation for VBGRAMG module pages. */
(function () {
  function install() {
    var path = window.location.pathname || "/";
    var cleanPath = path.replace(/\\/+$/, "") || "/";
    if (cleanPath.endsWith("/index.html") || cleanPath === "/" || path.endsWith("/")) return;
    var header = document.querySelector("header");
    if (document.querySelector(".global-sidebar")) return;
    if (header) header.querySelectorAll("a.menu-link").forEach(function (a) { a.remove(); });
    document.body.classList.add("has-global-sidebar");
    var links = [
      ["MIS", "./mis.html", "♙"],
      ["FTO History", "./fto.html", "▤"],
      ["Work Demand", "./demand.html", "☷"],
      ["Periods", "./periods.html", "◷"],
      ["Contribution", "./contribution.html", "₹"]
    ];
    var sidebar = document.createElement("aside");
    sidebar.className = "global-sidebar";
    sidebar.id = "global-sidebar";
    sidebar.setAttribute("aria-label", "Main navigation");
    sidebar.innerHTML = '<div class="global-sidebar-brand"><span class="global-sidebar-mark" aria-hidden="true">V</span><span><strong>VBGRAMG</strong><small>Village Benefit Management</small></span></div><div class="global-sidebar-label">WORKSPACE</div><nav class="global-sidebar-links" aria-label="Workspace"></nav>';
    var nav = sidebar.querySelector(".global-sidebar-links");
    links.forEach(function (item) {
      var a = document.createElement("a");
      a.href = item[1];
      a.className = "global-sidebar-link";
      a.innerHTML = '<span class="global-sidebar-icon" aria-hidden="true"></span><span class="global-sidebar-text"></span>';
      a.querySelector(".global-sidebar-icon").textContent = item[2];
      a.querySelector(".global-sidebar-text").textContent = item[0];
      var targetPath = new URL(item[1], window.location.href).pathname.replace(/\\/+$/, "") || "/";
      var isCurrent = targetPath === cleanPath || (item[0] === "FTO History" && cleanPath.endsWith("/fto-import.html"));
      if (isCurrent) { a.classList.add("is-current"); a.setAttribute("aria-current", "page"); }
      nav.appendChild(a);
    });
    var overlay = document.createElement("div");
    overlay.className = "global-sidebar-overlay";
    function makeToggle(className) {
      var toggle = document.createElement("button");
      toggle.type = "button";
      toggle.className = className;
      toggle.setAttribute("aria-label", "Open navigation");
      toggle.setAttribute("aria-controls", "global-sidebar");
      toggle.setAttribute("aria-expanded", "false");
      toggle.textContent = "☰";
      return toggle;
    }
    var desktopButton = makeToggle("global-sidebar-toggle global-sidebar-desktop-toggle");
    if (header) header.insertBefore(desktopButton, header.firstChild);
    else {
      var desktopMount = document.querySelector("main .panel, main section, main") || document.body;
      desktopMount.insertBefore(desktopButton, desktopMount.firstChild);
    }
    var button = makeToggle("global-sidebar-toggle global-mobile-menu-button");

    var pageNames = {
      "/mis.html": "MIS",
      "/fto.html": "FTO History",
      "/fto-import.html": "FTO Import",
      "/demand.html": "Work Demand",
      "/periods.html": "Periods",
      "/contribution.html": "Contribution"
    };
    var pageName = pageNames[cleanPath] || document.title.replace(/\\s*[—|–-]\\s*VBGRAMG.*$/i, "").trim() || "VBGRAMG";
    var mobileHeader = document.createElement("div");
    mobileHeader.className = "global-mobile-header";
    var title = document.createElement("span");
    title.className = "global-mobile-header-title";
    title.textContent = pageName;
    mobileHeader.appendChild(button);
    mobileHeader.appendChild(title);
    var main = document.querySelector("main");
    if (main) main.insertBefore(mobileHeader, main.firstChild);
    else document.body.insertBefore(mobileHeader, document.body.firstChild);

    var mobileHeaderStyle = document.createElement("style");
    mobileHeaderStyle.textContent = `
      .global-mobile-header{display:none}
      @media(max-width:700px){
        .global-mobile-header{display:flex;align-items:center;justify-content:space-between;gap:12px;width:100%;min-height:48px;margin:0 auto 12px;padding:5px 10px;background:#fff;border:1px solid #e3e8f0;border-radius:12px;box-shadow:0 3px 12px rgb(23 32 51 / 4%)}
        .global-sidebar-desktop-toggle{display:none!important}
        .global-mobile-header .global-sidebar-toggle{display:inline-flex!important;position:static!important;inset:auto!important;transform:none!important;flex:0 0 40px;width:40px;height:40px;min-height:40px;margin:0!important;padding:0!important;align-items:center;justify-content:center;border:1px solid #e0e6ef!important;border-radius:9px!important;background:#f0f3f8!important;color:#172033!important;font-size:21px!important;line-height:1!important;box-shadow:none!important}
        .global-mobile-header .global-mobile-header-title{margin-left:auto;text-align:right;font-size:.94rem;font-weight:750;letter-spacing:-.015em;color:#172033;line-height:1.25}
      }
    `;
    document.head.appendChild(mobileHeaderStyle);

    document.body.insertBefore(sidebar, document.body.firstChild);
    document.body.appendChild(overlay);
    function close() {
      sidebar.classList.remove("is-open"); overlay.classList.remove("is-visible");
      [button, desktopButton].forEach(function (toggle) { toggle.setAttribute("aria-expanded", "false"); toggle.setAttribute("aria-label", "Open navigation"); });
    }
    function open() {
      sidebar.classList.add("is-open"); overlay.classList.add("is-visible");
      [button, desktopButton].forEach(function (toggle) { toggle.setAttribute("aria-expanded", "true"); toggle.setAttribute("aria-label", "Close navigation"); });
    }
    [button, desktopButton].forEach(function (toggle) {
      toggle.addEventListener("click", function () { sidebar.classList.contains("is-open") ? close() : open(); });
    });
    overlay.addEventListener("click", close);
    nav.addEventListener("click", function (event) { if (event.target.closest("a")) close(); });
    document.addEventListener("keydown", function (event) {
      if (event.key === "Escape" && sidebar.classList.contains("is-open")) { close(); button.focus(); }
    });
    window.addEventListener("resize", function () { if (window.innerWidth > 700) close(); });
  }
  if (document.readyState === "loading") document.addEventListener("DOMContentLoaded", install);
  else install();
})();
