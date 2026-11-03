// Release driver for AndroPI's desktop ports (Windows and Linux).
//
// Run it through mise so it uses this checkout's toolchain:
//
//   mise run release        # on Windows  -> release/andropi-<v>-windows-x64.zip
//   mise run release        # inside WSL  -> release/andropi-<v>-linux-x64.tar.gz
//
// On Linux it is only `flutter build linux` + tar. On Windows it also prepares
// the user-local toolchain documented in tool/windows/README.md when the
// machine has no Visual Studio (installing one needs an Administrator
// account), before running `flutter build windows` as usual. Nothing is
// written outside the checkout, the scoop app directory and the mise tool
// cache - no global environment variables are touched.
import 'dart:convert';
import 'dart:io';

const xwinRelease =
    'https://github.com/Jake-Shadle/xwin/releases/download/0.10.0/'
    'xwin-0.10.0-x86_64-pc-windows-msvc.tar.gz';

Future<void> main(List<String> args) async {
  final root = Directory.current.absolute.path;
  final version = _readVersion(root);

  if (Platform.isWindows) {
    if (!await _buildWindows(root, version)) exitCode = 1;
    return;
  }
  if (!await _buildLinux(root, version)) exitCode = 1;
}

// ---------------------------------------------------------------------------
// Linux (also runs inside WSL)
// ---------------------------------------------------------------------------

Future<bool> _buildLinux(String root, String version) async {
  if (!await _run('flutter', <String>['build', 'linux', '--release'])) {
    return false;
  }
  final bundle = Directory('$root/build/linux/x64/release/bundle');
  if (!bundle.existsSync()) {
    stderr.writeln('Expected bundle at ${bundle.path} but it does not exist.');
    return false;
  }
  if (!await _bundleAgent(root, bundle.path)) return false;
  Directory('$root/release').createSync(recursive: true);
  final out = '$root/release/andropi-$version-linux-x64.tar.gz';
  if (!await _run(
    'tar',
    <String>['-czf', out, '-C', bundle.path, '.'],
  )) {
    return false;
  }
  stdout.writeln('Release: ${_relative(root, out)}');
  return true;
}

// ---------------------------------------------------------------------------
// Windows
// ---------------------------------------------------------------------------

Future<bool> _buildWindows(String root, String version) async {
  final env = Map<String, String>.from(Platform.environment);

  // What the cmake shim configures for us: a single-config Release build,
  // installing its bundle (see below) under build/ instead of the default
  // "%ProgramFiles(x86)%/<name>" - which for this build is the vswhere stub
  // tree, because PROGRAMFILES(X86) is overridden.
  env['ANDROPI_BUILD_TYPE'] = 'Release';
  final bundleDir = '${root.replaceAll(r'\', '/')}/build/windows/x64/bundle';
  env['ANDROPI_INSTALL_PREFIX'] = bundleDir;

  // A real Visual Studio? Then behave like stock Flutter.
  final realVsWhere =
      '${env['ProgramFiles(x86)'] ?? ''}'
      r'\Microsoft Visual Studio\Installer\vswhere.exe';
  final hasVisualStudio =
      File(realVsWhere).existsSync() &&
      await _succeeds(realVsWhere, <String>['-latest', '-products', '*']);

  if (hasVisualStudio) {
    stdout.writeln('Visual Studio found; building with the stock toolchain.');
  } else {
    stdout.writeln(
      'No Visual Studio (installing one needs an Administrator account); '
      'using the user-local toolchain in tool/windows/.',
    );
    if (!await _prepareUserLocalToolchain(root, env)) return false;
    if (!await _reconfigureIfNeeded(
      root,
      env['ANDROPI_BUILD_TYPE']!,
      env['ANDROPI_INSTALL_PREFIX']!,
    )) {
      return false;
    }
    if (!await _prepareNugetPackages(env)) return false;
  }

  // Flutter links each plugin into windows/flutter/ephemeral/.plugin_symlinks,
  // which Windows only allows for a member of Administrators or with
  // Developer Mode on. Directory junctions need neither, are reported as
  // links by dart:io, and hold the same target string, so seed them first:
  // flutter then finds them valid and skips its own link creation.
  if (!await _seedPluginJunctions(root)) {
    return false;
  }
  if (!hasVisualStudio && !await _patchPluginSources(root)) {
    return false;
  }

  if (!await _run(
    'flutter',
    <String>['build', 'windows', '--release'],
    extraEnv: env,
  )) {
    return false;
  }

  // The bundle CMake's install step assembled at ANDROPI_INSTALL_PREFIX: the
  // exe, flutter_windows.dll, the plugin DLLs, data/flutter_assets, icudtl.dat
  // and the release AOT snapshot - exactly what the zip should carry. (The
  // VS build bundles into runner/Release the same way; with the Ninja shim the
  // exe itself additionally sits in runner/, without its assets.)
  final outDir = Directory(bundleDir);
  if (!outDir.existsSync() || !File('$bundleDir/andropi.exe').existsSync()) {
    stderr.writeln(
      'Expected install bundle at ${outDir.path} but it is missing.',
    );
    return false;
  }
  if (!await _bundleAgent(root, bundleDir)) return false;
  Directory('$root/release').createSync(recursive: true);
  final out = '$root/release/andropi-$version-windows-x64.zip';
  if (!await _run(
    'tar',
    <String>['-a', '-c', '-f', out, '-C', outDir.path, '.'],
    extraEnv: env,
  )) {
    return false;
  }
  stdout.writeln('Release: ${_relative(root, out)}');
  return true;
}

/// Seeds `windows/flutter/ephemeral/.plugin_symlinks/<name>` as directory
/// junctions pointing at the pub cache copies of the plugins (see the comment
/// at the call site). Returns false only when something is truly wrong - an
/// entry that flutter itself will treat as valid is enough.
Future<bool> _seedPluginJunctions(String root) async {
  final deps = File('$root${Platform.pathSeparator}.flutter-plugins-dependencies');
  if (!deps.existsSync()) {
    stderr.writeln('Missing .flutter-plugins-dependencies; run `flutter pub get`.');
    return false;
  }
  final data = jsonDecode(deps.readAsStringSync()) as Map<String, dynamic>;
  final plugins = data['plugins'] as Map<String, dynamic>;

  // `flutter pub get` records each plugin under the pub cache of whichever OS
  // ran it last: building through WSL rewrites these paths to /root/..., a
  // Windows run rewrites them to C:\... . Translate them to this machine's pub
  // cache before anything compares or links against them, so the seeded
  // junctions never point across the OS boundary.
  var healed = false;
  for (final dynamic value in plugins.values) {
    for (final dynamic entry in value! as List<dynamic>) {
      final plugin = entry as Map<String, dynamic>;
      final fixed = _healPluginPath(plugin['path']! as String);
      if (fixed != plugin['path']) {
        plugin['path'] = fixed;
        healed = true;
      }
    }
  }
  if (healed) deps.writeAsStringSync(jsonEncode(data));

  final sep = Platform.pathSeparator;
  // One symlink tree per desktop platform: `flutter build windows` keeps both
  // in sync (the Linux one matters for a Linux host, the Windows one as soon
  // as a checkout with a linux/ runner is built anywhere).
  final linkDirs = <String, Directory>{
    'windows': Directory(
      <String>[root, 'windows', 'flutter', 'ephemeral', '.plugin_symlinks']
          .join(sep),
    ),
    'linux': Directory(
      <String>[root, 'linux', 'flutter', 'ephemeral', '.plugin_symlinks']
          .join(sep),
    ),
  };

  for (final MapEntry<String, Directory> platform in linkDirs.entries) {
    final linkDir = platform.value;
    linkDir.createSync(recursive: true);
    final entries = plugins[platform.key] ?? const <dynamic>[];
    if (!await _seedJunctionsFor(linkDir, entries, sep)) return false;
  }
  return true;
}

Future<bool> _seedJunctionsFor(
  Directory linkDir,
  List<dynamic> plugins,
  String sep,
) async {
  for (final dynamic entry in plugins) {
    final name = (entry as Map<String, dynamic>)['name']! as String;
    final target = ((entry['path']! as String).replaceAll(RegExp(r'[\\/]+$'), ''));
    final linkPath = '${linkDir.path}$sep$name';

    final type = FileSystemEntity.typeSync(linkPath, followLinks: false);
    if (type == FileSystemEntityType.link) {
      try {
        final current = Link(linkPath).targetSync();
        String normalize(String p) => p.replaceAll('/', sep).toLowerCase();
        if (normalize(current).replaceFirst(RegExp(r'[\\/]$'), '') ==
            normalize(target)) {
          continue;
        }
      } on FileSystemException {
        // fall through: recreate it
      }
      Link(linkPath).deleteSync();
    } else if (type == FileSystemEntityType.directory) {
      Directory(linkPath).deleteSync(recursive: true);
    } else if (type != FileSystemEntityType.notFound) {
      File(linkPath).deleteSync();
    }

    final result = Process.runSync(
      'cmd',
      <String>['/c', 'mklink', '/J', linkPath, target],
      runInShell: false,
    );
    if (result.exitCode != 0) {
      stderr.writeln(
        'Could not junction $linkPath -> '
        '${(result.stderr as String).trim()}',
      );
      return false;
    }
  }
  return true;
}

/// One plugin source statement the clang build needs rewritten, inside the
/// `.plugin_symlinks` copy of [plugin] ([relativePath] '/'-separated).
class _ClangSourcePatch {
  const _ClangSourcePatch(
    this.plugin,
    this.relativePath,
    this.from,
    this.to,
  );

  final String plugin;
  final String relativePath;
  final String from;
  final String to;
}

/// clang-cl compiles with standard C++20 coroutines; MSVC - the only compiler
/// Flutter's Windows plugins are tested against - also accepts its legacy
/// `/await` extension, and local_auth_windows relies on it in exactly one
/// place: `RequestVerificationForWindowAsync` is a coroutine (it `co_await`s
/// the verification) yet ends in a plain `return`, which clang rejects as
/// "return statement not allowed in coroutine". Grepping the plugin sources
/// for co_await finds no other case, and upstream flutter/packages still has
/// the same statement, so rewrite it in the pub-cache copy flutter compiles
/// from - the same kind of in-cache fix as the cppwinrt stand-in, applied
/// only when building without Visual Studio.
const _clangSourcePatches = <_ClangSourcePatch>[
  _ClangSourcePatch(
    'local_auth_windows',
    'windows/local_auth_plugin.cpp',
    '    return consent_result;',
    '    co_return consent_result;',
  ),
];

Future<bool> _patchPluginSources(String root) async {
  final sep = Platform.pathSeparator;
  final linkDir = <String>[
    root,
    'windows',
    'flutter',
    'ephemeral',
    '.plugin_symlinks',
  ].join(sep);

  for (final patch in _clangSourcePatches) {
    final segments = <String>[linkDir, patch.plugin, ...patch.relativePath.split('/')];
    final file = File(segments.join(sep));
    if (!file.existsSync()) {
      stderr.writeln('Expected ${file.path} from the ${patch.plugin} plugin.');
      return false;
    }
    final source = file.readAsStringSync();
    if (source.contains(patch.to)) continue; // patched already
    if (!source.contains(patch.from)) {
      // Upstream changed the statement; the patch is obsolete (or wrong),
      // and the compiler will say whether it is now happy.
      stdout.writeln(
        'Note: ${patch.plugin} no longer has the statement patched for '
        'clang-cl; building it unmodified.',
      );
      continue;
    }
    file.writeAsStringSync(source.replaceAll(patch.from, patch.to));
    stdout.writeln(
      'Patched ${patch.plugin}/${patch.relativePath} for clang-cl '
      'coroutine rules.',
    );
  }
  return true;
}

/// The production agent bundle (host.mjs + pruned, minified node_modules +
/// skills) that `agent/build.mjs` stages for the Android asset. It is pure
/// Node.js, so one staging serves both desktop ports.
String? _stagedAgentBundle(String root) {
  final dir = Directory(
    <String>[root, 'build', 'agent-stage', 'out'].join(Platform.pathSeparator),
  );
  if (File('${dir.path}${Platform.pathSeparator}host.mjs').existsSync() &&
      Directory('${dir.path}${Platform.pathSeparator}node_modules').existsSync()) {
    return dir.path;
  }
  return null;
}

/// Copies the production agent bundle into `<bundle>/agent` so the desktop app
/// finds it at runtime (see DesktopProcessBackend) and the release archive is
/// self-contained: at runtime the machine only needs Node.js on PATH. Reuses
/// the existing staging; when the checkout has none yet it runs
/// agent/build.mjs, which stages it and refreshes the Android asset too.
Future<bool> _bundleAgent(String root, String bundleDir) async {
  var src = _stagedAgentBundle(root);
  if (src == null) {
    stdout.writeln('Staging the production agent bundle (npm install + minify)...');
    if (!await _run(
      'node',
      <String>['agent${Platform.pathSeparator}build.mjs'],
      cwd: root,
    )) {
      return false;
    }
    src = _stagedAgentBundle(root);
    if (src == null) {
      stderr.writeln('agent/build.mjs did not produce build/agent-stage/out/host.mjs.');
      return false;
    }
  }
  final dest = '$bundleDir${Platform.pathSeparator}agent';
  final existing = Directory(dest);
  if (existing.existsSync()) existing.deleteSync(recursive: true);
  _copyRecursive(src, dest);
  stdout.writeln(
    'Bundled the agent (${_dirSizeMb(dest)} MB) at ${_relative(root, dest)}',
  );
  return true;
}

void _copyRecursive(String src, String dest) {
  final destDir = Directory(dest)..createSync(recursive: true);
  for (final entity in Directory(src).listSync(followLinks: false)) {
    final target =
        '${destDir.path}${Platform.pathSeparator}${entity.path.split(Platform.pathSeparator).last}';
    if (entity is Directory) {
      _copyRecursive(entity.path, target);
    } else if (entity is File) {
      entity.copySync(target);
    }
  }
}

String _dirSizeMb(String dir) {
  var bytes = 0;
  for (final f in Directory(dir).listSync(recursive: true).whereType<File>()) {
    bytes += f.lengthSync();
  }
  return (bytes / 1e6).toStringAsFixed(1);
}

/// Flutter only runs the CMake configure step while `CMakeCache.txt` is
/// missing, so a cache left by an older configuration - before the shim set
/// a build type, or with the old install prefix - would silently keep being
/// used. Drop it whenever it disagrees with what the shim will inject, which
/// makes flutter configure again on its next invocation.
Future<bool> _reconfigureIfNeeded(
  String root,
  String buildType,
  String prefix,
) async {
  final cache = File('$root/build/windows/x64/CMakeCache.txt');
  if (!cache.existsSync()) return true;
  final text = cache.readAsStringSync();
  final wanted = <String, String>{
    'CMAKE_BUILD_TYPE:STRING=': buildType,
    'CMAKE_INSTALL_PREFIX:PATH=': prefix.replaceAll(r'\', '/'),
  };
  for (final entry in wanted.entries) {
    final line = text
        .split('\n')
        .map((String l) => l.trim())
        .firstWhere((String l) => l.startsWith(entry.key), orElse: () => '');
    if (line != '${entry.key}${entry.value}') {
      stdout.writeln('Reconfiguring: cache holds "$line".');
      cache.deleteSync();
      return true;
    }
  }
  return true;
}

/// Builds/refreshes the shimmed Visual Studio tree and fills [env] with what
/// a clang-lld-lld-link build needs: PATH, INCLUDE, LIB, ANDROPI_* markers for
/// the CMake shim, and the programme-files override that makes flutter find
/// our vswhere stub.
Future<bool> _prepareUserLocalToolchain(
  String root,
  Map<String, String> env,
) async {
  final win = '$root${Platform.pathSeparator}tool${Platform.pathSeparator}windows';
  final sep = Platform.pathSeparator;
  final scoop = env['SCOOP'] ?? '${env['USERPROFILE']}${sep}scoop';

  // 1. clang-cl/lld-link/llvm-lib and the SDK's rc.exe, all per-user scoops.
  final llvmBin = '$scoop${sep}apps${sep}llvm${sep}current${sep}bin';
  if (!File('$llvmBin${sep}clang-cl.exe').existsSync()) {
    stderr.writeln('Missing $llvmBin$sep`clang-cl.exe` - run: scoop install llvm');
    return false;
  }
  final sdkTools = '$scoop${sep}apps${sep}windows-sdk-buildtools${sep}current';
  if (!File('$sdkTools${sep}rc.exe').existsSync()) {
    stderr.writeln(
      'Missing $sdkTools${sep}rc.exe - run: scoop install windows-sdk-buildtools',
    );
    return false;
  }

  // 2. MSVC CRT + Windows SDK headers/libraries, fetched without any installer.
  final splat = await _ensureSplat(win);
  if (splat == null) return false;
  final includes = _splatIncludes(splat);
  final libs = _splatLibs(splat);
  if (includes.isEmpty || libs.isEmpty) {
    stderr.writeln('Could not locate headers/libraries under $splat');
    return false;
  }

  // 3. The vswhere stub and the CMake entry point that flutter insists on.
  final pfx86 = '$win${sep}pfx86';
  final vsRoot = '$win${sep}vs';
  if (!await _compileShim(
    '$win${sep}shims${sep}vswhere_shim.dart',
    '$pfx86$sep' 'Microsoft Visual Studio$sep' 'Installer$sep' 'vswhere.exe',
  )) {
    return false;
  }
  if (!await _compileShim(
    '$win${sep}shims${sep}cmake_shim.dart',
    '$vsRoot$sep' 'Common7$sep' 'IDE$sep' 'CommonExtensions$sep'
        'Microsoft$sep' 'CMake$sep' 'CMake$sep' 'bin$sep' 'cmake.exe',
  )) {
    return false;
  }

  final realCmake = await _which('cmake');
  if (realCmake == null) {
    stderr.writeln('cmake not on PATH - run this through `mise run release`.');
    return false;
  }

  env['PROGRAMFILES(X86)'] = pfx86;
  env['ANDROPI_REAL_CMAKE'] = realCmake;
  env['ANDROPI_TOOLCHAIN'] = '$win${sep}toolchain.cmake';
  env['ANDROPI_SPLAT'] = splat;
  env['PATH'] = <String>[sdkTools, llvmBin, env['PATH'] ?? ''].join(';');
  env['INCLUDE'] = includes.join(';');
  env['LIB'] = libs.join(';');
  return true;
}

/// Pre-installs the NuGet packages the plugins would otherwise fetch during
/// configure, then compiles tool/windows/shims/cppwinrt_shim.dart over
/// nuget's cppwinrt.exe: the real tool only looks for the Windows SDK in the
/// registry, which stays empty on this machine (no installer can run).
/// Re-running `nuget install` afterwards reports "already installed" and
/// keeps the stand-in (verified: same hash and timestamp), so the plugin's
/// own configure step stays stock.
Future<bool> _prepareNugetPackages(Map<String, String> env) async {
  final root = Directory.current.absolute.path;
  final outDir = '$root/build/windows/x64/packages';
  final nuget = await _nugetExe(root, env);
  if (nuget == null) return false;

  const packages = <String, List<String>>{
    'Microsoft.Windows.CppWinRT': <String>['-Version', '2.0.220418.1'],
    'Microsoft.Windows.ImplementationLibrary': <String>[
      '-Version',
      '1.0.220201.1',
    ],
  };
  for (final MapEntry<String, List<String>> package in packages.entries) {
    if (!await _run(nuget, <String>[
      'install',
      package.key,
      ...package.value,
      '-OutputDirectory',
      outDir,
    ])) {
      return false;
    }
  }
  return _compileShim(
    '$root/tool/windows/shims/cppwinrt_shim.dart',
    '$outDir/Microsoft.Windows.CppWinRT.2.0.220418.1/bin/cppwinrt.exe',
  );
}

/// nuget.exe where the plugin's FetchContent would have downloaded it, so a
/// second configure run finds it without touching the network.
Future<String?> _nugetExe(String root, Map<String, String> env) async {
  final cached = File('$root/build/windows/x64/_deps/nuget-src/nuget.exe');
  if (cached.existsSync()) return cached.path;

  stdout.writeln('Fetching nuget.exe...');
  if (!await _run('powershell', <String>[
    '-NoProfile',
    '-Command',
    r'$ProgressPreference="SilentlyContinue"; '
        "Invoke-WebRequest -Uri "
        "'https://dist.nuget.org/win-x86-commandline/v6.0.0/nuget.exe' "
        '-OutFile "\$env:TEMP\\nuget.exe"',
  ])) {
    return null;
  }
  final downloaded = File(
    '${env['TEMP'] ?? '.'}${Platform.pathSeparator}nuget.exe',
  );
  if (!downloaded.existsSync()) return null;
  cached.parent.createSync(recursive: true);
  downloaded.copySync(cached.path);
  return cached.path;
}

/// Downloads (if needed) the MSVC CRT + Windows SDK with xwin. Returns the
/// splat directory, or null on failure.
Future<String?> _ensureSplat(String win) async {
  final splat = '$win${Platform.pathSeparator}splat';
  final cache = '$win${Platform.pathSeparator}.xwin-cache';
  if (_splatIsUsable(splat) && Directory(cache).existsSync()) return splat;

  var xwin = '$win${Platform.pathSeparator}xwin.exe';
  if (!File(xwin).existsSync()) {
    stdout.writeln('Fetching xwin (MSVC CRT + Windows SDK, no installer)...');
    final member = 'xwin-0.10.0-x86_64-pc-windows-msvc/xwin.exe';
    if (!await _run('powershell', <String>[
      '-NoProfile',
      '-Command',
      r'$ProgressPreference="SilentlyContinue"; '
          "Invoke-WebRequest -Uri '$xwinRelease' -OutFile "
          '"\$env:TEMP\\xwin.tgz"; '
          "tar -xzf \"\$env:TEMP\\xwin.tgz\" -C '$win' '$member'",
    ])) {
      return null;
    }
    const folder = 'xwin-0.10.0-x86_64-pc-windows-msvc';
    final produced = '$win${Platform.pathSeparator}$folder'
        '${Platform.pathSeparator}xwin.exe';
    if (!File(produced).existsSync()) return null;
    xwin = '$win${Platform.pathSeparator}xwin.exe';
    File(produced).renameSync(xwin);
    final leftover = Directory('$win${Platform.pathSeparator}$folder');
    if (leftover.existsSync()) leftover.deleteSync(recursive: true);
    if (!File(xwin).existsSync()) return null;
  }

  stdout.writeln('Splatting MSVC CRT and Windows SDK (download + unpack)...');
  for (final step in <List<String>>[
    <String>['--accept-license', 'download'],
    <String>['--accept-license', 'unpack'],
  ]) {
    if (!await _run(xwin, step)) return null;
  }
  // splat exits non-zero when the one directory alias it wants to create would
  // need a symlink privilege this account does not have; everything the build
  // needs is already on disk by then, so validate instead of trusting the code.
  await _run(xwin, <String>[
    '--accept-license',
    'splat',
    // The compiler test and `--debug` builds link the debug CRT
    // (msvcrtd.lib etc.), which xwin prunes unless asked to keep it.
    '--include-debug-libs',
    '--disable-symlinks',
    '--output',
    splat,
  ]);
  if (!_splatIsUsable(splat)) {
    stderr.writeln('xwin splat did not produce a usable tree at $splat');
    return null;
  }
  return splat;
}

/// Include paths for clang-cl: the MSVC CRT headers plus the Windows SDK's
/// `ucrt`, `shared`, `um` (and `winrt`) trees of an xwin splat.
List<String> _splatIncludes(String splat) {
  final out = <String>[];
  void addIfPresent(String path) {
    if (Directory(path).existsSync()) out.add(path);
  }

  addIfPresent('$splat/crt/include');
  for (final part in <String>['ucrt', 'shared', 'um', 'winrt']) {
    addIfPresent('$splat/sdk/include/$part');
  }
  return out;
}

/// Library paths for lld-link: the MSVC CRT libs plus the SDK's `ucrt` and
/// `um` libs for the host architecture (xwin names it x64 or x86_64).
List<String> _splatLibs(String splat) {
  final out = <String>[];
  String? archDir(String parent) {
    for (final name in <String>['x64', 'x86_64']) {
      final d = '$parent/$name';
      if (Directory(d).existsSync()) return d;
    }
    return null;
  }

  final crt = archDir('$splat/crt/lib');
  if (crt != null) out.add(crt);
  for (final part in <String>['ucrt', 'um']) {
    final sdk = archDir('$splat/sdk/lib/$part');
    if (sdk != null) out.add(sdk);
  }
  return out;
}

/// True once the splat holds everything the build compiles and links against.
bool _splatIsUsable(String splat) =>
    Directory('$splat/crt/include').existsSync() &&
    Directory('$splat/crt/lib').existsSync() &&
    Directory('$splat/sdk/include/um').existsSync() &&
    Directory('$splat/sdk/lib/um').existsSync() &&
    Directory('$splat/sdk/lib/ucrt').existsSync();

Future<bool> _compileShim(String source, String output) async {
  final src = File(source);
  if (!src.existsSync()) {
    stderr.writeln('Missing shim source $source');
    return false;
  }
  final exe = File(output);
  if (!exe.existsSync() ||
      src.lastModifiedSync().compareTo(exe.lastModifiedSync()) > 0) {
    exe.parent.createSync(recursive: true);
    final ok = await _run('dart', <String>['compile', 'exe', '-o', output, source]);
    if (!ok) return false;
  }
  return true;
}

// ---------------------------------------------------------------------------
// helpers
// ---------------------------------------------------------------------------

String _readVersion(String root) {
  final file = File(
    '$root${Platform.pathSeparator}pubspec.yaml',
  );
  for (final line in file.readAsLinesSync()) {
    final match = RegExp(r'^version:\s*(\S+)').firstMatch(line);
    if (match != null) return match.group(1)!.split('+').first;
  }
  throw StateError('pubspec.yaml has no version:');
}

/// Rewrites a plugin path recorded by the *other* OS' `flutter pub get` to
/// this machine's pub cache. Unchanged when the path already belongs here.
String _healPluginPath(String path) {
  final looksWindows = RegExp(r'^[A-Za-z]:[/\\]').hasMatch(path);
  if (looksWindows == Platform.isWindows) return path;

  final parts =
      path.replaceAll('\\', '/').split('/').where((String s) => s.isNotEmpty).toList();
  if (parts.isEmpty) return path;
  final pkg = parts.last;
  final sep = Platform.pathSeparator;
  for (final String base in _pubCacheCandidates()) {
    // Fully native separators: cmd's mklink parses a stray `/Pub` in the
    // middle of the target as a switch and refuses the junction.
    final candidate = <String>[base, pkg].join(sep).replaceAll('/', sep);
    if (Directory(candidate).existsSync()) return candidate;
  }
  return path;
}

/// Where `pub` keeps its packages on this OS, in order of likelihood.
List<String> _pubCacheCandidates() {
  final env = Platform.environment;
  if (Platform.isWindows) {
    return <String>[
      if (env['PUB_CACHE'] != null) '${env['PUB_CACHE']}/hosted/pub.dev',
      if (env['LOCALAPPDATA'] != null)
        '${env['LOCALAPPDATA']}/Pub/Cache/hosted/pub.dev',
      if (env['APPDATA'] != null)
        '${env['APPDATA']}/Pub/Cache/hosted/pub.dev',
      if (env['USERPROFILE'] != null)
        '${env['USERPROFILE']}/.pub-cache/hosted/pub.dev',
    ];
  }
  return <String>[
    if (env['PUB_CACHE'] != null) '${env['PUB_CACHE']}/hosted/pub.dev',
    if (env['HOME'] != null) '${env['HOME']}/.pub-cache/hosted/pub.dev',
    if (env['XDG_CACHE_HOME'] != null)
      '${env['XDG_CACHE_HOME']}/pub/hosted/pub.dev',
  ];
}

Future<String?> _which(String exe) async {
  final result = await Process.run(
    Platform.isWindows ? 'where.exe' : 'which',
    <String>[exe],
    runInShell: false,
  );
  if (result.exitCode != 0) return null;
  final lines = (result.stdout as String)
      .split(RegExp(r'\r?\n'))
      .where((l) => l.trim().isNotEmpty)
      .toList();
  return lines.isEmpty ? null : lines.first.trim();
}

Future<bool> _succeeds(String exe, List<String> args) async {
  try {
    final r = await Process.run(exe, args);
    return r.exitCode == 0;
  } catch (_) {
    return false;
  }
}

Future<bool> _run(
  String exe,
  List<String> args, {
  Map<String, String>? extraEnv,
  String? cwd,
}) async {
  stdout.writeln('> ${[exe, ...args].join(' ')}');
  final process = await Process.start(
    exe,
    args,
    environment: extraEnv,
    workingDirectory: cwd,
    mode: ProcessStartMode.inheritStdio,
    runInShell: false,
  );
  return await process.exitCode == 0;
}

String _relative(String root, String path) {
  final from = root.replaceAll('/', Platform.isWindows ? r'\' : '/');
  final to = path.replaceAll('/', Platform.isWindows ? r'\' : '/');
  if (!to.startsWith(from)) return to;
  return to.substring(from.length).replaceFirst(RegExp(r'^[\\/]+'), '');
}