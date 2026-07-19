// Flux landing — detect the visitor's platform and spotlight the right download.
(function () {
  "use strict";

  var ua = navigator.userAgent || "";
  var platform = navigator.platform || "";
  var os = "other";

  if (/Mac|iPhone|iPad|iPod/i.test(ua + platform)) os = "macos";
  else if (/Linux|X11/i.test(ua + platform) && !/Android/i.test(ua)) os = "linux";
  else if (/Win/i.test(ua + platform)) os = "windows";

  var map = { macos: "dl-macos", linux: "dl-linux", windows: "dl-source" };
  var labels = {
    macos: "Download for macOS",
    linux: "Download for Linux",
    windows: "Get Flux",
    other: "Download Flux",
  };

  // Highlight the matching download card.
  var cardId = map[os];
  if (cardId) {
    var card = document.getElementById(cardId);
    if (card) card.classList.add("recommended");
  }

  // Update the hero button label + target.
  var heroLabel = document.getElementById("hero-download-label");
  if (heroLabel) heroLabel.textContent = labels[os] || labels.other;
})();
