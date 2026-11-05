/* Shared sidebar navigation for VBGRAMG module pages. */
(function () {
  function install() {
    if (window.self !== window.top) return;
    var path = window.location.pathname || "/";
    var cleanPath = path.replace(/\/+$/, "") || "/";
    if (cleanPath.endsWith("/index.html") || cleanPath === "/" || path.endsWith("/")) return;
    if (document.querySelector(".global-sidebar")) return;
    var main = document.querySelector("main");
    if (!main) return;
    document.querySelectorAll("main > header.app-header, main > header.topbar").forEach(function (h) { h.remove(); });
    document.body.classList.add("has-global-sidebar");
    function syncResponsiveMode(){
      var phoneLandscape=window.matchMedia("(max-height:600px) and (pointer:coarse)").matches;
      var tablet=(window.innerWidth>=768&&window.innerWidth<=1023)||phoneLandscape;
      var mobile=window.innerWidth<=767;
      document.body.classList.toggle("is-mobile-layout",mobile);
      document.body.classList.toggle("is-tablet-layout",tablet&&!phoneLandscape);
    }
    syncResponsiveMode();
    var links = [
      ["MIS", "./mis.html", "♙"],
      ["FTO", "./fto.html", "▤"],
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
      var targetPath = new URL(item[1], window.location.href).pathname.replace(/\/+$/, "") || "/";
      var isCurrent = targetPath === cleanPath || (item[0] === "FTO" && cleanPath.endsWith("/fto-import.html"));
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
    var button = makeToggle("global-sidebar-toggle global-mobile-menu-button");

    var pageNames = {
      "/mis.html": "MIS",
      "/fto.html": "FTO",
      "/fto-import.html": "FTO Import",
      "/demand.html": "Demand",
      "/periods.html": "Periods",
      "/contribution.html": "Contribution"
    };
    var pageKey = Object.keys(pageNames).find(function (key) { return cleanPath.endsWith(key); });
    var pageName = (pageKey && pageNames[pageKey]) || document.title.split("—")[0].split("|")[0].trim() || "VBGRAMG";
    var mobileHeader = document.createElement("div");
    mobileHeader.className = "global-mobile-header";
    var title = document.createElement("span");
    title.className = "global-mobile-header-title";
    title.textContent = "VBGRAMG / " + pageName;
    mobileHeader.appendChild(title);
    mobileHeader.appendChild(desktopButton);
    mobileHeader.appendChild(button);
    main.insertBefore(mobileHeader, main.firstChild);

    var mobileHeaderStyle = document.createElement("style");
    mobileHeaderStyle.textContent = `
      .global-mobile-header{display:flex;align-items:center;justify-content:space-between;gap:12px;width:100%;min-height:48px;margin:0 auto 12px;padding:5px 10px;background:transparent;border:0;border-radius:0;box-shadow:none}
      .global-mobile-header-title{margin-right:auto!important;margin-left:0!important;text-align:left!important;font-size:1rem;font-weight:750;letter-spacing:-.015em;color:#172033;line-height:1.25}
      .global-sidebar-desktop-toggle{display:inline-grid;place-items:center;flex:none;width:38px;min-width:38px;height:38px;min-height:38px;margin-left:8px;padding:0;border:1px solid #dfe5ee;border-radius:10px;background:#fff;color:#344054;font-size:17px;line-height:1;cursor:pointer}
      .global-mobile-menu-button{display:none!important}
      @media(max-width:1023px), (max-height:600px) and (pointer:coarse){
        .global-mobile-header{min-height:48px;margin-bottom:12px;padding:5px 10px;background:#fff;border:1px solid #e3e8f0;border-radius:12px;box-shadow:0 3px 12px rgb(23 32 51 / 4%)}
        .global-sidebar-desktop-toggle{display:none!important}
        .global-mobile-header .global-mobile-menu-button{display:inline-flex!important;position:static!important;inset:auto!important;transform:none!important;flex:0 0 40px;width:40px;height:40px;min-height:40px;margin:0!important;padding:0!important;align-items:center;justify-content:center;border:1px solid #e0e6ef!important;border-radius:9px!important;background:#f0f3f8!important;color:#172033!important;font-size:21px!important;line-height:1!important;box-shadow:none!important}
      }
    `;
    document.head.appendChild(mobileHeaderStyle);

    /* Give native dialogs one predictable title-left / close-right header. */
    document.querySelectorAll('dialog[aria-labelledby]').forEach(function(dialog){
      var titleId=dialog.getAttribute('aria-labelledby');
      var titleNode=titleId&&dialog.querySelector('#'+CSS.escape(titleId));
      if(!titleNode||dialog.querySelector('.vbgramg-dialog-header'))return;
      var content=titleNode.parentElement;
      if(!content||content.matches('header,.fto-import-modal-head,.fto-view-modal-header'))return;
      var header=document.createElement('div');
      header.className='vbgramg-dialog-header';
      content.insertBefore(header,titleNode);
      header.appendChild(titleNode);
      var closeButton=document.createElement('button');
      closeButton.type='button';closeButton.className='vbgramg-dialog-close';
      closeButton.setAttribute('aria-label','Close dialog');closeButton.textContent='×';
      closeButton.addEventListener('click',function(){if(typeof dialog.close==='function')dialog.close();else dialog.removeAttribute('open');});
      header.appendChild(closeButton);
    });
    var dialogHeaderStyle=document.createElement('style');
    dialogHeaderStyle.textContent='.vbgramg-dialog-header{display:flex;align-items:center;justify-content:space-between;gap:12px;width:100%;margin:0 0 12px}.vbgramg-dialog-header h2{margin:0!important;text-align:left!important}.vbgramg-dialog-close{display:inline-flex;align-items:center;justify-content:center;flex:0 0 36px;width:36px;min-width:36px;height:36px;min-height:36px;padding:0!important;border:1px solid #e0e6ef!important;border-radius:9px!important;background:#f0f3f8!important;color:#344054!important;font-size:22px!important;line-height:1!important;box-shadow:none!important}.vbgramg-dialog-close:hover{background:#e6ebf3!important}';
    document.head.appendChild(dialogHeaderStyle);

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
    window.addEventListener("resize", function () { syncResponsiveMode(); if (window.innerWidth > 1023 && !window.matchMedia("(max-height:600px) and (pointer:coarse)").matches) close(); });
  }
  if (document.readyState === "loading") document.addEventListener("DOMContentLoaded", install);
  else install();
})();
