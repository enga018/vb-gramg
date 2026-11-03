/* Shared VBGRAMG toast notifications. */
(function () {
  var timer = null;
  var host = null;
  function ensureHost() {
    if (host && host.isConnected) return host;
    host = document.getElementById("app-toast");
    if (host) return host;
    var style = document.createElement("style");
    style.id = "app-toast-styles";
    style.textContent = "#app-toast{position:fixed;z-index:10000;left:50%;bottom:24px;transform:translate(-50%,16px);width:max-content;max-width:calc(100vw - 28px);padding:12px 16px;border:1px solid #d9e1eb;border-radius:12px;background:#fff;color:#273449;font:600 14px/1.45 system-ui,-apple-system,BlinkMacSystemFont,'Segoe UI',sans-serif;box-shadow:0 10px 30px rgba(23,32,51,.18);opacity:0;visibility:hidden;pointer-events:none;transition:opacity .18s ease,transform .18s ease,visibility .18s}#app-toast.show{opacity:1;visibility:visible;transform:translate(-50%,0)}#app-toast.success{background:#effaf3;border-color:#bfe6cc;color:#17663a}#app-toast.error{background:#fff0ed;border-color:#f3c5bd;color:#9b2c20}#app-toast.warning{background:#fff8e9;border-color:#f1d59f;color:#805b2c}#app-toast.info{background:#f3f7fd;border-color:#d9e5f5;color:#344b70}@media(max-width:600px){#app-toast{bottom:16px;width:calc(100vw - 28px);text-align:center}}";
    document.head.appendChild(style);
    host = document.createElement("div");
    host.id = "app-toast";
    host.setAttribute("role", "status");
    host.setAttribute("aria-live", "polite");
    host.setAttribute("aria-atomic", "true");
    document.body.appendChild(host);
    return host;
  }
  window.showToast = function (message, type, duration) {
    if (message == null || String(message).trim() === "") return;
    var node = ensureHost();
    node.textContent = String(message);
    node.className = (type || "info");
    node.classList.add("show");
    window.clearTimeout(timer);
    timer = window.setTimeout(function () { node.classList.remove("show"); }, Number(duration) > 0 ? Number(duration) : (String(message).length > 120 ? 5000 : 3200));
  };
})();