/* AnymeX+ TV: the list of audio and subtitle tracks inside an MKV file.
 *
 * The TV's player plays every track in an MKV but doesn't tell the page
 * what they are, so this reads the start of the file (where MKV keeps its
 * track list) and names them: language, title, codec, channels.
 * Old-style JavaScript, like app.js.
 */
(function () {
  'use strict';

  var EBML = 0x1A45DFA3, SEGMENT = 0x18538067, SEEKHEAD = 0x114D9B74, SEEK = 0x4DBB, SEEKID = 0x53AB,
    SEEKPOS = 0x53AC, TRACKS = 0x1654AE6B, ENTRY = 0xAE, NUMBER = 0xD7, TYPE = 0x83, LANG = 0x22B59C,
    LANGIETF = 0x22B59D, NAME = 0x536E, CODEC = 0x86, DEFAULT = 0x88, FORCED = 0x55AA, AUDIO = 0xE1,
    CHANNELS = 0x9F, CLUSTER = 0x1F43B675;

  // Element id at [at]: {v, n} (the id keeps its length marker, as MKV writes it).
  function readId(b, at) {
    if (at >= b.length) return null;
    var first = b[at], n = 1, mask = 0x80;
    while (n <= 4 && !(first & mask)) { n++; mask >>= 1; }
    if (n > 4 || at + n > b.length) return null;
    var v = 0;
    for (var i = 0; i < n; i++) v = v * 256 + b[at + i];
    return { v: v, n: n };
  }

  // Element size at [at]: {v, n}; v = -1 when the size is "unknown".
  function readSize(b, at) {
    if (at >= b.length) return null;
    var first = b[at], n = 1, mask = 0x80;
    while (n <= 8 && !(first & mask)) { n++; mask >>= 1; }
    if (n > 8 || at + n > b.length) return null;
    var v = first & (mask - 1), all = v === mask - 1;
    for (var i = 1; i < n; i++) {
      v = v * 256 + b[at + i];
      if (b[at + i] !== 0xff) all = false;
    }
    return { v: all ? -1 : v, n: n };
  }

  // Calls each(id, dataStart, dataEnd) for the elements in [start, end).
  // Stops at an element that runs past the bytes we have (each gets
  // partial = true for it) or when each returns false.
  function walk(b, start, end, each) {
    var at = start;
    while (at < end) {
      var id = readId(b, at);
      if (!id) return;
      var size = readSize(b, at + id.n);
      if (!size) return;
      var ds = at + id.n + size.n;
      var de = size.v < 0 ? end : ds + size.v;
      var partial = de > b.length;
      if (each(id.v, ds, Math.min(de, b.length), partial) === false || partial) return;
      at = de;
    }
  }

  function uint(b, s, e) { var v = 0; for (var i = s; i < e; i++) v = v * 256 + b[i]; return v; }

  function str(b, s, e) {
    var out = '';
    for (var i = s; i < e && b[i] !== 0; i++) out += String.fromCharCode(b[i]);
    try { return decodeURIComponent(escape(out)); } catch (x) { return out; }
  }

  function readTracks(b, s, e) {
    var audio = [], subs = [];
    walk(b, s, e, function (id, ds, de, partial) {
      if (id !== ENTRY || partial) return true;
      var t = { type: 0, lang: 'eng', name: '', codec: '', def: true, forced: false, channels: 0 };
      walk(b, ds, de, function (cid, cs, ce) {
        if (cid === TYPE) t.type = uint(b, cs, ce);
        else if (cid === LANG) t.lang = str(b, cs, ce);
        else if (cid === LANGIETF) t.ietf = str(b, cs, ce);
        else if (cid === NAME) t.name = str(b, cs, ce);
        else if (cid === CODEC) t.codec = str(b, cs, ce);
        else if (cid === DEFAULT) t.def = uint(b, cs, ce) !== 0;
        else if (cid === FORCED) t.forced = uint(b, cs, ce) !== 0;
        else if (cid === AUDIO) {
          walk(b, cs, ce, function (aid, as, ae) { if (aid === CHANNELS) t.channels = uint(b, as, ae); return true; });
        }
        return true;
      });
      if (t.ietf) t.lang = t.ietf;
      delete t.ietf;
      if (t.type === 2) audio.push(t);
      else if (t.type === 0x11) subs.push(t);
      return true;
    });
    return { audio: audio, subs: subs };
  }

  // bytes: the start of the file (Uint8Array), offset: where they start.
  // Returns {audio, subs} when the track list is in there, else
  // {need: position} when it is further on in the file, else null.
  function parse(bytes, offset) {
    var b = bytes, off = offset || 0, result = null;
    if (off > 0) {
      // A second read starting right at the track list.
      var id = readId(b, 0);
      if (!id || id.v !== TRACKS) return null;
      var size = readSize(b, id.n);
      if (!size || id.n + size.n + size.v > b.length) return null;
      return readTracks(b, id.n + size.n, id.n + size.n + size.v);
    }
    var first = readId(b, 0);
    if (!first || first.v !== EBML) return null;
    walk(b, 0, b.length, function (top, ds, de) {
      if (top !== SEGMENT) return true;
      var tracksAt = -1;
      walk(b, ds, de, function (id2, cs, ce, partial) {
        if (id2 === TRACKS) {
          if (!partial) result = readTracks(b, cs, ce);
          else tracksAt = cs - 12;   // re-read from a little before
          return false;
        }
        if (id2 === SEEKHEAD && !partial) {
          walk(b, cs, ce, function (sid, ss, se) {
            if (sid !== SEEK) return true;
            var what = 0, pos = -1;
            walk(b, ss, se, function (k, ks, ke) {
              if (k === SEEKID) what = uint(b, ks, ke);
              else if (k === SEEKPOS) pos = uint(b, ks, ke);
              return true;
            });
            if (what === TRACKS && pos >= 0) tracksAt = ds + pos;
            return true;
          });
        }
        if (id2 === CLUSTER) return false;
        return true;
      });
      if (!result && tracksAt >= 0) result = { need: tracksAt };
      return false;
    });
    return result;
  }

  var LANGS = { eng: 'English', en: 'English', jpn: 'Japanese', ja: 'Japanese', spa: 'Spanish', es: 'Spanish',
    fre: 'French', fra: 'French', fr: 'French', ger: 'German', deu: 'German', de: 'German', ita: 'Italian', it: 'Italian',
    por: 'Portuguese', pt: 'Portuguese', 'pt-BR': 'Portuguese (Brazil)', kor: 'Korean', ko: 'Korean',
    chi: 'Chinese', zho: 'Chinese', zh: 'Chinese', rus: 'Russian', ru: 'Russian', ara: 'Arabic', ar: 'Arabic',
    hin: 'Hindi', hi: 'Hindi', dut: 'Dutch', nld: 'Dutch', pol: 'Polish', tur: 'Turkish', swe: 'Swedish',
    nor: 'Norwegian', dan: 'Danish', fin: 'Finnish', gre: 'Greek', heb: 'Hebrew', ind: 'Indonesian',
    vie: 'Vietnamese', tha: 'Thai', ukr: 'Ukrainian', rum: 'Romanian', hun: 'Hungarian', cze: 'Czech',
    'es-419': 'Spanish (Latin America)', und: '' };

  var CODECS = { A_EAC3: 'E-AC3', A_AC3: 'AC3', A_TRUEHD: 'TrueHD', A_DTS: 'DTS', 'A_DTS/MA': 'DTS-HD MA',
    A_AAC: 'AAC', 'A_AAC/MPEG4/LC': 'AAC', A_OPUS: 'Opus', A_FLAC: 'FLAC', A_VORBIS: 'Vorbis', A_MPEG_L3: 'MP3',
    'S_TEXT/UTF8': 'SRT', 'S_TEXT/ASS': 'ASS', 'S_TEXT/SSA': 'SSA', S_HDMV_PGS: 'PGS', 'S_HDMV/PGS': 'PGS',
    S_VOBSUB: 'VobSub', 'S_TEXT/WEBVTT': 'WebVTT' };

  function langName(code) {
    code = String(code || '');
    if (LANGS.hasOwnProperty(code)) return LANGS[code];
    var base = code.split('-')[0].toLowerCase();
    return LANGS.hasOwnProperty(base) ? LANGS[base] : code;
  }

  // "English · Commentary · E-AC3 5.1"
  function label(t, n) {
    var parts = [];
    var lang = langName(t.lang);
    if (lang) parts.push(lang);
    if (t.name && t.name.toLowerCase() !== lang.toLowerCase()) parts.push(t.name);
    var codec = CODECS[t.codec] || CODECS[String(t.codec).split('/')[0]] || '';
    var ch = t.channels === 1 ? 'mono' : t.channels === 2 ? 'stereo' : t.channels === 6 ? '5.1' :
      t.channels === 8 ? '7.1' : t.channels ? t.channels + 'ch' : '';
    var tech = (codec + (ch ? ' ' + ch : '')).replace(/^\s+/, '');
    if (tech) parts.push(tech);
    if (t.forced) parts.push('forced');
    return parts.length ? parts.join('  ·  ') : 'Track ' + n;
  }

  // Reads the tracks of the MKV at [url]. done({audio, subs} or null).
  function tracks(url, done) {
    var fin = false;
    function end(v) { if (!fin) { fin = true; done(v); } }
    function get(from, len, cb) {
      try {
        var x = new XMLHttpRequest();
        x.open('GET', url, true);
        x.responseType = 'arraybuffer';
        x.timeout = 15000;
        x.setRequestHeader('Range', 'bytes=' + from + '-' + (from + len - 1));
        var done = false;
        x.onreadystatechange = function () {
          // A server that ignores the range would send the whole file: stop.
          if (x.readyState === 2 && x.status !== 206 && !done) { done = true; try { x.abort(); } catch (e) { /* ignore */ } cb(null); }
        };
        x.onload = function () {
          if (done) return;
          done = true;
          if (x.status === 206 && x.response) cb(new Uint8Array(x.response).subarray(0, len));
          else cb(null);
        };
        x.onerror = function () { if (!done) { done = true; cb(null); } };
        x.ontimeout = function () { if (!done) { done = true; cb(null); } };
        x.send(null);
      } catch (e) { cb(null); }
    }
    get(0, 1048576, function (b) {
      var r = b && parse(b, 0);
      if (!r) { end(null); return; }
      if (!r.need) { end(r); return; }
      get(r.need, 262144, function (b2) {
        if (!b2) { end(null); return; }
        // The track list starts somewhere in the first bytes of this read.
        for (var i = 0; i < 64 && i < b2.length; i++) {
          if (b2[i] === 0x16 && b2[i + 1] === 0x54 && b2[i + 2] === 0xAE && b2[i + 3] === 0x6B) {
            end(parse(b2.subarray(i), 1));
            return;
          }
        }
        end(null);
      });
    });
  }

  window.AXMkv = { parse: parse, tracks: tracks, label: label, langName: langName };
})();
