import 'package:hive_flutter/hive_flutter.dart';

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
    'consecutiveFailures': consecutiveFailures,
    'tripCount': tripCount,
    'requestsLastMinute': requestsLastMinute,
    'dailyReads': dailyReads,
    'dailyWrites': dailyWrites,
    'minuteUsagePercent': minuteUsagePercent,
    'dailyReadUsagePercent': dailyReadUsagePercent,
    'rebuildOffenders': rebuildOffenders,
    'securityStatus': securityStatus,
  };

  factory SentinelSnapshot.fromJSON(Map<dynamic, dynamic> json) {
    return SentinelSnapshot(
      timestamp: DateTime.tryParse(json['timestamp'] ?? '') ?? DateTime.now(),
      circuitState: json['circuitState'] ?? 'closed',
      blockReason: json['blockReason'] ?? '',
      consecutiveFailures: json['consecutiveFailures'] ?? 0,
      tripCount: json['tripCount'] ?? 0,
      requestsLastMinute: json['requestsLastMinute'] ?? 0,
      dailyReads: json['dailyReads'] ?? 0,
      dailyWrites: json['dailyWrites'] ?? 0,
      minuteUsagePercent: (json['minuteUsagePercent'] ?? 0).toDouble(),
      dailyReadUsagePercent: (json['dailyReadUsagePercent'] ?? 0).toDouble(),
      rebuildOffenders: List<String>.from(json['rebuildOffenders'] ?? []),
    );
  }
}

/// Persistent store for [SentinelSnapshot] history.
///
/// Keeps the last [maxSnapshots] entries in a dedicated Hive box.
/// Snapshots are captured automatically on circuit trips and can be
/// captured on demand.
class SentinelSnapshotStore {
  SentinelSnapshotStore._();
  static final SentinelSnapshotStore instance = SentinelSnapshotStore._();

  static const String _boxName = 'sint_sentinel_snapshots';
  static const String _keySnapshots = 'snapshots';
  static const int maxSnapshots = 50;

  Box? _box;

  Future<Box> _getBox() async {
    _box ??= await Hive.openBox(_boxName);
    return _box!;
  }

  Future<void> init() async => await _getBox();

  /// Save a snapshot to the history ring buffer.
  Future<void> save(SentinelSnapshot snapshot) async {
    final box = await _getBox();
    final raw = box.get(_keySnapshots);
    final list = raw is List
        ? raw.map((e) => Map<String, dynamic>.from(e as Map)).toList()
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
    final box = await _getBox();
    final raw = box.get(_keySnapshots);
    if (raw == null) return [];
    return (raw as List)
        .map((e) => SentinelSnapshot.fromJSON(Map<dynamic, dynamic>.from(e as Map)))
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
    final box = await _getBox();
    await box.delete(_keySnapshots);
  }
}
