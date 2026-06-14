/* Bring Your Own Genome — vanilla, no deps.
   Scroll reveals · live numbers from receipts.json · fork animation ·
   karyotype landscape from landscape.json · economics calculator. */
(function () {
  "use strict";
  var reduceMotion = window.matchMedia && window.matchMedia("(prefers-reduced-motion: reduce)").matches;

  /* ---------- scroll reveals ---------- */
  var reveals = document.querySelectorAll(".reveal");
  if ("IntersectionObserver" in window && !reduceMotion) {
    var io = new IntersectionObserver(function (es) {
      es.forEach(function (e) { if (e.isIntersecting) { e.target.classList.add("in"); io.unobserve(e.target); } });
    }, { rootMargin: "0px 0px -8% 0px", threshold: 0.08 });
    reveals.forEach(function (el) { io.observe(el); });
  } else { reveals.forEach(function (el) { el.classList.add("in"); }); }

  /* ---------- helpers ---------- */
  function commas(n) { return Math.round(n).toLocaleString("en-US"); }
  function get(obj, path) { return path.split(".").reduce(function (o, k) { return (o == null ? o : o[k]); }, obj); }
  var CHR_ORDER = ["chr19", "chr20", "chr21", "chr22", "chrY"];

  function bindLive(r) {
    // computed aliases used by data-bind
    var warm = r.warm_shard_times || {};
    var warmVals = Object.keys(warm).map(function (k) { return warm[k]; });
    var warmAvg = warmVals.length ? warmVals.reduce(function (a, b) { return a + b; }, 0) / warmVals.length : 0;
    var dens = (r.biology && r.biology.island_density_per_mb) || {};
    var aliases = {
      "map_wallclock_sec_round": "~" + Math.round(r.map_wallclock_sec),
      "snapshot.size": (r.snapshot && r.snapshot.size) || "127 MB",
      "snapshot.save_sec": (r.snapshot ? r.snapshot.save_sec : 3.9),
      "genome.cpg_sites": commas(r.genome.cpg_sites),
      "genome.cpg_islands": commas(r.genome.cpg_islands),
      "genome.total_bp_mb": Math.round(r.genome.total_bp / 1e6),
      "genome.total_bp_commas": commas(r.genome.total_bp),
      "shards": String(r.shards),
      "cold_shard_avg_sec": r.cold_shard_avg_sec,
      "map_per_shard": "~" + warmAvg.toFixed(1),
      "biology.chr19_density": dens.chr19 != null ? dens.chr19 : "287.6",
      "biology.chrY_density": dens.chrY != null ? dens.chrY : "79.7",
      "economics.speedup_fanout": (r.economics ? r.economics.speedup_fanout : 2.3) + "×"
    };
    document.querySelectorAll("[data-bind]").forEach(function (el) {
      var key = el.getAttribute("data-bind");
      var v = aliases.hasOwnProperty(key) ? aliases[key] : get(r, key);
      if (v != null) el.textContent = v;
    });
  }

  /* ---------- fork fan-out animation ---------- */
  function setupFork(r) {
    var stage = document.getElementById("forkstage");
    var host = document.getElementById("fork-shards");
    var btn = document.getElementById("fork-run");
    if (!stage || !host) return;
    var chroms = (r && r.genome && r.genome.chroms) || CHR_ORDER;
    host.innerHTML = "";
    var shards = chroms.map(function (c) {
      var d = document.createElement("div");
      d.className = "shard";
      d.innerHTML = '<span class="box-tag">' + c + '</span><span class="box-sub">map</span>';
      host.appendChild(d);
      return d;
    });
    var timers = [];
    function clear() { timers.forEach(clearTimeout); timers = []; }
    function play() {
      clear();
      stage.setAttribute("data-state", "idle");
      shards.forEach(function (s) { s.classList.remove("lit"); });
      if (reduceMotion) { stage.setAttribute("data-state", "reduce"); shards.forEach(function (s) { s.classList.add("lit"); }); return; }
      timers.push(setTimeout(function () { stage.setAttribute("data-state", "snap"); }, 350));
      timers.push(setTimeout(function () { stage.setAttribute("data-state", "map"); }, 900));
      shards.forEach(function (s, i) {
        timers.push(setTimeout(function () { s.classList.add("lit"); }, 1150 + i * 220));
      });
      timers.push(setTimeout(function () { stage.setAttribute("data-state", "reduce"); }, 1150 + shards.length * 220 + 350));
    }
    if (btn) btn.addEventListener("click", play);
    // autoplay once when scrolled into view
    if ("IntersectionObserver" in window && !reduceMotion) {
      var once = new IntersectionObserver(function (es) {
        es.forEach(function (e) { if (e.isIntersecting) { play(); once.unobserve(e.target); } });
      }, { threshold: 0.4 });
      once.observe(stage);
    } else { play(); }
  }

  /* ---------- karyotype landscape ---------- */
  var landscape = null, receipts = null, karyMetric = "cpg_oe";
  function bucket(metric, v) {
    if (metric === "gc") {
      if (v < 38) return 0; if (v < 42) return 1; if (v < 46) return 2; if (v < 50) return 3; return 4;
    }
    // cpg obs/exp
    if (v < 0.15) return 0; if (v < 0.22) return 1; if (v < 0.30) return 2; if (v < 0.40) return 3; return 4;
  }
  function renderKary() {
    var host = document.getElementById("kary");
    if (!host || !landscape) return;
    var byChr = {};
    landscape.forEach(function (b) { (byChr[b.chrom] = byChr[b.chrom] || []).push(b); });
    var order = CHR_ORDER.filter(function (c) { return byChr[c]; });
    Object.keys(byChr).forEach(function (c) { if (order.indexOf(c) < 0) order.push(c); });
    host.innerHTML = "";
    order.forEach(function (c) {
      var bins = byChr[c];
      var row = document.createElement("div"); row.className = "kary-row";
      var name = document.createElement("span"); name.className = "kary-name"; name.textContent = c;
      var track = document.createElement("div"); track.className = "kary-track";
      track.setAttribute("role", "img");
      bins.forEach(function (b) {
        var cell = document.createElement("span"); cell.className = "kary-cell";
        if (b.n_frac > 0.5) { cell.style.background = "var(--gap)"; }
        else {
          var val = karyMetric === "gc" ? b.gc : b.cpg_oe;
          cell.style.background = "var(--seq-" + bucket(karyMetric, val) + ")";
        }
        var mb = Math.round(b.start / 1e6);
        cell.title = c + ":" + mb + "Mb · GC " + b.gc + "% · CpG o/e " + b.cpg_oe + (b.n_frac > 0.05 ? " · gaps " + Math.round(b.n_frac * 100) + "%" : "");
        track.appendChild(cell);
      });
      var isl = document.createElement("span"); isl.className = "kary-isl";
      var pc = receipts && receipts.per_chrom && receipts.per_chrom[c];
      if (pc) isl.innerHTML = "<b>" + commas(pc.cpg_islands) + "</b> islands";
      track.setAttribute("aria-label", c + ": " + bins.length + " one-megabase bins" + (pc ? ", " + commas(pc.cpg_islands) + " CpG-island candidates" : ""));
      row.appendChild(name); row.appendChild(track); row.appendChild(isl);
      host.appendChild(row);
    });
    renderLegend();
  }
  function renderLegend() {
    var el = document.getElementById("kary-legend");
    if (!el) return;
    var lab = karyMetric === "gc" ? "GC&nbsp;% · low → high" : "CpG obs/exp · low → high";
    var sw = "";
    for (var i = 0; i < 5; i++) sw += '<i style="background:var(--seq-' + i + ')"></i>';
    el.innerHTML = '<span>' + lab + '</span><span class="legend-swatches">' + sw + '</span><i style="background:var(--gap);width:1.4rem;height:.8rem;display:inline-block"></i><span>assembly gap</span>';
  }
  function setupKaryToggle() {
    var seg = document.querySelector(".kary-seg");
    if (!seg) return;
    seg.addEventListener("click", function (ev) {
      var b = ev.target.closest("button[data-metric]"); if (!b) return;
      seg.querySelectorAll("button").forEach(function (x) { x.setAttribute("aria-selected", String(x === b)); });
      karyMetric = b.getAttribute("data-metric"); renderKary();
    });
  }

  /* ---------- economics calculator ---------- */
  function setupCalc(r) {
    var sh = document.getElementById("calc-shards"), re = document.getElementById("calc-reruns");
    if (!sh || !re || !r) return;
    var warm = r.warm_shard_times || {};
    var warmVals = Object.keys(warm).map(function (k) { return warm[k]; });
    var warmPer = warmVals.length ? warmVals.reduce(function (a, b) { return a + b; }, 0) / warmVals.length : 7.6;
    var coldPer = r.cold_shard_avg_sec || 21.9;
    var warmup = r.warmup_sec || 24, snap = (r.snapshot && r.snapshot.save_sec) || 3.9;
    var refPerShard = 72 / (r.shards || 5); // MB of reference per shard (approx)

    function fmt(s) { return s >= 90 ? (s / 60).toFixed(1) + " min" : Math.round(s) + " s"; }
    function recompute() {
      var N = +sh.value, R = +re.value;
      document.getElementById("calc-shards-out").textContent = N;
      document.getElementById("calc-reruns-out").textContent = R;
      // total machine-seconds you actually pay for
      var cold = N * coldPer * R;                       // every shard re-stages, every run
      var warmC = warmup + snap + N * warmPer * R;      // stage once, fork forever
      var speed = cold / warmC;
      var max = Math.max(cold, warmC);
      document.getElementById("bar-cold").style.width = (100 * cold / max) + "%";
      document.getElementById("bar-warm").style.width = (100 * warmC / max) + "%";
      document.getElementById("val-cold").textContent = fmt(cold);
      document.getElementById("val-warm").textContent = fmt(warmC);
      document.getElementById("calc-speedup").textContent = speed.toFixed(1) + "×";
      var redundant = N * R - 1;
      var mb = Math.round(redundant * refPerShard);
      document.getElementById("calc-saved").innerHTML =
        "Eliminates <b>" + commas(redundant) + "</b> repeated warm-ups and about <b>" +
        commas(mb) + " MB</b> of redundant reference staging.";
    }
    sh.addEventListener("input", recompute); re.addEventListener("input", recompute);
    recompute();
  }

  /* ---------- process timeline (3 measured phases, true proportions) ---------- */
  function renderTimeline(r) {
    var host = document.getElementById("proc-timeline");
    if (!host || !r) return;
    var snap = (r.snapshot && r.snapshot.save_sec) || 3.9;
    var phases = [
      { lab: "warm", sec: r.warmup_sec || 24.1, cls: "tl-warm" },
      { lab: "snapshot", sec: snap, cls: "tl-snap" },
      { lab: "fork · map · reduce", sec: r.map_wallclock_sec || 14.8, cls: "tl-map" }
    ];
    var total = phases.reduce(function (a, p) { return a + p.sec; }, 0);
    host.innerHTML = "";
    phases.forEach(function (p) {
      var seg = document.createElement("div");
      seg.className = "tl-seg " + p.cls;
      seg.style.flexGrow = String(p.sec);
      seg.style.flexBasis = "0";
      seg.innerHTML = '<span class="tl-lab">' + p.lab + '</span><span class="tl-sec">' + p.sec.toFixed(1) + 's</span>';
      seg.title = p.lab + " · " + p.sec.toFixed(1) + "s";
      host.appendChild(seg);
    });
    var cap = document.createElement("div");
    cap.className = "tl-total";
    cap.textContent = "first warm run, end to end: " + total.toFixed(1) + "s · every rerun after, reusing the snapshot: " + (r.map_wallclock_sec || 14.8).toFixed(1) + "s";
    host.appendChild(cap);
  }

  /* ---------- the two-reading bar: an infra metric that is a biology fact ---------- */
  function renderTwoRead(r) {
    var host = document.getElementById("tworead");
    var dens = r && r.biology && r.biology.island_density_per_mb;
    if (!host || !dens) return;
    var rows = Object.keys(dens).map(function (c) { return { chr: c, v: dens[c] }; })
      .sort(function (a, b) { return b.v - a.v; });
    var max = rows[0].v || 1;
    host.innerHTML = "";
    rows.forEach(function (row) {
      var el = document.createElement("div");
      el.className = "tworead-row";
      var w = (100 * row.v / max).toFixed(1) + "%";
      el.innerHTML = '<span class="tworead-name">' + row.chr + '</span>' +
        '<span class="tworead-bar' + (row.chr === "chr19" ? " hot" : "") + '" style="--w:' + w + '"></span>' +
        '<span class="tworead-val">' + row.v.toFixed(1) + '</span>';
      host.appendChild(el);
    });
    var fig = host.closest(".tworead");
    var lab = document.getElementById("tworead-axis-lab");
    var cap = document.getElementById("tworead-cap");
    function reveal() {
      if (!fig || fig.classList.contains("revealed")) return;
      fig.classList.add("revealed");
      if (lab) { lab.classList.add("swap"); lab.textContent = "gene density (GRCh38, established)"; }
      if (cap) cap.textContent = "// same bars, relabeled. that ordering is the gene-density gradient.";
    }
    var aha = document.getElementById("aha");
    if (reduceMotion || !("IntersectionObserver" in window) || !aha) { reveal(); return; }
    var io2 = new IntersectionObserver(function (es) {
      es.forEach(function (e) { if (e.isIntersecting) { reveal(); io2.unobserve(e.target); } });
    }, { threshold: 0.5 });
    io2.observe(aha);
  }

  /* ---------- boot: fetch real data, degrade gracefully ---------- */
  function boot(r, land) {
    if (r) { try { bindLive(r); } catch (e) {} receipts = r; }
    if (land) landscape = land;
    setupFork(r);
    if (r) { renderTimeline(r); renderTwoRead(r); }
    setupKaryToggle();
    if (land) renderKary(); else { var k = document.getElementById("kary"); if (k) k.innerHTML = '<p class="calc-note">landscape data unavailable</p>'; }
    setupCalc(r);
  }

  var pr = fetch("./data/receipts.json").then(function (x) { return x.ok ? x.json() : null; }).catch(function () { return null; });
  var pl = fetch("./data/landscape.json").then(function (x) { return x.ok ? x.json() : null; }).catch(function () { return null; });
  Promise.all([pr, pl]).then(function (res) { boot(res[0], res[1]); }).catch(function () { boot(null, null); });
})();
