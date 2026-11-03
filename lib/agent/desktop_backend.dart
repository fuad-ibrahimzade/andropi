import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'backend.dart';

/// Runs the pi agent host (`agent/host.mjs`) as a Node.js child process and
/// bridges it to the app, mirroring what MainActivity + AgentRuntime do on
/// Android. The host is platform-agnostic Node.js — it reads JSONL commands on
/// stdin and writes records on stdout — so no native layer is needed. The
/// difference from Android is where the tools come from: on a desktop the host
/// uses the machine's own `git`/`node`/`curl`/… on PATH, instead of the
/// Android `.so` bundle. The proot Linux container is Android-only and simply
/// reports "not installed" here.
class DesktopProcessBackend implements AgentBackend {
  Process? _proc;
  IOSink? _stdin;
  bool _running = false;
  final _events = StreamController<Map<String, dynamic>>.broadcast();
  Map<String, String> _paths = const {};
  Map<String, String> _env = const {};

  @override
  Stream<Map<String, dynamic>> get events => _events.stream;

  @override
  Future<dynamic> invoke(String method, [dynamic args]) async {
    switch (method) {
      case 'start':
        return _start();
      case 'send':
        _send(args as String);
        return null;
      case 'stop':
        _stop();
        return null;
      case 'isRunning':
        return _running;
      case 'openUrl':
        await _openUrl(args as String);
        return null;
      case 'environment':
        return _env.isEmpty ? _defaultEnv() : _env;
      case 'storageAccess':
        // On a desktop the app can read the real filesystem; the "phone
        // storage" root becomes the user's home, which the folder picker
        // browses like Android's shared storage.
        return <String, dynamic>{'available': true, 'granted': true, 'root': _home()};
      case 'setBusy':
      case 'keepAlive':
      case 'notify':
      case 'requestNotifications':
      case 'requestStorageAccess':
      case 'shareFile':
        // Android-only concerns (foreground service, notifications, share
        // sheet); harmless no-ops on desktop.
        return null;
      case 'takeLaunch':
        return null; // No share/shortcut launches on desktop.
      case 'listen':
        throw UnsupportedError('Voice input uses the system speech recognizer (Android only).');
      case 'saveToDownloads':
        return _saveToDownloads((args as Map)['path'] as String);
      default:
        throw UnsupportedError('Unknown agent method for desktop: $method');
    }
  }

  // ---------------------------------------------------------------------------
  // Process lifecycle

  Future<Map<String, String>> _start() async {
    if (_running) return _paths;

    final node = await _findNode();
    if (node == null) {
      throw const FormatException(
        'Node.js was not found on PATH. Install Node.js 22 or newer to run the agent.',
      );
    }
    final bundle = _findBundle();
    if (bundle == null) {
      throw const FormatException(
        'The agent bundle was not found (host.mjs). Build it with `node agent/build.mjs`.',
      );
    }

    final agentDir = _join([_dataDir(), 'agent']);
    final workspace = _join([_dataDir(), 'workspace']);
    Directory(agentDir).createSync(recursive: true);
    Directory(workspace).createSync(recursive: true);

    final env = _defaultEnv();
    env['PI_CODING_AGENT_DIR'] = agentDir;
    env['ANDROPI_WORKSPACE'] = workspace;
    env['ANDROPI_FILES'] = _dataDir();
    _env = env;
    _paths = <String, String>{
      'home': _home(),
      'agentDir': agentDir,
      'workspace': workspace,
      'hostDir': bundle,
      'nativeLibDir': '',
    };

    final proc = await Process.start(
      node,
      [_join([bundle, 'host.mjs'])],
      workingDirectory: workspace,
      environment: env,
      mode: ProcessStartMode.normal,
    );
    _proc = proc;
    _stdin = proc.stdin;
    _running = true;
    proc.stdout
        .transform(const Utf8Decoder(allowMalformed: true))
        .transform(const LineSplitter())
        .listen((line) => _events.add({'kind': 'stdout', 'line': line}));
    proc.stderr
        .transform(const Utf8Decoder(allowMalformed: true))
        .transform(const LineSplitter())
        .listen((line) => _events.add({'kind': 'stderr', 'line': line}));
    proc.exitCode.then((code) {
      _events.add({'kind': 'exit', 'code': code});
      if (identical(_proc, proc)) {
        _proc = null;
        _stdin = null;
        _running = false;
      }
    });
    return _paths;
  }

  /// The host's stdin sink is not safe for concurrent add/flush, and the app
  /// can issue several commands at once (boot fires history + providers
  /// together). Chain every write after the previous one so they serialize.
  Future<void> _writes = Future.value();

  void _send(String line) {
    final s = _stdin;
    if (s == null) return;
    _writes = _writes
        .then((_) {
          s.add(utf8.encode('$line\n'));
          return s.flush();
        })
        .catchError((Object _) {});
  }

  void _stop() {
    final proc = _proc;
    if (proc == null) return;
    try {
      _stdin?.flush();
      _stdin?.close();
    } catch (_) {}
    // Closing stdin asks the host to dispose and exit; force it if it hangs.
    Future<void>.delayed(const Duration(milliseconds: 1500), () {
      try {
        proc.kill(ProcessSignal.sigkill);
      } catch (_) {}
    });
  }

  // ---------------------------------------------------------------------------
  // Location of node and the bundle

  Future<String?> _findNode() async {
    final override = Platform.environment['ANDROPI_NODE'];
    if (override != null && override.isNotEmpty) return override;
    try {
      final res = await Process.run('node', ['--version']);
      if (res.exitCode == 0) return 'node'; // resolved from PATH by Process.start
    } catch (_) {}
    return null;
  }

  /// Finds a directory holding `host.mjs` next to the pi package. Honours the
  /// `ANDROPI_AGENT_BUNDLE` override, then walks up from the executable (so a
  /// dev build under `build/…/bundle` finds the checkout's `agent/`).
  String? _findBundle() {
    final override = Platform.environment['ANDROPI_AGENT_BUNDLE'];
    if (override != null && File(_join([override, 'host.mjs'])).existsSync()) return override;

    Directory? dir;
    try {
      dir = File(Platform.resolvedExecutable).parent;
    } catch (_) {
      dir = Directory.current;
    }
    for (var i = 0; i < 8 && dir != null; i++) {
      final cand = _join([dir.path, 'agent']);
      if (File(_join([cand, 'host.mjs'])).existsSync() &&
          Directory(_join([cand, 'node_modules', '@earendil-works', 'pi-coding-agent'])).existsSync()) {
        return cand;
      }
      dir = dir.parent;
    }
    return null;
  }

  // ---------------------------------------------------------------------------
  // Environment

  String _home() {
    if (Platform.isWindows) return Platform.environment['USERPROFILE'] ?? '.';
    return Platform.environment['HOME'] ?? Platform.environment['USERPROFILE'] ?? '.';
  }

  String _dataDir() {
    if (Platform.isWindows) {
      final base = Platform.environment['APPDATA'] ?? _join([_home(), 'AppData', 'Roaming']);
      return _join([base, 'andropi']);
    }
    final xdg = Platform.environment['XDG_DATA_HOME'];
    final base = (xdg != null && xdg.isNotEmpty) ? xdg : _join([_home(), '.local', 'share']);
    return _join([base, 'andropi']);
  }

  /// The environment every process the app launches should run with: the agent
  /// host and the terminal. Starts from the inherited environment so the host
  /// OS's tools (git, node, curl, …) stay on PATH.
  Map<String, String> _defaultEnv() {
    final env = Map<String, String>.from(Platform.environment);
    if (env['HOME'] == null || env['HOME']!.isEmpty) env['HOME'] = _home();
    env['PI_SKIP_VERSION_CHECK'] = '1';
    // AndroPI sends no telemetry; keep pi's install ping off.
    env['PI_TELEMETRY'] = '0';
    return env;
  }

  // ---------------------------------------------------------------------------
  // Desktop conveniences

  Future<void> _openUrl(String url) async {
    try {
      if (Platform.isWindows) {
        await Process.run('cmd', ['/c', 'start', '', url]);
      } else if (Platform.isMacOS) {
        await Process.run('open', [url]);
      } else {
        await Process.run('xdg-open', [url]);
      }
    } catch (_) {}
  }

  Future<String> _saveToDownloads(String path) async {
    final src = File(path);
    final name = src.uri.pathSegments.last;
    final home = _home();
    final dir = Directory(_join([home, 'Downloads', 'AndroPI']))..createSync(recursive: true);
    await src.copy(_join([dir.path, name]));
    return 'Downloads/AndroPI/$name';
  }

  String _join(List<String> parts) {
    var out = parts.first;
    for (var i = 1; i < parts.length; i++) {
      final sep = (out.endsWith('/') || out.endsWith('\\')) ? '' : Platform.pathSeparator;
      out = '$out$sep${parts[i]}';
    }
    return out;
  }
}
