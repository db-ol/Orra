// Orra website: plays the hero animation and reveals sections on scroll.
// Without this script, or with reduced motion, the page shows the final state.
(function () {
  "use strict";

  var reduce = window.matchMedia("(prefers-reduced-motion: reduce)");
  if (reduce.matches) return;

  document.documentElement.classList.add("js");

  // Reveal on scroll.
  var revealed = document.querySelectorAll(".reveal");
  if ("IntersectionObserver" in window) {
    var revealer = new IntersectionObserver(function (entries) {
      entries.forEach(function (entry) {
        if (entry.isIntersecting) {
          entry.target.classList.add("in");
          revealer.unobserve(entry.target);
        }
      });
    }, { rootMargin: "0px 0px -8% 0px" });
    revealed.forEach(function (el) { revealer.observe(el); });
  } else {
    revealed.forEach(function (el) { el.classList.add("in"); });
  }

  // Hero animation in two scenes. Dictation: hold the talk key, speak, release,
  // and the text lands at the cursor. Translation: hold the translation key,
  // speak Chinese, release, and the English translation lands on the next line.
  var demo = document.querySelector(".demo");
  if (!demo) return;

  var phases = [
    ["dictate", "idle", 900],
    ["dictate", "hold", 700],
    ["dictate", "speak", 2600],
    ["dictate", "release", 3400],
    ["translate", "idle", 700],
    ["translate", "hold", 700],
    ["translate", "speak", 2600],
    ["translate", "release", 4200]
  ];
  var index = 0;
  var timer = null;
  var visible = true;

  function step() {
    var phase = phases[index];
    demo.setAttribute("data-scene", phase[0]);
    demo.setAttribute("data-phase", phase[1]);
    index = (index + 1) % phases.length;
    timer = window.setTimeout(step, phase[2]);
  }

  function stop() {
    window.clearTimeout(timer);
    timer = null;
  }

  function start() {
    if (timer === null && visible && !document.hidden) {
      index = 0;
      step();
    }
  }

  function finish() {
    stop();
    demo.removeAttribute("data-scene");
    demo.removeAttribute("data-phase");
  }

  if ("IntersectionObserver" in window) {
    new IntersectionObserver(function (entries) {
      visible = entries[0].isIntersecting;
      if (visible) start(); else stop();
    }).observe(demo);
  }

  document.addEventListener("visibilitychange", function () {
    if (document.hidden) stop(); else start();
  });

  if (reduce.addEventListener) {
    reduce.addEventListener("change", function (e) { if (e.matches) finish(); });
  }

  start();
})();
