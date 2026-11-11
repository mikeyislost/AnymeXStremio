#!/usr/bin/env node
// Runs the AnymeX+ TV app (tv/) without a TV: a small fake page, a fake
// phone and fake web answers, then walks through pairing, the locked sync,
// browsing, playing, progress and the next episode, and checks what the app
// did. Run: node scripts/tv_smoke.js
'use strict';
const fs = require('fs');
const path = require('path');
const nodeCrypto = require('crypto');

const TV = path.join(__dirname, '..', 'tv');
let failed = 0;
function check(name, ok, extra) {
  if (!ok) { failed++; console.log('FAIL  ' + name + (extra !== undefined ? '  → ' + JSON.stringify(extra) : '')); }
  else console.log('ok    ' + name);
}

// ------------------------------------------------------------- a tiny page

class El {
  constructor(tag) {
    this.tagName = tag.toUpperCase(); this.childNodes = []; this.parentNode = null; this.attrs = {};
    this.cls = []; this.style = {}; this._text = ''; this.listeners = {}; this.value = '';
    this.scrollTop = 0; this.scrollLeft = 0; this.offsetTop = 0; this.offsetLeft = 0; this.offsetHeight = 0; this.clientHeight = 0;
    const self = this;
    this.classList = {
      add(c) { if (!self.cls.includes(c)) self.cls.push(c); },
      remove(c) { self.cls = self.cls.filter(x => x !== c); },
      contains(c) { return self.cls.includes(c); },
      toggle(c) { if (self.cls.includes(c)) this.remove(c); else this.add(c); }
    };
    if (tag === 'video') {
      this.paused = true; this.ended = false; this.currentTime = 0; this.duration = NaN; this.readyState = 0;
      this.play = () => { this.paused = false; }; this.pause = () => { this.paused = true; }; this.load = () => {};
      this.canPlayType = () => '';
    }
  }
  get className() { return this.cls.join(' '); }
  set className(v) { this.cls = String(v).split(/\s+/).filter(Boolean); }
  get firstChild() { return this.childNodes[0] || null; }
  get src() { return this.attrs.src || ''; }
  set src(v) { this.attrs.src = v; }
  appendChild(c) { if (c.parentNode) c.parentNode.removeChild(c); c.parentNode = this; this.childNodes.push(c); return c; }
  removeChild(c) { this.childNodes = this.childNodes.filter(x => x !== c); c.parentNode = null; return c; }
  get textContent() { return this._text + this.childNodes.map(c => c.textContent).join(''); }
  set textContent(v) { this.childNodes.forEach(c => { c.parentNode = null; }); this.childNodes = []; this._text = String(v); }
  setAttribute(k, v) { if (k === 'class') this.className = v; else this.attrs[k] = String(v); }
  getAttribute(k) { return k === 'class' ? this.className : (k in this.attrs ? this.attrs[k] : null); }
  removeAttribute(k) { delete this.attrs[k]; }
  contains(n) { while (n) { if (n === this) return true; n = n.parentNode; } return false; }
  all(out) { for (const c of this.childNodes) { out.push(c); c.all(out); } return out; }
  querySelectorAll(sel) {
    const parts = sel.split(',').map(s => s.trim().replace(/^\./, ''));
    return this.all([]).filter(e => parts.some(p => e.cls.includes(p)));
  }
  querySelector(sel) { return this.querySelectorAll(sel)[0] || null; }
  addEventListener(t, fn) { (this.listeners[t] = this.listeners[t] || []).push(fn); }
  fire(t, ev) { (this.listeners[t] || []).forEach(fn => fn(ev || {})); }
  getBoundingClientRect() { return { left: 0, top: 0, width: 0, height: 0 }; }
  focus() { document.activeElement = this; }
  blur() { if (document.activeElement === this) document.activeElement = null; }
}

function parse(html) {
  const body = new El('body');
  let cur = body;
  const src = html.slice(html.indexOf('<body>') + 6, html.indexOf('</body>'));
  const re = /<!--[\s\S]*?-->|<\/([a-zA-Z0-9]+)>|<([a-zA-Z0-9]+)([^>]*)>|([^<]+)/g;
  let m;
  while ((m = re.exec(src))) {
    if (m[1]) { cur = cur.parentNode || body; }
    else if (m[2]) {
      const tag = m[2].toLowerCase();
      const e = new El(tag);
      const ar = /([\w-]+)(?:="([^"]*)")?/g;
      let a;
      while ((a = ar.exec(m[3]))) e.setAttribute(a[1], a[2] === undefined ? '' : a[2]);
      cur.appendChild(e);
      if (!['img', 'input', 'br', 'meta', 'link'].includes(tag)) cur = e;
    } else if (m[4] && m[4].trim()) { const t = new El('#text'); t._text = m[4]; cur.appendChild(t); }
  }
  return body;
}

const body = parse(fs.readFileSync(path.join(TV, 'index.html'), 'utf8'));
const docListeners = {};
global.document = {
  readyState: 'complete', activeElement: null, body,
  getElementById(id) { return body.all([]).find(e => e.attrs.id === id) || null; },
  createElement(tag) { return new El(tag); },
  addEventListener(t, fn) { (docListeners[t] = docListeners[t] || []).push(fn); }
};
function docFire(t, ev) { (docListeners[t] || []).forEach(fn => fn(ev)); }
function press(code) { docFire('keydown', { keyCode: code, preventDefault() {} }); }
const KEY = { left: 37, up: 38, right: 39, down: 40, ok: 13, back: 461 };

const store = new Map();
global.localStorage = {
  getItem: k => (store.has(k) ? store.get(k) : null), setItem: (k, v) => store.set(k, String(v)), removeItem: k => store.delete(k)
};
global.window = global;
Object.defineProperty(global, 'navigator', { value: { userAgent: 'Fake TV Chrome/132.0' }, configurable: true });
global.atob = s => Buffer.from(s, 'base64').toString('binary');
let exits = 0;
global.webOSSystem = { platformBack() { exits++; }, activate() {} };

// ------------------------------------------------------------ a fake phone

const sent = [];
let sock = null;
global.WebSocket = class {
  constructor(url) { this.url = url; this.readyState = 0; sock = this; }
  send(s) { sent.push(JSON.parse(s)); }
  close() { this.readyState = 3; }
};
function fromPhone(msg) { sock.onmessage({ data: JSON.stringify(msg) }); }
function last(t) { for (let i = sent.length - 1; i >= 0; i--) if (sent[i].t === t) return sent[i]; return null; }

// ------------------------------------------------------- fake web answers

const requests = [];
const routes = [];   // [test(url, body) → answer or undefined]
// A small MKV: header, segment, (optional seek head + filler), tracks, cluster.
function vsize(n) { const b = Buffer.alloc(8); b[0] = 1; b.writeUIntBE(n, 2, 6); return b; }
function ebml(idHex, ...kids) {
  const body = Buffer.concat(kids.map(k => (Buffer.isBuffer(k) ? k : Buffer.from(String(k), 'utf8'))));
  return Buffer.concat([Buffer.from(idHex, 'hex'), vsize(body.length), body]);
}
const u8 = n => Buffer.from([n]);
function track(type, lang, codec, opts) {
  opts = opts || {};
  const kids = [ebml('83', u8(type)), ebml('22b59c', lang), ebml('86', codec)];
  if (opts.name) kids.push(ebml('536e', opts.name));
  if (opts.def === false) kids.push(ebml('88', u8(0)));
  if (opts.forced) kids.push(ebml('55aa', u8(1)));
  if (opts.ch) kids.push(ebml('e1', ebml('9f', u8(opts.ch))));
  return ebml('ae', ...kids);
}
function makeMkv(far) {
  const tracks = ebml('1654ae6b',
    track(1, 'und', 'V_MPEG4/ISO/AVC'),
    track(2, 'eng', 'A_EAC3', { ch: 6, def: false }),
    track(2, 'jpn', 'A_AAC', { ch: 2 }),
    track(0x11, 'eng', 'S_TEXT/UTF8', { name: 'Full' }),
    track(0x11, 'eng', 'S_HDMV/PGS', { forced: true, def: false }));
  const cluster = ebml('1f43b675', Buffer.alloc(64));
  let kids;
  if (far) {
    const filler = ebml('ec', Buffer.alloc(1300000));      // Void
    const seekLen = ebml('114d9b74', ebml('4dbb', ebml('53ab', Buffer.from('1654ae6b', 'hex')), ebml('53ac', Buffer.alloc(8)))).length;
    const pos = Buffer.alloc(8); pos.writeUIntBE(seekLen + filler.length, 2, 6);
    const seek = ebml('114d9b74', ebml('4dbb', ebml('53ab', Buffer.from('1654ae6b', 'hex')), ebml('53ac', pos)));
    kids = [seek, filler, tracks, cluster];
  } else kids = [tracks, cluster];
  return Buffer.concat([ebml('1a45dfa3', ebml('4282', 'matroska')), ebml('18538067', ...kids)]);
}
const MKV_NEAR = makeMkv(false), MKV_FAR = makeMkv(true);
const rangeReads = [];

global.XMLHttpRequest = class {
  constructor() { this.headers = {}; }
  open(method, url) { this.method = method; this.url = url; }
  setRequestHeader(k, v) { this.headers[k] = v; }
  abort() {}
  send(bodyText) {
    const reqBody = bodyText ? JSON.parse(bodyText) : null;
    requests.push({ method: this.method, url: this.url, body: reqBody });
    if (this.responseType === 'arraybuffer') {
      const file = /cdn\.example\/.*%3A1%3A1\.mkv$/.test(this.url) ? MKV_NEAR : /\.mkv$/.test(this.url) ? MKV_FAR : null;
      const m = /bytes=(\d+)-(\d+)/.exec(this.headers.Range || '');
      rangeReads.push(this.headers.Range);
      setImmediate(() => {
        if (!file || !m) { this.status = 404; this.response = null; }
        else {
          this.status = 206;
          const part = file.subarray(Number(m[1]), Number(m[2]) + 1);
          this.response = part.buffer.slice(part.byteOffset, part.byteOffset + part.length);
        }
        if (this.onload) this.onload();
      });
      return;
    }
    setImmediate(() => {
      let answer;
      for (const r of routes) { answer = r(this.url, reqBody); if (answer !== undefined) break; }
      if (answer === undefined) { this.status = 404; this.responseText = ''; }
      else { this.status = 200; this.responseText = typeof answer === 'string' ? answer : JSON.stringify(answer); }
      if (this.onload) this.onload();
    });
  }
};
const wait = (ms) => new Promise(r => setTimeout(r, ms || 20));

const ADDON = 'https://debrid.example/abc123';
const libraryItems = [{
  _id: 'tt0000001', name: 'Old Show', type: 'series', poster: 'https://img.example/old.jpg', removed: false, temp: false,
  _mtime: '2026-11-01T00:00:00.000Z',
  state: { timeOffset: 600000, duration: 1200000, video_id: 'tt0000001:1:2', timeWatched: 0, overallTimeWatched: 0, timesWatched: 0, flaggedWatched: 0, watched: 'keep-me' }
}];
const puts = [];
const showMeta = {
  id: 'tt7654321', type: 'series', name: 'Test Show', description: 'A show.', background: 'https://img.example/bg.jpg',
  videos: [
    { id: 'tt7654321:1:2', title: 'Two', season: 1, episode: 2, released: '2020-01-08T00:00:00.000Z' },
    { id: 'tt7654321:1:1', title: 'One', season: 1, episode: 1, released: '2020-01-01T00:00:00.000Z' },
    { id: 'tt7654321:2:1', title: 'Later', season: 2, episode: 1, released: '2021-01-01T00:00:00.000Z' },
    { id: 'tt7654321:0:1', title: 'Special', season: 0, episode: 1, released: '2020-06-01T00:00:00.000Z' }
  ]
};
routes.push((url, b) => {
  if (url === 'https://api.strem.io/api/datastoreGet') {
    return { result: b.all ? libraryItems : libraryItems.filter(i => b.ids.includes(i._id)) };
  }
  if (url === 'https://api.strem.io/api/datastorePut') { puts.push(b); return { result: { success: true } }; }
  if (url.startsWith('https://v3-cinemeta.strem.io/catalog/movie/top/search=')) {
    return { metas: [{ id: 'tt0133093', type: 'movie', name: 'The Matrix', poster: 'https://img.example/m.jpg' }] };
  }
  if (url.startsWith('https://v3-cinemeta.strem.io/catalog/series/top/search=')) return { metas: [] };
  if (url.startsWith('https://v3-cinemeta.strem.io/catalog/')) {
    return { metas: [{ id: 'tt0111161', type: 'movie', name: 'Default Title', poster: 'https://img.example/d.jpg' }] };
  }
  if (url.startsWith('https://api.themoviedb.org/3/trending/tv/day?api_key=TMDBKEY')) {
    return { results: [{ id: 42, name: 'Test Show', poster_path: '/p.jpg', backdrop_path: '/b.jpg', overview: 'About.', first_air_date: '2020-01-01', vote_average: 8.26 },
      { id: 43, name: 'No Poster' }] };
  }
  if (url.startsWith('https://api.themoviedb.org/3/tv/42/external_ids')) return { imdb_id: 'tt7654321' };
  if (url === 'https://v3-cinemeta.strem.io/meta/series/tt7654321.json') return { meta: showMeta };
  if (url.startsWith(ADDON + '/stream/series/')) {
    const id = decodeURIComponent(url.split('/stream/series/')[1].replace('.json', ''));
    return { streams: [
      { name: 'Debrid\n4K', title: 'Show.' + id + '.2160p.mkv\n12 GB', infoHash: 'abcdef' },
      { name: 'Debrid\n1080p', title: 'Show.' + id + '.1080p.mkv\n2 GB', url: 'https://cdn.example/' + encodeURIComponent(id) + '.mkv',
        behaviorHints: { bingeGroup: 'debrid-1080p', filename: 'Show.1080p.mkv' },
        subtitles: [{ url: 'https://subs.example/en.srt', lang: 'eng' }] },
      { name: 'Needs phone', url: 'https://cdn.example/h.mp4', behaviorHints: { proxyHeaders: { request: { Referer: 'x' } } } }
    ] };
  }
  if (url === 'https://api.ani.zip/mappings?anilist_id=101') {
    return { mappings: { anilist_id: 101, kitsu_id: 46474, imdb_id: 'tt22248376', type: 'TV' },
      episodes: { '1': { seasonNumber: 1, episodeNumber: 1 } } };
  }
  if (url === 'https://api.ani.zip/mappings?anilist_id=202') {
    return { mappings: { anilist_id: 202, imdb_id: 'tt7654321', type: 'TV' }, episodes: { '1': { seasonNumber: 2, episodeNumber: 1 } } };
  }
  if (url === 'https://anime-kitsu.strem.fun/meta/series/kitsu%3A46474.json') {
    return { meta: { id: 'kitsu:46474', type: 'series', name: 'Sousou no Frieren (Kitsu)', description: 'Kitsu says.',
      videos: [{ id: 'kitsu:46474:1', title: 'The Journey\'s End', episode: 1, season: 1 }, { id: 'kitsu:46474:2', title: 'Two', episode: 2 }] } };
  }
  if (url === 'https://graphql.anilist.co') {
    const v = (b && b.variables) || {};
    const all = [
      { id: 101, title: { english: 'Frieren', romaji: 'Sousou no Frieren' }, coverImage: { large: 'https://img.example/f.jpg' },
        bannerImage: 'https://img.example/banner.jpg', description: 'An elf <i>mage</i>.<br>A long journey &amp; more', averageScore: 91,
        seasonYear: 2023, episodes: 28, format: 'TV', status: 'FINISHED', isAdult: false },
      { id: 202, title: { english: 'Other Anime', romaji: 'Hoka' }, coverImage: { large: 'https://img.example/o.jpg' },
        bannerImage: null, description: 'Another.', averageScore: 70, seasonYear: 2024, episodes: 12, format: 'TV_SHORT',
        status: 'RELEASING', isAdult: false },
      { id: 303, title: { english: 'Adult One' }, coverImage: {}, isAdult: true }
    ];
    if (v.ids) return { data: { Page: { media: all.filter(m => v.ids.includes(m.id)) } } };
    if (v.q) return { data: { Page: { media: all.filter(m => m.id !== 101) } } };
    return { data: { Page: { media: all.filter(m => m.id === 202) } } };
  }
  if (url === 'https://subs.example/en.srt') return '1\n00:00:01,000 --> 00:00:02,000\nHello there\n';
  return undefined;
});

function seal(keyHex, obj) {
  const iv = nodeCrypto.randomBytes(12);
  const c = nodeCrypto.createCipheriv('aes-256-gcm', Buffer.from(keyHex, 'hex'), iv);
  const data = Buffer.concat([c.update(JSON.stringify(obj), 'utf8'), c.final(), c.getAuthTag()]);
  return { iv: iv.toString('base64'), data: data.toString('base64') };
}

const $ = id => document.getElementById(id);
const screenNow = () => ['pair', 'home', 'details', 'search', 'settings', 'player'].find(s => !$(s).classList.contains('hidden'));
const focusName = () => { const f = body.all([]).find(e => e.cls.includes('focus')); return f ? (f.getAttribute('data-name') || f.textContent) : ''; };

(async function main() {
  for (const f of ['gcm.js', 'mkv.js', 'browse.js', 'app.js']) {
    // eslint-disable-next-line no-eval
    (0, eval)(fs.readFileSync(path.join(TV, f), 'utf8'));
  }
  const video = $('video');
  check('starts on the pairing screen', screenNow() === 'pair');

  // The phone opens the app through LG's link, with its address and key.
  let KEYHEX = '';
  docFire('webOSLaunch', { detail: { host: '192.168.1.23', port: 41733, token: 'tok' } });
  check('dials the phone', sock && sock.url === 'ws://192.168.1.23:41733/tv');
  sock.readyState = 1; sock.onopen();
  const hello = last('hello');
  check('saved from before: hello says it has no key', hello && hello.sync === true && hello.hasKey === false, hello);

  fromPhone({ t: 'welcome', name: 'iPhone', token: 'tok' });
  await wait();
  check('goes to Home once connected', screenNow() === 'home');
  check('Home has the built-in rows before any sync', focusName() === 'Default Title', focusName());

  // The phone reopens the app through LG's link with the key: the TV keeps
  // its connection and asks for the sync.
  KEYHEX = nodeCrypto.randomBytes(32).toString('hex');
  docFire('webOSRelaunch', { detail: { host: '192.168.1.23', port: 41733, token: 'tok', key: KEYHEX } });
  check('key from the phone → asks for the sync', sent[sent.length - 1].t === 'need' && sock.readyState === 1);
  check('the key is never sent back', JSON.stringify(sent).indexOf(KEYHEX) < 0);
  const css = fs.readFileSync(path.join(TV, 'style.css'), 'utf8');
  check('highlight style comes after the button styles', css.lastIndexOf('.btn.focus') > css.lastIndexOf('.btn {') &&
    css.lastIndexOf('.sitem.focus') > css.lastIndexOf('.sitem {'));

  // A sync locked with the wrong key is refused.
  fromPhone(Object.assign({ t: 'sync', h: 'bad' }, seal(nodeCrypto.randomBytes(32).toString('hex'), { v: 1 })));
  await wait(60);
  check('wrong key → refused', last('syncFail') && !last('syncOk'), last('syncFail'));

  const bundle = {
    v: 1, from: 'iPhone', at: Date.now(),
    stremio: { authKey: 'AUTH', email: 'me@example.com', addons: [
      { url: ADDON + '/manifest.json', manifest: { id: 'x.debrid', name: 'Debrid', types: ['movie', 'series'], idPrefixes: ['tt'],
        resources: ['stream'], catalogs: [] } },
      { url: 'https://v3-cinemeta.strem.io/manifest.json', manifest: { id: 'com.linvo.cinemeta', name: 'Cinemeta', types: ['movie', 'series'],
        idPrefixes: ['tt'], resources: ['catalog', 'meta'], catalogs: [{ type: 'movie', id: 'top', extra: [{ name: 'search' }] },
          { type: 'series', id: 'top', extra: [{ name: 'search' }] }] } }
    ] },
    tmdb: { key: 'TMDBKEY', region: 'US' },
    rows: [{ kind: 'cw', title: 'Continue Watching' },
      { kind: 'tmdb', title: 'Trending · Series', type: 'series', path: 'trending/tv/day', query: '' }],
    settings: { watchedPoint: 0.8 }
  };
  fromPhone(Object.assign({ t: 'sync', h: 'h1' }, seal(KEYHEX, bundle)));
  await wait(80);
  const okMsg = last('syncOk');
  check('right key → synced', okMsg && okMsg.h === 'h1' && okMsg.addons === 2 && okMsg.rows === 2, okMsg);
  check('the bundle is kept for next time', JSON.parse(store.get('anymexplus_tv_bundle')).stremio.authKey === 'AUTH');
  const rows = $('hrows').childNodes;
  check('Home shows the phone\'s rows', rows.length === 2 && rows[0].childNodes[0].textContent === 'Continue Watching');
  check('Continue Watching comes from the Stremio library', rows[0]._strip.childNodes.length === 1 && focusName() === 'Old Show', focusName());
  check('TMDB row skips titles without a poster', rows[1]._strip.childNodes.length === 1);

  // Down to the TMDB row, open the title.
  press(KEY.down);
  check('down moves to the next row', focusName() === 'Test Show', focusName());
  check('focused title is described', $('hititle').textContent === 'Test Show' && /8\.3/.test($('himeta').textContent), $('himeta').textContent);
  press(KEY.ok);
  await wait(60);
  check('opens details by IMDb id', screenNow() === 'details' && $('dtitle').textContent === 'Test Show');
  check('main button plays the first real episode', focusName() === 'Play S1 E1', focusName());
  check('season chips, specials last', $('dseasons').childNodes.map(c => c.textContent).join('|') === 'Season 1|Season 2|Specials');
  check('episodes of season 1 in order', $('deps').childNodes.map(c => c._video.episode).join(',') === '1,2');

  press(KEY.ok);
  await wait(60);
  const list = $('splist');
  check('streams panel lists only what the TV can play', list.childNodes.length === 1 && focusName() === 'Debrid 1080p', focusName());
  press(KEY.ok);
  await wait();
  check('plays in the TV player', screenNow() === 'player' && video.src === 'https://cdn.example/tt7654321%3A1%3A1.mkv', video.src);
  check('title and episode on screen', $('ptitle').textContent === 'Test Show' && /S1 E1/.test($('psub').textContent));

  // Audio / subtitles panel, with the tracks read from the MKV itself.
  const far = window.AXMkv.parse(new Uint8Array(MKV_FAR.subarray(0, 1048576)), 0);
  check('MKV: track list far into the file → where to read next', far && far.need > 1048576, far);
  await new Promise(r => window.AXMkv.tracks('https://cdn.example/far.mkv', t => {
    check('MKV: second read finds the far track list', t && t.audio.length === 2 && t.subs.length === 2, t);
    r();
  }));
  check('MKV: only small parts of the file are read', rangeReads.every(x => /bytes=\d+-\d+/.test(x)), rangeReads);
  await wait(30);
  video.readyState = 4; video.duration = 1000; video.currentTime = 10; video.fire('loadedmetadata');
  // Stremio-style controls: Up brings up the buttons, menus open on the right.
  const menuTexts = () => $('tlist').querySelectorAll('sitem').map(e => e.textContent);
  const menuItem = (re) => $('tlist').querySelectorAll('sitem').find(e => re.test(e.textContent));
  function toButton(name) {
    for (let i = 0; i < 8 && focusName() !== name; i++) press(KEY.right);
    return focusName() === name;
  }
  press(KEY.up);
  check('Up brings up the controls on the play button', focusName() === 'Play or pause' && !$('osd').classList.contains('away'), focusName());
  check('buttons for this video: next episode, subtitles, audio, streams, episodes',
    ['bnext', 'bsubs', 'baudio', 'bsrc', 'beps'].every(id => !$(id).classList.contains('hidden')) && $('bsrcl').textContent === 'Streams');
  press(KEY.ok);
  check('OK on the play button pauses', video.paused === true);
  press(KEY.ok);
  check('… and plays again', video.paused === false);
  press(KEY.up);
  check('Up again reaches the seek bar', focusName() === 'Seek bar', focusName());
  press(KEY.right); press(KEY.right); press(KEY.right);
  check('Right on the seek bar moves a target, not the video yet', video.currentTime === 10 && /^0:40/.test($('pseekto').textContent), $('pseekto').textContent);
  await wait(900);
  check('… then jumps there', video.currentTime === 40, video.currentTime);
  press(KEY.down);
  check('Down goes back to the buttons', focusName() === 'Play or pause', focusName());

  // Audio menu.
  check('Audio button reachable', toButton('Audio'), focusName());
  press(KEY.ok);
  check('Audio opens a menu', !$('tpanel').classList.contains('hidden') && $('tptitle').textContent === 'Audio');
  const labels = menuTexts();
  check('audio tracks listed by name', labels.includes('English  ·  E-AC3 5.1') && labels.includes('Japanese  ·  AAC stereo'), labels);
  const jp = menuItem(/^Japanese  ·  AAC stereo$/);
  check('the default audio track is marked and highlighted', jp && jp.classList.contains('on') && focusName() === 'Japanese  ·  AAC stereo', focusName());
  check('no "next track" buttons when the list is known', !labels.some(l => /next/i.test(l)), labels);
  press(KEY.up); press(KEY.ok);   // English E-AC3
  await wait(350);
  const en = menuItem(/^English  ·  E-AC3 5\.1$/);
  check('choosing an audio track marks it', en && en.classList.contains('on'));
  check('the language is remembered for next time', JSON.parse(store.get('anymexplus_tv_trackpref')).audio === 'English');
  press(KEY.back);
  check('Back closes the menu, the highlight goes back to its button', $('tpanel').classList.contains('hidden') && focusName() === 'Audio', focusName());

  // Subtitles menu: languages | choices | settings.
  press(KEY.left);
  check('Subtitles button', focusName() === 'Subtitles', focusName());
  press(KEY.ok);
  check('Subtitles opens with three columns', $('tptitle').textContent === 'Subtitles' && $('tlist').childNodes.length === 3);
  const langs = $('tlist').childNodes[0].querySelectorAll('sitem').map(e => e.textContent);
  check('languages: off, inside the video, then each language', langs[0] === 'Off' && /^In the video/.test(langs[1]) && langs.some(l => /^English/.test(l)), langs);
  check('starts on Off (nothing on yet)', focusName() === 'Off', focusName());
  press(KEY.down);
  check('highlighting a language shows its choices', $('tlist').childNodes[1].querySelectorAll('sitem').map(e => e.textContent).includes('English  ·  Full  ·  SRT'),
    $('tlist').childNodes[1].textContent);
  press(KEY.down);
  check('English subtitle files listed', /English 1/.test($('tlist').childNodes[1].textContent), $('tlist').childNodes[1].textContent);
  press(KEY.ok);
  await wait();
  check('OK on a language turns on its first choice', menuItem(/^English 1/).classList.contains('on') && /^English 1/.test(focusName()), focusName());
  video.currentTime = 1.5;
  await wait(200);
  check('subtitle file is fetched and drawn', $('subs').textContent === 'Hello there', $('subs').textContent);
  press(KEY.right);
  check('Right reaches the settings column', focusName() === 'Delay +0.25 s', focusName());
  press(KEY.ok); press(KEY.ok);
  check('delay shows and moves the subtitles later', /Delay: \+0\.50 s/.test($('tlist').childNodes[2].textContent) && window.AXBrowse && true);
  video.currentTime = 1.3;
  await wait(200);
  check('… so a line starts half a second later', $('subs').textContent === '', $('subs').textContent);
  press(KEY.down); press(KEY.down); press(KEY.ok);
  check('subtitle size', $('subs').style.fontSize === '59px' && store.get('anymexplus_tv_subsize') === '110', $('subs').style.fontSize);
  press(KEY.down); press(KEY.down); press(KEY.ok);
  check('reset', $('subs').style.fontSize === '54px', $('subs').style.fontSize);
  check('subtitle language remembered', JSON.parse(store.get('anymexplus_tv_trackpref')).sub === 'English');
  press(KEY.back);
  check('Back closes the panel, not the video', $('tpanel').classList.contains('hidden') && screenNow() === 'player');

  // Streams menu: switch stream at the same spot.
  check('Streams button', toButton('Streams'), focusName());
  press(KEY.ok);
  await wait(60);
  check('Streams lists this episode\'s streams, the playing one marked', $('tptitle').textContent.indexOf('Streams  ·  S1 E1') === 0 &&
    focusName() === 'Debrid 1080p' && menuItem(/Debrid 1080p/).classList.contains('on'), [$('tptitle').textContent, focusName()]);
  press(KEY.ok);
  check('picking the one already playing just closes', $('tpanel').classList.contains('hidden') && video.src === 'https://cdn.example/tt7654321%3A1%3A1.mkv');

  // Episodes menu.
  check('Episodes button', toButton('Episodes'), focusName());
  press(KEY.ok);
  check('Episodes: seasons | episodes, on this one', $('tptitle').textContent === 'Episodes' && $('tlist').childNodes.length === 2 &&
    /^E1/.test(focusName()), focusName());
  press(KEY.down); press(KEY.ok);
  await wait(60);
  check('picking an episode lists its streams', /S1 E2/.test($('tptitle').textContent) && focusName() === 'Debrid 1080p', [$('tptitle').textContent, focusName()]);
  press(KEY.back);
  press(KEY.left); press(KEY.left); press(KEY.left); press(KEY.left);
  check('Back to the play button', focusName() === 'Play or pause', focusName());

  // The episode ends: progress is saved, the phone is told, the next one plays.
  video.currentTime = 999; video.ended = true;
  video.fire('ended');
  await wait(120);
  const put = puts[puts.length - 1];
  const item = put && put.changes[0];
  check('progress written to the Stremio library', put && put.authKey === 'AUTH' && item._id === 'tt7654321', put);
  check('finished episode → library points at the next one', item && item.state.video_id === 'tt7654321:1:2' && item.state.timeOffset === 1, item && item.state);
  check('new library item is a Continue Watching one', item && item.removed === true && item.temp === true && item.name === 'Test Show');
  const w = last('watched');
  check('the phone is told it was watched', w && w.id === 'tt7654321' && w.videoId === 'tt7654321:1:1' && w.type === 'series', w);
  fromPhone({ t: 'watchedOk', q: w.q });
  check('watched mark leaves the queue when the phone confirms', store.get('anymexplus_tv_wq') === '[]', store.get('anymexplus_tv_wq'));
  check('next episode starts by itself (same kind of stream)', screenNow() === 'player' && video.src === 'https://cdn.example/tt7654321%3A1%3A2.mkv', video.src);

  await wait(80);
  press(KEY.up);
  toButton('Subtitles'); press(KEY.ok);
  const embRow = $('tlist').childNodes[0].querySelectorAll('sitem')[1];
  check('next episode: subtitles in your last language turn on by themselves (inside the video first)',
    embRow && /^In the video/.test(embRow.textContent) && embRow.classList.contains('on'), embRow && embRow.textContent);
  press(KEY.back);

  // Back out of the player half way: resume point, details again.
  video.ended = false; video.currentTime = 300;
  press(KEY.up);
  press(KEY.back);
  check('Back with the buttons up hides them, the video keeps going', screenNow() === 'player' &&
    $('osd').classList.contains('away') && focusName() === '', focusName());
  press(KEY.back);
  await wait(80);
  check('Back returns to details on that episode', screenNow() === 'details' && /^S1 E2/.test(focusName()), focusName());
  const item2 = puts[puts.length - 1].changes[0];
  check('resume point saved', item2.state.video_id === 'tt7654321:1:2' && item2.state.timeOffset === 300000 && item2.state.duration === 1000000, item2.state);
  check('main button offers to resume', $('dbtns').childNodes[0].textContent === 'Resume S1 E2 from 5:00', $('dbtns').childNodes[0].textContent);

  // An item the phone changed meanwhile keeps its other fields.
  press(KEY.back);
  check('Back from details → Home', screenNow() === 'home');

  // Typing a search on the phone.
  fromPhone({ t: 'search', q: 'matrix' });
  await wait(60);
  check('search from the phone shows results', screenNow() === 'search' && $('srows').childNodes[0]._strip.childNodes[0]._card.name === 'The Matrix');
  press(KEY.down);
  check('results can be reached with the remote', focusName() === 'The Matrix', focusName());
  // Into the search box, keyboard closed without Enter, arrows still move.
  press(KEY.up); press(KEY.ok);
  check('OK on the box starts typing', document.activeElement === $('sq'));
  press(KEY.down);
  check('an arrow leaves the box after the keyboard closed', document.activeElement !== $('sq') && focusName() === 'The Matrix', focusName());
  press(KEY.back);
  check('Back from search → Home', screenNow() === 'home');
  press(KEY.back);
  check('Back on Home leaves the app', exits === 1);

  // The phone goes away: the TV carries on.
  sock.onclose();
  check('phone gone → still on Home', screenNow() === 'home' && /Phone not connected/.test($('hstatus').textContent));

  // Settings.
  press(KEY.up); press(KEY.up); press(KEY.right); press(KEY.right); press(KEY.ok);
  check('Settings opens and shows the sync', screenNow() === 'settings' && /me@example.com/.test($('setinfo').textContent));

  // Phone-driven playback (stage 1) still works and returns to Home.
  sock.readyState = 1; fromPhone({ t: 'welcome', name: 'iPhone', token: 'tok' });
  fromPhone({ t: 'play', url: 'https://x.example/a.mp4', title: 'From phone', id: 7, start: 0, kind: 'mp4' });
  check('Play on TV from the phone', screenNow() === 'player' && video.src === 'https://x.example/a.mp4');
  const before = puts.length;
  fromPhone({ t: 'stop' });
  await wait(40);
  check('phone stop → Home, nothing written by the TV', screenNow() === 'home' && puts.length === before);

  // ---- anime (stage 3): rows from the phone, episodes and links through it.
  let port = 41733;
  function reconnect() {
    // Another port each time, so the app dials again whatever it thinks of the old link.
    docFire('webOSLaunch', { detail: { host: '192.168.1.23', port: ++port, token: 'tok', key: KEYHEX } });
    sock.readyState = 1; sock.onopen();
    fromPhone({ t: 'welcome', name: 'iPhone', token: 'tok' });
  }
  reconnect();
  check('hello says the TV does anime', last('hello').anime === true);
  const now = Date.now();
  const bundle2 = Object.assign({}, JSON.parse(JSON.stringify(bundle)), {
    v: 2, anime: true,
    rows: [
      { kind: 'cw', title: 'Continue Watching', anime: [
        { a: '101', name: 'Frieren', romaji: 'Sousou no Frieren', poster: 'https://img.example/f.jpg', sub: '3 | 28', at: now },
        { a: '404', name: 'Old Show', sub: '1 | ??', at: 5 }] },
      { kind: 'anime', title: 'Trending Anime', cards: [{ a: '202', name: 'Other Anime', rating: '7.0' }] },
      { kind: 'alq', title: 'Romance', vars: { type: 'ANIME', sort: ['POPULARITY_DESC'], genres: ['Romance'] } },
      { kind: 'tmdb', title: 'Trending · Series', type: 'series', path: 'trending/tv/day', query: '' }]
  });
  bundle2.stremio.addons[0].manifest.idPrefixes = ['tt', 'kitsu'];
  fromPhone(Object.assign({ t: 'sync', h: 'h2' }, seal(KEYHEX, bundle2)));
  await wait(120);
  const rows2 = $('hrows').childNodes;
  check('anime rows are on Home with the Movies & TV rows', rows2.length === 4 &&
    rows2.map(r => r.childNodes[0].textContent).join('|') === 'Continue Watching|Trending Anime|Romance|Trending · Series');
  check('Continue Watching mixes anime in, newest first, no doubles',
    rows2[0]._strip.childNodes.map(c => c._card.name).join('|') === 'Frieren|Old Show', rows2[0]._strip.childNodes.map(c => c._card.name));
  check('the anime "Old Show" card wins over the Stremio one', rows2[0]._strip.childNodes[1]._card.a === '404');
  check('a filtered row is read from AniList by the TV', rows2[2]._strip.childNodes.length === 1 &&
    rows2[2]._strip.childNodes[0]._card.name === 'Other Anime');
  check('focus stays on the first card', focusName() === 'Frieren', focusName());
  await wait(600);
  check('AniList fills in what the title is about', $('hidesc').textContent === 'An elf mage. A long journey & more' &&
    /2023/.test($('himeta').textContent) && /9\.1/.test($('himeta').textContent) && /3 of 28 watched/.test($('himeta').textContent),
    [$('hidesc').textContent, $('himeta').textContent]);
  check('details are kept for next time', JSON.parse(store.get('anymexplus_tv_alinfo'))['101'].eps === 28);

  // Open an anime: matched to its Kitsu id, episodes and streams from addons.
  press(KEY.ok);
  await wait(80);
  check('an anime opens through its Kitsu id', screenNow() === 'details' && $('dtitle').textContent === 'Sousou no Frieren (Kitsu)' &&
    requests.some(r => r.url === 'https://api.ani.zip/mappings?anilist_id=101') &&
    requests.some(r => r.url === 'https://anime-kitsu.strem.fun/meta/series/kitsu%3A46474.json'), $('dtitle').textContent);
  check('nothing is asked of the phone', !sent.some(m => m.t === 'anime'));
  check('main button starts after your AniList progress', focusName() === 'Play S1 E4', focusName());
  check('every episode AniList counts is listed', $('deps').childNodes.length === 28 &&
    $('deps').childNodes[27]._video.id === 'kitsu:46474:28' && $('deps').childNodes[0]._video.title === 'The Journey\'s End');
  check('the match is kept for next time', JSON.parse(store.get('anymexplus_tv_animap'))['101'].k === '46474');
  press(KEY.ok);
  await wait(60);
  check('streams come from the addon, by Kitsu id', $('splist').childNodes.length === 1 && focusName() === 'Debrid 1080p' &&
    requests.some(r => r.url === ADDON + '/stream/series/kitsu%3A46474%3A4.json'), focusName());
  press(KEY.ok);
  await wait();
  check('the TV plays it by itself', screenNow() === 'player' && video.src === 'https://cdn.example/kitsu%3A46474%3A4.mkv', video.src);
  video.readyState = 4; video.duration = 1000; video.currentTime = 900; video.ended = false;
  sock.onclose();
  check('phone gone while playing → no message on screen', $('pnote').classList.contains('hidden') && screenNow() === 'player');
  reconnect();
  press(KEY.back); press(KEY.back);   // buttons first (they show at the start), then the video
  await wait(80);
  const aput = puts[puts.length - 1].changes[0];
  check('progress goes to the Stremio library under the Kitsu id', aput._id === 'kitsu:46474' && aput.state.video_id === 'kitsu:46474:4' &&
    aput.state.timeOffset === 900000, aput.state);
  const aw = last('watched');
  check('the phone is told, so AniList follows', aw && aw.id === 'kitsu:46474' && aw.videoId === 'kitsu:46474:4', aw);
  check('back on the episodes', screenNow() === 'details' && /^S1 E4/.test(focusName()), focusName());
  press(KEY.back);

  // A long show: 50 episodes at a time. And one only known by its IMDb id.
  const BT = window.AXBrowse._test;
  const many = [];
  for (let i = 1; i <= 120; i++) many.push({ id: 'k:' + i, season: 1, episode: i });
  const ps = BT.parts(many.concat([{ id: 's', season: 0, episode: 1 }]));
  check('long seasons are split in groups of 50', ps.map(x => x.label).join('|') ===
    'Season 1  ·  1 – 50|Season 1  ·  51 – 100|Season 1  ·  101 – 120|Specials', ps.map(x => x.label));
  check('one season: just the ranges', BT.parts(many).map(x => x.label).join('|') === '1 – 50|51 – 100|101 – 120');
  const mp = BT.mappingFromAniZip({ mappings: { imdb_id: 'tt9999999', kitsu_id: null, type: 'TV' },
    episodes: { '1': { seasonNumber: 2, episodeNumber: 1 }, '2': { seasonNumber: 2, episodeNumber: 2 }, 'S1': { seasonNumber: 0, episodeNumber: 1 } } });
  check('ani.zip: IMDb season and episode of each anime episode', mp && mp.i === 'tt9999999' && mp.k === '' &&
    JSON.stringify(mp.e) === '{"1":[2,1],"2":[2,2]}', mp);
  check('episodes ani.zip does not list yet carry on from the last', BT.imdbEpisode(mp, 5).join(':') === '2:5' && BT.imdbEpisode({ e: null }, 3).join(':') === '1:3');
  const shown = BT.shownRows([{ kind: 'cw' }, { kind: 'cat', type: 'other', title: 'RealDebrid · Other' }, { kind: 'cat', type: 'movie' }]);
  check('Home leaves out "other" catalogs (debrid Downloads)', shown.length === 2 && shown.every(r => r.type !== 'other'));
  check('no ids at all → no match', BT.mappingFromAniZip({ mappings: {} }) === null);

  press(KEY.down); press(KEY.ok);
  await wait(80);
  check('an anime without a Kitsu id opens by IMDb id, on its season', screenNow() === 'details' && $('dtitle').textContent === 'Test Show' &&
    focusName() === 'Play S2 E1', [$('dtitle').textContent, focusName()]);
  press(KEY.back);

  // Anime in search.
  fromPhone({ t: 'search', q: 'other' });
  await wait(80);
  fromPhone({ t: 'play', url: 'http://192.168.1.23:9000/proxy.m3u8', title: 'From phone', id: 21, start: 0, kind: 'hls' });
  fromPhone({ t: 'servers', id: 21, on: 0, list: ['HD-1 Sub', 'HD-2 Sub', 'HD-1 Dub'] });
  press(KEY.up);
  check('Play on TV from the phone: only play and Source', $('bsrcl').textContent === 'Source' && ['bnext', 'bsubs', 'baudio', 'beps'].every(id => $(id).classList.contains('hidden')));
  for (let i = 0; i < 6 && focusName() !== 'Streams'; i++) press(KEY.right);
  press(KEY.ok);
  check('Source lists the phone\'s servers', $('tptitle').textContent === 'Source' && $('tlist').querySelectorAll('fo').length === 3);
  press(KEY.down); press(KEY.ok);
  check('picking a server tells the phone', last('anime').cmd === 'server' && last('anime').i === 1);
  fromPhone({ t: 'stop' });
  fromPhone({ t: 'search', q: 'other' });
  await wait(80);
  check('search has an Anime row first', $('srows').childNodes[0].childNodes[0].textContent === 'Anime' &&
    $('srows').childNodes[0]._strip.childNodes.map(c => c._card.name).join('|') === 'Other Anime');
  check('adult titles are left out', !$('srows').childNodes[0]._strip.childNodes.some(c => c._card.name === 'Adult One'));

  console.log(failed ? '\n' + failed + ' check(s) failed' : '\nAll TV checks passed');
  process.exit(failed ? 1 : 0);
})().catch(e => { console.error(e); process.exit(1); });
