// Stand-in for nuget's cppwinrt.exe, used by the local_auth_windows plugin.
//
// The real tool discovers the Windows SDK in the registry, which is empty on
// this machine (no installer ever ran and none can: UAC is unusable). The
// xwin splat, however, already contains the exact same thing cppwinrt would
// generate - the SDK's pre-generated C++/WinRT projection under
// `<splat>/sdk/include/cppwinrt/winrt` - so this stand-in simply copies it
// into the requested output directory and exits 0. See tool/windows/README.md.
//
// Expected invocation (cwd = the plugin's CMake build directory):
//
//   cppwinrt -input sdk -output include
//
// tool/release.dart compiles this over `packages/.../bin/cppwinrt.exe` after
// nuget has downloaded the package (and again before a retry, if nuget
// re-extracted the original over it).
import 'dart:io';

void main(List<String> args) {
  String? output;
  for (var i = 0; i < args.length - 1; i++) {
    if (args[i] == '-output') output = args[i + 1];
  }
  if (output == null) {
    stderr.writeln('cppwinrt stand-in: no -output <dir> argument.');
    exit(1);
  }

  final splat = Platform.environment['ANDROPI_SPLAT'];
  if (splat == null || !Directory(splat).existsSync()) {
    stderr.writeln(
      'cppwinrt stand-in: ANDROPI_SPLAT is not set to the xwin splat '
      '(run this build through `mise run release`).',
    );
    exit(1);
  }

  // The projection the SDK ships pre-generated: <output>/winrt/*.h, the same
  // layout `cppwinrt -input sdk -output <dir>` produces.
  final source = '$splat${Platform.pathSeparator}sdk'
      '${Platform.pathSeparator}include${Platform.pathSeparator}cppwinrt'
      '${Platform.pathSeparator}winrt';
  if (!Directory(source).existsSync()) {
    stderr.writeln('cppwinrt stand-in: no pre-generated headers at $source.');
    exit(1);
  }

  final dest = Directory(
    '$output${Platform.pathSeparator}winrt',
  )..createSync(recursive: true);
  _copyTree(Directory(source), dest);
  exit(0);
}

void _copyTree(Directory from, Directory to) {
  final sep = Platform.pathSeparator;
  for (final entry in from.listSync(followLinks: false)) {
    // Not entry.uri.pathSegments.last: a directory URI ends in '/', so its
    // last segment is empty and every subdirectory would be skipped.
    final path = entry.path;
    final cut = path.lastIndexOf(sep);
    final name = cut < 0 ? path : path.substring(cut + 1);
    if (name.isEmpty) continue;
    if (entry is Directory) {
      final sub = Directory('${to.path}$sep$name')
        ..createSync(recursive: true);
      _copyTree(entry, sub);
    } else if (entry is File) {
      entry.copySync('${to.path}$sep$name');
    }
  }
}
