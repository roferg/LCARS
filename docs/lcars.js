/* ═══════════════════════════════════════════════════════════════
   LCARS — JavaScript: Mermaid config + interactive features
   Include after mermaid CDN script:
     <script src="https://cdn.jsdelivr.net/npm/mermaid@10/dist/mermaid.min.js"></script>
     <script src="lcars.js"></script>
   ═══════════════════════════════════════════════════════════════ */

// ── Mermaid — LCARS dark theme ────────────────────────────────

mermaid.initialize({
  startOnLoad: true,
  theme: 'dark',
  themeVariables: {
    primaryColor:          '#0e1830',
    primaryTextColor:      '#ffaa00',
    primaryBorderColor:    '#ffaa00',
    lineColor:             '#ffaa00',
    secondaryColor:        '#0b1224',
    tertiaryColor:         '#070d1c',
    background:            '#030608',
    mainBkg:               '#0e1830',
    nodeBorder:            '#ffaa00',
    clusterBkg:            '#070d1c',
    clusterBorder:         'rgba(255,170,0,0.28)',
    titleColor:            '#ffaa00',
    edgeLabelBackground:   '#030608',
    fontFamily:            '-apple-system, "Segoe UI", system-ui, sans-serif',
    fontSize:              '13px',
    // Sequence diagrams
    actorBkg:              '#0e1830',
    actorBorder:           '#ffaa00',
    actorTextColor:        '#ffaa00',
    actorLineColor:        '#50688a',
    signalColor:           '#c4d4ee',
    signalTextColor:       '#c4d4ee',
    labelBoxBkgColor:      '#070d1c',
    labelBoxBorderColor:   'rgba(255,170,0,0.28)',
    labelTextColor:        '#c4d4ee',
    loopTextColor:         '#c4d4ee',
    noteBorderColor:       'rgba(68,153,255,0.4)',
    noteBkgColor:          'rgba(68,153,255,0.08)',
    noteTextColor:         '#c4d4ee',
    activationBorderColor: '#ffaa00',
    activationBkgColor:    '#0e1830',
    sequenceNumberColor:   '#030608',
    // State diagrams
    stateBkg:              '#0e1830',
    stateBorder:           '#ffaa00',
    labelColor:            '#c4d4ee',
    altBackground:         '#070d1c',
    transitionColor:       '#ffaa00',
    transitionLabelColor:  '#c4d4ee',
    specialStateColor:     '#ffaa00',
    // Misc
    errorBkgColor:         'rgba(255,51,68,0.1)',
    errorTextColor:        '#ff3344',
    fillType0: '#0e1830',
    fillType1: '#0b1224',
    fillType2: '#070d1c',
    fillType3: '#0b1630',
    fillType4: '#0e1428',
  }
});


// ── Stardate ──────────────────────────────────────────────────
// Formula: TNG-era stardate (approx.)
// 1000 units per year, starting ~2364 = stardate 41000

function computeStardate() {
  const tngEpochYear = 2323.5; // approx start of TNG stardate 0
  const now = new Date();
  const yearFraction = now.getFullYear() + (now.getMonth() / 12) + (now.getDate() / 365);
  const stardate = ((yearFraction - tngEpochYear) * 1000).toFixed(1);
  return stardate;
}

function renderStardate() {
  const el = document.getElementById('stardate-value');
  if (el) el.textContent = computeStardate();
}


// ── Active nav highlighting via IntersectionObserver ──────────

function initActiveNav() {
  const sections = document.querySelectorAll('section[id]');
  const navLinks  = document.querySelectorAll('nav a[href^="#"]');

  if (!sections.length || !navLinks.length) return;

  const observer = new IntersectionObserver(
    entries => {
      entries.forEach(entry => {
        if (entry.isIntersecting) {
          navLinks.forEach(link => link.classList.remove('active'));
          const active = document.querySelector(`nav a[href="#${entry.target.id}"]`);
          if (active) active.classList.add('active');
        }
      });
    },
    {
      rootMargin: '-20% 0px -70% 0px',
      threshold: 0,
    }
  );

  sections.forEach(s => observer.observe(s));
}


// ── Boot ──────────────────────────────────────────────────────

document.addEventListener('DOMContentLoaded', () => {
  renderStardate();
  initActiveNav();
});
