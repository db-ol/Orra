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

  // Demos: dictation, then cleanup, then translation. One plays while the
  // others wait in their final state. Each goes idle, then speak, then strike
  // (the filler is crossed out), then done (the text is pasted).
  var demos = document.querySelector(".demos");
  if (!demos) return;

  // Speech appears at about 8.5 characters a second in Chinese and Japanese,
  // which have no spaces between words, and 3 words a second in English and
  // Spanish. The spoken line is split into spans that fade in one after the
  // other, so it wraps like normal text. The speak phase lasts as long as
  // the line takes to appear, plus a short pause.
  var speakMs = {};
  demos.querySelectorAll("[data-demo]").forEach(function (figure) {
    var said = figure.querySelector(".demo-said");
    if (!said) return;
    var characters = /^(zh|ja)/i.test((said.closest("[lang]") || document.documentElement).getAttribute("lang"));
    var step = characters ? 1 / 8.5 : 1 / 3;
    var count = 0;
    // The quotation marks around the line show with its first and last unit.
    Array.from(said.childNodes).forEach(function (node) {
      var part = node.nodeType === 1 ? node : document.createElement("span");
      var units = characters ? Array.from(node.textContent) : node.textContent.match(/\S+\s*/g) || [];
      if (part !== node) said.replaceChild(part, node);
      part.textContent = "";
      units.forEach(function (unit) {
        var span = document.createElement("span");
        span.className = "unit";
        span.textContent = unit;
        if (part === node) {
          span.style.setProperty("--i", count);
          count += 1;
        } else {
          span.style.setProperty("--i", Math.max(count - 1, 0));
        }
        part.appendChild(span);
      });
    });
    figure.style.setProperty("--step", step + "s");
    speakMs[figure.getAttribute("data-demo")] = Math.round(count * step * 1000) + 400;
  });

  function speak(name) {
    return speakMs[name] || 2600;
  }

  var phases = [
    ["dictate", "idle", 800],
    ["dictate", "speak", speak("dictate")],
    ["dictate", "strike", 500],
    ["dictate", "done", 2700],
    ["cleanup", "idle", 800],
    ["cleanup", "speak", speak("cleanup")],
    ["cleanup", "strike", 500],
    ["cleanup", "done", 3100],
    ["translate", "idle", 800],
    ["translate", "speak", speak("translate")],
    ["translate", "strike", 500],
    ["translate", "done", 3300]
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
    if (timer === null && visible && !document.hidden && !reduce.matches) {
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
