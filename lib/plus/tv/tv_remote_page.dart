import 'package:anymex/plus/airplay.dart';
import 'package:anymex/plus/tv/flutter_tv_pair.dart';
import 'package:anymex/plus/tv/tv_link.dart';
import 'package:anymex/plus/tv/tv_sync.dart';
import 'package:anymex/widgets/non_widgets/snackbar.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:get/get.dart';

/// Settings → TV Remote: connects to the AnymeX+ TV app (LG webOS) and
/// works as its remote: a D-pad, a search box that types on the TV, the
/// sync of your Stremio account and addons, test videos and a report.
class PlusTvRemotePage extends StatefulWidget {
  const PlusTvRemotePage({super.key});

  @override
  State<PlusTvRemotePage> createState() => _PlusTvRemotePageState();
}

class _PlusTvRemotePageState extends State<PlusTvRemotePage> {
  final link = PlusTvLink.instance;
  final _ip = TextEditingController();
  final _url = TextEditingController();
  final _tvSearch = TextEditingController();
  List<PlusTvDevice> _tvs = const [];
  bool _searching = false;
  String _opening = '';

  /// Short public clips, one per kind of file the TV has to handle.
  static const _samples = <(String, String)>[
    ('MP4 (H.264)', 'https://test-videos.co.uk/vids/bigbuckbunny/mp4/h264/1080/Big_Buck_Bunny_1080_10s_5MB.mp4'),
    ('MKV (H.264)', 'https://test-videos.co.uk/vids/bigbuckbunny/mkv/1080/Big_Buck_Bunny_1080_10s_5MB.mkv'),
    ('MP4 (HEVC)', 'https://test-videos.co.uk/vids/bigbuckbunny/mp4/h265/1080/Big_Buck_Bunny_1080_10s_5MB.mp4'),
    ('HLS stream', 'https://test-streams.mux.dev/x36xhzz/x36xhzz.m3u8'),
  ];

  @override
  void initState() {
    super.initState();
    link.askAllow = _askAllow;
    link.start().then((_) => _search());
  }

  @override
  void dispose() {
    link.askAllow = null;
    _ip.dispose();
    _url.dispose();
    _tvSearch.dispose();
    super.dispose();
  }

  Future<bool> _askAllow(String tvIp) async {
    if (!mounted) return false;
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Connect this TV?'),
        content: Text('A TV at $tvIp wants to connect to AnymeX+. Only allow it if you just typed this '
            "device's address on your own TV."),
        actions: [
          TextButton(onPressed: () => Navigator.of(ctx).pop(false), child: const Text('No')),
          FilledButton(onPressed: () => Navigator.of(ctx).pop(true), child: const Text('Allow')),
        ],
      ),
    );
    return ok ?? false;
  }

  Future<void> _search() async {
    if (_searching) return;
    setState(() => _searching = true);
    try {
      final found = await link.findTvs();
      if (mounted) setState(() => _tvs = found);
    } finally {
      if (mounted) setState(() => _searching = false);
    }
  }

  Future<void> _open(String host) async {
    if (_opening.isNotEmpty) return;
    setState(() => _opening = host);
    try {
      await link.openOnTv(host, onPrompt: () => snackBar('Look at the TV and choose Allow', duration: 6000));
      snackBar('Opening AnymeX+ TV…');
    } catch (e) {
      final msg = '$e'.replaceFirst('Exception: ', '');
      snackBar("Couldn't open AnymeX+ TV there. Is the TV on and the TV app installed? ($msg)",
          duration: 6000, maxLines: 4);
    } finally {
      if (mounted) setState(() => _opening = '');
    }
  }

  void _addByIp() {
    final ip = _ip.text.trim();
    if (!PlusCastSearch.isIp(ip)) {
      snackBar('That should look like 192.168.1.49');
      return;
    }
    FocusScope.of(context).unfocus();
    _open(ip);
  }

  void _playLink() {
    final url = _url.text.trim();
    if (!url.startsWith('http')) {
      snackBar('Paste a link that starts with http');
      return;
    }
    FocusScope.of(context).unfocus();
    link.play(url, title: 'Pasted link');
  }

  /// AnymeX+ (Flutter) on the TV: send your logins with the code it shows.
  Widget _flutterTvCard(BuildContext context) {
    final paired = PlusFlutterTvPair.savedPairs();
    return Card(
      child: ListTile(
        leading: const Icon(Icons.key_rounded),
        title: const Text('Send logins to the Flutter TV app'),
        subtitle: Text(paired.isEmpty
            ? 'AniList, Simkl, MyAnimeList and Stremio, for "AnymeX+ (Flutter)" on your TV. '
                'On the TV: Settings → Accounts → Get logins from your phone.'
            : 'Paired with ${paired.map((p) => p['host']).join(', ')}. Fresh logins go to it each time this app starts.'),
        isThreeLine: true,
        trailing: const Icon(Icons.chevron_right_rounded),
        onTap: _sendLogins,
      ),
    );
  }

  Future<void> _sendLogins() async {
    final saved = PlusFlutterTvPair.savedPairs();
    final host = TextEditingController(
        text: saved.isNotEmpty ? saved.last['host'] : (_tvs.isNotEmpty ? _tvs.first.host : ''));
    final code = TextEditingController();
    var busy = false;
    var error = '';
    await showDialog<void>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setD) {
          Future<void> go() async {
            final h = host.text.trim(), c = code.text.replaceAll(' ', '');
            if (!PlusCastSearch.isIp(h)) {
              setD(() => error = 'The TV address should look like 192.168.1.49 (it shows on the TV).');
              return;
            }
            if (c.length != 6) {
              setD(() => error = 'Type the 6-digit code from the TV.');
              return;
            }
            setD(() {
              busy = true;
              error = '';
            });
            try {
              final took = await PlusFlutterTvPair.send(h, c);
              if (ctx.mounted) Navigator.of(ctx).pop();
              snackBar(took.isEmpty ? 'Sent, but the TV took none of them' : 'The TV is signed in: ${took.join(', ')}',
                  duration: 5000);
              if (mounted) setState(() {});
            } catch (e) {
              setD(() {
                busy = false;
                error = '$e'.replaceFirst('Exception: ', '');
                if (error.startsWith('Wrong code')) code.clear();
              });
            }
          }

          return AlertDialog(
            title: const Text('Send logins to the TV'),
            content: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
              const Text('On the TV, open AnymeX+ (Flutter) → Settings → Accounts → Get logins from your phone.'),
              const SizedBox(height: 12),
              if (_tvs.isNotEmpty)
                Wrap(spacing: 6, children: [
                  for (final tv in _tvs)
                    ActionChip(label: Text(tv.host), onPressed: () => setD(() => host.text = tv.host)),
                ]),
              TextField(
                controller: host,
                keyboardType: const TextInputType.numberWithOptions(decimal: true),
                decoration: const InputDecoration(labelText: 'TV address'),
              ),
              TextField(
                controller: code,
                autofocus: true,
                keyboardType: TextInputType.number,
                maxLength: 7,
                decoration: const InputDecoration(labelText: 'Code on the TV'),
                onSubmitted: (_) => go(),
              ),
              if (error.isNotEmpty) Text(error, style: TextStyle(color: Theme.of(ctx).colorScheme.error)),
            ]),
            actions: [
              TextButton(onPressed: busy ? null : () => Navigator.of(ctx).pop(), child: const Text('Cancel')),
              FilledButton(
                onPressed: busy ? null : go,
                child: busy
                    ? const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2))
                    : const Text('Send'),
              ),
            ],
          );
        },
      ),
    );
  }

  Future<void> _copyReport() async {
    await Clipboard.setData(ClipboardData(text: link.report()));
    snackBar('TV report copied');
  }

  static String _clock(num seconds) {
    final s = seconds.isFinite && seconds > 0 ? seconds.floor() : 0;
    final m = (s ~/ 60) % 60, h = s ~/ 3600, x = s % 60;
    final mm = h > 0 ? m.toString().padLeft(2, '0') : '$m';
    return '${h > 0 ? '$h:' : ''}$mm:${x.toString().padLeft(2, '0')}';
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('TV Remote')),
      body: SafeArea(
        child: Obx(() {
          final connected = link.status.value == PlusTvStatus.connected;
          return ListView(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 48),
            children: [
              _statusCard(context, connected),
              const SizedBox(height: 12),
              _flutterTvCard(context),
              const SizedBox(height: 16),
              if (connected) ..._connected(context) else ..._notConnected(context),
            ],
          );
        }),
      ),
    );
  }

  Widget _statusCard(BuildContext context, bool connected) {
    final scheme = Theme.of(context).colorScheme;
    final info = link.tvInfo;
    final model = info['model'] ?? 'TV';
    final system = info['sdkVersion'] ?? info['platformVersion'] ?? '';
    return Card(
      color: connected ? scheme.primaryContainer : scheme.surfaceContainerHighest,
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Row(
          children: [
            Icon(connected ? Icons.tv_rounded : Icons.tv_off_rounded,
                size: 36, color: connected ? scheme.onPrimaryContainer : scheme.onSurfaceVariant),
            const SizedBox(width: 16),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(connected ? 'Connected to $model' : 'Not connected',
                      style: Theme.of(context).textTheme.titleMedium),
                  const SizedBox(height: 4),
                  Text(
                    connected
                        ? '${link.tvAddress.value}${system == '' ? '' : ' · system $system'} · '
                            'TV app ${info['app'] ?? '?'}'
                        : 'Open AnymeX+ TV on your TV, or tap your TV below to open it from here.',
                    style: Theme.of(context).textTheme.bodySmall,
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  List<Widget> _notConnected(BuildContext context) {
    final text = Theme.of(context).textTheme;
    final ip = link.localIp.value;
    final usualPort = link.port.value == PlusTvLink.defaultPort;
    return [
      Row(
        children: [
          Expanded(child: Text('Your TVs', style: text.titleMedium)),
          if (_searching)
            const SizedBox(width: 20, height: 20, child: CircularProgressIndicator(strokeWidth: 2))
          else
            IconButton(onPressed: _search, icon: const Icon(Icons.refresh_rounded), tooltip: 'Search again'),
        ],
      ),
      if (_tvs.isEmpty && !_searching)
        Padding(
          padding: const EdgeInsets.symmetric(vertical: 8),
          child: Text('No LG TV found yet. Add yours by its IP address below.', style: text.bodyMedium),
        ),
      for (final tv in _tvs)
        Card(
          child: ListTile(
            leading: const Icon(Icons.tv_rounded),
            title: Text(tv.name),
            subtitle: Text(tv.host),
            trailing: _opening == tv.host
                ? const SizedBox(width: 20, height: 20, child: CircularProgressIndicator(strokeWidth: 2))
                : const Icon(Icons.play_arrow_rounded),
            onTap: () => _open(tv.host),
          ),
        ),
      const SizedBox(height: 8),
      Row(
        children: [
          Expanded(
            child: TextField(
              controller: _ip,
              keyboardType: const TextInputType.numberWithOptions(decimal: true),
              decoration: const InputDecoration(
                labelText: 'TV IP address',
                hintText: '192.168.1.49',
                border: OutlineInputBorder(),
                isDense: true,
              ),
              onSubmitted: (_) => _addByIp(),
            ),
          ),
          const SizedBox(width: 8),
          FilledButton(onPressed: _addByIp, child: const Text('Open')),
        ],
      ),
      const SizedBox(height: 24),
      Text('Or connect from the TV', style: text.titleMedium),
      const SizedBox(height: 8),
      Text(
        ip.isEmpty
            ? "This device isn't on a home network, so a TV can't reach it."
            : usualPort
                ? 'Open AnymeX+ TV on the TV, type this address there and choose Connect:'
                : 'Typing the address on the TV is not available right now (another app is using the '
                    'port). Tap your TV above instead.',
        style: text.bodyMedium,
      ),
      if (ip.isNotEmpty && usualPort)
        Padding(
          padding: const EdgeInsets.only(top: 8),
          child: SelectableText(ip, style: text.headlineMedium),
        ),
      const SizedBox(height: 16),
      Text('Keep this page open while you use the TV app.', style: text.bodySmall),
      if (PlusTvLink.isComputer) ...[
        const SizedBox(height: 16),
        _PcSourceSwitch(),
      ],
    ];
  }

  List<Widget> _connected(BuildContext context) {
    final text = Theme.of(context).textTheme;
    final state = link.tvState;
    final player = state['player'];
    return [
      Center(child: _dpad(context)),
      const SizedBox(height: 8),
      Center(
        child: Text(
          state.isEmpty
              ? 'Waiting for the TV…'
              : 'TV shows: ${state['screen']}'
                  '${(state['focus'] ?? '') == '' ? '' : ' · on "${state['focus']}"'}'
                  ' · ${state['presses'] ?? 0} presses',
          style: text.bodySmall,
        ),
      ),
      const SizedBox(height: 16),
      Row(
        children: [
          Expanded(
            child: TextField(
              controller: _tvSearch,
              textInputAction: TextInputAction.search,
              decoration: const InputDecoration(
                labelText: 'Search on the TV',
                border: OutlineInputBorder(),
                isDense: true,
              ),
              onSubmitted: (q) => PlusTvSync.instance.search(q.trim()),
            ),
          ),
          const SizedBox(width: 8),
          FilledButton(
            onPressed: () => PlusTvSync.instance.search(_tvSearch.text.trim()),
            child: const Text('Search'),
          ),
        ],
      ),
      const SizedBox(height: 16),
      Card(
        child: ListTile(
          leading: const Icon(Icons.sync_rounded),
          title: const Text('Sync to the TV'),
          subtitle: Obx(() => Text(PlusTvSync.instance.status.value.isEmpty
              ? 'Your Stremio account, addons and Movies & TV rows, locked so only this TV can read them.'
              : PlusTvSync.instance.status.value)),
          trailing: TextButton(
            onPressed: () => PlusTvSync.instance.sendNow(),
            child: const Text('Sync now'),
          ),
        ),
      ),
      const SizedBox(height: 24),
      Text('Play a test video on the TV', style: text.titleMedium),
      const SizedBox(height: 8),
      Wrap(
        spacing: 8,
        runSpacing: 8,
        children: [
          for (final (name, url) in _samples)
            OutlinedButton(onPressed: () => link.play(url, title: name), child: Text(name)),
        ],
      ),
      const SizedBox(height: 12),
      Row(
        children: [
          Expanded(
            child: TextField(
              controller: _url,
              keyboardType: TextInputType.url,
              decoration: const InputDecoration(
                labelText: 'Or paste a video link',
                border: OutlineInputBorder(),
                isDense: true,
              ),
              onSubmitted: (_) => _playLink(),
            ),
          ),
          const SizedBox(width: 8),
          FilledButton(onPressed: _playLink, child: const Text('Play')),
        ],
      ),
      if (player is Map) ...[
        const SizedBox(height: 16),
        _playerCard(context, Map<String, dynamic>.from(player)),
      ],
      const SizedBox(height: 24),
      Row(
        children: [
          Expanded(
            child: OutlinedButton.icon(
              onPressed: _copyReport,
              icon: const Icon(Icons.copy_rounded),
              label: const Text('Copy TV report'),
            ),
          ),
          const SizedBox(width: 8),
          Expanded(
            child: OutlinedButton.icon(
              onPressed: link.disconnect,
              icon: const Icon(Icons.link_off_rounded),
              label: const Text('Disconnect'),
            ),
          ),
        ],
      ),
    ];
  }

  Widget _dpad(BuildContext context) {
    Widget b(IconData icon, String key, String tip) => Padding(
          padding: const EdgeInsets.all(6),
          child: IconButton.filledTonal(
            onPressed: () {
              HapticFeedback.selectionClick();
              link.key(key);
            },
            iconSize: 36,
            padding: const EdgeInsets.all(18),
            icon: Icon(icon),
            tooltip: tip,
          ),
        );
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        b(Icons.keyboard_arrow_up_rounded, 'up', 'Up'),
        Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            b(Icons.keyboard_arrow_left_rounded, 'left', 'Left'),
            Padding(
              padding: const EdgeInsets.all(6),
              child: IconButton.filled(
                onPressed: () {
                  HapticFeedback.selectionClick();
                  link.key('ok');
                },
                iconSize: 36,
                padding: const EdgeInsets.all(18),
                icon: const Icon(Icons.circle_outlined),
                tooltip: 'OK',
              ),
            ),
            b(Icons.keyboard_arrow_right_rounded, 'right', 'Right'),
          ],
        ),
        b(Icons.keyboard_arrow_down_rounded, 'down', 'Down'),
        TextButton.icon(
          onPressed: () => link.key('back'),
          icon: const Icon(Icons.arrow_back_rounded),
          label: const Text('Back'),
        ),
      ],
    );
  }

  Widget _playerCard(BuildContext context, Map<String, dynamic> p) {
    final text = Theme.of(context).textTheme;
    final scheme = Theme.of(context).colorScheme;
    final error = '${p['error'] ?? ''}';
    final pos = (p['pos'] as num?) ?? 0;
    final dur = (p['dur'] as num?) ?? 0;
    final paused = p['paused'] == true;
    final audio = p['audio'] is List ? (p['audio'] as List) : const [];
    final subs = p['subs'] is List ? (p['subs'] as List) : const [];
    final w = (p['w'] as num?) ?? 0;
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('${p['title'] ?? ''}'.isEmpty ? 'Playing on the TV' : '${p['title']}', style: text.titleSmall),
            const SizedBox(height: 4),
            Text(
              error.isNotEmpty
                  ? 'The TV could not play it: $error'
                  : '${p['waiting'] == true && !paused ? 'Loading' : (paused ? 'Paused' : 'Playing')}'
                      ' · ${_clock(pos)} / ${_clock(dur)}'
                      '${w > 0 ? ' · ${w.toInt()}×${((p['h'] as num?) ?? 0).toInt()}' : ''}'
                      ' · audio ${audio.length} · subtitles ${subs.length}',
              style: text.bodySmall?.copyWith(color: error.isNotEmpty ? scheme.error : null),
            ),
            const SizedBox(height: 8),
            LinearProgressIndicator(value: dur > 0 ? (pos / dur).clamp(0.0, 1.0).toDouble() : 0),
            const SizedBox(height: 8),
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceEvenly,
              children: [
                IconButton(
                  onPressed: () => link.player('seekBy', by: -10),
                  icon: const Icon(Icons.replay_10_rounded),
                  tooltip: 'Back 10 seconds',
                ),
                IconButton.filled(
                  onPressed: () => link.player('toggle'),
                  icon: Icon(paused ? Icons.play_arrow_rounded : Icons.pause_rounded),
                  tooltip: paused ? 'Play' : 'Pause',
                ),
                IconButton(
                  onPressed: () => link.player('seekBy', by: 10),
                  icon: const Icon(Icons.forward_10_rounded),
                  tooltip: 'Forward 10 seconds',
                ),
                IconButton(
                  onPressed: link.stopVideo,
                  icon: const Icon(Icons.stop_rounded),
                  tooltip: 'Stop',
                ),
              ],
            ),
            if (audio.length > 1)
              Wrap(
                spacing: 8,
                children: [
                  for (var i = 0; i < audio.length; i++)
                    ActionChip(
                      label: Text('Audio ${i + 1}'),
                      onPressed: () => link.player('audio', index: i),
                    ),
                ],
              ),
          ],
        ),
      ),
    );
  }
}

/// AnymeX+: on a PC, whether the TV app may use this PC for anime from your
/// extensions whenever AnymeX+ is open here.
class _PcSourceSwitch extends StatefulWidget {
  @override
  State<_PcSourceSwitch> createState() => _PcSourceSwitchState();
}

class _PcSourceSwitchState extends State<_PcSourceSwitch> {
  bool on = PlusTvLink.pcSource;

  @override
  Widget build(BuildContext context) => Card(
        child: SwitchListTile(
          value: on,
          title: const Text('Anime source for the TV'),
          subtitle: const Text('While AnymeX+ is open on this PC, the TV app can play anime from your '
              'extensions through it, also when your phone is asleep. Open the TV app from this PC once '
              '(tap your TV above) so the TV knows this PC.'),
          onChanged: (v) {
            setState(() => on = v);
            PlusTvLink.pcSource = v;
          },
        ),
      );
}
