import 'package:hive/hive.dart';

/// Singleton Hive controller for persisting SintSentinel state across
/// app restarts.
///
/// Follows the same factory-singleton pattern used by every Hive
/// controller in the Open Neom ecosystem (VstHiveController,
/// GamesHiveController, etc.).
class SentinelHiveController {

  // ---------------------------------------------------------------------------
  // Singleton
  // ---------------------------------------------------------------------------

  static final SentinelHiveController _instance =
      SentinelHiveController._internal();
  factory SentinelHiveController() => _instance;
  SentinelHiveController._internal();

  // ---------------------------------------------------------------------------
  // Hive box
  // ---------------------------------------------------------------------------

  Box? _box;
  static const String _boxName = 'sint_sentinel';

  Future<Box> _getBox() async {
    _box ??= await Hive.openBox(_boxName);
    return _box!;
  }

  Future<void> init() async {
    await _getBox();
  }

  // ---------------------------------------------------------------------------
  // Keys
  // ---------------------------------------------------------------------------

  static const String _keyCircuitState = 'circuit_state';
  static const String _keyDailyReads = 'daily_reads';
  static const String _keyDailyWrites = 'daily_writes';
  static const String _keyLastResetDate = 'last_reset_date';
  static const String _keyMinuteTimestamps = 'minute_timestamps';
  static const String _keyConsecutiveFailures = 'consecutive_failures';
  static const String _keyOpenUntil = 'open_until';
  static const String _keyTripCount = 'trip_count';

  // ---------------------------------------------------------------------------
  // Circuit state
  // ---------------------------------------------------------------------------

  Future<String> getCircuitState() async {
    final box = await _getBox();
    return box.get(_keyCircuitState, defaultValue: 'closed') as String;
  }

  Future<void> setCircuitState(String state) async {
    final box = await _getBox();
    await box.put(_keyCircuitState, state);
  }

  // ---------------------------------------------------------------------------
  // Daily counters
  // ---------------------------------------------------------------------------

  Future<int> getDailyReads() async {
    final box = await _getBox();
    return box.get(_keyDailyReads, defaultValue: 0) as int;
  }

  Future<void> setDailyReads(int count) async {
    final box = await _getBox();
    await box.put(_keyDailyReads, count);
  }

  Future<int> incrementDailyReads() async {
    final count = await getDailyReads() + 1;
    await setDailyReads(count);
    return count;
  }

  Future<int> getDailyWrites() async {
    final box = await _getBox();
    return box.get(_keyDailyWrites, defaultValue: 0) as int;
  }

  Future<void> setDailyWrites(int count) async {
    final box = await _getBox();
    await box.put(_keyDailyWrites, count);
  }

  Future<int> incrementDailyWrites() async {
    final count = await getDailyWrites() + 1;
    await setDailyWrites(count);
    return count;
  }

  // ---------------------------------------------------------------------------
  // Last reset date
  // ---------------------------------------------------------------------------

  Future<String?> getLastResetDate() async {
    final box = await _getBox();
    return box.get(_keyLastResetDate) as String?;
  }

  Future<void> setLastResetDate(String isoDate) async {
    final box = await _getBox();
    await box.put(_keyLastResetDate, isoDate);
  }

  // ---------------------------------------------------------------------------
  // Sliding-window timestamps (milliseconds since epoch)
  // ---------------------------------------------------------------------------

  Future<List<int>> getMinuteTimestamps() async {
    final box = await _getBox();
    final raw = box.get(_keyMinuteTimestamps);
    if (raw == null) return <int>[];
    return (raw as List).cast<int>();
  }

  Future<void> setMinuteTimestamps(List<int> timestamps) async {
    final box = await _getBox();
    await box.put(_keyMinuteTimestamps, timestamps);
  }

  // ---------------------------------------------------------------------------
  // Consecutive failures
  // ---------------------------------------------------------------------------

  Future<int> getConsecutiveFailures() async {
    final box = await _getBox();
    return box.get(_keyConsecutiveFailures, defaultValue: 0) as int;
  }

  Future<void> setConsecutiveFailures(int count) async {
    final box = await _getBox();
    await box.put(_keyConsecutiveFailures, count);
  }

  // ---------------------------------------------------------------------------
  // Open-until timestamp (ms since epoch) — when OPEN state expires
  // ---------------------------------------------------------------------------

  Future<int?> getOpenUntil() async {
    final box = await _getBox();
    return box.get(_keyOpenUntil) as int?;
  }

  Future<void> setOpenUntil(int? timestampMs) async {
    final box = await _getBox();
    if (timestampMs == null) {
      await box.delete(_keyOpenUntil);
    } else {
      await box.put(_keyOpenUntil, timestampMs);
    }
  }

  // ---------------------------------------------------------------------------
  // Trip count (for exponential backoff)
  // ---------------------------------------------------------------------------

  Future<int> getTripCount() async {
    final box = await _getBox();
    return box.get(_keyTripCount, defaultValue: 0) as int;
  }

  Future<void> setTripCount(int count) async {
    final box = await _getBox();
    await box.put(_keyTripCount, count);
  }

  // ---------------------------------------------------------------------------
  // Reset helpers
  // ---------------------------------------------------------------------------

  /// Resets all daily counters and updates the last reset date.
  Future<void> resetDaily() async {
    await setDailyReads(0);
    await setDailyWrites(0);
    await setLastResetDate(DateTime.now().toIso8601String());
  }

  /// Clears the entire sentinel box (full reset).
  Future<void> clearAll() async {
    final box = await _getBox();
    await box.clear();
  }
}
