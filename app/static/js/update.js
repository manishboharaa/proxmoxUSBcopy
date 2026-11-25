/* Update banner: asks the dashboard (cached server-side) whether a newer
 * version was pushed to GitHub. Fails quiet everywhere. */
(function () {
  "use strict";

  var banner = document.getElementById("update-banner");
  if (!banner) return;
  if (window.sessionStorage && window.sessionStorage.getItem("usbcopy-update-dismissed")) {
    return;
  }

  var textEl = document.getElementById("update-banner-text");
  var copyBtn = document.getElementById("update-copy");
  var dismissBtn = document.getElementById("update-dismiss");
  var command = "";

  function hide() {
    banner.hidden = true;
  }

  dismissBtn.addEventListener("click", function () {
    if (window.sessionStorage) {
      window.sessionStorage.setItem("usbcopy-update-dismissed", "1");
    }
    hide();
  });

  copyBtn.addEventListener("click", function () {
    var done = function () {
      copyBtn.textContent = "Copied — paste it on the Proxmox host";
      window.setTimeout(function () {
        copyBtn.textContent = "Copy update command";
      }, 4000);
    };
    if (navigator.clipboard && navigator.clipboard.writeText) {
      navigator.clipboard.writeText(command).then(done, function () {
        window.prompt("Copy this command:", command);
      });
    } else {
      window.prompt("Copy this command:", command);
    }
  });

  fetch("/api/update/check", { credentials: "same-origin" })
    .then(function (response) {
      if (!response.ok) throw new Error("update check unavailable");
      return response.json();
    })
    .then(function (body) {
      if (!body.update_available) return;
      command = body.command || "";
      textEl.textContent =
        "Update available: v" + body.latest_version +
        " (installed v" + body.current_version + "). ";
      banner.hidden = false;
    })
    .catch(function () {
      /* No network, no newer version, or a session problem: stay quiet. */
    });
})();
