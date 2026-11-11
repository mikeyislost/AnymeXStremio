/* AnymeX+ TV: browsing on the TV itself (Movies & TV, and anime).
 *
 * The phone sends over what it knows (Stremio login, addons, the rows of
 * its Movies & TV page, the TMDB key). With that the TV can show rows,
 * details, episodes and streams by itself, and play them with the LG
 * remote, also when the phone is not around. Progress goes to your Stremio
 * library; "watched" marks go to the phone, which updates AniList / Simkl.
 *
 * Anime: the phone also sends its Home's anime rows (your lists, trending…).
 * The TV shows them and reads titles' details from AniList by itself.
 * Episodes and video links come from the anime extensions, which only run
 * on the phone, so for those the TV asks the phone ("anime" messages); the
 * phone then plays the episode here and keeps your progress.
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
  var ANILIST = 'https://graphql.anilist.co';
  var K_ALINFO = 'anymexplus_tv_alinfo';
  var AL_FIELDS = 'id title{english romaji} coverImage{large} bannerImage description(asHtml:false) ' +
    'averageScore seasonYear episodes format status isAdult';
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
    if (A.screen() === 'player') return tracksOpen ? $('tpanel') : $('osd');
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
    if (tracksOpen) menuFocus(node);
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
    if (vert && g.getAttribute('data-col')) {
      // Menu columns side by side: up / down stay in the column.
      if (along) { if (its[i + along]) focusOn(its[i + along]); return; }
      var cg = gs[gs.indexOf(g) + across];
      if (!cg || !cg.getAttribute('data-col')) return;
      var cits = items(cg), to = null;
      for (var q = 0; q < cits.length && !to; q++) if (cits[q].classList.contains('sel')) to = cits[q];
      focusOn(to || (cg._last >= 0 && cits[cg._last]) || onItem(cg));
      return;
    }
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
    else if (act === 'season') { showPart(f._part, null); }
    else if (act === 'ep') openStreams(f._video, -1);
    else if (act === 'stream') playStream(f._stream);
    else if (act === 'server') pickServer(f._server);
    else if (playerAct(act, f)) { /* player buttons and menus */ }
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
    if (c.type) meta.push(c.type === 'series' ? 'Series' : (c.type === 'movie' ? 'Movie' : (c.type === 'anime' ? 'Anime' : c.type)));
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
    // Filled a second time (Continue Watching): stay where you were in it.
    var f = A.focused(), had = f && row._strip.contains(f) ? items(row._strip).indexOf(f) : -1;
    clear(row._strip);
    for (var i = 0; i < cards.length && i < 30; i++) row._strip.appendChild(cardEl(cards[i]));
    hide(row, !cards.length);
    if (had >= 0) {
      var its = items(row._strip);
      if (its.length) focusOn(its[Math.min(had, its.length - 1)]); else focusFirst();
    }
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
        at: Date.parse(s.lastWatched || x._mtime || '') || 0,
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
      var mine = animeCards(spec.anime);
      if (mine.length) { fill(mine); enrich(mine); }   // shown at once; Movies & TV join when loaded
      loadLibrary(function () { fill(mergeContinue(mine, continueCards())); });
    } else if (spec.kind === 'anime') {
      var cards = animeCards(spec.cards);
      fill(cards);
      enrich(cards);
    } else if (spec.kind === 'alq') {
      anilist('query($type:MediaType,$genres:[String],$from:FuzzyDateInt,$to:FuzzyDateInt,$minScore:Int,$sort:[MediaSort]){' +
        'Page(perPage:30){media(type:$type,genre_in:$genres,startDate_greater:$from,startDate_lesser:$to,' +
        'averageScore_greater:$minScore,sort:$sort,isAdult:false){' + AL_FIELDS + '}}}', spec.vars || {}, function (list) {
        fill(cardsFromAnilist(list));
      });
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

  // Rows the TV leaves out: catalogs of type "other", such as a debrid
  // addon's Downloads list (raw file names, nothing to watch from there).
  function shownRows(list) {
    var out = [];
    for (var i = 0; i < list.length; i++) {
      var r = list[i];
      if (r && r.kind === 'cat' && String(r.type || '').toLowerCase() === 'other') continue;
      out.push(r);
    }
    return out;
  }

  function loadHome() {
    var token = ++homeToken;
    var specs = shownRows((bundle && bundle.rows && bundle.rows.length) ? bundle.rows : defaultRows());
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
    if (c.a) { openAnime(c); return; }
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


  // -------------------------------------------------------------------- anime
  //
  // Cards with an "a" (AniList id). What a title is about comes from
  // AniList, read by the TV and kept; episodes come from the phone.

  var alInfo = load(K_ALINFO, {});    // AniList id → {bg, desc, year, rating, eps, fmt, st}
  var alCards = {};                   // AniList id → cards on screen, to fill in later
  var alWant = [], alTimer = null;

  function cleanText(s) {
    s = String(s || '').replace(/<br\s*\/?>/gi, ' ').replace(/<[^>]*>/g, '').replace(/&quot;/g, '"')
      .replace(/&#0?39;|&apos;/g, "'").replace(/&amp;/g, '&').replace(/&lt;/g, '<').replace(/&gt;/g, '>')
      .replace(/&nbsp;/g, ' ').replace(/\s+/g, ' ').replace(/^\s+|\s+$/g, '');
    return s.length > 600 ? s.slice(0, 600) + '…' : s;
  }

  function anilist(query, vars, done) {
    postJson(ANILIST, { query: query, variables: vars }, function (r) {
      done((r && r.data && r.data.Page && r.data.Page.media) || []);
    });
  }

  function infoFromAnilist(m) {
    return {
      bg: m.bannerImage || '', desc: cleanText(m.description), year: m.seasonYear ? String(m.seasonYear) : '',
      rating: m.averageScore ? (m.averageScore / 10).toFixed(1) : '', eps: m.episodes || 0,
      fmt: String(m.format || '').replace(/_/g, ' '), st: String(m.status || '')
    };
  }

  function applyInfo(c) {
    var i = alInfo[c.a];
    if (!i) return false;
    c.bg = i.bg; c.desc = i.desc; c.year = i.year; c.eps = i.eps; c.fmt = i.fmt; c.st = i.st;
    if (i.rating) c.rating = i.rating;
    return true;
  }

  function saveInfo() {
    var keys = [];
    for (var k in alInfo) if (alInfo.hasOwnProperty(k)) keys.push(k);
    for (var i = 0; i < keys.length - 800; i++) delete alInfo[keys[i]];
    save(K_ALINFO, alInfo);
  }

  // "3 | 12" (watched | episodes; sometimes with the released count in
  // between) → "3 of 12 watched".
  function watchedLine(sub) {
    if (!sub) return '';
    var p = String(sub).split('|'), cur = p[0].replace(/\s/g, ''), tot = p[p.length - 1].replace(/\s/g, '');
    if (!cur) return '';
    return p.length > 1 && /^\d+$/.test(tot) ? cur + ' of ' + tot + ' watched' : cur + ' watched';
  }

  // A card as the phone sent it → a card of this app.
  function animeCards(list) {
    var out = [];
    for (var i = 0; list && i < list.length; i++) {
      var x = list[i];
      if (!x || !x.a) continue;
      var c = { a: String(x.a), type: 'anime', name: String(x.name || ''), romaji: String(x.romaji || ''),
        poster: x.poster || '', sub: watchedLine(x.sub), watched: parseInt(String(x.sub || ''), 10) || 0,
        rating: x.rating ? String(x.rating) : '', at: Number(x.at) || 0, bg: '', desc: '', year: '' };
      applyInfo(c);
      out.push(c);
    }
    return out;
  }

  function cardsFromAnilist(list) {
    var out = [];
    for (var i = 0; list && i < list.length; i++) {
      var m = list[i];
      if (!m || !m.id || m.isAdult) continue;
      var t = m.title || {};
      alInfo[String(m.id)] = infoFromAnilist(m);
      var c = { a: String(m.id), type: 'anime', name: String(t.english || t.romaji || ''), romaji: String(t.romaji || ''),
        poster: (m.coverImage && m.coverImage.large) || '', sub: '', rating: '', at: 0, bg: '', desc: '', year: '' };
      applyInfo(c);
      out.push(c);
    }
    if (out.length) saveInfo();
    return out;
  }

  // Fills in what AniList knows (picture behind, description, year, score)
  // for cards that don't have it yet; a few rows are asked for together.
  function enrich(cards) {
    for (var i = 0; i < cards.length; i++) {
      var c = cards[i];
      (alCards[c.a] = alCards[c.a] || []).push(c);
      if (!alInfo[c.a] && alWant.indexOf(c.a) < 0 && /^\d+$/.test(c.a)) alWant.push(c.a);
    }
    if (!alWant.length) return;
    clearTimeout(alTimer);
    alTimer = setTimeout(function () {
      var ids = alWant;
      alWant = [];
      for (var at = 0; at < ids.length && at < 400; at += 50) {
        (function (chunk) {
          var nums = [];
          for (var j = 0; j < chunk.length; j++) nums.push(Number(chunk[j]));
          anilist('query($ids:[Int]){Page(perPage:50){media(id_in:$ids,type:ANIME){' + AL_FIELDS + '}}}', { ids: nums },
            function (list) {
              for (var k = 0; k < list.length; k++) {
                var id = String(list[k].id);
                alInfo[id] = infoFromAnilist(list[k]);
                var cs = alCards[id] || [];
                for (var n = 0; n < cs.length; n++) applyInfo(cs[n]);
              }
              if (!list.length) return;
              saveInfo();
              var f = A.focused();
              if (A.screen() === 'home' && f && f._card && f._card.a && alInfo[f._card.a]) showHomeInfo(f._card);
            });
        })(ids.slice(at, at + 50));
      }
    }, 400);
  }

  function normTitle(s) { return String(s || '').toLowerCase().replace(/[^a-z0-9]/g, ''); }

  // Anime and Movies & TV in one Continue Watching row, newest first. A
  // Movies & TV entry of a show that is also among the anime is left out.
  function mergeContinue(anime, stremio) {
    var titles = {}, all = [], i;
    for (i = 0; i < anime.length; i++) {
      if (anime[i].name) titles[normTitle(anime[i].name)] = 1;
      if (anime[i].romaji) titles[normTitle(anime[i].romaji)] = 1;
      all.push(anime[i]);
    }
    for (i = 0; i < stremio.length; i++) if (!titles[normTitle(stremio[i].name)]) all.push(stremio[i]);
    all.sort(function (x, y) { return (y.at || 0) - (x.at || 0); });
    return all.slice(0, 30);
  }

  // ---- an anime → the id your Stremio addons know it by
  //
  // ani.zip says which Kitsu and IMDb ids an AniList title has, and for
  // IMDb which season / episode each of its episodes is. Kitsu ids are
  // used when a stream addon takes them (one id per AniList entry, same
  // episode numbers), IMDb ids otherwise. From there on an anime is a
  // title like any other: streams from your addons, played by the TV
  // itself, progress to your Stremio library and, through the phone when
  // it is around, to AniList.

  var ANIZIP = 'https://api.ani.zip/mappings?anilist_id=';
  var ARM = 'https://arm.haglund.dev/api/v2/ids?source=anilist&id=';
  var KITSU = 'https://anime-kitsu.strem.fun';
  var K_ANIMAP = 'anymexplus_tv_animap';
  var aniMap = load(K_ANIMAP, {});    // AniList id → {k, i, m, e: {n: [season, episode]}}

  function mappingFromAniZip(r) {
    var mp = (r && r.mappings) || {}, eps = {}, any = false;
    var kitsu = mp.kitsu_id != null ? String(mp.kitsu_id) : '', imdb = String(mp.imdb_id || '');
    var list = (r && r.episodes) || {};
    for (var n in list) {
      if (!list.hasOwnProperty(n) || !list[n]) continue;
      var se = parseInt(list[n].seasonNumber, 10), ep = parseInt(list[n].episodeNumber, 10);
      if (se > 0 && ep >= 0 && /^\d+$/.test(n)) { eps[n] = [se, ep]; any = true; }
    }
    if (!/^\d+$/.test(kitsu)) kitsu = '';
    if (imdb.indexOf('tt') !== 0) imdb = '';
    if (!kitsu && !imdb) return null;
    return { k: kitsu, i: imdb, m: String(mp.type || '').toUpperCase() === 'MOVIE', e: any ? eps : null };
  }

  function animeMapping(id, done) {
    if (aniMap[id]) { done(aniMap[id]); return; }
    function keep(m) {
      if (m) {
        aniMap[id] = m;
        var keys = [];
        for (var k in aniMap) if (aniMap.hasOwnProperty(k)) keys.push(k);
        for (var i = 0; i < keys.length - 500; i++) delete aniMap[keys[i]];
        save(K_ANIMAP, aniMap);
      }
      done(m);
    }
    getJson(ANIZIP + encodeURIComponent(id), function (r) {
      var m = mappingFromAniZip(r);
      if (m) { keep(m); return; }
      // ani.zip doesn't know it (or can't be reached): ids only.
      getJson(ARM + encodeURIComponent(id), function (a) {
        var kitsu = a && a.kitsu != null ? String(a.kitsu) : '', imdb = String((a && a.imdb) || '');
        if (!/^\d+$/.test(kitsu)) kitsu = '';
        if (imdb.indexOf('tt') !== 0) imdb = '';
        keep(kitsu || imdb ? { k: kitsu, i: imdb, m: false, e: null } : null);
      });
    });
  }

  // IMDb [season, episode] of an anime's episode n. Episodes ani.zip doesn't
  // list yet continue on from the last one it does.
  function imdbEpisode(map, n) {
    var e = map.e || {};
    if (e[n]) return e[n];
    var best = null, bestK = 0;
    for (var k in e) {
      if (!e.hasOwnProperty(k)) continue;
      var kn = parseInt(k, 10);
      if (kn < n && kn > bestK) { bestK = kn; best = e[k]; }
    }
    return best ? [best[0], best[1] + (n - bestK)] : [1, n];
  }

  function streamTakes(type, id) {
    var list = addons();
    for (var i = 0; i < list.length; i++) {
      if (supports(list[i], 'stream', type, id) || supports(list[i], 'stream', 'anime', id)) return true;
    }
    return false;
  }

  // What to open for an anime: {type, id, start (video to begin with),
  // season, metaTypes, kitsu}.
  function animeTarget(c, map) {
    var movie = map.m || c.fmt === 'MOVIE';
    var next = (c.watched || 0) + 1;
    var kitsu = map.k ? 'kitsu:' + map.k : '';
    var kitsuOk = kitsu && streamTakes(movie ? 'movie' : 'series', movie ? kitsu : kitsu + ':1');
    var imdbOk = map.i && (movie || map.e) && streamTakes(movie ? 'movie' : 'series', movie ? map.i : map.i + ':1:1');
    if (kitsu && (kitsuOk || !imdbOk)) {
      return { type: movie ? 'movie' : 'series', id: kitsu, kitsu: true, start: movie ? '' : kitsu + ':' + next, season: 0,
        metaTypes: movie ? ['movie', 'series', 'anime'] : ['series', 'anime', 'movie'], a: c.a, card: c, map: map };
    }
    if (!map.i) return null;
    var first = imdbEpisode(map, 1), at = imdbEpisode(map, next);
    return { type: movie ? 'movie' : 'series', id: map.i, kitsu: false, season: movie ? 0 : first[0],
      start: movie ? '' : map.i + ':' + at[0] + ':' + at[1], metaTypes: [movie ? 'movie' : 'series'], a: c.a, card: c, map: map };
  }

  // An anime no Stremio id is known for: it is played from your anime
  // extensions only (through the phone or PC), by its AniList id.
  function alTarget(c) {
    var id = 'anilist:' + c.a, movie = c.fmt === 'MOVIE';
    return { type: movie ? 'movie' : 'series', id: id, kitsu: false, al: true, season: 0,
      start: movie ? '' : id + ':' + ((c.watched || 0) + 1), metaTypes: [], a: c.a, card: c, map: null };
  }

  function openAnime(c) {
    var token = ++detToken;
    det = null;
    closePanel(true);
    if (A.screen() !== 'details') go('details');
    text($('dtitle'), c.name || c.romaji || '');
    text($('dmeta'), '');
    text($('ddesc'), c.desc || '');
    setBackdrop($('dbg'), c.bg || '');
    clear($('dbtns')); clear($('dseasons')); clear($('deps'));
    text($('dmsg'), 'Finding this anime on your addons…');
    A.setFocus(null);
    lastFocus.details = null;
    enrich([c]);
    animeMapping(c.a, function (map) {
      if (token !== detToken) return;
      var t = map && animeTarget(c, map);
      if (!t && A.connected()) t = alTarget(c);
      if (!t) {
        text($('dmsg'), "Couldn't match this anime to an id your Stremio addons use. Open AnymeX+ on your phone or PC to play it from your anime extensions, or try Search.");
        return;
      }
      openDetails(t.type, t.id, c, t);
    });
  }

  // ---- the servers of the episode the phone is playing here

  var srv = null;   // {id, list, on}

  function setHint(s) { var h = $('phint'); if (h) text(h, s || ''); }

  function hasServers() {
    var p = A.playing();
    return !!(srv && srv.list.length > 1 && p && p.url && p.id === srv.id);
  }

  // ------------------------------------------------------------------ details

  var det = null;       // {type, id, meta, videos, parts, part, anime (how an anime was matched)}
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
    if (id.indexOf('kitsu:') === 0 && !seen[KITSU]) out.push(KITSU);
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

  // anime: how an anime was matched to this id (animeTarget), if it was.
  function openDetails(type, id, hint, anime) {
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
    // Where to read the title from: each place, under each type it may be
    // listed as there (an anime can be a series, an "anime" or a movie).
    var types = (anime && anime.metaTypes) || [type], tries = [], seen = {}, i, j;
    for (i = 0; i < types.length; i++) {
      var srcs = metaSources(types[i], id);
      for (j = 0; j < srcs.length; j++) {
        if (!seen[srcs[j] + '|' + types[i]]) { seen[srcs[j] + '|' + types[i]] = 1; tries.push([srcs[j], types[i]]); }
      }
    }
    var at = 0;
    function ready(meta) {
      var t = type;
      if (anime && anime.kitsu && type === 'series' && !(meta.videos && meta.videos.length > 1)) {
        // One video: a film after all (unless episodes are only missing from the list).
        if (String(meta.type) === 'movie' || !(hint && hint.eps > 1)) t = 'movie';
      }
      det = { type: t, id: id, meta: meta, videos: sortVideos(meta.videos || []), parts: [], part: 0, anime: anime || null };
      if (anime && t !== 'movie') fillAnimeVideos(det, hint);
      if (!libraryLoaded && authKey()) loadLibrary(function () { if (token === detToken) renderDetails(null); });
      else renderDetails(null);
    }
    function next() {
      if (token !== detToken) return;
      if (at >= tries.length) {
        if (anime && hint) {
          // No addon describes it: what AniList said is enough to play it.
          ready({ id: id, type: type, name: hint.name, description: hint.desc, background: hint.bg, poster: hint.poster, videos: [] });
          return;
        }
        text($('dmsg'), "Couldn't load this title. Check the TV's internet and try again.");
        return;
      }
      var tr = tries[at++];
      getJson(resourceUrl(tr[0], 'meta', tr[1], id), function (r) {
        if (token !== detToken) return;
        if (r && r.meta && r.meta.id) ready(r.meta); else next();
      });
    }
    next();
  }

  // An anime by its Kitsu id: every episode AniList counts gets a place,
  // also the ones the addon doesn't list (yet).
  function fillAnimeVideos(d, c) {
    if (d.anime.al) { if (!d.videos.length) alVideos(d, c, null); askEpisodes(d); return; }
    if (!d.anime.kitsu) return;
    var have = {}, max = 0, i;
    for (i = 0; i < d.videos.length; i++) {
      var v = d.videos[i];
      if (!(v.episode > 0)) { var m = /:(\d+)$/.exec(v.id); v.episode = m ? Number(m[1]) : 0; }
      v.season = 1;
      have[v.episode] = 1;
      if (v.episode > max) max = v.episode;
    }
    var count = Math.max(max, (c && c.st !== 'RELEASING' && c.eps) || 0, (c && c.watched) || 0);
    if (!d.videos.length && !count) count = 1;
    for (i = 1; i <= count && i <= 3000; i++) {
      if (!have[i]) d.videos.push({ id: d.id + ':' + i, title: '', season: 1, episode: i, released: NaN, thumb: '', overview: '' });
    }
    d.videos.sort(function (a, b) { return a.episode - b.episode; });
  }

  // Episodes of an extension-only anime: from the extension's list when it
  // came, else 1 … the AniList count.
  function alVideos(d, c, eps) {
    var out = [], i;
    if (eps && eps.length) {
      for (i = 0; i < eps.length; i++) {
        var n = Number(eps[i].n);
        if (!(n > 0)) continue;
        out.push({ id: d.id + ':' + eps[i].n, title: String(eps[i].title || ''), season: 1, episode: n, released: NaN,
          thumb: String(eps[i].thumb || ''), overview: '' });
      }
    }
    if (!out.length) {
      var count = Math.max((c && c.eps) || 0, ((c && c.watched) || 0) + 1);
      for (i = 1; i <= count && i <= 3000; i++) out.push({ id: d.id + ':' + i, title: '', season: 1, episode: i, released: NaN, thumb: '', overview: '' });
    }
    out.sort(function (a, b) { return a.episode - b.episode; });
    d.videos = out;
  }

  var epsAsk = null;   // {q, det}

  function askEpisodes(d) {
    if (!A.connected() || !d.anime || !d.anime.a) return;
    var c = d.anime.card || {};
    epsAsk = { q: 'e' + Date.now(), det: d };
    A.send({ t: 'anime', cmd: 'eps', q: epsAsk.q, id: String(d.anime.a), name: c.name || '', romaji: c.romaji || '', poster: c.poster || '' });
  }

  function onAnimeEps(m) {
    if (!epsAsk || m.q !== epsAsk.q) return;
    var d = epsAsk.det;
    if (d !== det) return;
    if (!m.ok || !m.eps || !m.eps.length) {
      if (m.err && A.screen() === 'details' && !panelOpen) text($('dmsg'), String(m.err));
      return;
    }
    var focusId = null, f = A.focused();
    if (f && f._video) focusId = f._video.id;
    alVideos(d, d.anime.card, m.eps);
    if (A.screen() === 'details' && !panelOpen) renderDetails(focusId);
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
    // An anime that is one season of a longer show: stay in that season.
    if (v && det.anime && det.anime.season && v.season !== det.anime.season) v = null;
    // An anime not started here yet: the episode after your AniList progress.
    if (!v && det.anime && det.anime.start) v = findVideo(det.anime.start);
    if (!v && det.anime && det.anime.season) {
      for (var a = 0; a < det.videos.length; a++) if (det.videos[a].season === det.anime.season) { v = det.videos[a]; break; }
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
      var i;
      det.parts = parts(det.videos);
      if (det.parts.length > 1) {
        for (i = 0; i < det.parts.length; i++) {
          var chip = button(det.parts[i].label, 'season');
          chip.classList.add('chip');
          chip._part = i;
          seasonsBox.appendChild(chip);
        }
      }
      var focusVideo = focusVideoId ? findVideo(focusVideoId) : null;
      showPart(partOf(focusVideo || target), focusVideo || target);
      if (focusVideo) {
        var eps = $('deps').querySelectorAll('.fo');
        for (i = 0; i < eps.length; i++) if (eps[i]._video === focusVideo) { focusOn(eps[i]); return; }
      }
    }
    if (A.screen() === 'details') focusOn(btns.firstChild);
  }

  var PART = 50;

  // The episode list in pieces: one per season, and long seasons 50
  // episodes at a time. [{label, videos}]
  function parts(videos) {
    var seasons = [], by = {}, i, out = [];
    for (i = 0; i < videos.length; i++) {
      var s = videos[i].season;
      if (!by[s]) { by[s] = []; seasons.push(s); }
      by[s].push(videos[i]);
    }
    seasons.sort(function (a, b) { return (a === 0 ? 1e9 : a) - (b === 0 ? 1e9 : b); });
    for (i = 0; i < seasons.length; i++) {
      var list = by[seasons[i]], name = seasons[i] === 0 ? 'Specials' : 'Season ' + seasons[i];
      if (list.length <= PART) { out.push({ label: name, videos: list }); continue; }
      for (var at = 0; at < list.length; at += PART) {
        var piece = list.slice(at, at + PART);
        var range = piece[0].episode + ' – ' + piece[piece.length - 1].episode;
        out.push({ label: seasons.length > 1 ? name + '  ·  ' + range : range, videos: piece });
      }
    }
    return out;
  }

  function partOf(video) {
    for (var i = 0; i < det.parts.length; i++) if (det.parts[i].videos.indexOf(video) >= 0) return i;
    return 0;
  }

  function showPart(index, mark) {
    if (!det || !det.parts.length) return;
    if (!det.parts[index]) index = 0;
    det.part = index;
    var chips = $('dseasons').querySelectorAll('.fo'), i;
    for (i = 0; i < chips.length; i++) {
      if (chips[i]._part === index) chips[i].classList.add('on'); else chips[i].classList.remove('on');
    }
    var box = $('deps');
    clear(box);
    box.scrollLeft = 0;
    box._last = 0;
    var now = Date.now(), list = det.parts[index].videos;
    for (i = 0; i < list.length; i++) {
      var v = list[i];
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

  // ---- anime from your extensions (phase 2): the phone or PC finds the
  // servers and passes the video on, with the headers the site wants.

  var extAsks = {};   // q -> {each, done, seen, timer}

  // AniList show and episode number for [videoId], when it is an anime.
  function extTarget(type, videoId) {
    var an = null, id = '';
    if (det && det.anime && videoId.indexOf(det.id) === 0) { an = det.anime; id = det.id; }
    else if (cur && cur.anime && videoId.indexOf(cur.id) === 0) { an = cur.anime; id = cur.id; }
    if (!an || !an.a) return null;
    var n = '';
    if (type === 'movie' || videoId === id) n = '1';
    else if (an.kitsu || an.al) n = videoId.substring(id.length + 1);
    else {
      var m = /:(\d+):(\d+)$/.exec(videoId);
      if (!m) return null;
      var se = Number(m[1]), ep = Number(m[2]);
      for (var k = 1; k <= 3000 && !n; k++) {
        var at = an.map ? imdbEpisode(an.map, k) : [1, k];
        if (at[0] === se && at[1] === ep) n = String(k);
      }
    }
    if (!/^\d+(\.\d+)?$/.test(n)) return null;
    var c = an.card || {};
    return { a: String(an.a), n: n, name: c.name || '', romaji: c.romaji || '', poster: c.poster || '' };
  }

  function extName(source) {
    return 'From ' + (A.peer() || 'phone') + (source ? '  ·  ' + source : '');
  }

  // A server from the phone / PC as a Stremio-style stream.
  function extStream(e, source) {
    var ext = { hls: 'm3u8', mkv: 'mkv', webm: 'webm', ts: 'ts', mp4: 'mp4' }[e.kind] || '';
    var subs = [];
    for (var i = 0; e.subs && i < e.subs.length; i++) if (e.subs[i] && e.subs[i].url) subs.push({ url: e.subs[i].url, lang: e.subs[i].lang || '?' });
    return { url: String(e.url), name: String(e.name || 'Server'), title: extName(source),
      behaviorHints: ext ? { filename: 'video.' + ext } : {}, subtitles: subs };
  }

  function onExtServers(m) {
    var w = extAsks[m.q];
    if (!w) return;
    var fresh = [], list = m.list || [];
    for (var i = 0; i < list.length; i++) {
      if (!list[i] || !list[i].url || w.seen[list[i].url]) continue;
      w.seen[list[i].url] = 1;
      fresh.push(extStream(list[i], m.source));
    }
    if (fresh.length) w.each(fresh, 'ext:' + (m.source || ''));
    if (m.err) w.err = String(m.err);
    if (m.done) finishExt(m.q);
  }

  function finishExt(q) {
    var w = extAsks[q];
    if (!w) return;
    delete extAsks[q];
    clearTimeout(w.timer);
    w.done(w.err || '');
  }

  // Asks the phone / PC; each(streams, addonName), done(problem) at the end.
  function askExt(t, each, done) {
    var q = 'x' + Date.now() + Math.floor(Math.random() * 1000);
    extAsks[q] = { each: each, done: done, seen: {}, err: '', timer: setTimeout(function () { finishExt(q); }, 75000) };
    A.send({ t: 'ext', cmd: 'servers', q: q, a: t.a, n: t.n, name: t.name, romaji: t.romaji, poster: t.poster });
  }

  // Asks every stream addon (and for anime the phone / PC's extensions);
  // each(list, addonName) per answer, done(asked) at the end.
  function collectStreams(type, videoId, each, done) {
    var list = addons(), todo = [];
    for (var i = 0; i < list.length; i++) {
      if (supports(list[i], 'stream', type, videoId) || supports(list[i], 'stream', 'anime', videoId)) todo.push(list[i]);
    }
    var ext = A.connected() ? extTarget(type, videoId) : null;
    var left = todo.length + (ext ? 1 : 0);
    if (!left) { done(0); return; }
    if (ext) {
      askExt(ext, each, function (why) {
        if (why) lastExtProblem = why;
        if (--left === 0) done(todo.length + 1);
      });
    }
    for (var j = 0; j < todo.length; j++) {
      (function (addon) {
        getJson(resourceUrl(baseOf(addon), 'stream', type, videoId), function (r) {
          each((r && r.streams) || [], String((addon.manifest && addon.manifest.name) || 'Addon'));
          if (--left === 0) done(todo.length + (ext ? 1 : 0));
        }, 25000);
      })(todo[j]);
    }
  }

  var lastExtProblem = '';

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
    text($('spmsg'), extTarget(det.type, video.id) && A.connected() ? 'Finding streams (your ' + (A.peer() || 'phone') + ' is checking your anime extensions)…' : 'Finding streams…');
    lastExtProblem = '';
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
      else if (hidden) text($('spmsg'), 'Nothing the TV can play by itself (' + hidden + ' torrent-only streams). Debrid and direct links work here.' + (lastExtProblem ? '\n' + lastExtProblem : ''));
      else text($('spmsg'), lastExtProblem || 'No streams found.');
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

  // keep: {url, label, delay} of a subtitle file to carry over (another
  // stream of the same episode).
  function playStream(s, keep) {
    if (!s || !det) return;
    var video = s.video;
    closePanel(true);
    closeTracks();
    cur = {
      type: det.type, id: det.id, videoId: video.id, video: video, meta: det.meta, videos: det.videos,
      binge: s.binge, addon: s.addon, name: s.name, anime: det.anime || null, lastPos: Math.round((s.start || 0) * 1000), lastAt: Date.now(),
      lastSave: Date.now(), sentWatched: false, subs: [], emb: -1, aud: 0, delay: keep ? keep.delay || 0 : 0
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
    if (keep && keep.url) { cur.subTouched = true; cur.subOn = keep.url; cur.subLabel = keep.label; A.loadSubs(keep.url, keep.label); }
    A.playing().subDelay = -(cur.delay || 0);
    applySubSize();
    readMkvTracks(cur, s);
    autoSub(cur);
  }

  // MKV: name the tracks inside the file (the TV's player doesn't).
  function readMkvTracks(c, s) {
    var k = kindOf(s);
    if (k !== 'mkv' && k !== '') return;
    if (!window.AXMkv) return;
    c.mkvLoading = true;
    window.AXMkv.tracks(s.url, function (r) {
      if (cur !== c) return;
      c.mkvLoading = false;
      c.mkv = r && (r.audio.length || r.subs.length) ? r : null;
      if (c.mkv) {
        for (var i = 0; i < c.mkv.audio.length; i++) if (c.mkv.audio[i].def) { c.aud = i; break; }
        autoAudio(c);
      }
      autoSub(c);
      if (tracksOpen && (pmode === 'subs' || pmode === 'audio')) renderMenu();
    });
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
          autoSub(c);
          if (tracksOpen && cur === c && pmode === 'subs') renderMenu();
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
    if (!key || c.id.indexOf('anilist:') === 0) {
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
    if (!cur) {
      if (tracksOpen && !(pmode === 'servers' && hasServers())) closeTracks(true);
      return;
    }
    if (!A.playing().local) { cur = null; closeTracks(); return; }
    if (Date.now() - cur.lastSave > 30000) saveProgress(false);
  }

  // The player was closed (Back / Stop). Returns the screen to show.
  function leftPlayer() {
    closeTracks();
    srv = null;
    setHint('');
    if (!cur) return has() || A.phone() ? 'home' : 'pair';
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
    sameStream(c, next, function (pick) {
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

  // ------------------------------------------------------- player controls
  //
  // Stremio-style: a seek bar and a row of buttons over the video, and menus
  // (subtitles, audio, streams, episodes) that open as a sheet on the right.
  //
  // Remote: Left / Right seek (hold on for bigger jumps), OK pauses, Up /
  // Down bring up the buttons. Back closes a menu, then hides the buttons,
  // then leaves the video.

  var K_SUBSIZE = 'anymexplus_tv_subsize', K_PREF = 'anymexplus_tv_trackpref';
  var subSize = load(K_SUBSIZE, 100);
  var pref = load(K_PREF, { sub: '', audio: '' });   // languages you picked last
  var pmode = null;         // the open menu: subs | audio | streams | eps | servers
  var pTarget = null;       // streams menu: the episode it lists streams for
  var pLang = null;         // subtitles menu: the language shown on the right
  var pPart = -1;           // episodes menu: the season shown
  var menuBack = null, menuToken = 0, menuCols = {};
  var osdTimer = null;
  var seekTo = null, seekTimer = null, seekHits = 0, seekAt = 0;

  function osdShown() { return !$('osd').classList.contains('away'); }

  function wake() {
    $('osd').classList.remove('away');
    $('player').classList.add('ctl');   // subtitles move up above the controls
    clearTimeout(osdTimer);
    osdTimer = setTimeout(sleepOsd, 5000);
  }

  function sleepOsd() {
    if (A.screen() !== 'player') return;
    var v = A.video(), p = A.playing();
    if (tracksOpen || seekTo != null || !v || v.paused || (p && p.error)) { osdTimer = setTimeout(sleepOsd, 2000); return; }
    hideOsd();
  }

  function hideOsd() {
    clearTimeout(osdTimer);
    commitSeek();
    $('osd').classList.add('away');
    $('player').classList.remove('ctl');
    A.setFocus(null);
  }

  function hm(d) {
    var h = d.getHours(), m = d.getMinutes(), ap = h >= 12 ? 'PM' : 'AM';
    h = h % 12 || 12;
    return h + ':' + (m < 10 ? '0' : '') + m + ' ' + ap;
  }

  // Every second, and after each key, with the player's state from app.js.
  function drawPlayer(s) {
    var osd = $('osd');
    if (s.paused) osd.classList.add('paused'); else osd.classList.remove('paused');
    var line = s.error ? 'Problem: ' + s.error : (s.ended ? 'Finished' : (s.waiting && !s.paused ? 'Loading…' : ''));
    if (s.note) line += (line ? '   ' : '') + '(' + s.note + ')';
    text($('pstate'), line);
    var pos = seekTo != null ? seekTo : s.pos, dur = s.dur;
    var pct = dur ? Math.min(100, Math.max(0, pos / dur * 100)) : 0;
    $('pfill').style.width = pct + '%';
    $('pknob').style.left = pct + '%';
    var v = A.video(), buf = 0;
    try { if (v && v.buffered && v.buffered.length && dur) buf = v.buffered.end(v.buffered.length - 1) / dur * 100; } catch (e) { /* ignore */ }
    $('pbuf').style.width = Math.min(100, Math.max(0, buf)) + '%';
    text($('ppos'), fmt(s.pos));
    text($('pseekto'), seekTo != null ? fmt(seekTo) + '   (' + (seekTo >= s.pos ? '+' : '−') + fmt(Math.abs(seekTo - s.pos)) + ')' : '');
    text($('pdur'), dur ? fmt(dur) : '');
    var now = new Date(), clock = hm(now);
    if (dur > 0) clock += '\nEnds at ' + hm(new Date(now.getTime() + Math.max(0, dur - s.pos) * 1000));
    text($('pclock'), clock);
    updateButtons();
  }

  function mine() { return !!(cur && A.playing() && A.playing().local); }

  function updateButtons() {
    var m = mine();
    hide($('bnext'), !(m && cur.type !== 'movie' && nextVideo(cur)));
    hide($('bsubs'), !m);
    hide($('baudio'), !m);
    hide($('bsrc'), !(m || hasServers()));
    text($('bsrcl'), m ? 'Streams' : 'Source');
    hide($('beps'), !(m && cur.type !== 'movie' && cur.videos.length > 1));
    var f = A.focused();
    if (f && $('pctl').contains(f) && f.classList.contains('hidden')) focusOn($('bpp'));
  }

  // ---- seeking: each press moves a target; the jump happens when you stop.

  function seekStep(dir) {
    var v = A.video();
    if (!v || !A.playing().url) return;
    var dur = isFinite(v.duration) ? v.duration : 0, now = Date.now();
    seekHits = now - seekAt < 700 ? seekHits + 1 : 0;
    seekAt = now;
    var step = seekHits < 4 ? 10 : (seekHits < 12 ? 30 : 60);
    var to = Math.max(0, (seekTo != null ? seekTo : (v.currentTime || 0)) + dir * step);
    if (dur) to = Math.min(to, Math.max(0, dur - 2));
    seekTo = to;
    clearTimeout(seekTimer);
    seekTimer = setTimeout(commitSeek, 800);
  }

  function commitSeek() {
    clearTimeout(seekTimer);
    if (seekTo == null) return;
    var to = seekTo;
    seekTo = null;
    seekHits = 0;
    A.command({ cmd: 'seekTo', to: to });
  }

  // Keys while the player is up. True = taken care of here.
  function playerKey(k) {
    if (tracksOpen) {
      if (k === 'back') closeTracks(true); else key(k);
      return true;
    }
    if (k === 'back') {
      // Buttons up: Back hides them. Only a Back with nothing on screen leaves.
      if (osdShown()) { hideOsd(); return true; }
      return false;
    }
    var f = A.focused();
    var up = osdShown() && f && $('osd').contains(f);
    wake();
    if (!up) {
      if (k === 'left' || k === 'right') { focusOn($('pseek')); seekStep(k === 'left' ? -1 : 1); }
      else if (k === 'ok') { A.command({ cmd: 'toggle' }); focusOn($('bpp')); }
      else focusOn($('bpp'));
      return true;
    }
    if (f === $('pseek')) {
      if (k === 'left' || k === 'right') { seekStep(k === 'left' ? -1 : 1); return true; }
      if (k === 'ok') { if (seekTo != null) commitSeek(); else A.command({ cmd: 'toggle' }); return true; }
      if (k === 'up') return true;
    }
    key(k);
    return true;
  }

  // Buttons and menu items (from press()).
  function playerAct(act, f) {
    if (act === 'pp') A.command({ cmd: 'toggle' });
    else if (act === 'seek') { if (seekTo != null) commitSeek(); else A.command({ cmd: 'toggle' }); }
    else if (act === 'pnext') playNext();
    else if (act === 'psubs') openMenu('subs');
    else if (act === 'paudio') openMenu('audio');
    else if (act === 'psrc') { if (mine()) openMenu('streams', cur.video); else if (hasServers()) openMenu('servers'); }
    else if (act === 'peps') openMenu('eps');
    else if (act === 'sublang') pickLang(f._lang);
    else if (act === 'subfx') subEffect(f._fx);
    else if (act === 'pstream') switchStream(f._stream);
    else if (act === 'ppart') { pPart = f._ppart; fillEps(); var e = menuCols.eps && items(menuCols.eps)[0]; if (e) focusOn(e); }
    else if (act === 'pep') openMenu('streams', f._video);
    else return false;
    return true;
  }

  // ---- menus

  function openMenu(mode, target) {
    if (mode !== 'servers' && !mine()) return;
    commitSeek();
    menuBack = A.focused() && $('osd').contains(A.focused()) ? A.focused() : null;
    pmode = mode;
    pTarget = target || null;
    pLang = null;
    pPart = -1;
    tracksOpen = true;
    hide($('tpanel'), false);
    A.setFocus(null);
    renderMenu();
  }

  // back: opened by you with Back, so the highlight returns to the button.
  function closeTracks(back) {
    if (!tracksOpen) return;
    tracksOpen = false;
    pmode = null;
    menuToken++;
    hide($('tpanel'), true);
    A.setFocus(null);
    if (back && A.screen() === 'player') {
      wake();
      if (menuBack && shown(menuBack, $('osd'))) focusOn(menuBack); else focusOn($('bpp'));
    }
    menuBack = null;
  }

  function column(cls, head) {
    var c = el('div', 'grp pcol' + (cls ? ' ' + cls : ''));
    c.setAttribute('data-dir', 'v');
    c.setAttribute('data-col', '1');
    if (head) c.appendChild(el('div', 'thead', head));
    $('tlist').appendChild(c);
    return c;
  }

  function mitem(parent, label, act, key, on) {
    var d = el('div', 'fo sitem' + (on ? ' on' : ''), label);
    d.setAttribute('data-act', act);
    d._key = key;
    parent.appendChild(d);
    return d;
  }

  function onItem(col) {
    var its = items(col);
    for (var i = 0; i < its.length; i++) if (its[i].classList.contains('on')) return its[i];
    return its[0] || null;
  }

  // Draws the open menu again, keeping the highlight where it was.
  function renderMenu() {
    if (!tracksOpen) return;
    var panel = $('tpanel'), list = $('tlist');
    var f = A.focused(), keep = f && panel.contains(f) ? f._key : null;
    menuToken++;
    clear(list);
    menuCols = {};
    text($('tpmsg'), '');
    panel.classList.remove('wide');
    var want = null;
    if (pmode === 'servers') want = renderServers();
    else if (!cur) { closeTracks(true); return; }
    else if (pmode === 'subs') want = renderSubs();
    else if (pmode === 'audio') want = renderAudio();
    else if (pmode === 'streams') want = renderStreams();
    else if (pmode === 'eps') want = renderEps();
    var its = list.querySelectorAll('.fo'), pick = null;
    for (var i = 0; i < its.length && keep; i++) if (its[i]._key === keep) pick = its[i];
    pick = pick || want || its[0];
    if (pick) focusOn(pick);
  }

  // A menu item got the highlight: the subtitles menu shows that language's
  // choices, the episodes menu that season.
  function menuFocus(node) {
    if (pmode === 'subs' && node._lang != null && node._lang !== pLang) { pLang = node._lang; fillVariants(); }
    else if (pmode === 'eps' && node._ppart != null && node._ppart !== pPart) { pPart = node._ppart; fillEps(); }
  }

  // ---- the phone's servers (Play on TV from an anime extension)

  function renderServers() {
    text($('tptitle'), 'Source');
    var col = column('', 'Servers from your phone'), pick = null;
    for (var i = 0; i < srv.list.length; i++) {
      var d = mitem(col, String(srv.list[i]), 'server', 'srv' + i, srv.on === i);
      d._server = i;
      if (srv.on === i) pick = d;
    }
    return pick;
  }

  function buildServers() { if (tracksOpen && pmode === 'servers') renderMenu(); }

  function pickServer(i) {
    if (!hasServers()) { closeTracks(true); return; }
    var name = String(srv.list[i]);
    if (i !== srv.on) {
      srv.on = i;
      A.send({ t: 'anime', cmd: 'server', i: i });
      A.setNote('Switching to ' + name + '…');
      setTimeout(function () { A.setNote(''); }, 5000);
    }
    closeTracks(true);
  }

  // ---- subtitles: languages | choices in that language | delay and size

  var LANGS = { eng: 'English', spa: 'Spanish', fre: 'French', fra: 'French', ger: 'German', deu: 'German', ita: 'Italian',
    por: 'Portuguese', pob: 'Portuguese (Brazil)', jpn: 'Japanese', kor: 'Korean', chi: 'Chinese', zho: 'Chinese',
    rus: 'Russian', ara: 'Arabic', hin: 'Hindi', dut: 'Dutch', nld: 'Dutch', pol: 'Polish', tur: 'Turkish',
    swe: 'Swedish', nor: 'Norwegian', dan: 'Danish', fin: 'Finnish', gre: 'Greek', ell: 'Greek', heb: 'Hebrew',
    ind: 'Indonesian', vie: 'Vietnamese', tha: 'Thai', ukr: 'Ukrainian', rum: 'Romanian', ron: 'Romanian',
    hun: 'Hungarian', cze: 'Czech', ces: 'Czech', en: 'English', es: 'Spanish', fr: 'French', de: 'German',
    it: 'Italian', pt: 'Portuguese', ja: 'Japanese', ko: 'Korean', zh: 'Chinese', ru: 'Russian', ar: 'Arabic' };

  function langName(code) {
    var c = String(code || '').toLowerCase();
    if (LANGS[c]) return LANGS[c];
    var head = c.split(/[-_]/)[0];
    if (LANGS[head]) return LANGS[head];
    return code ? String(code) : 'Unknown';
  }

  // [{key, label, items: [{label, key, data, on}]}]
  function subGroups(c) {
    var out = [], by = {}, i;
    function group(key, label) {
      if (!by[key]) { by[key] = { key: key, label: label, items: [] }; out.push(by[key]); }
      return by[key];
    }
    group('off', 'Off');
    if (c.mkv && c.mkv.subs.length) {
      var e = group('emb', 'In the video');
      for (i = 0; i < c.mkv.subs.length; i++) {
        e.items.push({ label: window.AXMkv.label(c.mkv.subs[i], i + 1), key: 'emb' + i, data: { embI: i }, on: c.subOn === 'emb' + i });
      }
    } else if (!c.mkv && !c.mkvLoading) {
      group('emb', 'In the video').items.push({ label: 'Next track' + (c.emb >= 0 ? ' (now: ' + (c.emb + 1) + ')' : ''),
        key: 'embn', data: { emb: true }, on: c.subOn === 'emb' });
    }
    var subs = c.subs.slice();
    subs.sort(function (a, b) {
      var an = langName(a.lang), bn = langName(b.lang);
      var ap = an === pref.sub ? 0 : (an === 'English' ? 1 : 2), bp = bn === pref.sub ? 0 : (bn === 'English' ? 1 : 2);
      return ap - bp || an.localeCompare(bn);
    });
    for (i = 0; i < subs.length; i++) {
      var name = langName(subs[i].lang), g = group('l:' + name, name);
      if (g.items.length >= 15) continue;
      g.items.push({ label: name + ' ' + (g.items.length + 1) + (subs[i].from ? '  ·  ' + subs[i].from : ''),
        key: 'u:' + subs[i].url, data: { url: subs[i].url, label: name }, on: c.subOn === subs[i].url });
    }
    return out;
  }

  function groupOn(g, c) {
    if (g.key === 'off') return c.subOn == null;
    for (var i = 0; i < g.items.length; i++) if (g.items[i].on) return true;
    return false;
  }

  function renderSubs() {
    var c = cur, groups = subGroups(c), i, pick = null;
    text($('tptitle'), 'Subtitles');
    $('tpanel').classList.add('wide');
    if (c.mkvLoading) text($('tpmsg'), 'Reading the subtitles inside the video…');
    if (pLang == null) {
      for (i = 0; i < groups.length; i++) if (groupOn(groups[i], c)) pLang = groups[i].key;
      if (pLang == null) pLang = 'off';
    }
    var langs = menuCols.langs = column('narrow', 'Language');
    for (i = 0; i < groups.length; i++) {
      var d = mitem(langs, groups[i].label + (groups[i].items.length > 1 ? '  (' + groups[i].items.length + ')' : ''),
        'sublang', 'g:' + groups[i].key, groupOn(groups[i], c));
      d._lang = groups[i].key;
      if (groups[i].key === pLang) { d.classList.add('sel'); pick = d; }
    }
    menuCols.vars = column('', '');
    menuCols.groups = groups;
    fillVariants();
    var fx = menuCols.fx = column('narrow', 'Settings');
    fx.appendChild(el('div', 'fxval', ''));
    var fxs = [['later', 'Delay +0.25 s'], ['earlier', 'Delay −0.25 s'], ['bigger', 'Bigger'], ['smaller', 'Smaller'], ['reset', 'Reset']];
    for (i = 0; i < fxs.length; i++) mitem(fx, fxs[i][1], 'subfx', 'fx:' + fxs[i][0], false)._fx = fxs[i][0];
    showFx();
    return pick;
  }

  function fillVariants() {
    var col = menuCols.vars, groups = menuCols.groups || [];
    if (!col) return;
    clear(col);
    var langs = menuCols.langs ? items(menuCols.langs) : [];
    for (var j = 0; j < langs.length; j++) {
      if (langs[j]._lang === pLang) langs[j].classList.add('sel'); else langs[j].classList.remove('sel');
    }
    var g = null;
    for (var i = 0; i < groups.length; i++) if (groups[i].key === pLang) g = groups[i];
    col.appendChild(el('div', 'thead', g ? g.label : ''));
    if (!g || g.key === 'off') { col.appendChild(el('div', 'pmsg dim', g ? 'Press OK to turn subtitles off.' : '')); return; }
    for (var k = 0; k < g.items.length; k++) {
      var it = g.items[k];
      mitem(col, it.label, 'sub', it.key, it.on)._sub = it.data;
    }
  }

  function showFx() {
    var box = menuCols.fx && menuCols.fx.querySelector('.fxval');
    if (!box) return;
    var d = (cur && cur.delay) || 0;
    var s = 'Delay: ' + (d > 0 ? '+' : (d < 0 ? '−' : '')) + Math.abs(d).toFixed(2) + ' s\nSize: ' + subSize + '%';
    if (cur && cur.subOn != null && String(cur.subOn).indexOf('emb') === 0) s += '\nDelay and size work on subtitle files only';
    text(box, s);
  }

  function applySubSize() {
    var n = $('subs');
    if (n) n.style.fontSize = Math.round(54 * subSize / 100) + 'px';
  }

  function subEffect(fx) {
    var c = cur;
    if (!c) return;
    if (fx === 'later') c.delay = Math.round(((c.delay || 0) + 0.25) * 100) / 100;
    else if (fx === 'earlier') c.delay = Math.round(((c.delay || 0) - 0.25) * 100) / 100;
    else if (fx === 'bigger') subSize = Math.min(200, subSize + 10);
    else if (fx === 'smaller') subSize = Math.max(50, subSize - 10);
    else if (fx === 'reset') { c.delay = 0; subSize = 100; }
    A.playing().subDelay = -(c.delay || 0);   // app.js shows a cue at time + subDelay
    save(K_SUBSIZE, subSize);
    applySubSize();
    showFx();
  }

  // OK on a language: off, or its first choice (or the one already on).
  function pickLang(key) {
    if (key === 'off') { pickSub({ off: true }); return; }
    var groups = menuCols.groups || [], g = null, i;
    for (i = 0; i < groups.length; i++) if (groups[i].key === key) g = groups[i];
    if (!g || !g.items.length) return;
    pLang = key;
    var on = null;
    for (i = 0; i < g.items.length; i++) if (g.items[i].on) on = g.items[i];
    if (!on) { pickSub(g.items[0].data); on = g.items[0]; }
    else fillVariants();
    var its = menuCols.vars ? items(menuCols.vars) : [];
    for (i = 0; i < its.length; i++) if (its[i]._key === on.key) { focusOn(its[i]); return; }
  }

  // auto: picked by the app from your last language, not by you.
  function pickSub(s, auto) {
    var c = cur;
    if (!c || !s) return;
    if (!auto) c.subTouched = true;
    if (s.off) { c.subOn = null; A.clearSubs(); A.selectSub(-1); }
    else if (s.embI != null) { c.emb = s.embI; c.subOn = 'emb' + s.embI; A.clearSubs(); A.selectSub(s.embI); }
    else if (s.emb) { c.emb++; c.subOn = 'emb'; A.clearSubs(); A.selectSub(c.emb); checkSub(c, c.emb); }
    else { c.subOn = s.url; c.subLabel = s.label; A.loadSubs(s.url, s.label); A.playing().subDelay = -(c.delay || 0); }
    if (!auto && !s.emb) {
      pref.sub = s.off ? 'off' : (s.embI != null ? langName(c.mkv.subs[s.embI].lang) : s.label);
      save(K_PREF, pref);
    }
    if (tracksOpen && pmode === 'subs') renderMenu();
  }

  // Turns on subtitles in the language you used last: inside the video
  // first, else a subtitle file from the stream or an addon.
  function autoSub(c) {
    if (cur !== c || c.subTouched || c.subOn != null || c.mkvLoading) return;
    if (!pref.sub || pref.sub === 'off') return;
    var i;
    if (c.mkv) {
      for (i = 0; i < c.mkv.subs.length; i++) {
        if (!c.mkv.subs[i].forced && langName(c.mkv.subs[i].lang) === pref.sub) { pickSub({ embI: i }, true); return; }
      }
    }
    for (i = 0; i < c.subs.length; i++) {
      if (langName(c.subs[i].lang) === pref.sub) { pickSub({ url: c.subs[i].url, label: pref.sub }, true); return; }
    }
  }

  // The TV says no once there are no more tracks: go back to the start.
  function checkSub(c, i) {
    setTimeout(function () {
      if (cur !== c || c.emb !== i || !A.playing().subNote) return;
      c.emb = -1; c.subOn = null;
      A.selectSub(-1);
      A.playing().subNote = '';
      if (tracksOpen && pmode === 'subs') renderMenu();
    }, 1200);
  }

  // ---- audio

  function renderAudio() {
    var c = cur, v = A.video(), col = column('', ''), i, pick = null, tracks = v && v.audioTracks, mkv = c.mkv;
    text($('tptitle'), 'Audio');
    if (mkv && mkv.audio.length) {
      for (i = 0; i < mkv.audio.length; i++) {
        var d = mitem(col, window.AXMkv.label(mkv.audio[i], i + 1), 'audio', 'a' + i, c.aud === i);
        d._audio = { i: i };
        if (c.aud === i) pick = d;
      }
    } else if (tracks && tracks.length > 1) {
      for (i = 0; i < tracks.length; i++) {
        var on = tracks[i].enabled === true;
        var t = mitem(col, 'Audio ' + (i + 1) + (tracks[i].language ? '  ·  ' + langName(tracks[i].language) : '') +
          (tracks[i].label ? '  ·  ' + tracks[i].label : ''), 'audio', 'a' + i, on);
        t._audio = { i: i };
        if (on) pick = t;
      }
    } else if (c.mkvLoading) {
      col.appendChild(el('div', 'pmsg dim', 'Reading the track list…'));
    } else {
      mitem(col, 'Next audio track (now: ' + (c.aud + 1) + ')', 'audio', 'anext', false)._audio = { next: true };
    }
    return pick;
  }

  function pickAudio(a, auto) {
    var c = cur;
    if (!c || !a) return;
    if (a.next) {
      c.aud++;
      A.selectAudio(c.aud);
      var i = c.aud;
      setTimeout(function () {
        if (cur !== c || c.aud !== i || !A.playing().audioNote) return;
        c.aud = 0;
        A.selectAudio(0);
        if (tracksOpen && pmode === 'audio') renderMenu();
      }, 1200);
    } else {
      c.aud = a.i;
      A.selectAudio(a.i);
      if (!auto && c.mkv && c.mkv.audio[a.i]) { pref.audio = langName(c.mkv.audio[a.i].lang); save(K_PREF, pref); }
    }
    setTimeout(function () { if (tracksOpen && pmode === 'audio' && cur === c) renderMenu(); }, 300);
  }

  // The audio language you picked last, when the file has it.
  function autoAudio(c) {
    if (!c.mkv || !pref.audio) return;
    var d = c.mkv.audio[c.aud];
    if (d && langName(d.lang) === pref.audio) return;
    for (var i = 0; i < c.mkv.audio.length; i++) {
      if (langName(c.mkv.audio[i].lang) === pref.audio) { pickAudio({ i: i }, true); return; }
    }
  }

  // ---- streams: switch to another stream of this episode (same spot), or
  // pick one for another episode.

  function renderStreams() {
    var c = cur, video = pTarget || c.video, col = column('', ''), token = menuToken;
    var same = video.id === c.videoId, url = A.playing().url, count = 0, hidden = 0;
    text($('tptitle'), 'Streams' + (c.type !== 'movie' && video.season != null ? '  ·  ' + epLabel(video) +
      (video.title ? '  ·  ' + video.title : '') : ''));
    text($('tpmsg'), 'Finding streams…');
    var cache = c.streams || (c.streams = {});
    function add(s) {
      var d = el('div', 'fo sitem' + (same && s.url === url ? ' on' : ''));
      d.setAttribute('data-act', 'pstream');
      d.setAttribute('data-name', s.name);
      d._key = 's:' + s.url;
      d._stream = s;
      d.appendChild(el('div', 'sname', s.name));
      if (s.desc) d.appendChild(el('div', 'sdesc', s.desc));
      col.appendChild(d);
      count++;
      var f = A.focused();
      if (!f || !$('tpanel').contains(f) || (same && s.url === url)) focusOn(d);
    }
    function msg(asked) {
      if (count) { text($('tpmsg'), same ? 'Picking one keeps your place' : ''); return; }
      if (!asked) text($('tpmsg'), 'No stream addons for this yet. Add them in AnymeX+ on your phone.');
      else if (hidden) text($('tpmsg'), 'Nothing the TV can play by itself (' + hidden + ' torrent-only streams).');
      else text($('tpmsg'), 'No streams found.');
    }
    var have = cache[video.id];
    if (have && have.done) {
      for (var i = 0; i < have.list.length; i++) add(have.list[i]);
      hidden = have.hidden;
      msg(have.asked);
      return null;
    }
    var got = { list: [], hidden: 0, done: false };
    collectStreams(c.type, video.id, function (streams, addonName) {
      for (var j = 0; j < streams.length; j++) {
        if (!playable(streams[j])) { got.hidden++; continue; }
        var s = streamInfo(streams[j], addonName);
        s.video = video;
        got.list.push(s);
        if (token === menuToken && cur === c) add(s);
      }
      hidden = got.hidden;
    }, function (asked) {
      got.done = true;
      got.asked = asked;
      if (cur === c) cache[video.id] = got;
      if (token === menuToken && cur === c) msg(asked);
    });
    return null;
  }

  function switchStream(s) {
    var c = cur;
    if (!c || !s) return;
    var same = s.video.id === c.videoId;
    if (same && s.url === A.playing().url) { closeTracks(true); return; }
    var v = A.video();
    saveProgress(false);
    s.start = same ? ((v && v.currentTime) || 0) : startFor(s.video.id);
    var keep = same && c.subOn && String(c.subOn).indexOf('emb') !== 0 ? { url: c.subOn, label: c.subLabel, delay: c.delay } : null;
    closeTracks();
    playStream(s, keep);
  }

  // The next episode now: the same kind of stream if there is one, else the
  // list of its streams.
  function playNext() {
    var c = cur;
    if (!c) return;
    var next = nextVideo(c);
    if (!next) return;
    saveProgress(false);
    A.setNote('Finding the next episode…');
    sameStream(c, next, function (pick) {
      if (cur !== c) return;
      A.setNote('');
      if (pick) { pick.video = next; pick.start = 0; playStream(pick); return; }
      wake();
      openMenu('streams', next);
    });
  }

  // A stream for [video] like the one playing now (same binge group, or same
  // addon and name).
  function sameStream(c, video, done) {
    var pick = null;
    collectStreams(c.type, video.id, function (streams, addonName) {
      for (var i = 0; i < streams.length && !pick; i++) {
        if (!playable(streams[i])) continue;
        var s = streamInfo(streams[i], addonName);
        if ((c.binge && s.binge === c.binge) || (!c.binge && s.addon === c.addon && s.name === c.name)) pick = s;
      }
    }, function () { done(pick); });
  }

  // ---- episodes: seasons | episodes; picking one lists its streams.

  function renderEps() {
    var c = cur, ps = parts(c.videos), i, j, here = -1;
    text($('tptitle'), 'Episodes');
    for (i = 0; i < ps.length && here < 0; i++) {
      for (j = 0; j < ps[i].videos.length; j++) if (ps[i].videos[j].id === c.videoId) { here = i; break; }
    }
    if (pPart < 0 || !ps[pPart]) pPart = here >= 0 ? here : 0;
    menuCols.parts = ps;
    var pick = null;
    if (ps.length > 1) {
      var pc = menuCols.pcol = column('narrow', 'Season');
      for (i = 0; i < ps.length; i++) {
        var d = mitem(pc, ps[i].label, 'ppart', 'p' + i, i === here);
        d._ppart = i;
        if (i === pPart) d.classList.add('sel');
      }
    } else menuCols.pcol = null;
    menuCols.eps = column('', '');
    fillEps();
    var its = items(menuCols.eps);
    for (i = 0; i < its.length; i++) if (its[i].classList.contains('on')) pick = its[i];
    return pick;
  }

  function fillEps() {
    var col = menuCols.eps, ps = menuCols.parts || [];
    if (!col || !ps[pPart]) return;
    clear(col);
    if (menuCols.pcol) {
      var pcs = items(menuCols.pcol);
      for (var k = 0; k < pcs.length; k++) { if (pcs[k]._ppart === pPart) pcs[k].classList.add('sel'); else pcs[k].classList.remove('sel'); }
    }
    col.appendChild(el('div', 'thead', ps[pPart].label));
    var now = Date.now(), list = ps[pPart].videos;
    for (var i = 0; i < list.length; i++) {
      var v = list[i];
      var d = mitem(col, 'E' + v.episode + '  ·  ' + (v.title || 'Episode ' + v.episode) + (v.released > now ? '  ·  not out yet' : ''),
        'pep', 'e:' + v.id, v.id === cur.videoId);
      d._video = v;
    }
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
    if (bundle && bundle.anime) {
      left++;
      var arow = rowEl('Anime');
      box.appendChild(arow);
      anilist('query($q:String){Page(perPage:20){media(search:$q,type:ANIME,isAdult:false,sort:[SEARCH_MATCH]){' +
        AL_FIELDS + '}}}', { q: q }, function (list) {
        if (token !== searchToken) return;
        var cards = cardsFromAnilist(list);
        fillRow(arow, cards);
        found += cards.length;
        if (--left === 0) text($('shint'), found ? '' : 'Nothing found for "' + q + '".');
      });
    }
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
      lines.push('Anime rows   ' + (bundle.anime ? 'yes (streams from your Stremio addons, and your extensions through the phone or PC)' : 'update AnymeX+ on the phone'));
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
    if (m.t === 'animeEps') { onAnimeEps(m); return true; }
    if (m.t === 'extServers') { onExtServers(m); return true; }
    if (m.t === 'animePlay') return true;   // older idea: the phone played it
    if (m.t === 'servers') {
      srv = { id: m.id, list: m.list || [], on: Number(m.on) };
      setHint('');
      buildServers();
      return true;
    }
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
    for (var q in extAsks) if (extAsks.hasOwnProperty(q)) { extAsks[q].err = 'Your ' + (A.peer() || 'phone') + ' went away.'; finishExt(q); }
    updateStatus();
    if (A.screen() === 'settings') showSettings();
  }

  function helloExtra() {
    var p = A.phone();
    return { sync: true, anime: true, ext: true, hasKey: !!(p && p.key), have: bundleHash, from: (bundle && bundle.from) || '' };
  }

  function start() {
    applySubSize();
    var input = $('sq');
    input.addEventListener('input', onInput);
    input.addEventListener('change', function () { runSearch(input.value); });
    input.addEventListener('blur', function () { runSearch(input.value); });
    // The TV's keyboard closed (Back, or its own hide button): let go of the
    // box so the arrows move around again.
    document.addEventListener('keyboardStateChange', function (e) {
      var d = e && e.detail;
      if (d && d.visibility === false && document.activeElement === input) input.blur();
    });
  }

  return {
    screens: SCREENS, has: has, start: start, enter: enter, key: key, home: home,
    onMessage: onMessage, onConnected: onConnected, onDisconnected: onDisconnected, helloExtra: helloExtra,
    tick: tick, ended: ended, leftPlayer: leftPlayer, playerKey: playerKey, wake: wake, drawPlayer: drawPlayer,
    // for tests
    _test: { parts: parts, mappingFromAniZip: mappingFromAniZip, imdbEpisode: imdbEpisode, shownRows: shownRows,
      extTarget: extTarget, alTarget: alTarget, setDet: function (d) { det = d; } },
    _mergeContinue: mergeContinue, _cleanText: cleanText, _watchedLine: watchedLine,
    _supports: supports, _applyProgress: applyProgress, _baseOf: baseOf
  };
};
