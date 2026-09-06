// Mouse and scroll parallax for the two background windows in the hero display.
// Both feed one requestAnimationFrame loop that eases toward the target, so
// pointer jitter never reaches the DOM and there is no CSS transition to fight.
(() => {
  const reduceMotion = window.matchMedia('(prefers-reduced-motion: reduce)');
  if (reduceMotion.matches) return;

  const display = document.getElementById('display');
  if (!display) return;
  const windows = Array.from(display.querySelectorAll('.bg-window')).map((el) => ({
    el,
    depth: parseFloat(el.dataset.depth || '1'),
  }));
  if (windows.length === 0) return;

  const MOUSE_RANGE = 14;   // px at full pointer travel across the display
  const SCROLL_RANGE = 60;  // px over the first SCROLL_DISTANCE px of scrolling
  const SCROLL_DISTANCE = 900;
  const EASE = 0.08;

  let targetX = 0, targetY = 0;
  let currentX = 0, currentY = 0;
  let scrollY = 0;
  let frame = 0;

  const schedule = () => { if (!frame) frame = requestAnimationFrame(tick); };

  function tick() {
    frame = 0;
    currentX += (targetX - currentX) * EASE;
    currentY += (targetY - currentY) * EASE;
    const scrollShift = Math.min(scrollY / SCROLL_DISTANCE, 1) * SCROLL_RANGE;
    for (const { el, depth } of windows) {
      const x = -currentX * MOUSE_RANGE * depth;
      const y = -currentY * MOUSE_RANGE * 0.7 * depth + scrollShift * depth;
      el.style.transform = `translate3d(${x.toFixed(2)}px, ${y.toFixed(2)}px, 0)`;
    }
    if (Math.abs(targetX - currentX) > 0.001 || Math.abs(targetY - currentY) > 0.001) schedule();
  }

  const clamp = (v) => Math.max(-0.5, Math.min(0.5, v));

  window.addEventListener('pointermove', (e) => {
    if (e.pointerType && e.pointerType !== 'mouse') return;
    const r = display.getBoundingClientRect();
    // Track the pointer over the whole viewport, relative to the display's centre,
    // so the windows drift even while the cursor is on the headline above.
    targetX = clamp((e.clientX - (r.left + r.width / 2)) / window.innerWidth);
    targetY = clamp((e.clientY - (r.top + r.height / 2)) / window.innerHeight);
    schedule();
  }, { passive: true });

  window.addEventListener('pointerleave', () => { targetX = 0; targetY = 0; schedule(); });
  document.addEventListener('mouseleave', () => { targetX = 0; targetY = 0; schedule(); });

  window.addEventListener('scroll', () => { scrollY = window.scrollY; schedule(); }, { passive: true });
  scrollY = window.scrollY;
  schedule();
})();
