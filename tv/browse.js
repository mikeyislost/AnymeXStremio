/* AnymeX+ TV: browsing on the TV itself (Movies & TV).
 *
 * The phone sends over what it knows (Stremio login, addons, the rows of
 * its Movies & TV page, the TMDB key). With that the TV can show rows,
 * details, episodes and streams by itself, and play them with the LG
 * remote, also when the phone is not around. Progress goes to your Stremio
 * library; "watched" marks go to the phone, which updates AniList / Simkl.
 *
 * Old-style JavaScript on purpose, like app.js.
 */
window.AXBrowse = function (A) {
  'use strict';

  var $ = A.$, text = A.text;
  var API = 'https://api.strem.io/api/';
  var CINEMETA = 'https://v3-cinemeta.strem.io';
  var TMDB = 'https://api.themoviedb.org/3/';
  var IMG = 'https://image.tmdb.org/t/p/';
  var K_BUNDLE = 'anymexplus_tv_bundle', K_HASH = 'anymexplus_tv_bundle_h';
  var K_RESUME = 'anymexplus_tv_resume', K_WQ = 'anymexplus_tv_wq';
  var SCREENS = ['home', 'details', 'search', 'settings'];

  // ------------------------------------------------------------------ storage

  function load(key, fallback) {
    try {
      var v = JSON.parse(localStorage.getItem(key) || 'null');
      return v == null ? fallback : v;
    } catch (e) { return fallback; }
  }
  function save(key, v) {
    try { localStorage.setItem(key, JSON.stringify(v)); } catch (e) { /* full: ignore */ }
  }

  var bundle = load(K_BUNDLE, null);
  var bundleHash = load(K_HASH, '');
  var resume = load(K_RESUME, {});   // "<id>|<videoId>" → {pos, dur, at}
  var wq = load(K_WQ, []);           // watched marks waiting for the phone
  var library = {};                  // Stremio library items by id
  var libraryLoaded = false;

  function has() { return !!bundle; }
  function authKey() { return (bundle && bundle.stremio && bundle.stremio.authKey) || ''; }
  function addons() { return (bundle && bundle.stremio && bundle.stremio.addons) || []; }
  function tmdbKey() { return (bundle && bundle.tmdb && bundle.tmdb.key) || ''; }
  function watchedPoint() {
    var p = bundle && bundle.settings && Number(bundle.settings.watchedPoint);
    return p >= 0.5 && p <= 0.99 ? p : 0.9;
  }

  // ---------------------------------------------------------------------- web

  function request(method, url, body, done, timeout) {
    var x, fin = false;
    function end(v) { if (!fin) { fin = true; done(v); } }
    try {
      x = new XMLHttpRequest();
      x.open(method, url, true);
      x.timeout = timeout || 15000;
      if (body != null) x.setRequestHeader('Content-Type', 'application/json');
      x.onload = function () {
        var v = null;
        if (x.status >= 200 && x.status < 300) { try { v = JSON.parse(x.responseText); } catch (e) { v = null; } }
        end(v);
      };
      x.onerror = function () { end(null); };
      x.ontimeout = function () { end(null); };
      x.send(body == null ? null : JSON.stringify(body));
    } catch (e) { end(null); }
  }
  function getJson(url, done, timeout) { request('GET', url, null, done, timeout); }
  function postJson(url, body, done) { request('POST', url, body, done, 20000); }

  // ------------------------------------------------------------------- addons

  function baseOf(addon) {
    var u = String(addon.url || '');
    var q = u.indexOf('?');
    if (q >= 0) u = u.slice(0, q);
    u = u.replace(/\/manifest\.json$/, '').replace(/\/+$/, '');
    return u;
  }

  function strList(v) {
    var out = [];
    if (v && v.length && typeof v !== 'string') for (var i = 0; i < v.length; i++) out.push(String(v[i]));
    return out;
  }

  // Can this addon give [resource] (meta, stream, subtitles) for this id?
  function supports(addon, resource, type, id) {
    var m = addon.manifest || {};
    var res = m.resources;
    if (!res || !res.length) return false;
    for (var i = 0; i < res.length; i++) {
      var r = res[i], types, prefixes;
      if (typeof r === 'string') {
        if (r !== resource) continue;
        types = strList(m.types);
        prefixes = m.idPrefixes ? strList(m.idPrefixes) : null;
      } else if (r && r.name === resource) {
        types = r.types ? strList(r.types) : strList(m.types);
        prefixes = r.idPrefixes ? strList(r.idPrefixes) : (m.idPrefixes ? strList(m.idPrefixes) : null);
      } else continue;
      if (types.length && types.indexOf(type) < 0) continue;
      if (prefixes && prefixes.length) {
        var ok = false;
        for (var j = 0; j < prefixes.length; j++) if (id.indexOf(prefixes[j]) === 0) { ok = true; break; }
        if (!ok) continue;
      }
      return true;
    }
    return false;
  }

  function resourceUrl(base, resource, type, id, extra) {
    return base + '/' + resource + '/' + encodeURIComponent(type) + '/' + encodeURIComponent(id) +
      (extra ? '/' + extra : '') + '.json';
  }

  // ---------------------------------------------------------------- the page

  function el(tag, cls, s) {
    var d = document.createElement(tag);
    if (cls) d.className = cls;
    if (s != null) text(d, s);
    return d;
  }
  function clear(node) { while (node.firstChild) node.removeChild(node.firstChild); }
  function hide(node, yes) { if (yes) node.classList.add('hidden'); else node.classList.remove('hidden'); }

  function fmt(s) {
    if (!isFinite(s) || s < 0) s = 0;
    s = Math.floor(s);
    var h = Math.floor(s / 3600), m = Math.floor((s % 3600) / 60), x = s % 60;
    return (h ? h + ':' + (m < 10 ? '0' : '') : '') + m + ':' + (x < 10 ? '0' : '') + x;
  }

  // ------------------------------------------------------------ moving around
  //
  // A screen is made of groups (.grp) stacked top to bottom; each holds
  // items (.fo) side by side, or one under the other (data-dir="v").

  var stack = [];          // screens to go back to
  var lastFocus = {};      // what was highlighted on each screen
  var panelOpen = false;   // the streams panel on the details screen
  var tracksOpen = false;  // the audio / subtitles panel in the player
  var homeTouched = false;

  function root() {
    if (A.screen() === 'player') return $('tpanel');
    if (panelOpen) return $('spanel');
    return $(A.screen());
  }

  function shown(node, top) {
    while (node && node !== top) {
      if (node.classList && node.classList.contains('hidden')) return false;
      node = node.parentNode;
    }
    return true;
  }

  function items(g) {
    var list = g.querySelectorAll('.fo'), out = [];
    for (var i = 0; i < list.length; i++) if (shown(list[i], g)) out.push(list[i]);
    return out;
  }

  function groups() {
    var top = root();
    var list = top.querySelectorAll('.grp'), out = [];
    for (var i = 0; i < list.length; i++) {
      if (shown(list[i], top) && items(list[i]).length) out.push(list[i]);
    }
    return out;
  }

  function groupOf(node) {
    while (node && !(node.classList && node.classList.contains('grp'))) node = node.parentNode;
    return node;
  }

  function scrollerOf(name) {
    return name === 'home' ? $('hrows') : name === 'search' ? $('srows') : null;
  }

  function reveal(node) {
    var g = groupOf(node);
    if (!g) return;
    if (g.getAttribute('data-dir') === 'v') {
      g.scrollTop = Math.max(0, node.offsetTop - (g.clientHeight - node.offsetHeight) / 2);
    } else if (g.classList.contains('strip')) {
      g.scrollLeft = Math.max(0, node.offsetLeft - 96);
    }
    if (panelOpen || tracksOpen) return;
    var name = A.screen(), sc = scrollerOf(name);
    if (!sc) return;
    var row = g;
    while (row && row.parentNode !== sc) row = row.parentNode;
    if (!row) { sc.scrollTop = 0; return; }
    sc.scrollTop = Math.max(0, row.offsetTop);
  }

  function focusOn(node) {
    if (!node) return;
    var g = groupOf(node);
    if (g) g._last = items(g).indexOf(node);
    A.setFocus(node);
    reveal(node);
    if (!panelOpen && !tracksOpen) lastFocus[A.screen()] = node;
    if (A.screen() === 'home' && node._card) showHomeInfo(node._card);
  }

  function focusFirst() {
    var gs = groups();
    if (gs.length) focusOn(items(gs[0])[0]); else A.setFocus(null);
  }

  function move(dx, dy) {
    var gs = groups();
    if (!gs.length) return;
    var f = A.focused(), g = f && groupOf(f);
    if (!f || gs.indexOf(g) < 0) { focusFirst(); return; }
    var its = items(g), i = its.indexOf(f);
    var vert = g.getAttribute('data-dir') === 'v';
    var along = vert ? dy : dx, across = vert ? dx : dy;
    var d = 0;
    if (along) {
      if (its[i + along]) { focusOn(its[i + along]); return; }
      if (!vert) return;
      d = along;
    } else if (across && !vert) d = across;
    if (!d) return;
    var ng = gs[gs.indexOf(g) + d];
    if (!ng) return;
    var nits = items(ng);
    var at = ng.getAttribute('data-dir') === 'v' ? (d > 0 ? 0 : nits.length - 1)
      : Math.min(ng._last > 0 ? ng._last : 0, nits.length - 1);
    focusOn(nits[at]);
  }

  // Called by app.js whenever a screen is shown.
  function enter(name) {
    if (SCREENS.indexOf(name) < 0) return;
    var keep = lastFocus[name];
    if (keep && $(name).contains(keep) && shown(keep, $(name)) && !panelOpen) focusOn(keep);
    else focusFirst();
    if (name === 'settings') showSettings();
    updateStatus();
  }

  function go(name) {
    stack.push(A.screen());
    A.show(name);
  }

  function back() {
    if (tracksOpen) { closeTracks(); return; }
    if (panelOpen) { closePanel(); return; }
    var input = $('sq');
    if (document.activeElement === input) { input.blur(); return; }
    if (stack.length) { A.show(stack.pop()); return; }
    if (A.screen() !== 'home') { A.show('home'); return; }
    A.exit();
  }

  function key(k) {
    homeTouched = true;
    if (k === 'up') move(0, -1);
    else if (k === 'down') move(0, 1);
    else if (k === 'left') move(-1, 0);
    else if (k === 'right') move(1, 0);
    else if (k === 'ok') press();
    else if (k === 'back') back();
  }

  function press() {
    var f = A.focused();
    if (!f) return;
    var act = f.getAttribute('data-act');
    if (act === 'card') openCard(f._card);
    else if (act === 'search') { go('search'); }
    else if (act === 'refresh') { loadHome(); }
    else if (act === 'settings') { go('settings'); }
    else if (act === 'input') {
      var input = $('sq');
      if (document.activeElement === input) { input.blur(); runSearch(input.value); }
      else { try { input.focus(); } catch (e) { /* ignore */ } }
    }
    else if (act === 'play') playMain(false);
    else if (act === 'restart') playMain(true);
    else if (act === 'season') { showSeason(f._season, null); }
    else if (act === 'ep') openStreams(f._video, -1);
    else if (act === 'stream') playStream(f._stream);
    else if (act === 'sub') pickSub(f._sub);
    else if (act === 'audio') pickAudio(f._audio);
    else if (act === 'resync') { A.send({ t: 'need' }); setSettingsNote(A.connected() ? 'Asked the phone…' : 'The phone is not connected. Open AnymeX+ on it.'); }
    else if (act === 'pairscreen') { stack = []; A.show('pair'); }
    else if (act === 'clear') clearBundle();
    else if (act === 'forget') { stack = []; A.forget(); }
  }

  // --------------------------------------------------------------------- home

  var homeToken = 0;
  var bgTimer = null;

  function defaultRows() {
    return [
      { kind: 'cw', title: 'Continue Watching' },
      { kind: 'cat', title: 'Popular · Movies', base: CINEMETA, type: 'movie', id: 'top' },
      { kind: 'cat', title: 'Popular · Series', base: CINEMETA, type: 'series', id: 'top' }
    ];
  }

  function updateStatus() {
    var parts = [];
    parts.push(A.connected() ? 'Phone connected' : 'Phone not connected');
    if (bundle) {
      parts.push((bundle.stremio && bundle.stremio.email) || 'No Stremio account');
      parts.push(addons().length + ' addons');
    } else {
      parts.push('Nothing synced yet');
    }
    text($('hstatus'), parts.join('  ·  '));
  }

  function setBackdrop(img, url) {
    if (!url) { img.classList.add('off'); return; }
    if (img.getAttribute('src') === url) { img.classList.remove('off'); return; }
    img.classList.add('off');
    img.onload = function () { img.classList.remove('off'); };
    img.onerror = function () { img.classList.add('off'); };
    img.setAttribute('src', url);
  }

  function showHomeInfo(c) {
    text($('hititle'), c.name || '');
    var meta = [];
    if (c.year) meta.push(c.year);
    if (c.rating) meta.push('★ ' + c.rating);
    if (c.type) meta.push(c.type === 'series' ? 'Series' : (c.type === 'movie' ? 'Movie' : c.type));
    if (c.sub) meta.push(c.sub);
    text($('himeta'), meta.join('  ·  '));
    text($('hidesc'), c.desc || '');
    clearTimeout(bgTimer);
    bgTimer = setTimeout(function () { setBackdrop($('hbg'), c.bg || ''); }, 350);
  }

  function cardEl(c) {
    var d = el('div', 'fo card');
    d.setAttribute('data-act', 'card');
    d.setAttribute('data-name', c.name || '');
    d._card = c;
    var name = el('div', 'cname', c.name || '');
    d.appendChild(name);
    if (c.poster) {
      var img = el('img', 'cimg');
      img.setAttribute('loading', 'lazy');
      img.onerror = function () { img.classList.add('hidden'); };
      img.setAttribute('src', c.poster);
      d.appendChild(img);
    }
    if (c.progress > 0) {
      var bar = el('div', 'cprog'), fill = el('i');
      fill.style.width = Math.min(100, Math.round(c.progress * 100)) + '%';
      bar.appendChild(fill);
      d.appendChild(bar);
    }
    return d;
  }

  function rowEl(title) {
    var row = el('div', 'row hidden');
    row.appendChild(el('div', 'rtitle', title));
    var strip = el('div', 'strip grp');
    row.appendChild(strip);
    row._strip = strip;
    return row;
  }

  function fillRow(row, cards) {
    clear(row._strip);
    for (var i = 0; i < cards.length && i < 30; i++) row._strip.appendChild(cardEl(cards[i]));
    hide(row, !cards.length);
  }

  function yearOf(s) { var m = /(\d{4})/.exec(String(s || '')); return m ? m[1] : ''; }

  function cardFromMeta(m) {
    if (!m || !m.id) return null;
    return {
      id: String(m.id), type: String(m.type || ''), name: String(m.name || ''), poster: m.poster || '',
      bg: m.background || '', desc: m.description || '', year: yearOf(m.releaseInfo || m.year || m.released),
      rating: m.imdbRating ? String(m.imdbRating) : ''
    };
  }

  function cardFromTmdb(r, type) {
    if (!r || r.adult || !r.poster_path) return null;
    var name = String(r.title || r.name || '');
    if (!name) return null;
    return {
      tmdb: r.id, type: type, name: name, poster: IMG + 'w342' + r.poster_path,
      bg: r.backdrop_path ? IMG + 'w1280' + r.backdrop_path : '', desc: r.overview || '',
      year: yearOf(r.release_date || r.first_air_date),
      rating: r.vote_average ? (Math.round(r.vote_average * 10) / 10).toFixed(1) : ''
    };
  }

  function continueCards() {
    var list = [];
    for (var id in library) {
      if (!library.hasOwnProperty(id)) continue;
      var it = library[id], st = it.state || {};
      if (it.type === 'other' || !(st.timeOffset > 0)) continue;
      if (it.removed && !it.temp) continue;
      list.push(it);
    }
    list.sort(function (a, b) { return String(b._mtime || '').localeCompare(String(a._mtime || '')); });
    var out = [];
    for (var i = 0; i < list.length && i < 30; i++) {
      var x = list[i], s = x.state || {}, sub = '';
      var m = /:(\d+):(\d+)$/.exec(String(s.video_id || ''));
      if (m) sub = 'S' + m[1] + ' E' + m[2];
      out.push({
        id: String(x._id), type: String(x.type || ''), name: String(x.name || ''), poster: x.poster || '',
        bg: '', desc: '', year: '', rating: '', sub: sub,
        progress: s.duration > 0 ? Math.max(0.03, s.timeOffset / s.duration) : 0.03
      });
    }
    return out;
  }

  function loadLibrary(done) {
    var key = authKey();
    if (!key) { library = {}; libraryLoaded = true; done(); return; }
    postJson(API + 'datastoreGet', { authKey: key, collection: 'libraryItem', ids: [], all: true }, function (r) {
      if (r && r.result && r.result.length != null) {
        library = {};
        for (var i = 0; i < r.result.length; i++) {
          var it = r.result[i];
          if (it && it._id) library[String(it._id)] = it;
        }
        libraryLoaded = true;
      }
      done();
    });
  }

  function loadRow(spec, row, token) {
    function fill(cards) {
      if (token !== homeToken) return;
      fillRow(row, cards);
      // Start on the first title instead of the buttons, unless you've moved.
      if (cards.length && !homeTouched && A.screen() === 'home') {
        var rows = $('hrows').childNodes, first = null;
        for (var r = 0; r < rows.length && !first; r++) {
          if (!rows[r].classList.contains('hidden')) first = items(rows[r]._strip)[0];
        }
        if (first) focusOn(first);
      }
    }
    if (spec.kind === 'cw') {
      loadLibrary(function () { fill(continueCards()); });
    } else if (spec.kind === 'tmdb') {
      if (!tmdbKey()) { fill([]); return; }
      getJson(TMDB + spec.path + '?api_key=' + encodeURIComponent(tmdbKey()) + (spec.query || ''), function (r) {
        var cards = [], list = (r && r.results) || [];
        for (var i = 0; i < list.length; i++) {
          var c = cardFromTmdb(list[i], spec.type);
          if (c) cards.push(c);
        }
        fill(cards);
      });
    } else if (spec.kind === 'cat') {
      getJson(resourceUrl(spec.base, 'catalog', spec.type, spec.id, spec.extra || ''), function (r) {
        var cards = [], list = (r && r.metas) || [];
        for (var i = 0; i < list.length; i++) {
          var c = cardFromMeta(list[i]);
          if (c) cards.push(c);
        }
        fill(cards);
      });
    } else fill([]);
  }

  function loadHome() {
    var token = ++homeToken;
    var specs = (bundle && bundle.rows && bundle.rows.length) ? bundle.rows : defaultRows();
    var box = $('hrows');
    clear(box);
    box.scrollTop = 0;
    lastFocus.home = null;
    homeTouched = false;
    hide($('hnote'), has());
    updateStatus();
    for (var i = 0; i < specs.length && i < 40; i++) {
      var row = rowEl(specs[i].title || '');
      box.appendChild(row);
      loadRow(specs[i], row, token);
    }
    if (A.screen() === 'home') focusFirst();
  }

  var homeBuilt = false;
  function home() {
    stack = [];
    panelOpen = false;
    hide($('spanel'), true);
    if (!homeBuilt) { homeBuilt = true; A.show('home'); loadHome(); }
    else A.show('home');
  }

  function openCard(c) {
    if (!c) return;
    if (c.id) { openDetails(c.type, c.id, c); return; }
    if (!c.tmdb) return;
    text($('hstatus'), 'Opening ' + c.name + '…');
    var kind = c.type === 'series' ? 'tv' : 'movie';
    getJson(TMDB + kind + '/' + c.tmdb + '/external_ids?api_key=' + encodeURIComponent(tmdbKey()), function (r) {
      updateStatus();
      var imdb = r && r.imdb_id;
      if (imdb && String(imdb).indexOf('tt') === 0) { c.id = String(imdb); openDetails(c.type, c.id, c); }
      else text($('hstatus'), "Couldn't open " + c.name + '.');
    });
  }

  // ------------------------------------------------------------------ details

  var det = null;       // {type, id, meta, videos, season}
  var detToken = 0;

  function metaSources(type, id) {
    var out = [], list = addons(), seen = {};
    for (var i = 0; i < list.length; i++) {
      if (supports(list[i], 'meta', type, id)) {
        var b = baseOf(list[i]);
        if (!seen[b]) { seen[b] = 1; out.push(b); }
      }
    }
    if (id.indexOf('tt') === 0 && !seen[CINEMETA]) out.push(CINEMETA);
    return out;
  }

  function sortVideos(videos) {
    var out = [];
    for (var i = 0; i < videos.length; i++) {
      var v = videos[i];
      if (!v || !v.id) continue;
      out.push({
        id: String(v.id), title: String(v.title || v.name || ''),
        season: v.season == null ? 1 : Number(v.season), episode: Number(v.episode != null ? v.episode : (v.number || 0)),
        released: v.released ? Date.parse(v.released) : NaN, thumb: v.thumbnail || '', overview: v.overview || v.description || ''
      });
    }
    out.sort(function (a, b) { return a.season - b.season || a.episode - b.episode; });
    return out;
  }

  function openDetails(type, id, hint) {
    var token = ++detToken;
    det = null;
    closePanel(true);
    if (A.screen() !== 'details') go('details');
    text($('dtitle'), (hint && hint.name) || '');
    text($('dmeta'), '');
    text($('ddesc'), (hint && hint.desc) || '');
    setBackdrop($('dbg'), (hint && hint.bg) || '');
    clear($('dbtns')); clear($('dseasons')); clear($('deps'));
    text($('dmsg'), 'Loading…');
    A.setFocus(null);
    lastFocus.details = null;
    var sources = metaSources(type, id), at = 0;
    function next() {
      if (token !== detToken) return;
      if (at >= sources.length) { text($('dmsg'), "Couldn't load this title. Check the TV's internet and try again."); return; }
      getJson(resourceUrl(sources[at++], 'meta', type, id), function (r) {
        if (token !== detToken) return;
        if (r && r.meta && r.meta.id) {
          det = { type: type, id: id, meta: r.meta, videos: sortVideos(r.meta.videos || []), season: null };
          if (!libraryLoaded && authKey()) loadLibrary(function () { if (token === detToken) renderDetails(null); });
          else renderDetails(null);
        } else next();
      });
    }
    next();
  }

  function isSeries() { return det && det.type !== 'movie' && det.videos.length > 0; }

  function movieVideoId() {
    var h = det.meta.behaviorHints || {};
    return String(h.defaultVideoId || det.id);
  }

  function findVideo(videoId) {
    for (var i = 0; i < det.videos.length; i++) if (det.videos[i].id === videoId) return det.videos[i];
    return null;
  }

  // Where to start [videoId], in seconds: your Stremio library first, then
  // what this TV remembers.
  function startFor(videoId) {
    var it = library[det.id], st = it && it.state;
    if (st && String(st.video_id || '') === videoId && st.timeOffset > 1000 &&
        !(st.duration > 0 && st.timeOffset > st.duration * watchedPoint())) {
      return st.timeOffset / 1000;
    }
    var r = resume[det.id + '|' + videoId];
    if (r && r.pos > 5 && !(r.dur > 0 && r.pos > r.dur * watchedPoint())) return r.pos;
    return 0;
  }

  // The episode (or movie) the big button plays.
  function mainTarget() {
    if (!isSeries()) return { id: movieVideoId(), title: '', season: null, episode: null };
    var it = library[det.id], st = it && it.state;
    var v = st && st.video_id ? findVideo(String(st.video_id)) : null;
    if (!v) {
      var newest = null, at = 0;
      for (var i = 0; i < det.videos.length; i++) {
        var r = resume[det.id + '|' + det.videos[i].id];
        if (r && r.at > at) { at = r.at; newest = det.videos[i]; }
      }
      v = newest;
    }
    if (!v) {
      for (var j = 0; j < det.videos.length; j++) if (det.videos[j].season > 0) { v = det.videos[j]; break; }
    }
    return v || det.videos[0];
  }

  function epLabel(v) {
    if (v.season == null) return '';
    return 'S' + v.season + ' E' + v.episode;
  }

  function button(label, act) {
    var b = el('div', 'fo btn', label);
    b.setAttribute('data-act', act);
    return b;
  }

  function renderDetails(focusVideoId) {
    var m = det.meta;
    text($('dtitle'), m.name || '');
    var bits = [];
    var year = m.releaseInfo || m.year || '';
    if (year) bits.push(String(year));
    if (m.runtime) bits.push(String(m.runtime));
    if (m.imdbRating) bits.push('★ ' + m.imdbRating);
    var genres = strList(m.genres || m.genre).slice(0, 3);
    if (genres.length) bits.push(genres.join(', '));
    text($('dmeta'), bits.join('  ·  '));
    text($('ddesc'), m.description || '');
    setBackdrop($('dbg'), m.background || '');
    text($('dmsg'), '');

    var target = mainTarget(), start = startFor(target.id);
    var btns = $('dbtns');
    clear(btns);
    var label = (start > 5 ? 'Resume' : 'Play') + (isSeries() ? ' ' + epLabel(target) : '') +
      (start > 5 ? ' from ' + fmt(start) : '');
    btns.appendChild(button(label, 'play'));
    if (start > 5) btns.appendChild(button('Start from the beginning', 'restart'));

    var seasonsBox = $('dseasons');
    clear(seasonsBox);
    clear($('deps'));
    if (isSeries()) {
      var seasons = [], i;
      for (i = 0; i < det.videos.length; i++) if (seasons.indexOf(det.videos[i].season) < 0) seasons.push(det.videos[i].season);
      seasons.sort(function (a, b) { return (a === 0 ? 1e9 : a) - (b === 0 ? 1e9 : b); });
      if (seasons.length > 1) {
        for (i = 0; i < seasons.length; i++) {
          var chip = button(seasons[i] === 0 ? 'Specials' : 'Season ' + seasons[i], 'season');
          chip.classList.add('chip');
          chip._season = seasons[i];
          seasonsBox.appendChild(chip);
        }
      }
      var focusVideo = focusVideoId ? findVideo(focusVideoId) : null;
      showSeason(focusVideo ? focusVideo.season : target.season, focusVideo || target);
      if (focusVideo) {
        var eps = $('deps').querySelectorAll('.fo');
        for (i = 0; i < eps.length; i++) if (eps[i]._video === focusVideo) { focusOn(eps[i]); return; }
      }
    }
    if (A.screen() === 'details') focusOn(btns.firstChild);
  }

  function showSeason(season, mark) {
    if (!det) return;
    det.season = season;
    var chips = $('dseasons').querySelectorAll('.fo'), i;
    for (i = 0; i < chips.length; i++) {
      if (chips[i]._season === season) chips[i].classList.add('on'); else chips[i].classList.remove('on');
    }
    var box = $('deps');
    clear(box);
    box.scrollLeft = 0;
    box._last = 0;
    var now = Date.now();
    for (i = 0; i < det.videos.length; i++) {
      var v = det.videos[i];
      if (v.season !== season) continue;
      var c = el('div', 'fo epc');
      c.setAttribute('data-act', 'ep');
      c.setAttribute('data-name', epLabel(v) + ' ' + v.title);
      c._video = v;
      if (v.thumb) {
        var img = el('img', 'eimg');
        img.setAttribute('loading', 'lazy');
        img.onerror = (function (im) { return function () { im.classList.add('hidden'); }; })(img);
        img.setAttribute('src', v.thumb);
        c.appendChild(img);
      }
      c.appendChild(el('div', 'enum', 'E' + v.episode + (v.released > now ? '  ·  not out yet' : '')));
      c.appendChild(el('div', 'etitle', v.title || 'Episode ' + v.episode));
      if (mark && mark.id === v.id) { c.classList.add('cur'); box._last = box.childNodes.length; }
      box.appendChild(c);
    }
    if (box._last > 0 && box.childNodes[box._last]) box.scrollLeft = Math.max(0, box.childNodes[box._last].offsetLeft - 96);
  }

  function playMain(fromStart) {
    if (!det) return;
    var t = mainTarget();
    openStreams(t, fromStart ? 0 : -1);
  }

  // ------------------------------------------------------------------ streams

  var streamToken = 0;
  var panelBack = null;

  function closePanel(quiet) {
    streamToken++;
    panelOpen = false;
    hide($('spanel'), true);
    if (!quiet && panelBack && $('details').contains(panelBack)) focusOn(panelBack);
    panelBack = null;
  }

  function playable(s) {
    if (!s || !s.url || !/^https?:\/\//i.test(String(s.url))) return false;
    var h = s.behaviorHints && s.behaviorHints.proxyHeaders && s.behaviorHints.proxyHeaders.request;
    if (h) { for (var k in h) if (h.hasOwnProperty(k)) return false; }   // needs the phone in between
    return true;
  }

  // Asks every stream addon; each(list, addonName) per answer, done() at the end.
  function collectStreams(type, videoId, each, done) {
    var list = addons(), todo = [];
    for (var i = 0; i < list.length; i++) if (supports(list[i], 'stream', type, videoId)) todo.push(list[i]);
    var left = todo.length;
    if (!left) { done(0); return; }
    for (var j = 0; j < todo.length; j++) {
      (function (addon) {
        getJson(resourceUrl(baseOf(addon), 'stream', type, videoId), function (r) {
          each((r && r.streams) || [], String((addon.manifest && addon.manifest.name) || 'Addon'));
          if (--left === 0) done(todo.length);
        }, 25000);
      })(todo[j]);
    }
  }

  function streamInfo(s, addonName) {
    var hints = s.behaviorHints || {};
    return {
      url: String(s.url), addon: addonName,
      name: String(s.name || addonName).replace(/\s*\n\s*/g, ' '),
      desc: String(s.title || s.description || '').split('\n').slice(0, 3).join('\n'),
      binge: hints.bingeGroup ? String(hints.bingeGroup) : '',
      file: String(hints.filename || ''),
      subs: s.subtitles && s.subtitles.length ? s.subtitles : []
    };
  }

  // start: seconds, or -1 for "where you left off".
  function openStreams(video, start) {
    if (!det || !video) return;
    var token = ++streamToken;
    panelBack = A.focused();
    panelOpen = true;
    var list = $('splist');
    clear(list);
    list.scrollTop = 0;
    hide($('spanel'), false);
    A.setFocus(null);
    text($('sptitle'), isSeries() ? epLabel(video) + (video.title ? '  ·  ' + video.title : '') : (det.meta.name || ''));
    text($('spmsg'), 'Finding streams…');
    var hidden = 0, count = 0;
    var from = start < 0 ? startFor(video.id) : start;
    collectStreams(det.type, video.id, function (streams, addonName) {
      if (token !== streamToken) return;
      for (var i = 0; i < streams.length; i++) {
        if (!playable(streams[i])) { hidden++; continue; }
        var s = streamInfo(streams[i], addonName);
        s.video = video;
        s.start = from;
        var d = el('div', 'fo sitem');
        d.setAttribute('data-act', 'stream');
        d.setAttribute('data-name', s.name);
        d._stream = s;
        d.appendChild(el('div', 'sname', s.name));
        if (s.desc) d.appendChild(el('div', 'sdesc', s.desc));
        list.appendChild(d);
        count++;
      }
      if (count && !A.focused()) focusOn(list.firstChild);
      if (count) text($('spmsg'), from > 5 ? 'Starts at ' + fmt(from) : '');
    }, function (asked) {
      if (token !== streamToken) return;
      if (count) return;
      if (!asked) text($('spmsg'), 'No stream addons for this yet. Add them in AnymeX+ on your phone; they sync to the TV by themselves.');
      else if (hidden) text($('spmsg'), 'Nothing the TV can play by itself (' + hidden + ' torrent-only streams). Debrid and direct links work here.');
      else text($('spmsg'), 'No streams found.');
    });
  }

  function kindOf(s) {
    var f = (s.file || s.url.split('?')[0]).toLowerCase();
    if (/\.mkv$/.test(f)) return 'mkv';
    if (/\.mp4$|\.m4v$/.test(f)) return 'mp4';
    if (/\.m3u8$/.test(f)) return 'hls';
    if (/\.webm$/.test(f)) return 'webm';
    return '';
  }

  // ----------------------------------------------------------- playing here

  var cur = null;       // what this TV started by itself
  var localId = 0;

  function playStream(s) {
    if (!s || !det) return;
    var video = s.video;
    closePanel(true);
    cur = {
      type: det.type, id: det.id, videoId: video.id, video: video, meta: det.meta, videos: det.videos,
      binge: s.binge, addon: s.addon, name: s.name, lastPos: Math.round((s.start || 0) * 1000), lastAt: Date.now(),
      lastSave: Date.now(), sentWatched: false, subs: [], emb: -1, aud: 0
    };
    var i;
    for (i = 0; i < s.subs.length; i++) {
      if (s.subs[i] && s.subs[i].url) cur.subs.push({ url: String(s.subs[i].url), lang: String(s.subs[i].lang || '?'), from: s.addon });
    }
    loadSubtitleList(cur);
    A.play({
      url: s.url, title: det.meta.name || '', sub: isSeries() ? epLabel(video) + (video.title ? '  ·  ' + video.title : '') : '',
      start: s.start || 0, kind: kindOf(s), id: -(++localId)
    });
    A.playing().local = true;
  }

  function loadSubtitleList(c) {
    var list = addons();
    for (var i = 0; i < list.length; i++) {
      if (!supports(list[i], 'subtitles', c.type, c.videoId)) continue;
      (function (addon) {
        getJson(resourceUrl(baseOf(addon), 'subtitles', c.type, c.videoId), function (r) {
          var subs = (r && r.subtitles) || [];
          for (var j = 0; j < subs.length && c.subs.length < 200; j++) {
            if (subs[j] && subs[j].url) {
              c.subs.push({ url: String(subs[j].url), lang: String(subs[j].lang || '?'),
                from: String((addon.manifest && addon.manifest.name) || '') });
            }
          }
          if (tracksOpen && cur === c) buildTracks();
        });
      })(list[i]);
    }
  }

  function nextVideo(c) {
    var idx = -1, i;
    for (i = 0; i < c.videos.length; i++) if (c.videos[i].id === c.videoId) { idx = i; break; }
    if (idx < 0) return null;
    for (i = idx + 1; i < c.videos.length; i++) {
      var v = c.videos[i];
      if (v.season === 0) continue;
      if (v.released > Date.now()) return null;
      return v;
    }
    return null;
  }

  function isoNow() { return new Date().toISOString(); }

  function newItem(c) {
    var now = isoNow();
    return {
      _id: c.id, name: c.meta.name || '', type: c.type, poster: c.meta.poster || null, posterShape: 'poster',
      removed: true, temp: true, _ctime: now, _mtime: now,
      state: { lastWatched: now, timeWatched: 0, timeOffset: 0, overallTimeWatched: 0, timesWatched: 0, flaggedWatched: 0,
        duration: 0, video_id: null, watched: null, noNotif: false },
      behaviorHints: { defaultVideoId: null, featuredVideoId: null, hasScheduledVideos: false }
    };
  }

  function num(v) { v = Number(v); return isFinite(v) ? v : 0; }

  // The same bookkeeping the phone does. Returns true when this report is
  // the one that makes the video count as watched.
  function applyProgress(item, c, posMs, durMs, delta, isFinal) {
    var st = item.state || (item.state = {});
    var point = watchedPoint(), justWatched = false;
    st.lastWatched = isoNow();
    if (String(st.video_id || '') !== c.videoId) {
      st.video_id = c.videoId;
      st.overallTimeWatched = num(st.overallTimeWatched) + num(st.timeWatched);
      st.timeWatched = 0;
      st.flaggedWatched = 0;
    } else {
      st.timeWatched = num(st.timeWatched) + delta;
      st.overallTimeWatched = num(st.overallTimeWatched) + delta;
    }
    st.timeOffset = posMs < 1 ? 1 : posMs;
    st.duration = durMs;
    if (!num(st.flaggedWatched) && durMs > 0 && (num(st.timeWatched) > durMs * point || posMs > durMs * point)) {
      st.flaggedWatched = 1;
      st.timesWatched = num(st.timesWatched) + 1;
      justWatched = true;
    }
    if (isFinal && posMs > durMs * point) {
      st.timeOffset = 0;
      var next = nextVideo(c);
      if (next) {
        st.video_id = next.id;
        st.overallTimeWatched = num(st.overallTimeWatched) + num(st.timeWatched);
        st.timeWatched = 0;
        st.flaggedWatched = 0;
        st.timeOffset = 1;
      }
    }
    item._mtime = isoNow();
    return justWatched;
  }

  function queueWatched(c) {
    if (c.sentWatched) return;
    c.sentWatched = true;
    wq.push({ q: Date.now() + '-' + Math.floor(Math.random() * 1e6), type: c.type, id: c.id, videoId: c.videoId });
    if (wq.length > 200) wq = wq.slice(-200);
    save(K_WQ, wq);
    flushWatched();
  }

  function flushWatched() {
    if (!A.connected()) return;
    for (var i = 0; i < wq.length; i++) {
      A.send({ t: 'watched', q: wq[i].q, type: wq[i].type, id: wq[i].id, videoId: wq[i].videoId });
    }
  }

  function saveProgress(isFinal) {
    var c = cur, v = A.video();
    if (!c || !v) return;
    var pos = v.currentTime || 0, dur = isFinite(v.duration) ? v.duration : 0;
    if (!(dur > 0)) return;
    var posMs = Math.round(pos * 1000), durMs = Math.round(dur * 1000);
    var now = Date.now();
    // Real watch time since the last report; jumps don't count.
    var delta = posMs - c.lastPos;
    if (delta < 0 || delta > (now - c.lastAt) * 4) delta = 0;
    c.lastPos = posMs; c.lastAt = now; c.lastSave = now;

    resume[c.id + '|' + c.videoId] = { pos: pos, dur: dur, at: now };
    var keys = [];
    for (var k in resume) if (resume.hasOwnProperty(k)) keys.push(k);
    if (keys.length > 300) {
      keys.sort(function (a, b) { return resume[a].at - resume[b].at; });
      for (var i = 0; i < keys.length - 300; i++) delete resume[keys[i]];
    }
    save(K_RESUME, resume);

    var key = authKey();
    if (!key) {
      if (pos > dur * watchedPoint()) queueWatched(c);
      return;
    }
    // Read the library item fresh, change only the progress, write it back:
    // the phone may have changed other parts of it meanwhile.
    postJson(API + 'datastoreGet', { authKey: key, collection: 'libraryItem', ids: [c.id], all: false }, function (r) {
      if (!r || !r.result) return;   // Stremio not reachable: try again at the next report
      var item = r.result[0] || library[c.id] || newItem(c);
      if (!item.name) item.name = c.meta.name || '';
      if (!item.poster && c.meta.poster) item.poster = c.meta.poster;
      var justWatched = applyProgress(item, c, posMs, durMs, delta, isFinal);
      library[c.id] = item;
      postJson(API + 'datastorePut', { authKey: key, collection: 'libraryItem', changes: [item] }, function () {
        if (justWatched || (pos > dur * watchedPoint() && !c.sentWatched)) queueWatched(c);
      });
    });
  }

  // Once a second while the player is up.
  function tick() {
    if (!cur) return;
    if (!A.playing().local) { cur = null; closeTracks(); return; }
    if (Date.now() - cur.lastSave > 30000) saveProgress(false);
  }

  // The player was closed (Back / Stop). Returns the screen to show.
  function leftPlayer() {
    closeTracks();
    if (!cur) return has() || A.connected() ? 'home' : 'pair';
    var c = cur;
    saveProgress(false);
    cur = null;
    if (det && det.id === c.id) {
      setTimeout(function () { if (det && det.id === c.id && A.screen() === 'details') renderDetails(c.videoId); }, 0);
      return 'details';
    }
    return 'home';
  }

  // The video ran to its end: play the next episode when the same kind of
  // stream is there for it, else show the episode list.
  function ended() {
    if (!cur) return false;
    var c = cur;
    saveProgress(true);
    var next = c.type !== 'movie' ? nextVideo(c) : null;
    if (!next) { finish(c, null); return true; }
    A.setNote('Finding the next episode…');
    var pick = null;
    collectStreams(c.type, next.id, function (streams, addonName) {
      for (var i = 0; i < streams.length && !pick; i++) {
        if (!playable(streams[i])) continue;
        var s = streamInfo(streams[i], addonName);
        if ((c.binge && s.binge === c.binge) || (!c.binge && s.addon === c.addon && s.name === c.name)) pick = s;
      }
    }, function () {
      if (cur !== c) return;
      A.setNote('');
      if (!pick || !det || det.id !== c.id) { finish(c, next); return; }
      pick.video = next;
      pick.start = 0;
      playStream(pick);
    });
    return true;
  }

  function finish(c, next) {
    cur = null;
    closeTracks();
    A.stop();
    if (det && det.id === c.id) {
      A.show('details');
      renderDetails(next ? next.id : c.videoId);
      if (next) openStreams(next, 0);
    } else A.show('home');
  }

  // ---------------------------------------------- audio / subtitles panel

  var LANGS = { eng: 'English', spa: 'Spanish', fre: 'French', fra: 'French', ger: 'German', deu: 'German', ita: 'Italian',
    por: 'Portuguese', pob: 'Portuguese (Brazil)', jpn: 'Japanese', kor: 'Korean', chi: 'Chinese', zho: 'Chinese',
    rus: 'Russian', ara: 'Arabic', hin: 'Hindi', dut: 'Dutch', nld: 'Dutch', pol: 'Polish', tur: 'Turkish',
    swe: 'Swedish', nor: 'Norwegian', dan: 'Danish', fin: 'Finnish', gre: 'Greek', ell: 'Greek', heb: 'Hebrew',
    ind: 'Indonesian', vie: 'Vietnamese', tha: 'Thai', ukr: 'Ukrainian', rum: 'Romanian', ron: 'Romanian',
    hun: 'Hungarian', cze: 'Czech', ces: 'Czech', en: 'English', es: 'Spanish', fr: 'French', de: 'German',
    it: 'Italian', pt: 'Portuguese', ja: 'Japanese', ko: 'Korean', zh: 'Chinese', ru: 'Russian', ar: 'Arabic' };

  function langName(code) { return LANGS[String(code).toLowerCase()] || String(code); }

  function titem(label, act, data, on) {
    var d = el('div', 'fo sitem' + (on ? ' on' : ''), label);
    d.setAttribute('data-act', act);
    if (act === 'sub') d._sub = data; else d._audio = data;
    return d;
  }

  function buildTracks() {
    if (!cur) return;
    var list = $('tlist'), keepText = A.focused() && $('tpanel').contains(A.focused()) ? A.focused().textContent : null;
    clear(list);
    var v = A.video(), i;
    list.appendChild(el('div', 'thead', 'Audio'));
    var tracks = v && v.audioTracks;
    if (tracks && tracks.length > 1) {
      for (i = 0; i < tracks.length; i++) {
        list.appendChild(titem('Audio ' + (i + 1) + (tracks[i].language ? '  ·  ' + langName(tracks[i].language) : '') +
          (tracks[i].label ? '  ·  ' + tracks[i].label : ''), 'audio', { i: i }, tracks[i].enabled === true));
      }
    } else {
      list.appendChild(titem('Next audio track (now: ' + (cur.aud + 1) + ')', 'audio', { next: true }, false));
    }
    list.appendChild(el('div', 'thead', 'Subtitles'));
    list.appendChild(titem('Off', 'sub', { off: true }, cur.subOn == null));
    list.appendChild(titem('Inside the video: next' + (cur.emb >= 0 ? ' (now: ' + (cur.emb + 1) + ')' : ''), 'sub',
      { emb: true }, cur.subOn === 'emb'));
    var subs = cur.subs.slice();
    subs.sort(function (a, b) {
      var ae = /^en/i.test(a.lang) ? 0 : 1, be = /^en/i.test(b.lang) ? 0 : 1;
      return ae - be || langName(a.lang).localeCompare(langName(b.lang));
    });
    var perLang = {};
    for (i = 0; i < subs.length; i++) {
      var n = perLang[subs[i].lang] = (perLang[subs[i].lang] || 0) + 1;
      if (n > 6) continue;
      list.appendChild(titem(langName(subs[i].lang) + ' ' + n + (subs[i].from ? '  ·  ' + subs[i].from : ''), 'sub',
        { url: subs[i].url, label: langName(subs[i].lang) }, cur.subOn === subs[i].url));
    }
    var its = items(list), pick = its[0];
    for (i = 0; i < its.length; i++) if (keepText && its[i].textContent === keepText) pick = its[i];
    if (tracksOpen) focusOn(pick);
  }

  function openTracks() {
    if (!cur) return;
    tracksOpen = true;
    hide($('tpanel'), false);
    buildTracks();
  }

  function closeTracks() {
    if (!tracksOpen) return;
    tracksOpen = false;
    hide($('tpanel'), true);
    A.setFocus(null);
  }

  function pickSub(s) {
    if (!cur || !s) return;
    if (s.off) { cur.subOn = null; A.clearSubs(); A.selectSub(-1); }
    else if (s.emb) { cur.emb++; cur.subOn = 'emb'; A.clearSubs(); A.selectSub(cur.emb); checkSub(cur, cur.emb); }
    else { cur.subOn = s.url; A.loadSubs(s.url, s.label); }
    buildTracks();
  }

  // The TV says no once there are no more tracks: go back to the start.
  function checkSub(c, i) {
    setTimeout(function () {
      if (cur !== c || c.emb !== i || !A.playing().subNote) return;
      c.emb = -1; c.subOn = null;
      A.selectSub(-1);
      A.playing().subNote = '';
      if (tracksOpen) buildTracks();
    }, 1200);
  }

  function pickAudio(a) {
    if (!cur || !a) return;
    var c = cur;
    if (a.next) {
      c.aud++;
      A.selectAudio(c.aud);
      var i = c.aud;
      setTimeout(function () {
        if (cur !== c || c.aud !== i || !A.playing().audioNote) return;
        c.aud = 0;
        A.selectAudio(0);
        if (tracksOpen) buildTracks();
      }, 1200);
    } else {
      c.aud = a.i;
      A.selectAudio(a.i);
    }
    setTimeout(function () { if (tracksOpen && cur === c) buildTracks(); }, 300);
  }

  // Keys while the player is up. True = taken care of here.
  function playerKey(k) {
    if (tracksOpen) { key(k); return true; }
    if (k === 'up' && cur) { openTracks(); return true; }
    return false;
  }

  // ------------------------------------------------------------------- search

  var searchToken = 0, searchTimer = null, lastQuery = '';

  function searchSources() {
    var out = [], list = addons(), seen = {};
    for (var i = 0; i < list.length && out.length < 8; i++) {
      var cats = (list[i].manifest && list[i].manifest.catalogs) || [];
      for (var j = 0; j < cats.length && out.length < 8; j++) {
        var c = cats[j], ok = false, k;
        if (c.extra && c.extra.length) { for (k = 0; k < c.extra.length; k++) if (c.extra[k] && c.extra[k].name === 'search') ok = true; }
        else if (c.extraSupported) ok = strList(c.extraSupported).indexOf('search') >= 0;
        if (!ok || (c.type !== 'movie' && c.type !== 'series')) continue;
        var base = baseOf(list[i]), sig = base + '|' + c.type;
        if (seen[sig]) continue;      // one search per addon and type
        seen[sig] = 1;
        out.push({ base: base, type: String(c.type), id: String(c.id),
          title: (c.type === 'movie' ? 'Movies' : 'Series') + '  ·  ' + String((list[i].manifest && list[i].manifest.name) || '') });
      }
    }
    if (!seen[CINEMETA + '|movie']) out.unshift({ base: CINEMETA, type: 'movie', id: 'top', title: 'Movies' });
    if (!seen[CINEMETA + '|series']) out.splice(1, 0, { base: CINEMETA, type: 'series', id: 'top', title: 'Series' });
    return out;
  }

  function runSearch(q) {
    q = String(q || '').replace(/^\s+|\s+$/g, '');
    if (q === lastQuery) return;
    lastQuery = q;
    var token = ++searchToken;
    var box = $('srows');
    clear(box);
    box.scrollTop = 0;
    if (q.length < 2) { text($('shint'), 'Press OK to type. You can also type the name in AnymeX+ on your phone (Settings → TV Remote).'); return; }
    text($('shint'), 'Searching for "' + q + '"…');
    var sources = searchSources(), left = sources.length, found = 0;
    for (var i = 0; i < sources.length; i++) {
      (function (src) {
        var row = rowEl(src.title);
        box.appendChild(row);
        getJson(resourceUrl(src.base, 'catalog', src.type, src.id, 'search=' + encodeURIComponent(q)), function (r) {
          if (token !== searchToken) return;
          var cards = [], list = (r && r.metas) || [];
          for (var j = 0; j < list.length; j++) { var c = cardFromMeta(list[j]); if (c) cards.push(c); }
          fillRow(row, cards);
          found += cards.length;
          if (--left === 0) text($('shint'), found ? '' : 'Nothing found for "' + q + '".');
        });
      })(sources[i]);
    }
  }

  // Typed on the phone.
  function searchFromPhone(q) {
    if (A.screen() === 'player') return;
    if (A.screen() !== 'search') {
      closePanel(true);
      go('search');
    }
    $('sq').value = String(q || '');
    runSearch(q);
  }

  function onInput() {
    clearTimeout(searchTimer);
    searchTimer = setTimeout(function () { runSearch($('sq').value); }, 700);
  }

  // ----------------------------------------------------------------- settings

  function setSettingsNote(s) { text($('setnote'), s || ''); }

  function showSettings() {
    var lines = [];
    var p = A.phone();
    lines.push('Phone        ' + (A.connected() ? 'connected (' + A.peer() + ')' : (p && p.host ? 'not connected (last: ' + p.host + ')' : 'none')));
    if (bundle) {
      lines.push('Synced       ' + new Date(bundle.at || 0).toLocaleString() + ' from ' + (bundle.from || 'phone'));
      lines.push('Stremio      ' + ((bundle.stremio && bundle.stremio.email) || (authKey() ? 'signed in' : 'not signed in')));
      lines.push('Addons       ' + addons().length);
      lines.push('Rows         ' + ((bundle.rows && bundle.rows.length) || 0));
      lines.push('TMDB rows    ' + (tmdbKey() ? 'yes' : 'no'));
    } else {
      lines.push('Synced       nothing yet');
    }
    if (wq.length) lines.push('Waiting      ' + wq.length + ' watched mark(s) for the phone');
    lines.push('App          ' + (A.info.app || ''));
    lines.push('TV           ' + (A.info.model || '?') + '  ·  ' + (A.info.ip || '?'));
    text($('setinfo'), lines.join('\n'));
  }

  function clearBundle() {
    bundle = null; bundleHash = ''; library = {}; libraryLoaded = false;
    try { localStorage.removeItem(K_BUNDLE); localStorage.removeItem(K_HASH); } catch (e) { /* ignore */ }
    setSettingsNote('Removed. The phone sends it again the next time it connects.');
    showSettings();
    if (homeBuilt) loadHome();
  }

  // --------------------------------------------------------------- from phone

  function onSync(m) {
    var p = A.phone();
    if (!p || !p.key) { A.send({ t: 'syncFail', why: 'no key' }); return; }
    window.AXGcm.open(p.key, m.iv, m.data, function (plain, why) {
      var b = null;
      if (plain) { try { b = JSON.parse(plain); } catch (e) { b = null; } }
      if (!b || typeof b !== 'object') { A.send({ t: 'syncFail', why: why || 'unreadable' }); return; }
      bundle = b;
      bundleHash = String(m.h || '');
      save(K_BUNDLE, bundle);
      save(K_HASH, bundleHash);
      libraryLoaded = false;
      A.send({ t: 'syncOk', h: bundleHash, addons: addons().length, rows: (bundle.rows && bundle.rows.length) || 0 });
      var s = A.screen();
      if (s === 'pair') home();
      else if (homeBuilt) loadHome();
      if (s === 'settings') { showSettings(); setSettingsNote('Synced.'); }
      updateStatus();
    });
  }

  // True when the message was for this part of the app.
  function onMessage(m) {
    if (m.t === 'sync') { onSync(m); return true; }
    if (m.t === 'search') { searchFromPhone(m.q); return true; }
    if (m.t === 'watchedOk') {
      var keep = [];
      for (var i = 0; i < wq.length; i++) if (wq[i].q !== m.q) keep.push(wq[i]);
      wq = keep;
      save(K_WQ, wq);
      return true;
    }
    return false;
  }

  function onConnected() {
    updateStatus();
    flushWatched();
    if (A.screen() === 'settings') showSettings();
  }

  function onDisconnected() {
    updateStatus();
    if (A.screen() === 'settings') showSettings();
  }

  function helloExtra() {
    var p = A.phone();
    return { sync: true, hasKey: !!(p && p.key), have: bundleHash };
  }

  function start() {
    var input = $('sq');
    input.addEventListener('input', onInput);
    input.addEventListener('change', function () { runSearch(input.value); });
  }

  return {
    screens: SCREENS, has: has, start: start, enter: enter, key: key, home: home,
    onMessage: onMessage, onConnected: onConnected, onDisconnected: onDisconnected, helloExtra: helloExtra,
    tick: tick, ended: ended, leftPlayer: leftPlayer, playerKey: playerKey,
    // for tests
    _supports: supports, _applyProgress: applyProgress, _baseOf: baseOf
  };
};
