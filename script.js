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
const ic = (n, c = '') => `<svg class="i ${c}" aria-hidden="true"><use href="assets/app-icons.svg#${n}"/></svg>`;
const lights = '<span class="lights"><i></i><i></i><i></i></span>';
const apps = {
  slack: () => `
    <div class="app slack">
      <div class="top">${lights}<span class="nav">${ic('arrow-left')}${ic('arrow-right')}${ic('clock')}</span>
        <div class="search">${ic('search')}Search Northwind</div><span class="nav"></span></div>
      <div class="body">
        <nav class="rail"><div class="wsi">N</div>
          <div class="ri on"><span>${ic('home')}</span>Home</div><div class="ri"><span>${ic('message-circle')}</span>DMs</div>
          <div class="ri"><span>${ic('bell')}</span>Activity</div><div class="ri"><span>${ic('dots')}</span>More</div></nav>
        <aside><div class="ws">Northwind ${ic('chevron-down')}<span class="new">${ic('edit')}</span></div>
          <div class="sec">${ic('chevron-down')}Channels</div>
          <div class="ch"><b>#</b>general</div><div class="ch on"><b>#</b>design-review</div><div class="ch"><b>#</b>launch</div><div class="ch"><b>#</b>random</div>
          <div class="sec">${ic('chevron-down')}Direct messages</div>
          <div class="ch"><i class="mini" style="background:#e8912d">M</i>Maya Chen</div><div class="ch"><i class="mini" style="background:#2bac76">L</i>Leo Park</div></aside>
        <main><div class="hd"><b># design-review ${ic('chevron-down')}</b><span class="mem"><i style="background:#e8912d"></i><i style="background:#2bac76"></i><i style="background:#5267ff"></i>12</span><span class="hud-btn">${ic('headphones')}${ic('chevron-down')}</span></div>
          <div class="tabsr"><span class="on">${ic('message-circle')}Messages</span><span>${ic('plus')}</span></div>
          <div class="feed" id="feed">
            <div class="msg"><div class="av" style="background:#e8912d">M</div><div><b>Maya Chen</b><time>10:42 AM</time><p>QA flagged two issues in the new onboarding. Still OK to ship this week?</p></div></div>
            <div class="msg"><div class="av" style="background:#2bac76">L</div><div><b>Leo Park</b><time>10:44 AM</time><p>Fixes are in review. Your call 👀</p></div></div>
          </div>
          <div class="composer" id="box">
            <div class="fmt">${ic('bold')}${ic('italic')}${ic('strikethrough')}<em></em>${ic('link')}<em></em>${ic('list-numbers')}${ic('list')}<em></em>${ic('code')}</div>
            <div class="txt"><span class="ins"></span><span class="caret"></span><span class="ph">Message #design-review</span></div>
            <div class="acts"><span class="plus">${ic('plus')}</span>${ic('typography')}${ic('mood-smile')}${ic('at')}<em></em>${ic('video')}${ic('microphone')}<em></em>${ic('slash')}
              <span class="send">${ic('send')}<em></em>${ic('chevron-down')}</span></div>
          </div></main>
      </div>
    </div>`,
  notes: () => `
    <div class="app notes">
      <aside><div class="tb">${lights}${ic('layout-sidebar')}</div>
        <div class="grp">iCloud</div>
        <div class="f">${ic('folder')}All iCloud<span>24</span></div><div class="f on">${ic('folder')}Notes<span>18</span></div><div class="f">${ic('folder')}Travel<span>6</span></div><div class="f">${ic('trash')}Recently Deleted<span>2</span></div></aside>
      <div class="list"><div class="tb">${ic('layout-list')}${ic('layout-grid')}<span class="sp"></span>${ic('trash')}</div>
        <div class="grp">Today</div>
        <div class="n on"><b>Weekend trip</b><span><time>9:14 AM</time>Packing list</span></div>
        <div class="grp">Previous 7 Days</div>
        <div class="n"><b>Book club picks</b><span><time>Tuesday</time>The Overstory, Piranesi</span></div>
        <div class="n"><b>Gift ideas</b><span><time>10/2/26</time>Dad: espresso grinder</span></div></div>
      <main><div class="tb">${ic('edit')}<span class="sp"></span>${ic('typography')}${ic('list-check')}${ic('table')}${ic('paperclip')}<span class="sp"></span>${ic('lock')}${ic('upload')}${ic('search')}</div>
        <div class="doc"><div class="date">October 10, 2026 at 9:14 AM</div><h3>Weekend trip</h3><div><span class="ins"></span><span class="caret"></span></div></div></main>
    </div>`,
  mail: () => `
    <div class="app mail">
      <div class="tb">${lights}<span class="sendb" id="box">${ic('send')}</span><span class="title">Q4 deck</span>
        <span class="tools">${ic('paperclip')}${ic('typography')}${ic('mood-smile')}${ic('photo')}</span></div>
      <div class="f"><label>To:</label><span class="chip">Priya Raman</span><span class="add">${ic('circle-plus')}</span></div>
      <div class="f"><label>Cc:</label></div>
      <div class="f"><label>Subject:</label>Q4 deck</div>
      <div class="f"><label>From:</label>Rajan Singh – rajan@northwind.co ${ic('chevron-down')}</div>
      <div class="body"><span class="ins"></span><span class="caret"></span></div>
    </div>`,
  ide: () => `
    <div class="app ide">
      <div class="tb">${lights}<span class="nav">${ic('arrow-left')}${ic('arrow-right')}</span><div class="cmd">${ic('search')}northwind</div><span class="nav">${ic('layout-sidebar')}${ic('settings')}</span></div>
      <div class="body">
        <aside><div class="acts">${ic('files', 'on')}${ic('search')}${ic('git-branch')}${ic('player-play')}${ic('layout-grid-add')}</div>
          <div class="ttl">NORTHWIND</div>
          <div class="fi">${ic('chevron-down')}src</div><div class="fi in"><b class="ts">TS</b>auth.ts</div><div class="fi in on"><b class="ts">TS</b>session.ts</div><div class="fi in"><b class="ts">TS</b>api.ts</div>
          <div class="fi">${ic('chevron-down', 'r')}tests</div><div class="fi"><b class="md">${ic('markdown')}</b>README.md</div></aside>
        <div class="ed"><div class="etabs"><span class="on"><b class="ts">TS</b>session.ts${ic('x')}</span><span><b class="ts">TS</b>api.ts</span></div>
          <div class="crumbs">src › session.ts › <span class="t">refresh</span></div>
          <div class="code"><div class="gut">1<br>2<br>3<br>4<br>5<br>6<br>7<br>8<br>9</div><div><span class="k">export async function</span> <span class="fn">refresh</span>(token) {
  <span class="k">const</span> res = <span class="k">await</span> <span class="fn">fetch</span>(<span class="s">'/auth/refresh'</span>, {
    method: <span class="s">'POST'</span>,
    body: JSON.<span class="fn">stringify</span>({ token }),
  })
  <span class="k">if</span> (!res.ok) <span class="k">throw new</span> <span class="t">AuthError</span>()
  <span class="k">return</span> res.<span class="fn">json</span>()
}
</div></div></div>
        <div class="chat"><div class="h"><span class="on">New Chat</span><span class="sp"></span>${ic('plus')}${ic('history')}${ic('dots')}</div>
          <div class="hist"></div>
          <div class="in"><div class="ctx"><span>@</span><span><b class="ts">TS</b>session.ts</span></div>
            <div class="txt"><span class="ins"></span><span class="caret"></span><span class="ph">Plan, search, build anything</span></div>
            <div class="row"><span class="pill">${ic('infinity')}Agent${ic('chevron-down')}</span><span class="model">Auto${ic('chevron-down')}</span><span class="sp"></span>${ic('photo')}<span class="go">${ic('arrow-up')}</span></div></div></div>
      </div>
      <div class="status"><span>${ic('git-branch')}main</span><span class="sp"></span><span>Ln 2, Col 18</span><span>TypeScript</span><span>Cursor Tab</span></div>
    </div>`,
  imsg: () => `
    <div class="app imsg">
      <aside><div class="tb">${lights}<span class="sp"></span>${ic('edit')}</div>
        <div class="search">${ic('search')}Search</div>
        <div class="c on"><i class="av">S</i><div><b>Sam<time>10:41 AM</time></b><span>You still coming?</span></div></div>
        <div class="c"><i class="av" style="background:linear-gradient(#f5a7c2,#e17ba1)">M</i><div><b>Mom<time>9:02 AM</time></b><span>Call me when you land 💛</span></div></div>
        <div class="c"><i class="av" style="background:linear-gradient(#9dc5f7,#6a9be0)">P</i><div><b>Priya Raman<time>Yesterday</time></b><span>Deck attached, no rush</span></div></div></aside>
      <main><div class="hd"><span class="sp"></span><div class="who"><i class="av">S</i>Sam</div><span class="sp r">${ic('video')}${ic('info-circle')}</span></div>
        <div class="thread" id="feed"><div class="stamp"><b>iMessage</b><br>Today 10:41 AM</div><div class="bub them">Table’s booked for 7 🍜</div><div class="bub them tail">You still coming?</div></div>
        <div class="bar"><span class="plus">${ic('plus')}</span><div class="field" id="box"><span class="ins"></span><span class="caret"></span><span class="ph">iMessage</span><span class="mic">${ic('microphone')}</span></div></div></main>
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
    if (s.send === 'slack') feed.insertAdjacentHTML('beforeend', `<div class="msg" style="animation:pop .35s"><div class="av" style="background:#5267ff">R</div><div><b>Rajan Singh</b><time>10:45 AM</time><p>${s.out}</p></div></div>`);
    else { feed.insertAdjacentHTML('beforeend', `<div class="bub me">${s.out}</div><div class="dlv">Delivered</div>`); }
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
