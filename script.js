// Mobile menu
const menuButton = document.querySelector('.menu-toggle');
const navLinks = document.querySelector('.nav-links');
menuButton?.addEventListener('click', () => {
  const open = menuButton.getAttribute('aria-expanded') !== 'true';
  menuButton.setAttribute('aria-expanded', String(open));
  menuButton.querySelector('.sr-only').textContent = open ? 'Close menu' : 'Open menu';
  navLinks.classList.toggle('open', open);
});
navLinks?.addEventListener('click', (event) => {
  if (!event.target.closest('a')) return;
  navLinks.classList.remove('open');
  menuButton.setAttribute('aria-expanded', 'false');
  menuButton.querySelector('.sr-only').textContent = 'Open menu';
});

// ---------- App mockups ----------
const apps = {
  slack: () => `
    <div class="app slack">
      <aside><div class="ws"><span class="lights"><i></i><i></i><i></i></span></div><div class="ws">Northwind</div>
        <div class="ch"># general</div><div class="ch on"># design-review</div><div class="ch"># launch</div><div class="ch"># random</div></aside>
      <main><div class="hd"># design-review <span style="color:#999;font-weight:400;font-size:12px">12 members</span></div>
        <div class="feed" id="feed">
          <div class="msg"><div class="av" style="background:#e8912d">M</div><div><b>Maya</b><time>10:42</time><p>QA flagged two issues in the new onboarding. Still OK to ship this week?</p></div></div>
          <div class="msg"><div class="av" style="background:#2bac76">L</div><div><b>Leo</b><time>10:44</time><p>Fixes are in review. Your call 👀</p></div></div>
        </div>
        <div class="composer" id="box"><span class="ins"></span><span class="caret"></span><span class="send"></span></div></main>
    </div>`,
  notes: () => `
    <div class="app notes">
      <aside><div class="lights" style="padding:2px 4px 14px"><i></i><i></i><i></i></div>
        <div class="n on"><b>Weekend trip</b><span>Today</span></div><div class="n"><b>Book club picks</b><span>Yesterday</span></div><div class="n"><b>Gift ideas</b><span>Oct 2</span></div></aside>
      <main><div class="date">October 10, 2026 at 9:14 AM</div><h3>Weekend trip</h3><div><span class="ins"></span><span class="caret"></span></div></main>
    </div>`,
  mail: () => `
    <div class="app mail">
      <div class="bar"><span class="lights"><i></i><i></i><i></i></span>New Message<span class="sendb">↑</span></div>
      <div class="f">To: <span class="chip">Priya Raman</span></div>
      <div class="f">Subject: <b>Q4 deck</b></div>
      <div class="body"><span class="ins"></span><span class="caret"></span></div>
    </div>`,
  ide: () => `
    <div class="app ide">
      <div class="tree"><div class="lights" style="margin-bottom:10px"><i></i><i></i><i></i></div>▾ src<br>&nbsp; auth.ts<br>&nbsp; <span class="on">session.ts</span><br>&nbsp; api.ts<br>▸ tests<br>README.md</div>
      <div class="code"><span class="c">// session.ts</span>
<span class="k">export async function</span> <span class="t">refresh</span>(token) {
  <span class="k">const</span> res = <span class="k">await</span> fetch(<span class="s">'/auth/refresh'</span>, {
    method: <span class="s">'POST'</span>,
    body: JSON.stringify({ token }),
  })
  <span class="k">if</span> (!res.ok) <span class="k">throw new</span> <span class="t">AuthError</span>()
  <span class="k">return</span> res.json()
}</div>
      <div class="chat"><div class="h">Agent</div><div class="hist"><div>How can I help with session.ts?</div></div>
        <div class="in"><span class="ins"></span><span class="caret"></span></div></div>
    </div>`,
  imsg: () => `
    <div class="app imsg">
      <div class="hd"><div class="av">S</div>Sam</div>
      <div class="thread" id="feed"><div class="bub them">Table’s booked for 7 🍜</div><div class="bub them">You still coming?</div></div>
      <div class="field" id="box"><span class="ins"></span><span class="caret" style="color:#0a84ff"></span></div>
    </div>`
};

// said: [text, kind]  kind: '' spoken, f filler, x retracted, c spoken command, d dictionary term
const scenes = [
  { app: 'slack', name: 'Slack', sub: 'Self-correction', logo: 'slack.svg', tile: '#fff', send: 'slack',
    said: [['um so','f'],['i think we should ship the new onboarding on',''],['friday actually no let’s do','x'],['monday so QA has time','']],
    out: 'I think we should ship the new onboarding on Monday so QA has time.' },
  { app: 'notes', name: 'Notes', sub: 'Lists by voice', logo: 'notes.png',
    said: [['packing list',''],['bullet point','c'],['passport',''],['bullet point','c'],['phone charger',''],['bullet point','c'],['um','f'],['sunscreen',''],['bullet point','c'],['the blue jacket','']],
    out: 'Packing list:<ul><li>Passport</li><li>Phone charger</li><li>Sunscreen</li><li>The blue jacket</li></ul>' },
  { app: 'mail', name: 'Mail', sub: 'Formatting', logo: 'mail.png',
    said: [['hi priya',''],['new line','c'],['thanks for sending the deck over',''],['uh','f'],['i’ll review it by three PM tomorrow and send notes','']],
    out: 'Hi Priya,<br>Thanks for sending the deck over. I’ll review it by 3 PM tomorrow and send notes.' },
  { app: 'ide', name: 'Cursor', sub: 'Your dictionary', logo: 'cursor_dark.svg', tile: '#14120b',
    said: [['make',''],['refresh','d'],['retry once on a',''],['four oh one',''],['and log it with',''],['sentry','d'],['then add a',''],['vitest','d'],['case','']],
    out: 'Make <code>refresh</code> retry once on a 401 and log it with <mark class="dict">Sentry</mark>, then add a <mark class="dict">Vitest</mark> case.' },
  { app: 'imsg', name: 'Messages', sub: 'Fillers & numbers', logo: 'messages.png', send: 'imsg',
    said: [['yes running',''],['like','f'],['ten minutes late sorry',''],['uh','f'],['order me the spicy one','']],
    out: 'Yes! Running 10 minutes late, sorry. Order me the spicy one.' }
];

const $ = s => document.querySelector(s);
const win = $('#win'), cap = $('#caption'), hud = $('#hud'), hudst = $('#hudst'), keys = $('#keys'), tabsEl = $('#tabs'), wave = $('#wave');
const reduced = matchMedia('(prefers-reduced-motion: reduce)').matches;
for (let i = 0; i < 22; i++) wave.appendChild(document.createElement('i'));
const bars = [...wave.children];
let speaking = false;
setInterval(() => bars.forEach((b, i) => b.style.height = (speaking ? 4 + Math.abs(Math.sin(Date.now()/180 + i*0.7)) * 16 * Math.random() + 2 : 4) + 'px'), 90);

scenes.forEach((s, i) => {
  const b = document.createElement('button');
  b.className = 'tab'; b.role = 'tab';
  b.innerHTML = `<span class="ic${s.tile ? ' tile' : ''}"${s.tile ? ` style="background:${s.tile}"` : ''}><img src="assets/apps/${s.logo}" alt=""></span><span>${s.name}<small>${s.sub}</small></span><span class="bar"><i></i></span>`;
  b.onclick = () => { paused = false; $('#pause').textContent = '❚❚ Pause'; $('#pause').setAttribute('aria-pressed', 'false'); play(i); };
  tabsEl.appendChild(b);
});

const WORD = 190, sleep = ms => new Promise(r => setTimeout(r, ms));
let run = 0, cur = 0, paused = false;
const dur = s => s.said.reduce((n, [t]) => n + t.split(' ').length, 0) * WORD + 800 + 700 + 3200;

async function play(i) {
  const id = ++run; cur = i;
  const s = scenes[i], alive = () => id === run;
  [...tabsEl.children].forEach((t, j) => {
    t.classList.toggle('on', j === i);
    const bar = t.querySelector('.bar i'); bar.style.transition = 'none'; bar.style.width = '0';
  });
  const bar = tabsEl.children[i].querySelector('.bar i');
  requestAnimationFrame(() => requestAnimationFrame(() => { bar.style.transition = `width ${dur(s)}ms linear`; bar.style.width = '100%'; }));

  win.classList.add('swap'); cap.classList.remove('show', 'clean'); hud.classList.add('idle');
  await sleep(350); if (!alive()) return;
  win.innerHTML = apps[s.app](); win.classList.remove('swap');
  const ins = win.querySelector('.ins');
  cap.innerHTML = '<span class="lbl">Hearing</span>' + s.said.map(([t, k]) => t.split(' ').map(w => `<span class="w ${k}">${w}</span>`).join(' ')).join(' ');
  const words = [...cap.querySelectorAll('.w')];
  if (reduced) { ins.innerHTML = s.out; return; }
  await sleep(600); if (!alive()) return;

  // 1. hold keys, listen
  keys.classList.add('down'); hud.classList.remove('idle', 'cleaning'); hudst.textContent = 'Listening'; speaking = true; cap.classList.add('show');
  for (const w of words) { await sleep(WORD); if (!alive()) return; w.classList.add('in'); }
  // 2. release, clean
  await sleep(250); if (!alive()) return;
  keys.classList.remove('down'); speaking = false; hud.classList.add('cleaning'); hudst.textContent = 'Cleaning'; cap.classList.add('clean');
  cap.querySelector('.lbl').textContent = 'Cleaning up';
  await sleep(800); if (!alive()) return;
  // 3. paste
  hud.classList.add('idle'); cap.classList.remove('show');
  ins.innerHTML = s.out; ins.classList.add('pasted');
  if (s.send) {
    await sleep(1100); if (!alive()) return;
    win.querySelector('#box')?.classList.add('ready');
    await sleep(400); if (!alive()) return;
    const feed = win.querySelector('#feed');
    if (s.send === 'slack') feed.insertAdjacentHTML('beforeend', `<div class="msg" style="animation:pop .35s"><div class="av" style="background:#5267ff">Y</div><div><b>You</b><time>10:45</time><p>${s.out}</p></div></div>`);
    else feed.insertAdjacentHTML('beforeend', `<div class="bub me">${s.out}</div>`);
    ins.innerHTML = '';
  }
  await sleep(dur(s) - (s.send ? 1500 : 0) - s.said.reduce((n, [t]) => n + t.split(' ').length, 0) * WORD - 1650);
  if (alive() && !paused) play((i + 1) % scenes.length);
}

$('#pause').onclick = () => {
  paused = !paused;
  $('#pause').textContent = paused ? '▶ Play' : '❚❚ Pause';
  $('#pause').setAttribute('aria-pressed', String(paused));
  if (!paused) play((cur + 1) % scenes.length);
  else { const b = tabsEl.children[cur].querySelector('.bar i'); b.style.transition = 'none'; b.style.width = getComputedStyle(b).width; }
};

// Start the demo when visible
new IntersectionObserver(([e], o) => { if (e.isIntersecting) { play(0); o.disconnect(); } }, { threshold: .3 }).observe($('#stage'));

// ---------- Bento morph loops ----------
document.querySelectorAll('[data-loop]').forEach((m, i) => {
  const variants = [...m.querySelectorAll('.v')], modes = m.closest('.card').querySelectorAll('.modes span');
  let n = 0;
  const cycle = async () => {
    m.classList.remove('mark', 'done');
    if (variants.length) {
      await sleep(450);
      variants.forEach((v, j) => v.classList.toggle('on', j === n));
      modes.forEach((c, j) => c.classList.toggle('on', j === n));
      n = (n + 1) % variants.length;
    }
    await sleep(1600);
    m.classList.add('mark'); await sleep(1300);
    m.classList.add('done'); await sleep(2800);
    cycle();
  };
  if (reduced) m.classList.add('done'); else setTimeout(cycle, i * 450);
});

// ---------- Marquee ----------
const list = [['Slack', 'slack.svg'], ['Notes', 'notes.png'], ['Mail', 'mail.png'], ['Messages', 'messages.png'], ['Cursor', 'cursor_dark.svg'], ['VS Code', 'vscode.svg'], ['Xcode', 'xcode.png'], ['Notion', 'notion.svg'], ['Linear', 'linear.svg'], ['Google Docs', 'google-docs.svg'], ['ChatGPT', 'openai.svg'], ['Claude', 'claude-ai-icon.svg'], ['Obsidian', 'obsidian.svg'], ['Terminal', 'terminal.png'], ['Figma', 'figma.svg'], ['Gmail', 'gmail.svg'], ['WhatsApp', 'whatsapp.svg'], ['Discord', 'discord.svg']];
$('#apps').innerHTML = [...list, ...list].map(([a, f]) => `<span${f.endsWith('.png') ? ' class="mac"' : ''}><img src="assets/apps/${f}" alt="" loading="lazy">${a}</span>`).join('');

// ---------- Reveal + race ----------
const io = new IntersectionObserver(es => es.forEach(e => { if (e.isIntersecting) { e.target.classList.add('in'); io.unobserve(e.target); } }), { threshold: .15 });
document.querySelectorAll('.reveal').forEach(el => io.observe(el));
new IntersectionObserver(([e], o) => { if (e.isIntersecting) { $('#race').classList.add('go'); o.disconnect(); } }, { threshold: .5 }).observe($('#race'));

$('#copy').onclick = () => { navigator.clipboard?.writeText('brew install --cask rajan9519/tap/heyvedu'); $('#copy').textContent = 'Copied'; setTimeout(() => $('#copy').textContent = 'Copy', 1500); };
