import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import 'desktop_backend.dart';

/// The platform boundary the [AgentClient] talks to.
///
/// On Android this is the `andropi/agent` method channel plus the
/// `andropi/agent/events` event channel, implemented in MainActivity/
/// AgentRuntime. On desktop there is no native layer: the pi agent host is
/// plain Node.js, so a Dart process driver ([DesktopProcessBackend]) spawns it
/// and bridges the same surface. Keeping the seam this small means the whole
/// agent protocol (prompt, sessions, models, git, …) is platform-agnostic.
abstract class AgentBackend {
  /// Mirrors `MethodChannel.invokeMethod`: [args] is the (single) argument and
  /// the returned value is the method's result (null for void methods).
  Future<dynamic> invoke(String method, [dynamic args]);

  /// Records the host emits, shaped like the Android event channel:
  /// `{kind: stdout, line}` / `{kind: stderr, line}` / `{kind: exit, code}`.
  Stream<Map<String, dynamic>> get events;
}

/// The backend for the platform the app is running on.
AgentBackend defaultBackend() =>
    defaultTargetPlatform == TargetPlatform.android
        ? PlatformChannelBackend()
        : DesktopProcessBackend();

/// The Android bridge over the channels wired up in MainActivity.
class PlatformChannelBackend implements AgentBackend {
  final _method = MethodChannel('andropi/agent');
  final _events = EventChannel('andropi/agent/events');
  Stream<Map<String, dynamic>>? _stream;

  @override
  Future<dynamic> invoke(String method, [dynamic args]) =>
      _method.invokeMethod<dynamic>(method, args);

  @override
  Stream<Map<String, dynamic>> get events =>
      _stream ??= _events.receiveBroadcastStream().map(
            (e) => (e as Map).cast<String, dynamic>(),
          );
}
