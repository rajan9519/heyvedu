const menuButton = document.querySelector('.menu-toggle');
const navLinks = document.querySelector('.nav-links');

menuButton?.addEventListener('click', () => {
  const open = menuButton.getAttribute('aria-expanded') !== 'true';
  menuButton.setAttribute('aria-expanded', String(open));
  menuButton.querySelector('.sr-only').textContent = open ? 'Close menu' : 'Open menu';
  navLinks.classList.toggle('open', open);
});

navLinks?.addEventListener('click', (event) => {
  if (event.target.closest('a')) {
    navLinks.classList.remove('open');
    menuButton.setAttribute('aria-expanded', 'false');
  }
});

const tabs = [...document.querySelectorAll('[role="tab"]')];
tabs.forEach((tab, index) => {
  tab.addEventListener('click', () => activateTab(tab));
  tab.addEventListener('keydown', (event) => {
    if (!['ArrowLeft', 'ArrowRight', 'Home', 'End'].includes(event.key)) return;
    event.preventDefault();
    let next = index;
    if (event.key === 'ArrowRight') next = (index + 1) % tabs.length;
    if (event.key === 'ArrowLeft') next = (index - 1 + tabs.length) % tabs.length;
    if (event.key === 'Home') next = 0;
    if (event.key === 'End') next = tabs.length - 1;
    activateTab(tabs[next]);
    tabs[next].focus();
  });
});

function activateTab(activeTab) {
  tabs.forEach((tab) => {
    const active = tab === activeTab;
    tab.setAttribute('aria-selected', String(active));
    tab.tabIndex = active ? 0 : -1;
    document.getElementById(tab.getAttribute('aria-controls')).hidden = !active;
  });
}

const copyButton = document.querySelector('.copy-command');
copyButton?.addEventListener('click', async () => {
  try {
    await navigator.clipboard.writeText(copyButton.dataset.copy);
    copyButton.textContent = 'Copied';
    setTimeout(() => { copyButton.textContent = 'Copy'; }, 1600);
  } catch {
    copyButton.textContent = 'Select command';
  }
});

const demo = document.querySelector('.demo-wrap');
const pauseButton = document.querySelector('.demo-pause');
const demoText = document.querySelector('.demo-text');
const hudStatus = document.querySelector('.hud-status');
const reduceMotion = window.matchMedia('(prefers-reduced-motion: reduce)').matches;
const raw = 'I want to book a meeting for two, actually no, three PM';
const result = 'I want to book a meeting for 3 PM.';
const demoTiming = {
  ready: 900,
  speaking: 2300,
  transcribing: 300,
  cleaning: 500,
  done: 2600,
};
const speakingEndsAt = demoTiming.ready + demoTiming.speaking;
const transcribingEndsAt = speakingEndsAt + demoTiming.transcribing;
const cleaningEndsAt = transcribingEndsAt + demoTiming.cleaning;
const demoDuration = cleaningEndsAt + demoTiming.done;
let timer;
let paused = false;
let elapsed = 0;

function setDemoState(time) {
  demo.classList.remove('talking', 'processing');
  if (time < demoTiming.ready) {
    hudStatus.textContent = 'Ready';
    demoText.textContent = '';
  } else if (time < speakingEndsAt) {
    demo.classList.add('talking');
    hudStatus.textContent = 'Listening';
    const progress = Math.min(1, (time - demoTiming.ready) / demoTiming.speaking);
    demoText.textContent = raw.slice(0, Math.ceil(raw.length * progress));
  } else if (time < transcribingEndsAt) {
    demo.classList.add('processing');
    hudStatus.textContent = 'Transcribing…';
    demoText.textContent = raw;
  } else if (time < cleaningEndsAt) {
    demo.classList.add('processing');
    hudStatus.textContent = 'Cleaning…';
    demoText.textContent = raw;
  } else {
    hudStatus.textContent = 'Done';
    demoText.textContent = result;
  }
}

function runDemo() {
  clearInterval(timer);
  timer = setInterval(() => {
    if (paused) return;
    elapsed = (elapsed + 80) % demoDuration;
    setDemoState(elapsed);
  }, 80);
}

if (reduceMotion) {
  elapsed = cleaningEndsAt;
  setDemoState(elapsed);
  pauseButton.hidden = true;
} else {
  runDemo();
}

pauseButton?.addEventListener('click', () => {
  paused = !paused;
  demo.classList.toggle('paused', paused);
  pauseButton.setAttribute('aria-pressed', String(paused));
  pauseButton.querySelector('[aria-hidden]').textContent = paused ? '▶' : 'Ⅱ';
  pauseButton.querySelector('.pause-label').textContent = paused ? 'Play demo' : 'Pause demo';
});
