/* Shared three-dot navigation for VBGRAMG pages. */
(function () {
  function install() {
    var path = window.location.pathname || "/";
    var cleanPath = path.replace(/\/+$/, "") || "/";
    if (cleanPath === "/index.html" || cleanPath === "/") return;

    var header = document.querySelector("header");
    if (!header || document.querySelector(".global-nav")) return;

    header.querySelectorAll("a.menu-link").forEach(function (a) { a.remove(); });

    var wrap = document.createElement("div");
    wrap.className = "global-nav";

    var button = document.createElement("button");
    button.type = "button";
    button.className = "global-nav-trigger";
    button.setAttribute("aria-label", "Open navigation menu");
    button.setAttribute("aria-haspopup", "true");
    button.setAttribute("aria-expanded", "false");
    button.title = "Navigation";
    button.textContent = "⋮";

    var panel = document.createElement("nav");
    panel.className = "global-nav-panel";
    panel.setAttribute("aria-label", "Main navigation");
    panel.hidden = true;

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
      button.setAttribute("aria-expanded", "false");
    }

    button.addEventListener("click", function () {
      var opening = panel.hidden;
      panel.hidden = !opening;
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