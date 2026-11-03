# Toolchain for the Windows port of AndroPI on machines that do not have (and
# cannot install) Visual Studio. It is injected by tool/windows/shims/cmake_
# shim.dart — the only entry point Flutter's Windows build accepts — and turns
# Flutter's Visual Studio generator invocation into a plain Ninja build:
#
#   clang-cl/lld-link/llvm-lib   scoop's `llvm`            (user-local)
#   rc.exe / mt.exe              scoop's `windows-sdk-buildtools` (user-local)
#   MSVC CRT + Windows SDK       xwin splat, see tool/windows (downloaded)
#
# tool/release.dart exports ANDROPI_SPLAT with the xwin output directory; the
# INCLUDE and LIB environment variables it exports point clang-cl and lld-link
# at the headers and libraries inside it, exactly like a Ninja build driven by
# vcvars64.bat would.

if(DEFINED ENV{ANDROPI_SPLAT})
  set(ANDROPI_SPLAT "$ENV{ANDROPI_SPLAT}")
endif()

set(CMAKE_C_COMPILER clang-cl CACHE FILEPATH "MSVC-compatible clang driver")
set(CMAKE_CXX_COMPILER clang-cl CACHE FILEPATH "MSVC-compatible clang driver")
set(CMAKE_RC_COMPILER rc CACHE FILEPATH "Windows resource compiler from the SDK build tools")
set(CMAKE_LINKER lld-link CACHE FILEPATH "LLVM's MSVC-compatible linker")
set(CMAKE_AR llvm-lib CACHE FILEPATH "LLVM's MSVC-compatible archiver")
set(CMAKE_MT llvm-mt CACHE FILEPATH "LLVM's manifest tool")

# Match what a Visual Studio driven build would use: the DLL runtime (/MD),
# which the prebuilt flutter_windows.dll expects.
set(CMAKE_MSVC_RUNTIME_LIBRARY "MultiThreaded$<$<CONFIG:Debug>:Debug>DLL")