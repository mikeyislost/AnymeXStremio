/* AnymeX+ TV.
 *
 * A small web app for LG webOS. It connects out to AnymeX+ on the phone
 * (the phone runs a little server), takes remote presses and "play this"
 * requests from it, plays video with the TV's own player and reports back
 * what it is doing, so the phone can keep your watch progress.
 *
 * browse.js adds browsing on the TV itself (rows, details, streams) with
 * what the phone has synced over; gcm.js opens that locked sync.
 *
 * Written in old-style JavaScript on purpose so it runs on older webOS too.
 */
(function () {
  'use strict';

  var APP_VERSION = '0.0.1'; // replaced by the build
  var DEFAULT_PORT = 41733;
  var STORE_KEY = 'anymexplus_tv_phone';
  var PLAYED_KEY = 'anymexplus_tv_played';

  function $(id) { return document.getElementById(id); }
  function text(el, s) { el.textContent = s; }

  // ---------------------------------------------------------------- TV info

  var info = { app: APP_VERSION, userAgent: navigator.userAgent };

  function readDeviceInfo() {
    var sys = window.webOSSystem || window.PalmSystem;
    if (sys && sys.deviceInfo) {
      try {
        var d = JSON.parse(sys.deviceInfo);
        info.model = d.modelName;
        info.platformVersion = d.platformVersion;
        info.screen = d.screenWidth + 'x' + d.screenHeight;
      } catch (e) { /* ignore */ }
    }
    var m = /Chrome\/(\d+)/.exec(navigator.userAgent);
    if (m) info.chrome = m[1];
    info.window = window.innerWidth + 'x' + window.innerHeight;
    var v = document.createElement('video');
    var types = {
      mp4_h264: 'video/mp4; codecs="avc1.640028, mp4a.40.2"',
      mp4_hevc: 'video/mp4; codecs="hvc1.1.6.L120.90"',
      mp4_av1: 'video/mp4; codecs="av01.0.08M.08"',
      webm_vp9: 'video/webm; codecs="vp9"',
      hls: 'application/vnd.apple.mpegurl',
      ac3: 'audio/mp4; codecs="ac-3"',
      eac3: 'audio/mp4; codecs="ec-3"'
    };
    var can = {};
    for (var k in types) {
      if (types.hasOwnProperty(k)) can[k] = v.canPlayType(types[k]) || 'no';
    }
    info.canPlay = can;
    info.audioTracksApi = 'audioTracks' in v;
    // The browser part can't tell what LG's player really plays (it says no
    // to MKV, which plays fine), so what has actually played is kept too.
    try { info.played = JSON.parse(localStorage.getItem(PLAYED_KEY) || '{}') || {}; } catch (e) { info.played = {}; }
  }

  // Calls a webOS system service. Fails quietly anywhere else (a browser).
  function luna(uri, params, done) {
    var Bridge = window.WebOSServiceBridge || window.PalmServiceBridge;
    if (!Bridge) { done(null); return; }
    try {
      var b = new Bridge();
      b.onservicecallback = function (raw) {
        try { done(JSON.parse(raw)); } catch (e) { done(null); }
      };
      b.call(uri, JSON.stringify(params || {}));
    } catch (e) { done(null); }
  }

  function readSystemInfo() {
    luna('luna://com.webos.service.tv.systemproperty/getSystemInfo',
      { keys: ['modelName', 'firmwareVersion', 'sdkVersion', 'UHD'] }, function (r) {
        if (r && r.returnValue !== false) {
          if (r.modelName) info.model = r.modelName;
          info.firmware = r.firmwareVersion;
          info.sdkVersion = r.sdkVersion;
          info.uhd = r.UHD;
        } else if (r) {
          info.systemInfoError = r.errorText || 'refused';
        }
        showInfo();
      });
    luna('luna://com.palm.connectionmanager/getStatus', {}, function (r) {
      if (r && r.returnValue !== false) {
        var w = r.wired || {}, f = r.wifi || {};
        info.ip = (w.state === 'connected' && w.ipAddress) || (f.state === 'connected' && f.ipAddress) || '';
        info.network = w.state === 'connected' ? 'wired' : (f.state === 'connected' ? 'wifi' : 'none');
        if (!typed && info.ip) {
          // Start the typed address with this TV's network, e.g. "192.168.1."
          typed = info.ip.replace(/\d+$/, '');
          showTyped();
        }
      }
      showInfo();
    });
  }

  // webOS 26 reports itself as platform 11.x, webOS 25 as 10.x, and so on.
  function webosName() {
    var v = info.sdkVersion || info.platformVersion || '';
    var major = parseInt(v, 10);
    var names = { 4: 'webOS 4 (2018)', 5: 'webOS 5 (2020)', 6: 'webOS 6 (2021)', 7: 'webOS 22', 8: 'webOS 23',
      9: 'webOS 24', 10: 'webOS 25', 11: 'webOS 26', 12: 'webOS 27' };
    return (names[major] || 'webOS') + (v ? ' (' + v + ')' : '');
  }

  function showInfo() {
    var lines = [
      'Model      ' + (info.model || '?'),
      'System     ' + webosName(),
      'Firmware   ' + (info.firmware || '?'),
      'Browser    Chrome ' + (info.chrome || '?'),
      'Address    ' + (info.ip || '?') + (info.network ? ' (' + info.network + ')' : ''),
      'Screen     ' + (info.screen || info.window),
      'App        ' + APP_VERSION,
      '',
      'Can play'
    ];
    for (var k in info.canPlay) {
      if (info.canPlay.hasOwnProperty(k)) lines.push('  ' + k + ': ' + info.canPlay[k]);
    }
    var played = [];
    for (var p in info.played) {
      if (info.played.hasOwnProperty(p)) played.push(p + ': ' + info.played[p]);
    }
    if (played.length) lines.push('', 'Has played', '  ' + played.join(', '));
    text($('info'), lines.join('\n'));
  }

  // ------------------------------------------------------------ phone link

  var ws = null;
  var connected = false;
  var phone = null;      // {host, port, token}
  var retryTimer = null;
  var typed = '';
  var peerName = '';
  var B = null;          // browsing on the TV (browse.js)

  function loadPhone() {
    try {
      var p = JSON.parse(localStorage.getItem(STORE_KEY) || 'null');
      if (p && p.host) return p;
    } catch (e) { /* ignore */ }
    return null;
  }

  function savePhone() {
    try { localStorage.setItem(STORE_KEY, JSON.stringify(phone)); } catch (e) { /* ignore */ }
  }

  function setStatus(s) { text($('status'), s); }

  function send(msg) {
    if (ws && ws.readyState === 1) {
      try { ws.send(JSON.stringify(msg)); } catch (e) { /* ignore */ }
    }
  }

  function connect(reason) {
    if (!phone || !phone.host) return;
    clearTimeout(retryTimer);
    if (ws) { try { ws.onclose = null; ws.close(); } catch (e) { /* ignore */ } ws = null; }
    var url = 'ws://' + phone.host + ':' + (phone.port || DEFAULT_PORT) + '/tv';
    if (!connected) setStatus((reason || 'Connecting') + ' to ' + phone.host + '…');
    var sock;
    try { sock = new WebSocket(url); } catch (e) { setStatus('Bad address: ' + phone.host); return; }
    ws = sock;
    sock.onopen = function () {
      var hello = { t: 'hello', app: 'anymexplus-tv', v: APP_VERSION, token: phone.token || '', info: info };
      var extra = B.helloExtra();
      for (var k in extra) if (extra.hasOwnProperty(k)) hello[k] = extra[k];
      send(hello);
      if (!phone.token) setStatus('Check your phone and tap Allow.');
    };
    sock.onmessage = function (ev) {
      var m;
      try { m = JSON.parse(ev.data); } catch (e) { return; }
      if (m && m.t) onMessage(m);
    };
    sock.onclose = function () {
      if (ws !== sock) return;
      ws = null;
      var was = connected;
      connected = false;
      if (was && playing.url) {
        // Keep playing, and say nothing: the TV plays by itself, and a
        // phone that was only locked picks up again when it is back.
      } else if (was && screen === 'pair') {
        setStatus('The phone disconnected. Waiting for it to come back…');
      } else if (was) {
        // The TV carries on by itself; the phone joins again when it's back.
        B.onDisconnected();
      } else {
        setStatus('Waiting for AnymeX+ on ' + phone.host + '. Open TV Remote on the phone.');
      }
      retryTimer = setTimeout(function () { connect('Reconnecting'); }, 3000);
    };
    sock.onerror = function () { /* onclose follows */ };
  }

  function onMessage(m) {
    switch (m.t) {
      case 'welcome':
        connected = true;
        peerName = m.name || 'phone';
        if (m.token) phone.token = m.token;
        savePhone();
        setNote('');
        if (screen === 'pair') B.home();
        B.onConnected();
        sendState();
        break;
      case 'denied':
        setStatus('The phone said no. Try again from the phone.');
        break;
      case 'key': onKey(m.k); break;
      case 'play': playVideo(m); break;
      case 'player': playerCommand(m); break;
      case 'stop': leavePlayer(); break;
      case 'ping': send({ t: 'pong' }); break;
      default: B.onMessage(m);
    }
  }

  // The phone opens this app through LG's own phone link and passes its
  // address along, so nothing has to be typed.
  function onLaunch(ev) {
    var p = ev && ev.detail;
    if (typeof p === 'string') { try { p = JSON.parse(p); } catch (e) { p = null; } }
    if (!p && window.webOSSystem && window.webOSSystem.launchParams) {
      try { p = JSON.parse(window.webOSSystem.launchParams); } catch (e2) { p = null; }
    }
    if (!p && window.PalmSystem && window.PalmSystem.launchParams) {
      try { p = JSON.parse(window.PalmSystem.launchParams); } catch (e3) { p = null; }
    }
    var same = p && p.host && phone && connected && phone.host === String(p.host) &&
      (phone.port || DEFAULT_PORT) === (Number(p.port) || DEFAULT_PORT);
    if (p && p.host && !same) {
      // key: opens what the phone syncs over (logins, addons). It only ever
      // arrives this way, through LG's own phone link.
      phone = { host: String(p.host), port: Number(p.port) || DEFAULT_PORT, token: String(p.token || ''),
        key: String(p.key || '') };
      savePhone();
      connected = false;
      connect('Connecting');
    } else if (same && p.key && phone.key !== String(p.key)) {
      phone.key = String(p.key);
      savePhone();
      send({ t: 'need' });
    }
    var sys = window.webOSSystem || window.PalmSystem;
    if (sys && sys.activate) { try { sys.activate(); } catch (e4) { /* ignore */ } }
  }

  // --------------------------------------------------------------- screens

  var screen = 'pair';
  var presses = 0;

  function show(name) {
    screen = name;
    var all = ['pair', 'home', 'details', 'search', 'settings', 'player'];
    for (var i = 0; i < all.length; i++) {
      var el = $(all[i]);
      if (all[i] === name) el.classList.remove('hidden'); else el.classList.add('hidden');
    }
    if (name === 'pair') setFocus(firstFocusable());
    else if (name === 'player') setFocus(null);
    else B.enter(name);
    sendState();
  }

  function focusables() {
    var root = $(screen);
    var list = root.querySelectorAll('.key, .tile');
    var out = [];
    for (var i = 0; i < list.length; i++) out.push(list[i]);
    return out;
  }

  function firstFocusable() { var f = focusables(); return f.length ? f[0] : null; }

  var focused = null;
  function setFocus(el) {
    if (focused) focused.classList.remove('focus');
    focused = el;
    if (el) el.classList.add('focus');
  }

  // Moves the highlight to the nearest item in the pressed direction.
  function move(dx, dy) {
    var list = focusables();
    if (!list.length) return;
    if (!focused || list.indexOf(focused) < 0) { setFocus(list[0]); return; }
    var a = focused.getBoundingClientRect();
    var ax = a.left + a.width / 2, ay = a.top + a.height / 2;
    var best = null, bestScore = Infinity;
    for (var i = 0; i < list.length; i++) {
      if (list[i] === focused) continue;
      var b = list[i].getBoundingClientRect();
      var bx = b.left + b.width / 2, by = b.top + b.height / 2;
      var along = (bx - ax) * dx + (by - ay) * dy;       // distance the right way
      var across = Math.abs((bx - ax) * dy) + Math.abs((by - ay) * dx);
      if (along <= 1) continue;
      var score = along + across * 3;
      if (score < bestScore) { bestScore = score; best = list[i]; }
    }
    if (best) setFocus(best);
  }

  function press() {
    if (!focused) return;
    var act = focused.getAttribute('data-act');
    if (act === 'digit') { typed += focused.getAttribute('data-v'); showTyped(); }
    else if (act === 'del') { typed = typed.slice(0, -1); showTyped(); }
    else if (act === 'connect') {
      var host = typed.replace(/\.$/, '');
      if (/^\d{1,3}(\.\d{1,3}){3}$/.test(host)) {
        phone = { host: host, port: DEFAULT_PORT, token: '' };
        connected = false;
        connect('Connecting');
      } else {
        setStatus('That address looks incomplete. It should look like 192.168.1.23');
      }
    }
  }

  function forgetPhone() {
    try { localStorage.removeItem(STORE_KEY); } catch (e) { /* ignore */ }
    phone = null;
    clearTimeout(retryTimer);
    if (ws) { try { ws.onclose = null; ws.close(); } catch (e2) { /* ignore */ } ws = null; }
    connected = false;
    show('pair');
    setStatus('Forgotten. Connect again from the phone.');
  }

  function leaveApp() {
    var sys = window.webOSSystem || window.PalmSystem;
    if (sys && sys.platformBack) { try { sys.platformBack(); } catch (e) { /* ignore */ } }
  }

  function showTyped() { text($('addr'), typed || ' '); }

  function onKey(k) {
    presses++;
    if (screen === 'player') { playerKey(k); return; }
    if (B.screens.indexOf(screen) >= 0) { B.key(k); sendState(); return; }
    if (k === 'up') move(0, -1);
    else if (k === 'down') move(0, 1);
    else if (k === 'left') move(-1, 0);
    else if (k === 'right') move(1, 0);
    else if (k === 'ok') press();
    else if (k === 'back') {
      if (screen === 'pair' && typed) { typed = typed.slice(0, -1); showTyped(); }
      else if (B.has()) B.home();
      else leaveApp();   // nothing left to go back to, like other TV apps
    }
    sendState();
  }

  function buildKeys() {
    var keys = $('keys');
    var labels = ['1', '2', '3', '4', '5', '6', '7', '8', '9', '.', '0'];
    for (var i = 0; i < labels.length; i++) addKey(keys, labels[i], 'digit', labels[i], false);
    addKey(keys, '⌫', 'del', '', false);
    addKey(keys, 'Connect', 'connect', '', true);
  }

  function addKey(parent, label, act, v, wide) {
    var d = document.createElement('div');
    d.className = 'key' + (wide ? ' wide' : '');
    d.setAttribute('data-act', act);
    d.setAttribute('data-v', v);
    text(d, label);
    parent.appendChild(d);
  }

  // ---------------------------------------------------------------- player

  var video = null;
  var playing = { url: '', title: '', error: '' };
  var osdTimer = null;
  var cues = [];        // subtitles sent by the phone: {s, e, t}
  var shownCue = '';

  function fmt(s) {
    if (!isFinite(s) || s < 0) s = 0;
    s = Math.floor(s);
    var h = Math.floor(s / 3600), m = Math.floor((s % 3600) / 60), x = s % 60;
    return (h ? h + ':' + (m < 10 ? '0' : '') : '') + m + ':' + (x < 10 ? '0' : '') + x;
  }

  function setNote(s) {
    var n = $('pnote');
    text(n, s || '');
    if (s) n.classList.remove('hidden'); else n.classList.add('hidden');
  }

  // m: {url, title, sub (second line), start (seconds), kind (mkv, mp4, hls…), id}
  function playVideo(m) {
    if (!m || !m.url) return;
    playing = { url: m.url, title: m.title || '', sub: m.sub || '', error: '', id: m.id || 0,
      start: Number(m.start) || 0, kind: m.kind || '', audio: -1, subNote: '', audioNote: '', pendingAudio: -1 };
    clearSubs();
    show('player');
    text($('ptitle'), playing.title || m.url);
    text($('psub'), playing.sub);
    wakeOsd();
    try {
      video.src = m.url;
      video.load();
      var p = video.play();
      if (p && p.catch) p.catch(function (e) { playing.error = String(e && e.message || e); sendState(); });
    } catch (e) {
      playing.error = String(e && e.message || e);
    }
    sendState();
  }

  function stopVideo() {
    if (!video) return;
    try { video.pause(); video.removeAttribute('src'); video.load(); } catch (e) { /* ignore */ }
    playing = { url: '', title: '', error: '' };
    clearSubs();
    setNote('');
  }

  // Once the file is open: jump to where the phone was and pick its audio.
  function onLoaded() {
    if (!playing.url) return;
    if (playing.start > 0) {
      try { video.currentTime = playing.start; } catch (e) { /* ignore */ }
      playing.start = 0;
    }
    if (playing.pendingAudio >= 0) { selectAudio(playing.pendingAudio); playing.pendingAudio = -1; }
    if (playing.pendingSub != null) { selectEmbeddedSub(playing.pendingSub); playing.pendingSub = null; }
  }

  function onPlaying() {
    if (playing.kind && info.played[playing.kind] !== 'yes') {
      info.played[playing.kind] = 'yes';
      try { localStorage.setItem(PLAYED_KEY, JSON.stringify(info.played)); } catch (e) { /* ignore */ }
    }
  }

  // ---- audio and subtitles inside the file (MKV). LG's player is asked
  // through the browser's track lists when it offers them, else directly.

  function selectAudio(i) {
    i = Number(i);
    if (!(i >= 0)) return;
    if (video.readyState < 1) { playing.pendingAudio = i; return; }
    playing.audio = i;
    var list = video.audioTracks;
    if (list && list.length > i) {
      for (var j = 0; j < list.length; j++) list[j].enabled = (j === i);
      playing.audioNote = '';
    } else if (video.mediaId) {
      luna('luna://com.webos.media/selectTrack', { type: 'audio', index: i, mediaId: video.mediaId }, function (r) {
        playing.audioNote = (r && r.returnValue !== false) ? '' : 'audio: ' + ((r && r.errorText) || 'refused');
        sendState();
      });
    } else {
      playing.audioNote = 'audio: this TV gives no way to switch';
    }
  }

  function selectEmbeddedSub(i) {
    i = Number(i);
    if (video.readyState < 1) { playing.pendingSub = i; return; }
    var list = video.textTracks, j;
    if (list && list.length > i && i >= 0) {
      for (j = 0; j < list.length; j++) list[j].mode = (j === i) ? 'showing' : 'disabled';
      playing.subNote = '';
      return;
    }
    if (list) for (j = 0; j < list.length; j++) list[j].mode = 'disabled';
    if (!video.mediaId) {
      if (i >= 0) playing.subNote = 'subtitles: this TV gives no way to switch';
      return;
    }
    if (i < 0) {
      luna('luna://com.webos.media/setSubtitleEnable', { mediaId: video.mediaId, enable: false }, function () {});
      playing.subNote = '';
      return;
    }
    luna('luna://com.webos.media/selectTrack', { type: 'text', index: i, mediaId: video.mediaId }, function (r) {
      playing.subNote = (r && r.returnValue !== false) ? '' : 'subtitles: ' + ((r && r.errorText) || 'refused');
      luna('luna://com.webos.media/setSubtitleEnable', { mediaId: video.mediaId, enable: true }, function () {});
      sendState();
    });
  }

  // ---- subtitles from the phone: fetched as text and drawn by this app,
  // so they look the same on every TV.

  function vttTime(s) {
    var p = s.replace(',', '.').split(':');
    var sec = parseFloat(p.pop()) || 0;
    var min = parseInt(p.pop() || '0', 10) || 0;
    var hr = parseInt(p.pop() || '0', 10) || 0;
    return hr * 3600 + min * 60 + sec;
  }

  function parseVtt(raw) {
    var out = [];
    var blocks = String(raw).replace(/\r/g, '').split(/\n{2,}/);
    for (var i = 0; i < blocks.length; i++) {
      var lines = blocks[i].split('\n');
      for (var j = 0; j < lines.length; j++) {
        var m = /^\s*([\d:.,]+)\s+-->\s+([\d:.,]+)/.exec(lines[j]);
        if (!m) continue;
        var t = lines.slice(j + 1).join('\n').replace(/<[^>]*>/g, '').replace(/&nbsp;/g, ' ')
          .replace(/&amp;/g, '&').replace(/&lt;/g, '<').replace(/&gt;/g, '>');
        t = t.replace(/\s+$/, '');
        if (t) out.push({ s: vttTime(m[1]), e: vttTime(m[2]), t: t });
        break;
      }
    }
    return out;
  }

  function clearSubs() {
    cues = [];
    shownCue = '';
    var el = $('subs');
    if (el) text(el, '');
  }

  function loadSubs(url, label) {
    clearSubs();
    selectEmbeddedSub(-1);
    var forId = playing.id;
    playing.subNote = '';
    try {
      var x = new XMLHttpRequest();
      x.open('GET', url, true);
      x.onload = function () {
        if (playing.id !== forId) return;
        if (x.status >= 200 && x.status < 300) {
          cues = parseVtt(x.responseText);
          playing.subNote = cues.length ? '' : 'subtitles: the file was empty';
        } else {
          playing.subNote = 'subtitles: the phone answered ' + x.status;
        }
        playing.subLabel = label || '';
        sendState();
      };
      x.onerror = function () { playing.subNote = 'subtitles: could not reach the phone'; sendState(); };
      x.send();
    } catch (e) { playing.subNote = 'subtitles: ' + String(e && e.message || e); }
  }

  function drawSubs() {
    if (!video || !playing.url) return;
    var t = (video.currentTime || 0) + (playing.subDelay || 0), s = '';
    for (var i = 0; i < cues.length; i++) {
      if (cues[i].s <= t && t < cues[i].e) s += (s ? '\n' : '') + cues[i].t;
    }
    if (s !== shownCue) { shownCue = s; text($('subs'), s); }
  }

  function playerCommand(m) {
    if (!video || !playing.url) return;
    try {
      if (m.cmd === 'toggle') { if (video.paused) video.play(); else video.pause(); }
      else if (m.cmd === 'play') video.play();
      else if (m.cmd === 'pause') video.pause();
      else if (m.cmd === 'seekBy') video.currentTime = Math.max(0, video.currentTime + Number(m.by || 0));
      else if (m.cmd === 'seekTo') video.currentTime = Math.max(0, Number(m.to || 0));
      else if (m.cmd === 'audio') { playing.audioWanted = m.i; selectAudio(m.i); }
      else if (m.cmd === 'sub') {
        // {url, label}: a subtitle file from the phone; {i}: one inside the
        // video file; neither: subtitles off.
        playing.subWanted = m.url ? 'file: ' + (m.label || '?') : (m.i == null ? 'off' : 'in the video, number ' + m.i);
        if (m.url) loadSubs(m.url, m.label);
        else { clearSubs(); selectEmbeddedSub(m.i == null ? -1 : m.i); }
      } else if (m.cmd === 'subDelay') playing.subDelay = Number(m.by || 0);
    } catch (e) { playing.error = String(e && e.message || e); }
    wakeOsd();
    sendState();
  }

  // Back / Stop in the player, or the phone ending it.
  function leavePlayer() {
    var to = B.leftPlayer();
    stopVideo();
    show(to);
  }

  // The controls (seek bar, buttons, menus) live in browse.js.
  function playerKey(k) {
    if (B.playerKey(k)) { sendState(); return; }
    if (k === 'back') leavePlayer();
  }

  function wakeOsd() { if (B) B.wake(); }

  function trackList(list) {
    var out = [];
    if (!list) return out;
    for (var i = 0; i < list.length; i++) {
      var t = list[i];
      out.push({ i: i, label: t.label || '', lang: t.language || '', kind: t.kind || '',
        on: t.enabled === true || t.mode === 'showing' });
    }
    return out;
  }

  function playerState() {
    if (!video || !playing.url) return null;
    var err = playing.error;
    if (!err && video.error) {
      var codes = { 1: 'stopped', 2: 'network problem', 3: 'could not decode', 4: 'format not supported' };
      err = (codes[video.error.code] || 'error ' + video.error.code) +
        (video.error.message ? ' (' + video.error.message + ')' : '');
    }
    var notes = [];
    if (playing.audioNote) notes.push(playing.audioNote);
    if (playing.subNote) notes.push(playing.subNote);
    return {
      id: playing.id || 0, url: playing.url, title: playing.title,
      paused: video.paused, ended: video.ended, waiting: video.readyState < 3,
      pos: video.currentTime || 0, dur: isFinite(video.duration) ? video.duration : 0,
      w: video.videoWidth || 0, h: video.videoHeight || 0,
      error: err || '', note: notes.join('; '), cues: cues.length,
      subWanted: playing.subWanted || '', audioWanted: playing.audioWanted == null ? '' : playing.audioWanted,
      mediaId: video.mediaId ? 'yes' : 'no',
      audio: trackList(video.audioTracks), subs: trackList(video.textTracks)
    };
  }

  function showPlayerState() {
    var s = playerState();
    if (!s || !B) return;
    B.drawPlayer(s);
  }

  function sendState() {
    showPlayerState();
    if (!connected) return;
    var name = focused ? (focused.getAttribute('data-name') || focused.textContent || '') : '';
    send({ t: 'state', screen: screen, focus: name.slice(0, 60), presses: presses,
      played: info.played, player: playerState() });
  }

  // ------------------------------------------------------------------ start

  function start() {
    text($('ver'), APP_VERSION);
    video = $('video');
    var events = ['playing', 'pause', 'waiting', 'ended', 'error', 'loadedmetadata', 'seeked', 'stalled'];
    // First, so the jump to the resume point happens before the report.
    video.addEventListener('loadedmetadata', onLoaded);
    video.addEventListener('playing', onPlaying);
    video.addEventListener('ended', function () { if (playing.local) B.ended(); });
    for (var i = 0; i < events.length; i++) video.addEventListener(events[i], sendState);
    setInterval(function () { if (screen === 'player') { sendState(); B.tick(); } }, 1000);
    setInterval(function () { if (screen === 'player') drawSubs(); }, 150);

    B = window.AXBrowse({
      $: $, text: text, luna: luna, send: send, info: info, show: show, setFocus: setFocus, setNote: setNote,
      screen: function () { return screen; }, focused: function () { return focused; },
      connected: function () { return connected; }, phone: function () { return phone; },
      peer: function () { return peerName; }, video: function () { return video; },
      playing: function () { return playing; }, play: playVideo, stop: stopVideo, command: playerCommand,
      selectAudio: selectAudio, selectSub: selectEmbeddedSub, loadSubs: loadSubs, clearSubs: clearSubs,
      exit: leaveApp, forget: forgetPhone
    });
    window.AXBrowse._test = B._test;
    B.start();
    buildKeys();
    readDeviceInfo();
    showInfo();
    readSystemInfo();
    showTyped();
    show('pair');

    // The TV remote: arrows, OK, Back (461), and the play / pause buttons.
    document.addEventListener('keydown', function (e) {
      var typing = document.activeElement && document.activeElement.tagName === 'INPUT';
      if (typing) {
        // In the search box: Enter and Back are ours; an arrow means the
        // TV's keyboard is gone, so leave the box and move on.
        if (e.keyCode === 13) { onKey('ok'); e.preventDefault(); return; }
        if (e.keyCode === 461 || e.keyCode === 27) { onKey('back'); e.preventDefault(); return; }
        if (e.keyCode < 37 || e.keyCode > 40) return;
        try { document.activeElement.blur(); } catch (x) { /* ignore */ }
      }
      var map = { 37: 'left', 38: 'up', 39: 'right', 40: 'down', 13: 'ok', 461: 'back', 27: 'back', 8: 'back' };
      var k = map[e.keyCode];
      if (k) { onKey(k); e.preventDefault(); return; }
      if (screen === 'player') {
        if (e.keyCode === 415) playerCommand({ cmd: 'play' });
        else if (e.keyCode === 19) playerCommand({ cmd: 'pause' });
        else if (e.keyCode === 10252) playerCommand({ cmd: 'toggle' });
        else if (e.keyCode === 413) leavePlayer();
        else if (e.keyCode === 412) playerCommand({ cmd: 'seekBy', by: -30 });
        else if (e.keyCode === 417) playerCommand({ cmd: 'seekBy', by: 30 });
      } else if (e.keyCode >= 48 && e.keyCode <= 57 && screen === 'pair') {
        typed += String(e.keyCode - 48);
        showTyped();
      }
    });

    document.addEventListener('webOSLaunch', onLaunch, true);
    document.addEventListener('webOSRelaunch', onLaunch, true);

    phone = loadPhone();
    // Paired before: straight to Home; the phone joins when it is around.
    if (B.has() || phone) B.home();
    if (phone) connect('Reconnecting');
    else setStatus('Waiting for your phone.');
    // Launch details can also be there before the launch event arrives.
    onLaunch(null);
  }

  if (document.readyState === 'loading') document.addEventListener('DOMContentLoaded', start);
  else start();
})();
