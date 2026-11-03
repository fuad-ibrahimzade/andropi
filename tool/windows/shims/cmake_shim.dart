// Stand-in for Visual Studio's `cmake.exe` (the only path Flutter accepts for
// the Windows build). It rewrites the invocation Flutter's Windows build makes
// into an ordinary Ninja + clang-cl build:
//
//   configure:  ... -G "Visual Studio 17 2022" -A x64 ...  ->
//               ... -G Ninja -DCMAKE_TOOLCHAIN_FILE=<toolchain.cmake>
//                   -DCMAKE_BUILD_TYPE=<ANDROPI_BUILD_TYPE>
//                   -DCMAKE_INSTALL_PREFIX=<build>/bundle ...
//   build:      --target INSTALL  ->  --target install  (Ninja is single-config)
//
// Everything else is passed through to the real CMake verbatim.
import 'dart:io';

Future<void> main(List<String> args) async {
  final env = Platform.environment;
  final real = env['ANDROPI_REAL_CMAKE'] ?? 'cmake';
  final toolchain = env['ANDROPI_TOOLCHAIN'];

  List<String> forwarded;
  if (args.contains('-G')) {
    forwarded = <String>[];
    for (var i = 0; i < args.length; i++) {
      final arg = args[i];
      // Drop the generator/platform/toolset flags and their values; Flutter
      // passes each value as the token right after the flag.
      if (arg == '-G' || arg == '-A' || arg == '-T') {
        i++;
        continue;
      }
      if ((arg.startsWith('-G') || arg.startsWith('-A') || arg.startsWith('-T')) &&
          arg.length > 2) {
        continue;
      }
      // Keep -DFLUTTER_* and everything else untouched.
      forwarded.add(arg);
    }
    forwarded.addAll(<String>['-G', 'Ninja']);
    // Ninja is single-config, and Flutter's Visual Studio invocation never
    // says which config it wants (`cmake --build --config Release` carries
    // the choice instead, which Ninja ignores). The release task exports the
    // config it is driving; without it the template defaults to Debug.
    final buildType = env['ANDROPI_BUILD_TYPE'];
    if (buildType != null && buildType.isNotEmpty) {
      forwarded.add('-DCMAKE_BUILD_TYPE=$buildType');
    }
    // Flutter's template leaves CMAKE_INSTALL_PREFIX to CMake's default of
    // "%ProgramFiles(x86)%/<name>" - which is this build's fake vswhere tree,
    // because that is where PROGRAMFILES(X86) points. The release task names
    // the bundle directory explicitly.
    final prefix = env['ANDROPI_INSTALL_PREFIX'];
    if (prefix != null && prefix.isNotEmpty) {
      forwarded.add('-DCMAKE_INSTALL_PREFIX=${_quoteIfNeeded(prefix)}');
    }
    if (toolchain != null) {
      forwarded.addAll(<String>[
        '-DCMAKE_TOOLCHAIN_FILE=${_quoteIfNeeded(toolchain)}',
      ]);
      // Run tool/windows/nuget_link_fix.cmake after every project(): it strips
      // the MSBuild .targets files plugins hand to target_link_libraries()
      // (lld-link: "unknown file type") at the end of each directory scope.
      final fix = toolchain.replaceAll(
        RegExp(r'toolchain\.cmake$'),
        'nuget_link_fix.cmake',
      );
      forwarded.add('-DCMAKE_PROJECT_INCLUDE=${_quoteIfNeeded(fix)}');
    }
  } else {
    forwarded = args.map((String a) {
      if (a == 'INSTALL') return 'install'; // CMake --target INSTALL -> Ninja
      return a;
    }).toList(growable: false);
  }

  final process = await Process.start(
    real,
    forwarded,
    mode: ProcessStartMode.inheritStdio,
  );
  exit(await process.exitCode);
}

String _quoteIfNeeded(String path) => path.contains(' ') ? '"$path"' : path;