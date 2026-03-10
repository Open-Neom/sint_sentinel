import '../core/sentinel_config.dart';

/// Monitors widget rebuild frequency to detect infinite rebuild loops.
///
/// Keeps an in-memory map of `widgetId → timestamps` and prunes entries
/// older than 1 second. If a widget exceeds [SentinelConfig.maxRebuildsPerSecond]
/// the method returns `false` so the caller can take action (log, trip circuit).
class StateWatchdog {
  final SentinelConfig config;

  /// Map from widget identifier to a list of rebuild timestamps (ms).
  final Map<String, List<int>> _rebuildTimestamps = {};

  /// Counts how many setState calls have been throttled per widget.
  final Map<String, int> _throttleCounts = {};

  /// Tracks which widgets have already triggered a console warning
  /// (to avoid spamming debugPrint on every dropped frame).
  final Set<String> _notifiedWidgets = {};

  StateWatchdog({required this.config});

  // ---------------------------------------------------------------------------
  // Core API
  // ---------------------------------------------------------------------------

  /// Registers a rebuild event for [widgetId].
  ///
  /// Returns `true` if the rebuild rate is **normal** (within threshold),
  /// `false` if the rate is **excessive** (above [config.maxRebuildsPerSecond]).
  bool recordRebuild(String widgetId) {
    final now = DateTime.now().millisecondsSinceEpoch;
    final stamps = _rebuildTimestamps.putIfAbsent(widgetId, () => <int>[]);
    stamps.add(now);

    // Prune entries older than 1 second
    final cutoff = now - 1000;
    stamps.removeWhere((t) => t < cutoff);

    return stamps.length <= config.maxRebuildsPerSecond;
  }

  /// Returns the current rebuild-per-second count for [widgetId].
  int getRebuildsPerSecond(String widgetId) {
    final stamps = _rebuildTimestamps[widgetId];
    if (stamps == null || stamps.isEmpty) return 0;

    final now = DateTime.now().millisecondsSinceEpoch;
    final cutoff = now - 1000;
    stamps.removeWhere((t) => t < cutoff);
    return stamps.length;
  }

  // ---------------------------------------------------------------------------
  // Throttle tracking
  // ---------------------------------------------------------------------------

  /// Records that a setState call was throttled (dropped) for [widgetId].
  ///
  /// Returns the **total** number of throttled calls for this widget.
  int recordThrottle(String widgetId) {
    _throttleCounts[widgetId] = (_throttleCounts[widgetId] ?? 0) + 1;
    return _throttleCounts[widgetId]!;
  }

  /// Whether this widget has already triggered a console warning.
  bool isNotified(String widgetId) => _notifiedWidgets.contains(widgetId);

  /// Marks a widget as having triggered its console warning.
  void markNotified(String widgetId) => _notifiedWidgets.add(widgetId);

  /// Returns the current throttle count for [widgetId] (0 if never throttled).
  int getThrottleCount(String widgetId) => _throttleCounts[widgetId] ?? 0;

  // ---------------------------------------------------------------------------
  // Lifecycle
  // ---------------------------------------------------------------------------

  /// Removes all tracking data for a widget that is no longer in the tree.
  void unregister(String widgetId) {
    _rebuildTimestamps.remove(widgetId);
    _throttleCounts.remove(widgetId);
    _notifiedWidgets.remove(widgetId);
  }

  /// Returns widget IDs that are currently exceeding the rebuild threshold.
  List<String> getOffenders() {
    final now = DateTime.now().millisecondsSinceEpoch;
    final cutoff = now - 1000;
    final offenders = <String>[];

    for (final entry in _rebuildTimestamps.entries) {
      entry.value.removeWhere((t) => t < cutoff);
      if (entry.value.length > config.maxRebuildsPerSecond) {
        offenders.add(entry.key);
      }
    }
    return offenders;
  }

  /// Clears all tracking data.
  void clear() {
    _rebuildTimestamps.clear();
    _throttleCounts.clear();
    _notifiedWidgets.clear();
  }
}
