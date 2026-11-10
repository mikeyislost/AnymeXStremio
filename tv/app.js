/* AnymeX+ TV (test build).
 *
 * A small web app for LG webOS. It connects out to AnymeX+ on the phone
 * (the phone runs a little server while its TV Remote page is open), takes
 * remote presses and "play this" requests from it, plays video with the
 * TV's own player and reports back what it is doing.
 *
 * Written in old-style JavaScript on purpose so it runs on older webOS too.
 */
(function () {
  'use strict';

  var APP_VERSION = '0.0.1'; // replaced by the build
  var DEFAULT_PORT = 41733;
  var STORE_KEY = 'anymexplus_tv_phone';

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
      mkv: 'video/x-matroska',
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
    text($('info'), lines.join('\n'));
  }

  // ------------------------------------------------------------ phone link

  var ws = null;
  var connected = false;
  var phone = null;      // {host, port, token}
  var retryTimer = null;
  var typed = '';
  var peerName = '';

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
      send({ t: 'hello', app: 'anymexplus-tv', v: APP_VERSION, token: phone.token || '', info: info });
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
      if (was) {
        stopVideo();
        show('pair');
        setStatus('The phone disconnected. Waiting for it to come back…');
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
        text($('peer'), 'to ' + peerName);
        show('home');
        sendState();
        break;
      case 'denied':
        setStatus('The phone said no. Try again from the phone.');
        break;
      case 'key': onKey(m.k); break;
      case 'play': playVideo(m.url, m.title || ''); break;
      case 'player': playerCommand(m); break;
      case 'stop': stopVideo(); show('home'); break;
      case 'ping': send({ t: 'pong' }); break;
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
    if (p && p.host) {
      phone = { host: String(p.host), port: Number(p.port) || DEFAULT_PORT, token: String(p.token || '') };
      savePhone();
      connected = false;
      connect('Connecting');
    }
    var sys = window.webOSSystem || window.PalmSystem;
    if (sys && sys.activate) { try { sys.activate(); } catch (e4) { /* ignore */ } }
  }

  // --------------------------------------------------------------- screens

  var screen = 'pair';
  var presses = 0;

  function show(name) {
    screen = name;
    var all = ['pair', 'home', 'player'];
    for (var i = 0; i < all.length; i++) {
      var el = $(all[i]);
      if (all[i] === name) el.classList.remove('hidden'); else el.classList.add('hidden');
    }
    var first = firstFocusable();
    setFocus(first);
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
    } else if (act === 'tile') {
      focused.classList.toggle('on');
      presses++;
      text($('presses'), presses + (presses === 1 ? ' press' : ' presses') + ' received');
    } else if (act === 'forget') {
      try { localStorage.removeItem(STORE_KEY); } catch (e) { /* ignore */ }
      phone = null;
      clearTimeout(retryTimer);
      if (ws) { try { ws.onclose = null; ws.close(); } catch (e2) { /* ignore */ } ws = null; }
      connected = false;
      show('pair');
      setStatus('Forgotten. Connect again from the phone.');
    }
  }

  function showTyped() { text($('addr'), typed || ' '); }

  function onKey(k) {
    if (screen === 'player') { playerKey(k); return; }
    if (k === 'up') move(0, -1);
    else if (k === 'down') move(0, 1);
    else if (k === 'left') move(-1, 0);
    else if (k === 'right') move(1, 0);
    else if (k === 'ok') press();
    else if (k === 'back') {
      if (screen === 'pair' && typed) { typed = typed.slice(0, -1); showTyped(); }
      else {
        // Nothing left to go back to: leave the app, like other TV apps.
        var sys = window.webOSSystem || window.PalmSystem;
        if (sys && sys.platformBack) { try { sys.platformBack(); } catch (e) { /* ignore */ } }
      }
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

  function buildGrid() {
    var grid = $('grid');
    for (var i = 1; i <= 7; i++) {
      var d = document.createElement('div');
      d.className = 'tile';
      d.setAttribute('data-act', 'tile');
      text(d, 'Tile ' + i);
      grid.appendChild(d);
    }
    var f = document.createElement('div');
    f.className = 'tile';
    f.setAttribute('data-act', 'forget');
    text(f, 'Forget phone');
    grid.appendChild(f);
  }

  // ---------------------------------------------------------------- player

  var video = null;
  var playing = { url: '', title: '', error: '' };
  var osdTimer = null;

  function fmt(s) {
    if (!isFinite(s) || s < 0) s = 0;
    s = Math.floor(s);
    var h = Math.floor(s / 3600), m = Math.floor((s % 3600) / 60), x = s % 60;
    return (h ? h + ':' + (m < 10 ? '0' : '') : '') + m + ':' + (x < 10 ? '0' : '') + x;
  }

  function playVideo(url, title) {
    if (!url) return;
    playing = { url: url, title: title, error: '' };
    show('player');
    text($('ptitle'), title || url);
    text($('pstate'), 'Loading…');
    wakeOsd();
    try {
      video.src = url;
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
  }

  function playerCommand(m) {
    if (!video || !playing.url) return;
    try {
      if (m.cmd === 'toggle') { if (video.paused) video.play(); else video.pause(); }
      else if (m.cmd === 'play') video.play();
      else if (m.cmd === 'pause') video.pause();
      else if (m.cmd === 'seekBy') video.currentTime = Math.max(0, video.currentTime + Number(m.by || 0));
      else if (m.cmd === 'seekTo') video.currentTime = Math.max(0, Number(m.to || 0));
      else if (m.cmd === 'audio' && video.audioTracks) {
        for (var i = 0; i < video.audioTracks.length; i++) video.audioTracks[i].enabled = (i === Number(m.i));
      } else if (m.cmd === 'sub' && video.textTracks) {
        for (var j = 0; j < video.textTracks.length; j++) {
          video.textTracks[j].mode = (j === Number(m.i)) ? 'showing' : 'disabled';
        }
      }
    } catch (e) { playing.error = String(e && e.message || e); }
    wakeOsd();
    sendState();
  }

  function playerKey(k) {
    if (k === 'ok') playerCommand({ cmd: 'toggle' });
    else if (k === 'left') playerCommand({ cmd: 'seekBy', by: -10 });
    else if (k === 'right') playerCommand({ cmd: 'seekBy', by: 10 });
    else if (k === 'back') { stopVideo(); show(connected ? 'home' : 'pair'); }
    else wakeOsd();
  }

  function wakeOsd() {
    var osd = $('osd');
    osd.classList.remove('away');
    clearTimeout(osdTimer);
    osdTimer = setTimeout(function () {
      if (video && !video.paused && !playing.error) osd.classList.add('away');
    }, 4000);
  }

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
    return {
      url: playing.url, title: playing.title,
      paused: video.paused, ended: video.ended, waiting: video.readyState < 3,
      pos: video.currentTime || 0, dur: isFinite(video.duration) ? video.duration : 0,
      w: video.videoWidth || 0, h: video.videoHeight || 0,
      error: err || '',
      audio: trackList(video.audioTracks), subs: trackList(video.textTracks)
    };
  }

  function showPlayerState() {
    var s = playerState();
    if (!s) return;
    var line = s.error ? 'Problem: ' + s.error
      : (s.waiting && !s.paused ? 'Loading…' : (s.paused ? 'Paused' : 'Playing'));
    line += '   ' + fmt(s.pos) + ' / ' + fmt(s.dur);
    if (s.w) line += '   ' + s.w + '×' + s.h;
    if (s.audio.length) line += '   audio tracks: ' + s.audio.length;
    if (s.subs.length) line += '   subtitles: ' + s.subs.length;
    text($('pstate'), line);
    $('pfill').style.width = (s.dur ? Math.min(100, s.pos / s.dur * 100) : 0) + '%';
  }

  function sendState() {
    showPlayerState();
    if (!connected) return;
    send({ t: 'state', screen: screen, focus: focused ? focused.textContent : '', presses: presses,
      player: playerState() });
  }

  // ------------------------------------------------------------------ start

  function start() {
    text($('ver'), 'test build ' + APP_VERSION);
    video = $('video');
    var events = ['playing', 'pause', 'waiting', 'ended', 'error', 'loadedmetadata', 'seeked', 'stalled'];
    for (var i = 0; i < events.length; i++) video.addEventListener(events[i], sendState);
    setInterval(function () { if (screen === 'player') sendState(); }, 1000);

    buildKeys();
    buildGrid();
    readDeviceInfo();
    showInfo();
    readSystemInfo();
    showTyped();
    show('pair');

    // The TV remote: arrows, OK, Back (461), and the play / pause buttons.
    document.addEventListener('keydown', function (e) {
      var map = { 37: 'left', 38: 'up', 39: 'right', 40: 'down', 13: 'ok', 461: 'back', 27: 'back', 8: 'back' };
      var k = map[e.keyCode];
      if (k) { onKey(k); e.preventDefault(); return; }
      if (screen === 'player') {
        if (e.keyCode === 415) playerCommand({ cmd: 'play' });
        else if (e.keyCode === 19) playerCommand({ cmd: 'pause' });
        else if (e.keyCode === 413) { stopVideo(); show(connected ? 'home' : 'pair'); }
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
    if (phone) connect('Reconnecting');
    else setStatus('Waiting for your phone.');
    // Launch details can also be there before the launch event arrives.
    onLaunch(null);
  }

  if (document.readyState === 'loading') document.addEventListener('DOMContentLoaded', start);
  else start();
})();
