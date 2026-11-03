# Injected by tool/windows/shims/cmake_shim.dart as CMAKE_PROJECT_INCLUDE
# whenever the user-local Ninja toolchain builds this project (see
# tool/windows/README.md). Three fixes for clang-cl builds; outside a
# shim-driven build nothing sets ANDROPI_SPLAT and this file does nothing, so
# a Visual Studio/MSBuild build keeps interpreting everything itself.

if(NOT DEFINED ENV{ANDROPI_SPLAT})
  return()
endif()

# clang-cl keeps the plugin template's `/await` switch, and apply_standard_
# settings adds `/WX` plus a `_HAS_EXCEPTIONS=0` define that /EHsc already
# implies, while the pigeon code generators emit unused stub functions. All
# three trip clang-cl's -Werror - and the suppressions are appended per-target
# inside _andropi_fix_one_dir below, so they land *after* /WX on the command
# line (a directory-level add_compile_options would place them before it).

# Flutter's flutter_assemble custom command produces flutter_windows.dll
#    (and the headers, wrapper sources) but not the import library the plugin
#    and runner links reference. MSBuild never notices; Ninja refuses any
#    graph containing an input with no producing rule. Add that rule: touching
#    the path satisfies the graph, and every link already waits (order-only)
#    on flutter_assemble, whose tool_backend step writes the real content
#    before any link runs.
get_property(_andropi_primer GLOBAL PROPERTY ANDROPI_FLUTTER_LIB_PRIMER)
if(NOT _andropi_primer)
  set_property(GLOBAL PROPERTY ANDROPI_FLUTTER_LIB_PRIMER TRUE)
  set(_andropi_flutter_lib
      "${CMAKE_SOURCE_DIR}/flutter/ephemeral/flutter_windows.dll.lib")
  add_custom_command(
    OUTPUT "${_andropi_flutter_lib}"
    COMMAND "${CMAKE_COMMAND}" -E touch "${_andropi_flutter_lib}"
    COMMENT "AndroPI: placeholder for flutter_windows.dll.lib (flutter_assemble writes the real one)"
  )
  add_custom_target(andropi_flutter_lib_primer ALL
    DEPENDS "${_andropi_flutter_lib}")
endif()

# 3. Fixes that run once all targets of a directory scope exist (registered
#    below as a deferred call, so the walk happens at the end of configure,
#    after the plugin and runner subdirectories have all been processed):
#
#    a) Plugins fetch NuGet packages at configure time and hand the MSBuild
#       `.targets` files to target_link_libraries(); MSBuild would expand
#       those, lld-link just reports "unknown file type". The packages here
#       carry include directories only, so such entries are replaced by a
#       plain target_include_directories() and dropped from the link inputs.
#    b) apply_standard_settings() passes `/wd"4100"` with literal quotes;
#       MSVC's parser strips them, clang-cl does not and aborts on an invalid
#       integral value. Remove the quotes from every target's COMPILE_OPTIONS.
#
# The walk is recursive (plugins nest, e.g. flutter_pty/windows/src) and uses
# per-directory BUILDSYSTEM_TARGETS, because the GLOBAL property is not
# populated until generate time (too late for a deferred call).
function(_andropi_fix_one_dir _dir)
  get_property(_targets DIRECTORY "${_dir}" PROPERTY BUILDSYSTEM_TARGETS)
  foreach(_tgt IN LISTS _targets)
    # (c) append clang-cl suppressions so they follow /WX / -Werror.
    get_property(_opts TARGET "${_tgt}" PROPERTY COMPILE_OPTIONS)
    set(_already FALSE)
    foreach(_o IN LISTS _opts)
      if(_o STREQUAL "-Wno-unused-function")
        set(_already TRUE)
      endif()
    endforeach()
    if(NOT _already)
      list(APPEND _opts
        -Wno-unused-command-line-argument
        -Wno-macro-redefined
        -Wno-unused-function)
      set_property(TARGET "${_tgt}" PROPERTY COMPILE_OPTIONS "${_opts}")
    endif()

    # (b) strip literal quotes from compile options.
    get_property(_opts2 TARGET "${_tgt}" PROPERTY COMPILE_OPTIONS)
    set(_clean_opts "")
    set(_opts_changed FALSE)
    foreach(_o IN LISTS _opts2)
      string(REPLACE "\"" "" _n "${_o}")
      if(NOT _o STREQUAL _n)
        set(_opts_changed TRUE)
      endif()
      list(APPEND _clean_opts "${_n}")
    endforeach()
    if(_opts_changed)
      set_property(TARGET "${_tgt}" PROPERTY COMPILE_OPTIONS "${_clean_opts}")
    endif()

    # (a) replace .targets link entries with their include directory.
    get_property(_links TARGET "${_tgt}" PROPERTY LINK_LIBRARIES)
    set(_kept "")
    set(_changed FALSE)
    foreach(_link IN LISTS _links)
      if(_link MATCHES "\\.targets$")
        set(_changed TRUE)
        # Plugins use the standard <pkg>/build/native/<file>.targets layout,
        # so a two-segment match is exact (and CMake regex has no nested
        # quantifiers, so a greedy variable-depth pattern over-matches).
        string(REGEX REPLACE "/build/[^/]+/[^/]+\\.targets$" ""
               _pkg "${_link}")
        if(IS_DIRECTORY "${_pkg}/include")
          target_include_directories("${_tgt}" PUBLIC "${_pkg}/include")
        else()
          message(WARNING "AndroPI: no include dir derivable from ${_link}")
        endif()
      else()
        list(APPEND _kept "${_link}")
      endif()
    endforeach()
    if(_changed)
      set_property(TARGET "${_tgt}" PROPERTY LINK_LIBRARIES "${_kept}")
      message(STATUS "AndroPI: dropped MSBuild .targets from ${_tgt}")
    endif()
  endforeach()

  get_property(_subs DIRECTORY "${_dir}" PROPERTY SUBDIRECTORIES)
  foreach(_sub IN LISTS _subs)
    get_filename_component(_abs "${_sub}" ABSOLUTE BASE_DIR "${_dir}")
    _andropi_fix_one_dir("${_abs}")
  endforeach()
endfunction()

if(NOT COMMAND _andropi_fix_nuget_link_targets)
  function(_andropi_fix_nuget_link_targets _scope_dir)
    _andropi_fix_one_dir("${_scope_dir}")
  endfunction()
endif()

# Fires at the end of the enclosing directory scope; the top-level project()
# call registers the full walk.
cmake_language(DEFER CALL _andropi_fix_nuget_link_targets
              "${CMAKE_CURRENT_SOURCE_DIR}")