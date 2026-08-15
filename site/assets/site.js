// bit — site-level interactivity
(function () {
  // mobile nav toggle
  const menu = document.querySelector(".topbar__menu");
  const nav  = document.querySelector(".topbar nav");
  if (menu && nav) {
    menu.addEventListener("click", () => nav.classList.toggle("open"));
  }

  // hero install copy (single button)
  const heroCopy = document.querySelector(".hero__install button");
  if (heroCopy) {
    heroCopy.addEventListener("click", () => {
      const cmd = heroCopy.parentElement.querySelector(".cmd");
      if (!cmd) return;
      navigator.clipboard.writeText(cmd.textContent).then(() => {
        const original = heroCopy.textContent;
        heroCopy.textContent = "copied";
        setTimeout(() => { heroCopy.textContent = original; }, 1400);
      });
    });
  }
})();
