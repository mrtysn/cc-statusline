(function () {
  var media = matchMedia("(prefers-color-scheme: light)");
  /* A page drawn for one theme says so with <html data-theme-fixed="light">: its colours then
     never mix with the other theme's tokens. */
  var fixed = document.documentElement.getAttribute("data-theme-fixed");
  function theme() {
    document.documentElement.dataset.theme = fixed || (media.matches ? "light" : "dark");
  }
  theme();
  media.addEventListener("change", theme);
})();
document.addEventListener("DOMContentLoaded", function () {
  [].forEach.call(document.querySelectorAll('a[href]:not([href^="#"])'), function (a) {
    a.target = "_blank";
    a.rel = "noopener noreferrer";
  });
  // Every code block in the text gets a Copy button: pages often carry text meant to be pasted
  // elsewhere. The clipboard API needs a secure context; a selection copy stands in without one.
  [].forEach.call(document.querySelectorAll("main pre"), function (pre) {
    if (pre.closest(".ws-no-copy")) return;
    var wrap = document.createElement("div"), button = document.createElement("button");
    wrap.className = "ws-copy-wrap";
    button.type = "button";
    button.className = "ws-copy";
    button.textContent = "Copy";
    pre.parentNode.insertBefore(wrap, pre);
    wrap.appendChild(button);
    wrap.appendChild(pre);
    function done(label) {
      button.textContent = label;
      setTimeout(function () { button.textContent = "Copy"; }, 1500);
    }
    function fallback(text) {
      var area = document.createElement("textarea"), ok = false;
      area.value = text;
      area.setAttribute("readonly", "");
      area.className = "ws-copy-buffer";
      document.body.appendChild(area);
      area.select();
      try { ok = document.execCommand("copy"); } catch (e) { ok = false; }
      document.body.removeChild(area);
      done(ok ? "Copied" : "Copy failed");
    }
    button.addEventListener("click", function () {
      var text = pre.textContent.replace(/\n$/, "");
      if (navigator.clipboard && window.isSecureContext) {
        navigator.clipboard.writeText(text).then(function () { done("Copied"); }, function () { fallback(text); });
      } else {
        fallback(text);
      }
    });
  });
  var links = [].slice.call(document.querySelectorAll(".ws-toc a"));
  if (!links.length) return;
  var sections = links.map(function (a) {
    return document.getElementById(a.getAttribute("href").slice(1));
  });
  function mark() {
    var at = window.innerHeight * 0.3, current = 0, k;
    for (k = 0; k < sections.length; k++) {
      if (sections[k] && sections[k].getBoundingClientRect().top <= at) current = k;
    }
    if (window.innerHeight + window.scrollY >= document.documentElement.scrollHeight - 2) current = sections.length - 1;
    links.forEach(function (a, n) {
      a.setAttribute("aria-current", n === current ? "true" : "false");
    });
  }
  addEventListener("scroll", mark, { passive: true });
  addEventListener("resize", mark);
  mark();
});

/* Tables in <main> with a header and three or more body rows sort by clicking a header; eight or more
   rows also get a filter box. Opt out with class ws-static. Rows are only reordered or hidden, so links
   and listeners inside cells survive. */
document.addEventListener("DOMContentLoaded", function () {
  var EMPTY = /^(|—|–|-|n\/a|not checked|none)$/i;
  function parseNumber(text) {
    var m = text.match(/\d[\d.,]*/), s, dot, comma, sep, parts;
    if (!m) return null;
    s = m[0].replace(/[.,]+$/, "");
    dot = s.lastIndexOf("."); comma = s.lastIndexOf(",");
    if (dot >= 0 && comma >= 0) {
      sep = dot > comma ? "." : ",";
      s = sep === "." ? s.replace(/,/g, "") : s.replace(/\./g, "").replace(",", ".");
    } else if (dot >= 0 || comma >= 0) {
      sep = dot >= 0 ? "." : ",";
      parts = s.split(sep);
      if (parts.length > 2 || parts[1].length === 3) s = parts.join("");
      else s = parts.join(".");
    }
    var n = parseFloat(s);
    return isNaN(n) ? null : n;
  }
  [].forEach.call(document.querySelectorAll("main table"), function (table) {
    if (table.classList.contains("ws-static") || !table.tHead || table.tBodies.length !== 1) return;
    var body = table.tBodies[0], rows = [].slice.call(body.rows);
    if (rows.length < 3) return;
    var headRow = table.tHead.rows[table.tHead.rows.length - 1];
    var state = { col: -1, dir: 0 };
    var cells = rows.map(function (row) {
      return [].map.call(row.cells, function (td) {
        var t = td.textContent.replace(/\s+/g, " ").trim();
        return { text: t, empty: EMPTY.test(t), num: parseNumber(t) };
      });
    });
    var info = rows.map(function (row, i) { return { row: row, cells: cells[i], index: i }; });
    function numericColumn(c) {
      var filled = 0, nums = 0;
      info.forEach(function (r) {
        var cell = r.cells[c];
        if (!cell || cell.empty) return;
        filled++;
        if (cell.num !== null) nums++;
      });
      return filled > 0 && nums > filled / 2;
    }
    function apply() {
      var c = state.col, numeric = c >= 0 && state.dir && numericColumn(c), sign = state.dir === -1 ? -1 : 1;
      var sorted = info.slice().sort(function (a, b) {
        if (!state.dir) return a.index - b.index;
        var x = a.cells[c] || { empty: true }, y = b.cells[c] || { empty: true }, r;
        if (numeric) {
          x = x.empty || x.num === null ? { empty: true } : x;
          y = y.empty || y.num === null ? { empty: true } : y;
        }
        if (x.empty || y.empty) return x.empty && y.empty ? a.index - b.index : (x.empty ? 1 : -1);
        r = numeric ? x.num - y.num : x.text.localeCompare(y.text, "tr");
        return r ? r * sign : a.index - b.index;
      });
      sorted.forEach(function (r) { body.appendChild(r.row); });
      [].forEach.call(headRow.cells, function (th, n) {
        var on = n === c && state.dir;
        if (th.querySelector(".ws-sort")) {
          th.setAttribute("aria-sort", on ? (state.dir === 1 ? "ascending" : "descending") : "none");
          th.querySelector(".ws-sort-mark").textContent = on ? (state.dir === 1 ? "▲" : "▼") : "";
        }
      });
    }
    [].forEach.call(headRow.cells, function (th, n) {
      if (th.colSpan > 1) return;
      var button = document.createElement("button"), mark = document.createElement("span");
      button.type = "button";
      button.className = "ws-sort";
      mark.className = "ws-sort-mark";
      mark.setAttribute("aria-hidden", "true");
      while (th.firstChild) button.appendChild(th.firstChild);
      button.appendChild(mark);
      th.appendChild(button);
      th.setAttribute("aria-sort", "none");
      button.addEventListener("click", function () {
        if (state.col !== n) { state.col = n; state.dir = 1; }
        else if (state.dir === 1) state.dir = -1;
        else state.dir = 0;
        apply();
      });
    });
    if (rows.length >= 8) {
      var bar = document.createElement("div"), input = document.createElement("input"), count = document.createElement("span");
      bar.className = "ws-filter";
      input.type = "search";
      input.placeholder = "Filter rows";
      input.setAttribute("aria-label", "Filter rows");
      count.className = "ws-filter-count";
      count.setAttribute("aria-live", "polite");
      bar.appendChild(input);
      bar.appendChild(count);
      table.parentNode.insertBefore(bar, table);
      var haystack = rows.map(function (row) { return row.textContent.replace(/\s+/g, " ").toLocaleLowerCase("tr"); });
      input.addEventListener("input", function () {
        var q = input.value.trim().toLocaleLowerCase("tr"), shown = 0;
        info.forEach(function (r) {
          var hit = !q || haystack[r.index].indexOf(q) >= 0;
          r.row.hidden = !hit;
          if (hit) shown++;
        });
        count.textContent = q ? shown + " of " + rows.length + " rows" : "";
      });
    }
  });
});

/* Task lists on a page that asks for it (<html data-ws-tasks="tick">) are ticked by the reader. A
   tick is kept in this browser's localStorage under the page's path and the line's own text, so a
   rebuilt page keeps the tick of every line whose wording did not change. A box the page's source
   already ticked stays ticked and read-only. The contents column, or the place above the first task
   list on a page without one, shows how many are done. */
document.addEventListener("DOMContentLoaded", function () {
  if (document.documentElement.getAttribute("data-ws-tasks") !== "tick") return;
  var boxes = [].slice.call(document.querySelectorAll('main li > input[type="checkbox"]'));
  if (!boxes.length) return;
  var KEY = "ws-tasks:" + location.pathname, saved = {};
  try { saved = JSON.parse(localStorage.getItem(KEY) || "{}") || {}; } catch (e) { saved = {}; }
  function lineOf(box) {
    var text = "";
    [].forEach.call(box.parentNode.childNodes, function (node) {
      if (node.nodeType === 3) text += node.textContent;
      else if (node.nodeType === 1 && !/^(UL|OL|INPUT)$/.test(node.tagName)) text += node.textContent;
    });
    return text.replace(/\s+/g, " ").trim();
  }
  var count = document.createElement("p"), toc = document.querySelector(".ws-toc");
  count.className = "ws-task-count";
  count.setAttribute("aria-live", "polite");
  if (toc) toc.appendChild(count);
  else {
    var list = boxes[0].parentNode.parentNode;
    list.parentNode.insertBefore(count, list);
  }
  function show() {
    var done = boxes.filter(function (box) { return box.checked; }).length;
    count.textContent = done + " of " + boxes.length + " done";
  }
  boxes.forEach(function (box) {
    var line = lineOf(box);
    box.setAttribute("aria-label", line.slice(0, 80));
    if (box.checked) return;
    box.disabled = false;
    box.checked = saved[line] === true;
    box.addEventListener("change", function () {
      if (box.checked) saved[line] = true;
      else delete saved[line];
      try { localStorage.setItem(KEY, JSON.stringify(saved)); } catch (e) {}
      show();
    });
  });
  show();
});
(function () {
  var KEY = "ws-font";
  var CHOICES = [
    ["default", "Page default", null],
    ["new-york", "New York", 'ui-serif, "New York", Charter, Georgia, serif'],
    ["charter", "Charter", 'Charter, "Iowan Old Style", Georgia, serif'],
    ["georgia", "Georgia", "Georgia, serif"],
    ["sf-pro", "SF Pro", "-apple-system, BlinkMacSystemFont, system-ui, sans-serif"],
    ["avenir", "Avenir Next", '"Avenir Next", Avenir, system-ui, sans-serif'],
    ["rounded", "SF Rounded", 'ui-rounded, "SF Pro Rounded", system-ui, sans-serif'],
    ["mono", "SF Mono", 'ui-monospace, "SF Mono", Menlo, monospace']
  ];
  var root = document.documentElement;
  function sizeOf(name) {
    var value = getComputedStyle(root).getPropertyValue(name).trim();
    return value.split(/\s+/)[0];
  }
  var size = { "--font-p": sizeOf("--font-p"), "--font-h": sizeOf("--font-h") };
  function find(id) {
    for (var i = 0; i < CHOICES.length; i++) if (CHOICES[i][0] === id) return CHOICES[i];
    return CHOICES[0];
  }
  function apply(id) {
    var stack = find(id)[2];
    ["--font-p", "--font-h"].forEach(function (name) {
      if (stack && size[name]) root.style.setProperty(name, size[name] + " " + stack);
      else root.style.removeProperty(name);
    });
  }
  function stored() {
    try { return localStorage.getItem(KEY) || "default"; } catch (e) { return "default"; }
  }
  function remember(id) {
    try { localStorage.setItem(KEY, id); } catch (e) {}
  }
  apply(stored());
  function build() {
    // A deck, and an app page (which keeps its own controls at the top), get no menu.
    if (document.body.classList.contains("ws-deck") || document.body.classList.contains("ws-app")) return;
    var bar = document.createElement("div");
    bar.className = "ws-fontpick";
    var label = document.createElement("label");
    label.textContent = "Font ";
    var select = document.createElement("select");
    CHOICES.forEach(function (choice) {
      var option = document.createElement("option");
      option.value = choice[0];
      option.textContent = choice[1];
      select.appendChild(option);
    });
    select.value = find(stored())[0];
    select.addEventListener("change", function () {
      apply(select.value);
      remember(select.value);
    });
    label.appendChild(select);
    bar.appendChild(label);
    document.body.insertBefore(bar, document.body.firstChild);
  }
  if (document.readyState === "loading") document.addEventListener("DOMContentLoaded", build);
  else build();
})();
(function () {
  if (window.wsViewer) return;
  window.wsViewer = true;

  var GALLERY = ".ws-gallery, [data-ws-viewer]";
  // A pointer that moves this far sideways, and further sideways than up or down, is a swipe.
  var SWIPE_PX = 40;

  var style = document.createElement("style");
  style.setAttribute("data-ws", "viewer");
  style.textContent = [
    ":is(.ws-gallery, [data-ws-viewer]) img { cursor: zoom-in; }",
    // The dialog fills the page's box (inset, not 100vw, so a scrollbar gutter the page reserves
    // never pushes it off the right edge); the page shows through its backdrop, nearly hidden.
    "dialog.ws-viewer { box-sizing: border-box; inset: 0; width: auto; height: auto; max-width: none;",
    "  max-height: none; margin: 0; padding: 3.5rem 3.5rem 1rem; border: 0; overflow: hidden;",
    "  background: transparent; color: var(--cfg); touch-action: pinch-zoom; }",
    "dialog.ws-viewer::backdrop { background: color-mix(in oklab, var(--cbg) 97%, transparent); }",
    ".ws-viewer figure { display: flex; flex-direction: column; align-items: center;",
    "  justify-content: center; gap: 0.5rem; height: 100%; margin: 0; }",
    // Never larger than the file, so a small figure is not blown up into a blur.
    ".ws-viewer figure > img { display: block; width: auto; height: auto; max-width: 100%;",
    "  max-height: calc(100dvh - 9rem); margin: 0; object-fit: contain; border-radius: 4px; }",
    ".ws-viewer figcaption { width: auto; max-width: 60ch; margin: 0; text-align: center;",
    "  color: var(--cdark); }",
    ".ws-viewer-count { margin-left: 0.5rem; font-variant-numeric: tabular-nums; white-space: nowrap; }",
    ".ws-viewer button { position: fixed; display: grid; place-items: center; width: 2.6rem;",
    "  height: 2.6rem; margin: 0; padding: 0; border-radius: 50%; font-size: 1.4rem; line-height: 1; }",
    ".ws-viewer button:focus-visible { outline: 2px solid var(--clink); outline-offset: 2px; }",
    ".ws-viewer-close { top: 0.5rem; right: 0.5rem; }",
    ".ws-viewer-prev, .ws-viewer-next { top: calc(50% - 1.3rem); }",
    ".ws-viewer-prev { left: 0.5rem; }",
    ".ws-viewer-next { right: 0.5rem; }",
    ".ws-viewer[data-single] :is(.ws-viewer-prev, .ws-viewer-next) { display: none; }",
    // On a phone the picture takes the width and the step buttons move under it.
    "@media (max-width: 30rem) {",
    "  dialog.ws-viewer { padding: 3.5rem 0.5rem 3.5rem; }",
    "  .ws-viewer figure > img { max-height: calc(100dvh - 11rem); }",
    "  .ws-viewer-prev, .ws-viewer-next { top: auto; bottom: 0.5rem; }",
    "}",
  ].join("\n");
  document.head.appendChild(style);

  var dialog, figure, big, caption, count;
  var items = [];
  var at = 0;
  var opener = null;
  var start = null;
  var swiped = false;

  function source(pic) {
    var link = pic.closest("a[href]");
    return link ? link.href : pic.currentSrc || pic.src;
  }

  function text(pic) {
    var fig = pic.closest("figure");
    var cap = fig && fig.querySelector("figcaption");
    return (cap && cap.textContent.trim()) || pic.title || pic.alt || "";
  }

  function button(cls, label, glyph, act) {
    var b = document.createElement("button");
    b.type = "button";
    b.className = cls;
    b.setAttribute("aria-label", label);
    b.textContent = glyph;
    b.addEventListener("click", function (e) {
      e.stopPropagation();
      act();
    });
    return b;
  }

  function build() {
    if (dialog) return;
    dialog = document.createElement("dialog");
    dialog.className = "ws-viewer";
    dialog.setAttribute("aria-label", "Picture");
    figure = document.createElement("figure");
    big = document.createElement("img");
    big.draggable = false;
    var cap = document.createElement("figcaption");
    caption = document.createElement("span");
    count = document.createElement("span");
    count.className = "ws-viewer-count";
    cap.append(caption, count);
    figure.append(big, cap);
    var close = button("ws-viewer-close", "Close", "×", function () {
      dialog.close();
    });
    close.autofocus = true;
    dialog.append(
      figure,
      button("ws-viewer-prev", "Previous picture", "‹", function () {
        show(at - 1);
      }),
      button("ws-viewer-next", "Next picture", "›", function () {
        show(at + 1);
      }),
      close,
    );

    // A click beside the picture and its caption closes the viewer; the click that ends a swipe does not.
    dialog.addEventListener("click", function (e) {
      if (!swiped && (e.target === dialog || e.target === figure)) dialog.close();
    });
    dialog.addEventListener("keydown", function (e) {
      if (e.key === "ArrowLeft") {
        e.preventDefault();
        show(at - 1);
      } else if (e.key === "ArrowRight") {
        e.preventDefault();
        show(at + 1);
      }
    });
    dialog.addEventListener("pointerdown", function (e) {
      start = { x: e.clientX, y: e.clientY };
      swiped = false;
    });
    dialog.addEventListener("pointerup", function (e) {
      if (!start) return;
      var dx = e.clientX - start.x;
      var dy = e.clientY - start.y;
      start = null;
      if (items.length > 1 && Math.abs(dx) > SWIPE_PX && Math.abs(dx) > Math.abs(dy)) {
        swiped = true;
        show(at + (dx < 0 ? 1 : -1));
      }
    });
    dialog.addEventListener("close", function () {
      document.documentElement.style.overflow = "";
      big.removeAttribute("src");
      if (opener && opener.isConnected) opener.focus();
    });
    document.body.appendChild(dialog);
  }

  function show(i) {
    at = (i + items.length) % items.length;
    var pic = items[at];
    big.src = source(pic);
    big.alt = pic.alt || "";
    caption.textContent = text(pic);
    count.textContent = items.length > 1 ? at + 1 + " / " + items.length : "";
    // The neighbours load now, so a step shows its picture at once.
    [at - 1, at + 1].forEach(function (j) {
      new Image().src = source(items[(j + items.length) % items.length]);
    });
  }

  function open(gallery, pic) {
    build();
    items = Array.prototype.slice.call(gallery.querySelectorAll("img"));
    opener = pic.closest("a[href]") || pic;
    dialog.toggleAttribute("data-single", items.length < 2);
    show(items.indexOf(pic));
    document.documentElement.style.overflow = "hidden";
    dialog.showModal();
  }

  document.addEventListener("click", function (e) {
    if (e.defaultPrevented || e.button !== 0 || e.metaKey || e.ctrlKey || e.shiftKey || e.altKey) return;
    var t = e.target;
    if (!(t instanceof Element) || (dialog && dialog.contains(t))) return;
    var gallery = t.closest(GALLERY);
    if (!gallery) return;
    var link = t.closest("a[href]");
    var pic = t.closest("img") || (link && link.querySelector("img"));
    if (!pic || !gallery.contains(pic)) return;
    e.preventDefault();
    open(gallery, pic);
  });
})();
