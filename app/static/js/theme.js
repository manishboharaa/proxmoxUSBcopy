(function () {
  var root = document.documentElement;
  var themeButton = document.getElementById("theme-toggle");

  if (!themeButton) {
    return;
  }

  function setTheme(theme) {
    root.dataset.theme = theme;
    var dark = theme === "dark";
    themeButton.setAttribute("aria-pressed", dark ? "true" : "false");
    themeButton.setAttribute(
      "aria-label",
      dark ? "Switch to light theme" : "Switch to dark theme"
    );
    try {
      localStorage.setItem("usbcopy-theme", theme);
    } catch (error) {
      return;
    }
  }

  setTheme(root.dataset.theme === "dark" ? "dark" : "light");

  themeButton.addEventListener("click", function () {
    setTheme(root.dataset.theme === "dark" ? "light" : "dark");
  });
})();
