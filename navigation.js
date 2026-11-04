/* Shared sidebar navigation for VBGRAMG module pages. */
(function () {
  function install() {
    var path = window.location.pathname || "/";
    var cleanPath = path.replace(/\/+$/, "") || "/";
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
      var targetPath = new URL(item[1], window.location.href).pathname.replace(/\/+$/, "") || "/";
      var isCurrent = targetPath === cleanPath || (item[0] === "FTO History" && cleanPath.endsWith("/fto-import.html"));
      if (isCurrent) { a.classList.add("is-current"); a.setAttribute("aria-current", "page"); }
      nav.appendChild(a);
    });
    var overlay = document.createElement("div");
    overlay.className = "global-sidebar-overlay";
    var button = document.createElement("button");
    button.type = "button";
    button.className = "global-sidebar-toggle";
    button.setAttribute("aria-label", "Open navigation");
    button.setAttribute("aria-controls", "global-sidebar");
    button.setAttribute("aria-expanded", "false");
    button.textContent = "☰";
    if (header) {
      header.insertBefore(button, header.firstChild);
    } else {
      var mount = document.querySelector("main .panel, main section, main") || document.body;
      button.style.marginBottom = "10px";
      mount.insertBefore(button, mount.firstChild);
    }
    document.body.insertBefore(sidebar, document.body.firstChild);
    document.body.appendChild(overlay);
    function close() {
      sidebar.classList.remove("is-open"); overlay.classList.remove("is-visible");
      button.setAttribute("aria-expanded", "false"); button.setAttribute("aria-label", "Open navigation");
    }
    function open() {
      sidebar.classList.add("is-open"); overlay.classList.add("is-visible");
      button.setAttribute("aria-expanded", "true"); button.setAttribute("aria-label", "Close navigation");
    }
    button.addEventListener("click", function () { sidebar.classList.contains("is-open") ? close() : open(); });
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
