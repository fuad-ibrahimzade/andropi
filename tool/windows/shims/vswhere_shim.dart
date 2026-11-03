// Stand-in for `vswhere.exe` so `flutter build windows` finds a toolchain on
// machines without an Administrator account (where Visual Studio cannot be
// installed). It is copied/rebuilt to
//
//   tool/windows/pfx86/Microsoft Visual Studio/Installer/vswhere.exe
//
// and `tool/release.dart` sets PROGRAMFILES(X86) to `tool/windows/pfx86` for
// the duration of the build, which is where flutter looks for vswhere. The
// installationPath it reports points at `tool/windows/vs`, a shimmed
// Visual Studio tree that only contains the CMake entry point; the CMake shim
// rewrites Flutter's Visual Studio generator invocation to Ninja + clang-cl
// (see tool/windows/shims/cmake_shim.dart and tool/windows/toolchain.cmake).
import 'dart:convert';
import 'dart:io';

void main(List<String> args) {
  // <.../pfx86>/Microsoft Visual Studio/Installer/vswhere.exe -> <.../vs>
  final installerDir = Directory.fromUri(Platform.script).parent;
  final vsRoot =
      '${installerDir.parent.parent.parent.parent.parent.path.replaceAll('\\', '/')}'
      '/tool/windows/vs';

  stdout.write(
    jsonEncode(<Map<String, Object?>>[
      <String, Object?>{
        'installationPath': vsRoot.replaceAll('/', Platform.isWindows ? r'\' : '/'),
        'installationVersion': '17.9.00000.0',
        'displayName': 'Visual Studio Community 2022 (shimmed by AndroPI)',
        'description': 'User-local toolchain shim; see tool/windows/README.md',
        'channelId': 'VisualStudio.17.Release',
        'isComplete': true,
        'isLaunchable': true,
        'isPrerelease': false,
        'isRebootRequired': false,
        'catalog': <String, String>{
          'productDisplayVersion': '17.0',
        },
      },
    ]),
  );
}