import '../core/sentinel_config.dart';
import '../persistence/sentinel_hive_controller.dart';

/// Snapshot of current traffic metrics — useful for debugging and UI.
class TrafficSnapshot {
  final int requestsLastMinute;
  final int dailyReads;
  final int dailyWrites;
  final int maxRequestsPerMinute;
  final int maxDailyRequests;
  final int maxDailyWrites;

  const TrafficSnapshot({
    required this.requestsLastMinute,
    required this.dailyReads,
    required this.dailyWrites,
    required this.maxRequestsPerMinute,
    required this.maxDailyRequests,
    required this.maxDailyWrites,
  });

  bool get isWithinMinuteQuota => requestsLastMinute < maxRequestsPerMinute;
  bool get isWithinDailyReadQuota => dailyReads < maxDailyRequests;
  bool get isWithinDailyWriteQuota => dailyWrites < maxDailyWrites;
  bool get isHealthy => isWithinMinuteQuota && isWithinDailyReadQuota && isWithinDailyWriteQuota;

  double get minuteUsagePercent =>
      maxRequestsPerMinute > 0 ? (requestsLastMinute / maxRequestsPerMinute * 100) : 0;
  double get dailyReadUsagePercent =>
      maxDailyRequests > 0 ? (dailyReads / maxDailyRequests * 100) : 0;
  double get dailyWriteUsagePercent =>
      maxDailyWrites > 0 ? (dailyWrites / maxDailyWrites * 100) : 0;

  @override
  String toString() => 'TrafficSnapshot('
      'rpm: $requestsLastMinute/$maxRequestsPerMinute, '
      'reads: $dailyReads/$maxDailyRequests, '
      'writes: $dailyWrites/$maxDailyWrites)';
}

/// Monitors request rates using a sliding 60-second window and daily counters.
///
/// Each call to [recordRequest] returns a [TrafficVerdict] indicating whether
/// the request is within the configured quotas.
class TrafficWatchdog {
  final SentinelConfig config;
  final SentinelHiveController _hive;

  /// In-memory sliding window of timestamps (ms since epoch).
  final List<int> _recentTimestamps = [];

  /// In-memory daily counters (synced to Hive periodically).
  int _dailyReads = 0;
  int _dailyWrites = 0;
  bool _initialized = false;

  TrafficWatchdog({
    required this.config,
    SentinelHiveController? hive,
  }) : _hive = hive ?? SentinelHiveController();

  // ---------------------------------------------------------------------------
  // Initialization
  // ---------------------------------------------------------------------------

  /// Restores counters from Hive and resets if a new day has started.
  Future<void> init() async {
    if (_initialized) return;

    // Restore sliding window
    _recentTimestamps
      ..clear()
      ..addAll(await _hive.getMinuteTimestamps());

    // Restore daily counters
    _dailyReads = await _hive.getDailyReads();
    _dailyWrites = await _hive.getDailyWrites();

    // Check if daily reset is due
    await _resetDailyIfNeeded();

    _initialized = true;
  }

  // ---------------------------------------------------------------------------
  // Core API
  // ---------------------------------------------------------------------------

  /// Records a request and returns `true` if the request is **within** quota,
  /// `false` if it **exceeds** any limit.
  ///
  /// When [isWrite] is `true` the request counts against both the daily read
  /// AND daily write quotas (writes are also reads from a cost perspective).
  ///
  /// When the return value is `false`, the caller should trip the circuit.
  /// The [violationReason] getter contains the human-readable reason.
  Future<bool> recordRequest({bool isWrite = false}) async {
    if (!_initialized) await init();

    final now = DateTime.now().millisecondsSinceEpoch;

    // 1. Prune timestamps older than 60 seconds
    _pruneOldTimestamps(now);

    // 2. Check per-minute rate
    if (_recentTimestamps.length >= config.maxRequestsPerMinute) {
      _lastViolation = 'Rate limit exceeded: '
          '${_recentTimestamps.length}/${config.maxRequestsPerMinute} req/min';
      return false;
    }

    // 3. Check daily reset
    await _resetDailyIfNeeded();

    // 4. Check daily read quota
    if (_dailyReads >= config.maxDailyRequests) {
      _lastViolation = 'Daily read quota exceeded: '
          '$_dailyReads/${config.maxDailyRequests}';
      return false;
    }

    // 5. Check daily write quota (if applicable)
    if (isWrite && _dailyWrites >= config.maxDailyWrites) {
      _lastViolation = 'Daily write quota exceeded: '
          '$_dailyWrites/${config.maxDailyWrites}';
      return false;
    }

    // --- All checks passed — record the request ---

    // Sliding window
    _recentTimestamps.add(now);
    // Persist every 10 requests to avoid thrashing Hive
    if (_recentTimestamps.length % 10 == 0) {
      await _hive.setMinuteTimestamps(List<int>.from(_recentTimestamps));
    }

    // Daily counters
    _dailyReads++;
    if (isWrite) _dailyWrites++;

    // Persist daily counters every 5 requests
    if (_dailyReads % 5 == 0) {
      await _hive.setDailyReads(_dailyReads);
      if (isWrite) await _hive.setDailyWrites(_dailyWrites);
    }

    _lastViolation = null;
    return true;
  }

  /// Human-readable reason for the last quota violation, or `null` if the
  /// last request was within quota.
  String? get violationReason => _lastViolation;
  String? _lastViolation;

  // ---------------------------------------------------------------------------
  // Snapshot / Debug
  // ---------------------------------------------------------------------------

  /// Returns a point-in-time snapshot of traffic metrics.
  TrafficSnapshot getSnapshot() {
    _pruneOldTimestamps(DateTime.now().millisecondsSinceEpoch);
    return TrafficSnapshot(
      requestsLastMinute: _recentTimestamps.length,
      dailyReads: _dailyReads,
      dailyWrites: _dailyWrites,
      maxRequestsPerMinute: config.maxRequestsPerMinute,
      maxDailyRequests: config.maxDailyRequests,
      maxDailyWrites: config.maxDailyWrites,
    );
  }

  // ---------------------------------------------------------------------------
  // Reset
  // ---------------------------------------------------------------------------

  /// Manually resets all counters (admin / testing).
  Future<void> resetCounters() async {
    _recentTimestamps.clear();
    _dailyReads = 0;
    _dailyWrites = 0;
    _lastViolation = null;
    await _hive.resetDaily();
    await _hive.setMinuteTimestamps(<int>[]);
  }

  // ---------------------------------------------------------------------------
  // Internal helpers
  // ---------------------------------------------------------------------------

  void _pruneOldTimestamps(int nowMs) {
    final cutoff = nowMs - const Duration(seconds: 60).inMilliseconds;
    _recentTimestamps.removeWhere((t) => t < cutoff);
  }

  Future<void> _resetDailyIfNeeded() async {
    final lastReset = await _hive.getLastResetDate();
    if (lastReset == null) {
      // First run ever — set today as the reset date.
      await _hive.setLastResetDate(DateTime.now().toIso8601String());
      return;
    }

    final lastResetDate = DateTime.tryParse(lastReset);
    if (lastResetDate == null) {
      await _hive.resetDaily();
      return;
    }

    final elapsed = DateTime.now().difference(lastResetDate);
    if (elapsed >= config.dailyResetDuration) {
      _dailyReads = 0;
      _dailyWrites = 0;
      await _hive.resetDaily();
    }
  }
}
