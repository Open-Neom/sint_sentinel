import '../core/sentinel_config.dart';

/// Monitors widget rebuild frequency to detect infinite rebuild loops.
///
/// Keeps an in-memory map of `widgetId → timestamps` and prunes entries
/// older than 1 second. If a widget exceeds [SentinelConfig.maxRebuildsPerSecond]
/// the method returns `false` so the caller can take action (log, trip circuit).
class StateWatchdog {
  static const int maxTrackedWidgets = 1024;
  static final RegExp _widgetIdControlAndBidi = RegExp(
    r'[\x00-\x1F\x7F-\x9F\u0085\u061C\u200B-\u200F\u2028-\u202E\u2060\u2066-\u2069\uFEFF]',
  );

  static String _cleanWidgetId(String raw) {
    final cleaned = raw.replaceAll(_widgetIdControlAndBidi, '').trim();
    if (cleaned.length <= 120) return cleaned;
    var end = 120;
    final lastCode = cleaned.codeUnitAt(end - 1);
    if (lastCode >= 0xD800 && lastCode <= 0xDBFF) end--;
    return cleaned.substring(0, end);
  }

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
    final cleanId = _cleanWidgetId(widgetId);
    if (cleanId.isEmpty) return true;
    final now = DateTime.now().millisecondsSinceEpoch;
    final cutoff = now - 1000;
    final maxFuture = now + 1000;
    if (!_rebuildTimestamps.containsKey(cleanId) &&
        _rebuildTimestamps.length >= maxTrackedWidgets) {
      _rebuildTimestamps.removeWhere((_, ts) {
        ts.removeWhere((t) => t < cutoff || t > maxFuture);
        return ts.isEmpty;
      });
      if (_rebuildTimestamps.length >= maxTrackedWidgets) {
        final oldestKey = _rebuildTimestamps.keys.first;
        unregister(oldestKey);
      }
    }
    final stamps = _rebuildTimestamps.putIfAbsent(cleanId, () => <int>[]);
    stamps.add(now);

    // Prune entries older than 1 second or skewed into the future
    stamps.removeWhere((t) => t < cutoff || t > maxFuture);

    return stamps.length <= config.maxRebuildsPerSecond;
  }

  /// Returns the current rebuild-per-second count for [widgetId].
  int getRebuildsPerSecond(String widgetId) {
    final cleanId = _cleanWidgetId(widgetId);
    final stamps = _rebuildTimestamps[cleanId];
    if (stamps == null || stamps.isEmpty) return 0;

    final now = DateTime.now().millisecondsSinceEpoch;
    final cutoff = now - 1000;
    final maxFuture = now + 1000;
    stamps.removeWhere((t) => t < cutoff || t > maxFuture);
    return stamps.length;
  }

  // ---------------------------------------------------------------------------
  // Throttle tracking
  // ---------------------------------------------------------------------------

  /// Records that a setState call was throttled (dropped) for [widgetId].
  ///
  /// Returns the **total** number of throttled calls for this widget.
  int recordThrottle(String widgetId) {
    final cleanId = _cleanWidgetId(widgetId);
    if (cleanId.isEmpty) return 0;
    if (!_throttleCounts.containsKey(cleanId) &&
        _throttleCounts.length >= maxTrackedWidgets) {
      _throttleCounts.remove(_throttleCounts.keys.first);
    }
    _throttleCounts[cleanId] = (_throttleCounts[cleanId] ?? 0) + 1;
    return _throttleCounts[cleanId]!;
  }

  /// Whether this widget has already triggered a console warning.
  bool isNotified(String widgetId) =>
      _notifiedWidgets.contains(_cleanWidgetId(widgetId));

  /// Marks a widget as having triggered its console warning.
  void markNotified(String widgetId) {
    final cleanId = _cleanWidgetId(widgetId);
    if (cleanId.isEmpty) return;
    if (!_notifiedWidgets.contains(cleanId) &&
        _notifiedWidgets.length >= maxTrackedWidgets) {
      _notifiedWidgets.remove(_notifiedWidgets.first);
    }
    _notifiedWidgets.add(cleanId);
  }

  /// Returns the current throttle count for [widgetId] (0 if never throttled).
  int getThrottleCount(String widgetId) =>
      _throttleCounts[_cleanWidgetId(widgetId)] ?? 0;

  // ---------------------------------------------------------------------------
  // Lifecycle
  // ---------------------------------------------------------------------------

  /// Removes all tracking data for a widget that is no longer in the tree.
  void unregister(String widgetId) {
    final cleanId = _cleanWidgetId(widgetId);
    _rebuildTimestamps.remove(cleanId);
    _throttleCounts.remove(cleanId);
    _notifiedWidgets.remove(cleanId);
  }

  /// Returns widget IDs that are currently exceeding the rebuild threshold.
  List<String> getOffenders() {
    final now = DateTime.now().millisecondsSinceEpoch;
    final cutoff = now - 1000;
    final maxFuture = now + 1000;
    final offenders = <String>[];

    for (final entry in _rebuildTimestamps.entries) {
      entry.value.removeWhere((t) => t < cutoff || t > maxFuture);
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
