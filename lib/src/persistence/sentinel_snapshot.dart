import 'dart:async';

import 'package:hive_ce_flutter/hive_ce_flutter.dart';

const Set<String> _kUnsafeSnapshotKeys = <String>{
  '__proto__',
  'constructor',
  'prototype',
};

final RegExp _kSnapshotBidiAndControls = RegExp(
  r'[\x00-\x1F\x7F-\x9F\u0085\u061C\u200B-\u200F\u2028-\u202E\u2060\u2066-\u2069\uFEFF]',
);
final RegExp _kSnapshotInternalTags = RegExp(
  r'<\|channel>\s*thought\b[\s\S]*?(?:<channel\|>|$)|<\|turn\|>|<\|im_(?:start|end)\|>|<\s*(think|thinking|thought|memory_recall|system_context|auto_memory)\b[^>]*>[\s\S]*?(?:<\s*/\s*\1\s*>|$)|</?(?:think|thinking|thought|system_context|memory_recall|auto_memory)\b[^>]*>|\[\s*/?\s*(?:MEMORY_RECALL|AUTO_MEMORY|SYSTEM_CONTEXT|BIOCHIP)\b[^\]]*\]',
  caseSensitive: false,
);
final RegExp _kSnapshotInlineSecret = RegExp(
  r'(?:Bearer\s+[A-Za-z0-9._\-~+/]+=*|Basic\s+[A-Za-z0-9._\-~+/]+=*|eyJ[A-Za-z0-9_\-]{8,}\.eyJ[A-Za-z0-9_\-]{8,}\.[A-Za-z0-9_\-]{8,}|(?:sk_live_|sk_test_|rk_live_|rk_test_|sk-)[A-Za-z0-9_\-]{8,}|hf_[A-Za-z0-9]{16,}|AIza[0-9A-Za-z_\-]{12,}|gh[pousr]_[A-Za-z0-9_]{12,}|xox[baprs]-[A-Za-z0-9\-]{10,}|(?:cookie|set-cookie)\s*:\s*[^\r\n;]+|(?:[?&](?:key|api_key|token|access_token|id_token|refresh_token|secret|password)=)[^&\s]+)',
  caseSensitive: false,
);

Map<String, dynamic> _copySafeSnapshotMap(Map<dynamic, dynamic> raw) {
  final out = <String, dynamic>{};
  for (final entry in raw.entries) {
    final key = entry.key?.toString() ?? '';
    if (key.isEmpty || _kUnsafeSnapshotKeys.contains(key)) continue;
    out[key] = entry.value;
  }
  return out;
}

String _cleanSnapshotText(Object? raw, {required int maxChars, String fallback = ''}) {
  if (raw == null || maxChars <= 0) return fallback;
  final text = raw
      .toString()
      .replaceAll(_kSnapshotInternalTags, '')
      .replaceAll(_kSnapshotInlineSecret, '[REDACTED]')
      .replaceAll(_kSnapshotBidiAndControls, '')
      .trim();
  if (text.isEmpty) return fallback;
  if (text.length <= maxChars) return text;
  var end = maxChars;
  final lastCode = text.codeUnitAt(end - 1);
  if (lastCode >= 0xD800 && lastCode <= 0xDBFF) end--;
  return end <= 0 ? fallback : text.substring(0, end);
}

int _parseSnapshotInt(Object? raw, {int fallback = 0}) {
  if (raw is num && raw.isFinite) {
    final v = raw.toInt();
    return v < 0 ? 0 : v;
  }
  if (raw is String) {
    final parsed = int.tryParse(raw.trim());
    if (parsed != null) return parsed < 0 ? 0 : parsed;
  }
  return fallback;
}

double _parseSnapshotDouble(Object? raw, {double fallback = 0.0}) {
  if (raw is num && raw.isFinite) return raw.toDouble();
  if (raw is String) {
    final parsed = double.tryParse(raw.trim());
    if (parsed != null && parsed.isFinite) return parsed;
  }
  return fallback;
}

DateTime _parseSnapshotTimestamp(Object? raw) {
  if (raw is DateTime) return raw;
  if (raw is String) {
    final parsed = DateTime.tryParse(raw.trim());
    if (parsed != null) return parsed;
  }
  if (raw is num && raw.isFinite) {
    final ms = raw.toInt();
    if (ms.abs() <= 8640000000000000) {
      return DateTime.fromMillisecondsSinceEpoch(ms);
    }
  }
  return DateTime.now();
}

/// A point-in-time snapshot of the Sentinel's state.
///
/// Captured automatically on every circuit trip and available on demand
/// via [SentinelSnapshotStore.capture()]. Consumers (like neom_ia) can
/// read the history without building their own audit logic.
class SentinelSnapshot {
  final DateTime timestamp;
  final String circuitState;
  final String blockReason;
  final int consecutiveFailures;
  final int tripCount;
  final int requestsLastMinute;
  final int dailyReads;
  final int dailyWrites;
  final double minuteUsagePercent;
  final double dailyReadUsagePercent;
  final List<String> rebuildOffenders;

  const SentinelSnapshot({
    required this.timestamp,
    required this.circuitState,
    this.blockReason = '',
    this.consecutiveFailures = 0,
    this.tripCount = 0,
    this.requestsLastMinute = 0,
    this.dailyReads = 0,
    this.dailyWrites = 0,
    this.minuteUsagePercent = 0,
    this.dailyReadUsagePercent = 0,
    this.rebuildOffenders = const [],
  });

  /// Status summary: CLEAN, ALERT_open, ALERT_halfOpen, etc.
  String get securityStatus {
    if (circuitState == 'closed') return 'CLEAN';
    return 'ALERT_$circuitState';
  }

  bool get isClean => circuitState == 'closed';

  Map<String, dynamic> toJSON() => {
    'timestamp': timestamp.toIso8601String(),
    'circuitState': circuitState,
    'blockReason': blockReason,
    'consecutiveFailures': consecutiveFailures < 0 ? 0 : consecutiveFailures,
    'tripCount': tripCount < 0 ? 0 : tripCount,
    'requestsLastMinute': requestsLastMinute < 0 ? 0 : requestsLastMinute,
    'dailyReads': dailyReads < 0 ? 0 : dailyReads,
    'dailyWrites': dailyWrites < 0 ? 0 : dailyWrites,
    'minuteUsagePercent': minuteUsagePercent.isFinite && minuteUsagePercent >= 0
        ? minuteUsagePercent
        : 0.0,
    'dailyReadUsagePercent':
        dailyReadUsagePercent.isFinite && dailyReadUsagePercent >= 0
        ? dailyReadUsagePercent
        : 0.0,
    'rebuildOffenders': rebuildOffenders,
    'securityStatus': securityStatus,
  };

  factory SentinelSnapshot.fromJSON(Map<dynamic, dynamic> json) {
    final rawOffenders = json['rebuildOffenders'];
    final offenders = rawOffenders is Iterable
        ? rawOffenders
              .take(64)
              .map((e) => _cleanSnapshotText(e, maxChars: 120))
              .where((s) => s.isNotEmpty)
              .toList()
        : <String>[];
    return SentinelSnapshot(
      timestamp: _parseSnapshotTimestamp(json['timestamp']),
      circuitState: _cleanSnapshotText(
        json['circuitState'],
        maxChars: 32,
        fallback: 'closed',
      ),
      blockReason: _cleanSnapshotText(json['blockReason'], maxChars: 300),
      consecutiveFailures: _parseSnapshotInt(json['consecutiveFailures']),
      tripCount: _parseSnapshotInt(json['tripCount']),
      requestsLastMinute: _parseSnapshotInt(json['requestsLastMinute']),
      dailyReads: _parseSnapshotInt(json['dailyReads']),
      dailyWrites: _parseSnapshotInt(json['dailyWrites']),
      minuteUsagePercent: _parseSnapshotDouble(json['minuteUsagePercent']),
      dailyReadUsagePercent: _parseSnapshotDouble(
        json['dailyReadUsagePercent'],
      ),
      rebuildOffenders: offenders,
    );
  }
}

/// Persistent store for [SentinelSnapshot] history.
///
/// Keeps the last [maxSnapshots] entries in a dedicated Hive box, with
/// automatic in-memory fallback when Hive is unavailable (e.g., tests or
/// restricted browser storage).
class SentinelSnapshotStore {
  SentinelSnapshotStore._({required bool inMemory}) : _inMemory = inMemory;
  static final SentinelSnapshotStore instance = SentinelSnapshotStore._(
    inMemory: false,
  );

  /// Creates an isolated, non-singleton in-memory store (zero disk/Hive IO).
  factory SentinelSnapshotStore.inMemory() =>
      SentinelSnapshotStore._(inMemory: true);

  static const String _boxName = 'sint_sentinel_snapshots';
  static const String _keySnapshots = 'snapshots';
  static const int maxSnapshots = 50;

  final bool _inMemory;
  bool _fallbackInMemory = false;
  final List<Map<String, dynamic>> _memorySnapshots = <Map<String, dynamic>>[];

  Box? _box;

  bool get _useMemory => _inMemory || _fallbackInMemory;

  Future<Box?> _tryGetBox() async {
    if (_useMemory) return null;
    if (_box != null) return _box;
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

  Future<void> init() async {
    await _tryGetBox();
  }

  /// Save a snapshot to the history ring buffer.
  Future<void> save(SentinelSnapshot snapshot) async {
    final box = await _tryGetBox();
    if (box == null) {
      _memorySnapshots.add(snapshot.toJSON());
      while (_memorySnapshots.length > maxSnapshots) {
        _memorySnapshots.removeAt(0);
      }
      return;
    }
    final raw = box.get(_keySnapshots);
    final list = raw is List
        ? raw
              .whereType<Map>()
              .map(_copySafeSnapshotMap)
              .toList()
        : <Map<String, dynamic>>[];

    list.add(snapshot.toJSON());

    // Keep only the latest N
    while (list.length > maxSnapshots) {
      list.removeAt(0);
    }

    await box.put(_keySnapshots, list);
  }

  /// Get all stored snapshots (oldest first).
  Future<List<SentinelSnapshot>> getAll() async {
    final box = await _tryGetBox();
    final Object? raw = box != null ? box.get(_keySnapshots) : _memorySnapshots;
    if (raw is! List) return <SentinelSnapshot>[];
    return raw
        .whereType<Map>()
        .map((e) => SentinelSnapshot.fromJSON(_copySafeSnapshotMap(e)))
        .toList();
  }

  /// Get the most recent snapshot, or null if none.
  Future<SentinelSnapshot?> getLatest() async {
    final all = await getAll();
    return all.isEmpty ? null : all.last;
  }

  /// Get snapshots from the last [duration].
  Future<List<SentinelSnapshot>> getRecent(Duration duration) async {
    final all = await getAll();
    final cutoff = DateTime.now().subtract(duration);
    return all.where((s) => s.timestamp.isAfter(cutoff)).toList();
  }

  /// Clear all snapshot history.
  Future<void> clear() async {
    final box = await _tryGetBox();
    if (box != null) {
      await box.delete(_keySnapshots);
    } else {
      _memorySnapshots.clear();
    }
  }
}
