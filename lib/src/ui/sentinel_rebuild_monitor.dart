import 'package:flutter/widgets.dart';

import '../guard/sint_sentinel_guard.dart';

/// A mixin for [State] subclasses that monitors widget rebuild frequency.
///
/// When a widget rebuilds more often than [SentinelConfig.maxRebuildsPerSecond],
/// the excess `setState` calls are dropped to prevent infinite rebuild loops.
///
/// ## Notification Levels
///
/// 1. **Console warning** — A `debugPrint` is emitted the first time a widget
///    exceeds the rebuild threshold (visible in developer tools / logcat).
/// 2. **Circuit trip** — If throttled calls accumulate beyond
///    `maxRebuildsPerSecond × rebuildTripMultiplier`, the circuit breaker
///    trips to OPEN and the maintenance page is shown.
///
/// ## Usage
///
/// ```dart
/// class _MyPageState extends State<MyPage> with SentinelRebuildMonitor {
///   // ... your normal State code
/// }
/// ```
///
/// The mixin automatically:
/// - Intercepts `setState` calls and registers them with the [StateWatchdog].
/// - Drops excess rebuilds if the threshold is exceeded.
/// - Logs a warning on first detection per widget.
/// - Trips the circuit on sustained cyclic rebuild abuse.
/// - Unregisters the widget when disposed.
mixin SentinelRebuildMonitor<T extends StatefulWidget> on State<T> {

  /// Override to provide a custom identifier. Defaults to `runtimeType.toString()`.
  String get sentinelWidgetId => runtimeType.toString();

  @override
  void setState(VoidCallback fn) {
    final circuit = SintSentinel.circuit;
    final watchdog = circuit?.stateWatchdog;

    if (watchdog != null && !watchdog.recordRebuild(sentinelWidgetId)) {
      // ── Rebuild threshold exceeded ──

      // 1. Track the throttled call
      final throttleCount = watchdog.recordThrottle(sentinelWidgetId);

      // 2. Console warning (once per widget lifecycle)
      if (!watchdog.isNotified(sentinelWidgetId)) {
        watchdog.markNotified(sentinelWidgetId);
        final limit = SintSentinel.config.maxRebuildsPerSecond;
        debugPrint(
          '⚠️ SintSentinel: Cyclic rebuild detected in [$sentinelWidgetId]. '
          'Exceeds $limit rebuilds/s. Throttling setState calls.',
        );
      }

      // 3. Trip circuit on sustained abuse
      final tripThreshold = SintSentinel.config.maxRebuildsPerSecond
          * SintSentinel.config.rebuildTripMultiplier;

      if (throttleCount >= tripThreshold && circuit != null) {
        debugPrint(
          '🛑 SintSentinel: Circuit TRIPPED by [$sentinelWidgetId]. '
          '$throttleCount throttled calls (threshold: $tripThreshold). '
          'Showing maintenance page.',
        );
        // Fire-and-forget — the async Hive writes complete in the background.
        // The Rx state update triggers SentinelApp's Obx on the next frame.
        circuit.trip(
          'Cyclic rebuild loop: $sentinelWidgetId '
          '($throttleCount throttled calls)',
        );
      }

      return; // Drop this setState
    }

    super.setState(fn);
  }

  @override
  void dispose() {
    SintSentinel.circuit?.stateWatchdog.unregister(sentinelWidgetId);
    super.dispose();
  }
}
