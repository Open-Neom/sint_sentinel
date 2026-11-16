import 'dart:async';

import 'package:hive_flutter/hive_flutter.dart';

/// Hive controller for persisting SintSentinel state across app restarts,
/// with an isolated in-memory mode (`SentinelHiveController.inMemory()`) and
/// automatic fallback if Hive is not yet initialized.
class SentinelHiveController {
  static const int maxMinuteTimestamps = 4096;

  static final SentinelHiveController _instance =
      SentinelHiveController._internal(inMemory: false);
  factory SentinelHiveController() => _instance;

  /// Creates an isolated, non-singleton in-memory store (zero disk/Hive IO).
  factory SentinelHiveController.inMemory() =>
      SentinelHiveController._internal(inMemory: true);

  SentinelHiveController._internal({required bool inMemory})
      : _inMemory = inMemory;

  final bool _inMemory;
  bool _fallbackInMemory = false;
  final Map<String, Object?> _memoryStore = <String, Object?>{};

  Box? _box;
  static const String _boxName = 'sint_sentinel';

  Future<Box?> _tryGetBox() async {
    if (_inMemory) return null;
    if (_box != null) {
      if (_box!.isOpen) return _box;
      _box = null;
    }
    if (_fallbackInMemory) return null;
    try {
      if (Hive.isBoxOpen(_boxName)) {
        _box = Hive.box(_boxName);
        return _box;
      }
      final completer = Completer<Box?>();
      runZonedGuarded(
        () async {
          try {
            final opened = await Hive.openBox(_boxName);
            if (!completer.isCompleted) completer.complete(opened);
          } catch (_) {
            if (!completer.isCompleted) completer.complete(null);
          }
        },
        (error, stack) {
          if (!completer.isCompleted) completer.complete(null);
        },
      );
      final box = await completer.future;
      if (box == null) {
        _fallbackInMemory = true;
        return null;
      }
      _box = box;
      return _box;
    } catch (_) {
      _fallbackInMemory = true;
      return null;
    }
  }

  Future<Object?> _read(String key) async {
    final box = await _tryGetBox();
    if (box != null) return box.get(key);
    return _memoryStore[key];
  }

  Future<void> _write(String key, Object? value) async {
    final box = await _tryGetBox();
    if (box != null) {
      if (value == null) {
        await box.delete(key);
      } else {
        await box.put(key, value);
      }
      return;
    }
    if (value == null) {
      _memoryStore.remove(key);
    } else {
      _memoryStore[key] = value;
    }
  }

  Future<void> init() async {
    if (!_inMemory) {
      _fallbackInMemory = false;
    }
    await _tryGetBox();
  }

  static const String _keyCircuitState = 'circuit_state';
  static const String _keyDailyReads = 'daily_reads';
  static const String _keyDailyWrites = 'daily_writes';
  static const String _keyLastResetDate = 'last_reset_date';
  static const String _keyMinuteTimestamps = 'minute_timestamps';
  static const String _keyConsecutiveFailures = 'consecutive_failures';
  static const String _keyOpenUntil = 'open_until';
  static const String _keyTripCount = 'trip_count';

  static final RegExp _unsafeStateChars = RegExp(
    r'[\x00-\x1F\x7F-\x9F\u0085\u061C\u200B-\u200F\u2028-\u202E\u2060-\u2064\u2066-\u2069\uFEFF]',
  );

  static String _sanitizeCircuitState(Object? raw) {
    if (raw is! String) return 'closed';
    final cleaned = raw.replaceAll(_unsafeStateChars, '').trim();
    if (cleaned.isEmpty) return 'closed';
    return cleaned.length > 32 ? cleaned.substring(0, 32) : cleaned;
  }

  static String? _sanitizeIsoDate(Object? raw) {
    if (raw is! String) return null;
    final cleaned = raw.replaceAll(_unsafeStateChars, '').trim();
    if (cleaned.isEmpty || cleaned.length > 64) return null;
    return cleaned;
  }

  static int? _tryFiniteInt(Object? raw) {
    if (raw is num) {
      if (!raw.isFinite || raw.abs() > 9007199254740991) return null;
      return raw.toInt();
    }
    if (raw is String) {
      final parsed = int.tryParse(raw.trim());
      if (parsed == null || parsed.abs() > 9007199254740991) return null;
      return parsed;
    }
    return null;
  }

  static int _clampNonNeg(int? value) {
    if (value == null || value < 0) return 0;
    return value;
  }

  Future<String> getCircuitState() async {
    return _sanitizeCircuitState(await _read(_keyCircuitState));
  }

  Future<void> setCircuitState(String state) async {
    await _write(_keyCircuitState, _sanitizeCircuitState(state));
  }

  Future<int> getDailyReads() async {
    return _clampNonNeg(_tryFiniteInt(await _read(_keyDailyReads)));
  }

  Future<void> setDailyReads(int count) async {
    final safe = _clampNonNeg(_tryFiniteInt(count));
    await _write(_keyDailyReads, safe);
  }

  Future<int> incrementDailyReads() async {
    final count = await getDailyReads() + 1;
    await setDailyReads(count);
    return count;
  }

  Future<int> getDailyWrites() async {
    return _clampNonNeg(_tryFiniteInt(await _read(_keyDailyWrites)));
  }

  Future<void> setDailyWrites(int count) async {
    final safe = _clampNonNeg(_tryFiniteInt(count));
    await _write(_keyDailyWrites, safe);
  }

  Future<int> incrementDailyWrites() async {
    final count = await getDailyWrites() + 1;
    await setDailyWrites(count);
    return count;
  }

  Future<String?> getLastResetDate() async {
    return _sanitizeIsoDate(await _read(_keyLastResetDate));
  }

  Future<void> setLastResetDate(String isoDate) async {
    final safe = _sanitizeIsoDate(isoDate);
    if (safe != null) {
      await _write(_keyLastResetDate, safe);
    }
  }

  Future<List<int>> getMinuteTimestamps() async {
    final raw = await _read(_keyMinuteTimestamps);
    if (raw is! List) return <int>[];
    final items = raw
        .whereType<num>()
        .where((n) => n.isFinite)
        .map((n) => n.toInt())
        .toList();
    if (items.length > maxMinuteTimestamps) {
      return items.sublist(items.length - maxMinuteTimestamps);
    }
    return items;
  }

  Future<void> setMinuteTimestamps(List<int> timestamps) async {
    final capped = timestamps.length > maxMinuteTimestamps
        ? timestamps.sublist(timestamps.length - maxMinuteTimestamps)
        : List<int>.from(timestamps);
    await _write(_keyMinuteTimestamps, capped);
  }

  Future<int> getConsecutiveFailures() async {
    return _clampNonNeg(_tryFiniteInt(await _read(_keyConsecutiveFailures)));
  }

  Future<void> setConsecutiveFailures(int count) async {
    await _write(_keyConsecutiveFailures, _clampNonNeg(_tryFiniteInt(count)));
  }

  Future<int?> getOpenUntil() async {
    final parsed = _tryFiniteInt(await _read(_keyOpenUntil));
    if (parsed == null || parsed < 0 || parsed > 8640000000000000) return null;
    return parsed;
  }

  Future<void> setOpenUntil(int? timestampMs) async {
    final parsed = timestampMs != null ? _tryFiniteInt(timestampMs) : null;
    final safe =
        parsed != null && parsed >= 0 && parsed <= 8640000000000000
        ? parsed
        : null;
    await _write(_keyOpenUntil, safe);
  }

  Future<int> getTripCount() async {
    return _clampNonNeg(_tryFiniteInt(await _read(_keyTripCount)));
  }

  Future<void> setTripCount(int count) async {
    await _write(_keyTripCount, _clampNonNeg(_tryFiniteInt(count)));
  }

  Future<void> resetDaily() async {
    await setDailyReads(0);
    await setDailyWrites(0);
    await setLastResetDate(DateTime.now().toIso8601String());
  }

  Future<void> clearAll() async {
    final box = await _tryGetBox();
    if (box != null) {
      await box.clear();
    } else {
      _memoryStore.clear();
    }
  }
}
