import 'package:flutter/widgets.dart';

import '../core/sentinel_state.dart';
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
  late final String _defaultSentinelWidgetId =
      '$runtimeType#${identityHashCode(this).toRadixString(16)}';

  /// Override to provide a custom identifier.
  ///
  /// Defaults to an instance-scoped identifier (`StateType#hash`) so multiple
  /// instances of the same widget (e.g. list items) neither share rebuild
  /// counters nor unregister active siblings when one instance is disposed.
  String get sentinelWidgetId => _defaultSentinelWidgetId;

  @override
  void setState(VoidCallback fn) {
    final circuit = SintSentinel.circuit;
    final watchdog = circuit?.stateWatchdog;

    if (watchdog != null && !watchdog.recordRebuild(sentinelWidgetId)) {
      // ── Rebuild threshold exceeded ──
      final safeId = SintSentinel.sanitizeDiagnosticText(
        sentinelWidgetId,
        maxChars: 120,
      );

      // 1. Track the throttled call
      final throttleCount = watchdog.recordThrottle(sentinelWidgetId);

      // 2. Console warning (once per widget lifecycle)
      if (!watchdog.isNotified(sentinelWidgetId)) {
        watchdog.markNotified(sentinelWidgetId);
        final limit = SintSentinel.config.maxRebuildsPerSecond;
        debugPrint(
          '⚠️ SintSentinel: Cyclic rebuild detected in [$safeId]. '
          'Exceeds $limit rebuilds/s. Throttling setState calls.',
        );
      }

      // 3. Trip circuit once on sustained abuse (avoid re-tripping on every
      //    throttled frame while the circuit is already OPEN).
      final tripThreshold = SintSentinel.config.maxRebuildsPerSecond
          * SintSentinel.config.rebuildTripMultiplier;

      if (tripThreshold > 0 &&
          throttleCount >= tripThreshold &&
          circuit != null &&
          circuit.state.value != SentinelCircuitState.open) {
        debugPrint(
          '🛑 SintSentinel: Circuit TRIPPED by [$safeId]. '
          '$throttleCount throttled calls (threshold: $tripThreshold). '
          'Showing maintenance page.',
        );
        // Fire-and-forget — the async Hive writes complete in the background.
        // The Rx state update triggers SentinelApp's Obx on the next frame.
        circuit.trip(
          'Cyclic rebuild loop: $safeId '
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
