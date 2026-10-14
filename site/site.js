// Orra website: plays the demos and reveals sections on scroll.
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

  // Demos: dictation, then translation. One plays while the other waits in
  // its final state. Each goes idle, then speak, then done.
  var demos = document.querySelector(".demos");
  if (!demos) return;

  var phases = [
    ["dictate", "idle", 800],
    ["dictate", "speak", 2600],
    ["dictate", "done", 3400],
    ["translate", "idle", 800],
    ["translate", "speak", 2600],
    ["translate", "done", 3800]
  ];
  var figures = demos.querySelectorAll("[data-demo]");
  var index = 0;
  var timer = null;
  var visible = true;

  function show(name, phase) {
    if (name) demos.setAttribute("data-active", name);
    else demos.removeAttribute("data-active");
    figures.forEach(function (figure) {
      if (figure.getAttribute("data-demo") === name) figure.setAttribute("data-phase", phase);
      else figure.removeAttribute("data-phase");
    });
  }

  function step() {
    var phase = phases[index];
    show(phase[0], phase[1]);
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
    show(null);
  }

  if ("IntersectionObserver" in window) {
    new IntersectionObserver(function (entries) {
      visible = entries[0].isIntersecting;
      if (visible) start(); else stop();
    }).observe(demos);
  }

  document.addEventListener("visibilitychange", function () {
    if (document.hidden) stop(); else start();
  });

  if (reduce.addEventListener) {
    reduce.addEventListener("change", function (e) { if (e.matches) finish(); });
  }

  start();
})();
