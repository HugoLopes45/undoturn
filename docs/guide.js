// Marks the chapter in view in the contents rail. The page works without this script.
(() => {
  const rail = document.querySelector('.rail');
  if (!rail) return;
  const entries = [...rail.querySelectorAll('a[href^="#"]')]
    .map((link) => ({ link, heading: document.getElementById(decodeURIComponent(link.hash.slice(1))) }))
    .filter((entry) => entry.heading);
  let current = null;
  let queued = false;

  const update = () => {
    queued = false;
    const line = innerHeight * 0.3;
    let next = null;
    for (const entry of entries) {
      if (entry.heading.getBoundingClientRect().top > line) break;
      next = entry;
    }
    if (next === current) return;
    current?.link.removeAttribute('aria-current');
    current = next;
    if (!current) return;
    current.link.setAttribute('aria-current', 'location');
    const top = current.link.offsetTop;
    const bottom = top + current.link.offsetHeight;
    if (top < rail.scrollTop) rail.scrollTop = top;
    else if (bottom > rail.scrollTop + rail.clientHeight) rail.scrollTop = bottom - rail.clientHeight;
  };
  const queue = () => {
    if (queued) return;
    queued = true;
    requestAnimationFrame(update);
  };

  addEventListener('scroll', queue, { passive: true });
  addEventListener('resize', queue);
  update();
})();

// Keeps code blocks and tables in the tab order only while they scroll sideways.
// Without this script, every one of them stays focusable.
(() => {
  const main = document.querySelector('main');
  if (!main) return;
  const boxes = main.querySelectorAll('pre, .table-scroll');
  const sync = () => {
    for (const box of boxes) {
      if (box.scrollWidth > box.clientWidth) box.setAttribute('tabindex', '0');
      else box.removeAttribute('tabindex');
    }
  };
  new ResizeObserver(sync).observe(main);
})();
