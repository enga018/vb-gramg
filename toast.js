/* Shared VBGRAMG toast notifications. */
(function () {
  var timer = null;
  var host = null;

  function ensureStyles() {
    if (document.getElementById("app-toast-styles")) return;

    var style = document.createElement("style");
    style.id = "app-toast-styles";
    style.textContent = `
      #app-toast {
        position: fixed;
        z-index: 10000;
        top: calc(16px + env(safe-area-inset-top, 0px));
        right: 20px;
        width: min(560px, calc(100vw - 40px));
        box-sizing: border-box;
        padding: 12px 16px;
        border: 1px solid var(--color-border, #d9e1eb);
        border-radius: 12px;
        background: var(--color-bg-surface-raised, #fff);
        color: var(--color-text-primary, #273449);
        font: 600 14px/1.45 var(--font-family-sans, system-ui, -apple-system, BlinkMacSystemFont, 'Segoe UI', sans-serif);
        box-shadow: var(--shadow-md, 0 10px 30px rgba(23,32,51,.18));
        opacity: 0;
        visibility: hidden;
        pointer-events: none;
        transform: translateY(-12px);
        transition: opacity .18s ease, transform .18s ease, visibility .18s;
        overflow-wrap: anywhere;
      }
      #app-toast.show {
        opacity: 1;
        visibility: visible;
        transform: translateY(0);
      }
      @media (max-width: 767px) {
        #app-toast {
          top: calc(12px + env(safe-area-inset-top, 0px));
          right: auto;
          left: 50%;
          width: calc(100vw - 28px);
          transform: translate(-50%, -12px);
        }
        #app-toast.show { transform: translate(-50%, 0); }
      }
      #app-toast.success {
        background: var(--color-status-success-bg, #effaf3);
        border-color: var(--color-status-success, #bfe6cc);
        color: var(--color-status-success, #17663a);
      }
      #app-toast.error {
        background: var(--color-status-danger-bg, #fff0ed);
        border-color: var(--color-status-danger, #f3c5bd);
        color: var(--color-status-danger, #9b2c20);
      }
      #app-toast.warning {
        background: var(--color-status-warning-bg, #fff8e9);
        border-color: var(--color-status-warning, #f1d59f);
        color: var(--color-status-warning, #805b2c);
      }
      #app-toast.info {
        background: var(--color-status-info-bg, #f3f7fd);
        border-color: var(--color-status-info, #d9e5f5);
        color: var(--color-status-info, #344b70);
      }
      @media (prefers-reduced-motion: reduce) {
        #app-toast { transition: none; transform: none; }
        @media (max-width: 767px) {
          #app-toast, #app-toast.show { transform: translateX(-50%); }
        }
      }
    `;
    document.head.appendChild(style);
  }

  function ensureHost() {
    ensureStyles();
    if (host && host.isConnected) return host;

    host = document.getElementById("app-toast");
    if (host) return host;

    host = document.createElement("div");
    host.id = "app-toast";
    document.body.appendChild(host);
    return host;
  }

  window.showToast = function (message, type, duration) {
    if (message == null || String(message).trim() === "") return;

    var node = ensureHost();
    var kind = ["success", "error", "warning", "info"].indexOf(type) >= 0 ? type : "info";

    node.textContent = String(message);
    node.className = kind;
    node.classList.add("show");
    node.setAttribute("role", kind === "error" ? "alert" : "status");
    node.setAttribute("aria-live", kind === "error" ? "assertive" : "polite");
    node.setAttribute("aria-atomic", "true");

    window.clearTimeout(timer);
    timer = window.setTimeout(function () {
      node.classList.remove("show");
    }, Number(duration) > 0 ? Number(duration) : (String(message).length > 120 ? 5000 : 3200));
  };
})();
