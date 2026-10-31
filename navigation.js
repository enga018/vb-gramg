/* Shared three-dot navigation for VBGRAMG pages. */
(function () {
  function install() {
    var path = window.location.pathname || "/";
    var cleanPath = path.replace(/\/+$/, "") || "/";
    if (cleanPath.endsWith("/index.html") || cleanPath === "/" || path.endsWith("/")) return;

    var header = document.querySelector("header");
    if (!header || document.querySelector(".global-nav")) return;

    header.querySelectorAll("a.menu-link").forEach(function (a) { a.remove(); });

    // Apply critical positioning inline so malformed/overridden shared CSS
    // cannot push the menu into the header's normal document flow.
    header.style.setProperty("position", "relative", "important");
    header.style.setProperty("padding-right", "60px", "important");

    var wrap = document.createElement("div");
    wrap.className = "global-nav";
    wrap.style.setProperty("position", "absolute", "important");
    wrap.style.setProperty("top", "8px", "important");
    wrap.style.setProperty("right", "8px", "important");
    wrap.style.setProperty("left", "auto", "important");
    wrap.style.setProperty("bottom", "auto", "important");
    wrap.style.setProperty("display", "inline-flex", "important");
    wrap.style.setProperty("align-items", "center", "important");
    wrap.style.setProperty("z-index", "1000", "important");
    wrap.style.setProperty("margin", "0", "important");
    wrap.style.setProperty("transform", "none", "important");

    var button = document.createElement("button");
    button.type = "button";
    button.className = "global-nav-trigger";
    button.setAttribute("aria-label", "Open navigation menu");
    button.setAttribute("aria-haspopup", "true");
    button.setAttribute("aria-expanded", "false");
    button.title = "Navigation";
    button.textContent = "⋮";
    // Match the neutral Refresh/action buttons used throughout the app.
    button.style.setProperty("appearance", "none", "important");
    button.style.setProperty("background", "#eef2f7", "important");
    button.style.setProperty("border", "1px solid #dfe5ee", "important");
    button.style.setProperty("border-radius", "14px", "important");
    button.style.setProperty("color", "#354258", "important");
    button.style.setProperty("width", "44px", "important");
    button.style.setProperty("min-width", "44px", "important");
    button.style.setProperty("height", "44px", "important");
    button.style.setProperty("min-height", "44px", "important");
    button.style.setProperty("padding", "0", "important");
    button.style.setProperty("font", "700 1.55rem/1 system-ui,sans-serif", "important");
    button.style.setProperty("box-shadow", "none", "important");

    var panel = document.createElement("nav");
    panel.className = "global-nav-panel";
    panel.setAttribute("aria-label", "Main navigation");
    panel.hidden = true;
    panel.style.setProperty("position", "absolute", "important");
    panel.style.setProperty("top", "calc(100% + 8px)", "important");
    panel.style.setProperty("right", "0", "important");
    panel.style.setProperty("left", "auto", "important");
    panel.style.setProperty("width", "min(260px, calc(100vw - 28px))", "important");
    panel.style.setProperty("padding", "9px", "important");
    panel.style.setProperty("display", "flex", "important");
    panel.style.setProperty("flex-direction", "column", "important");
    panel.style.setProperty("gap", "6px", "important");
    panel.style.setProperty("background", "#ffffff", "important");
    panel.style.setProperty("border", "1px solid #dfe5ee", "important");
    panel.style.setProperty("border-radius", "14px", "important");
    panel.style.setProperty("box-shadow", "0 12px 30px rgba(23,32,51,.16)", "important");
    panel.style.setProperty("z-index", "2000", "important");

    var links = [
      ["Main menu", "./"],
      ["MIS", "./mis.html"],
      ["FTO", "./fto.html"],
      ["Work Demand", "./demand.html"],
      ["Periods", "./periods.html"],
      ["Contribution", "./contribution.html"]
    ];

    links.forEach(function (item) {
      var a = document.createElement("a");
      a.href = item[1];
      a.textContent = item[0];
      a.style.setProperty("display", "flex", "important");
      a.style.setProperty("align-items", "center", "important");
      a.style.setProperty("min-height", "46px", "important");
      a.style.setProperty("padding", "10px 13px", "important");
      a.style.setProperty("border-radius", "10px", "important");
      a.style.setProperty("background", "#f3f5f8", "important");
      a.style.setProperty("border", "1px solid #e5e9f0", "important");
      a.style.setProperty("color", "#354258", "important");
      a.style.setProperty("font", "600 15px/1.3 system-ui,sans-serif", "important");
      a.style.setProperty("text-decoration", "none", "important");
      a.style.setProperty("white-space", "normal", "important");
      var targetPath = new URL(item[1], window.location.href).pathname.replace(/\/+$/, "") || "/";
      if (targetPath === cleanPath || (item[1] === "./" && (cleanPath.endsWith("/index.html") || cleanPath === "/"))) {
        a.classList.add("is-current");
        a.setAttribute("aria-current", "page");
      }
      panel.appendChild(a);
    });

    wrap.appendChild(button);
    wrap.appendChild(panel);
    header.appendChild(wrap);

    function close() {
      panel.hidden = true;
      panel.style.setProperty("display", "none", "important");
      button.setAttribute("aria-expanded", "false");
    }

    button.addEventListener("click", function (event) {
      event.stopPropagation();
      var opening = panel.hidden;
      panel.hidden = !opening;
      panel.style.setProperty("display", opening ? "flex" : "none", "important");
      button.setAttribute("aria-expanded", String(opening));
    });
    document.addEventListener("click", function (event) {
      if (!wrap.contains(event.target)) close();
    });
    document.addEventListener("keydown", function (event) {
      if (event.key === "Escape") {
        close();
        button.focus();
      }
    });
  }

  if (document.readyState === "loading") {
    document.addEventListener("DOMContentLoaded", install);
  } else {
    install();
  }
})();