import 'package:logger/logger.dart';

import '../core/sentinel_circuit.dart';
import '../core/sentinel_config.dart';
import '../core/sentinel_state.dart';
import '../persistence/sentinel_hive_controller.dart';
import '../persistence/sentinel_snapshot.dart';

/// Exception thrown when a guarded call is blocked by the circuit breaker.
class SentinelBlockedException implements Exception {
  /// Human-readable reason for the block.
  final String reason;

  const SentinelBlockedException(this.reason);

  @override
  String toString() => 'SentinelBlockedException: $reason';
}

/// Static facade for the SintSentinel circuit breaker & rate limiter.
///
/// ## Quick Start
///
/// ```dart
/// // 1. Initialize once (typically in SentinelApp or main.dart)
/// await SintSentinel.init(config: SentinelConfig.production());
///
/// // 2. Wrap any Future call
/// final doc = await SintSentinel.guard(
///   () => firestore.collection('items').doc(id).get(),
///   tag: 'Item.fetch',
/// );
/// ```
///
/// When the circuit is OPEN, [guard] throws a [SentinelBlockedException]
/// unless a [fallback] is provided, in which case the fallback value is
/// returned instead.
class SintSentinel {
  SintSentinel._(); // Non-instantiable

  // ---------------------------------------------------------------------------
  // Logger — use SintSentinel.logger.d(), .i(), .w(), .e(), .t(), .f()
  // ---------------------------------------------------------------------------

  /// Global logger instance available to all consumers.
  ///
  /// ```dart
  /// SintSentinel.logger.d('Debug message');
  /// SintSentinel.logger.i('Info message');
  /// SintSentinel.logger.w('Warning');
  /// SintSentinel.logger.e('Error', error: e, stackTrace: st);
  /// SintSentinel.logger.t('Trace / verbose');
  /// SintSentinel.logger.f('Fatal');
  /// ```
  ///
  /// Override the default logger via [configureLogger] before or after [init].
  static Logger logger = Logger(
    printer: PrettyPrinter(
      methodCount: 0,
      errorMethodCount: 5,
      lineLength: 80,
      colors: true,
      printEmojis: true,
      dateTimeFormat: DateTimeFormat.onlyTimeAndSinceStart,
    ),
  );

  /// Replaces the default logger with a custom [Logger] instance.
  ///
  /// Call before or after [init] — logging works either way.
  ///
  /// ```dart
  /// SintSentinel.configureLogger(Logger(
  ///   printer: PrettyPrinter(methodCount: 2, colors: false),
  ///   level: Level.warning,
  /// ));
  /// ```
  static void configureLogger(Logger custom) => logger = custom;

  // ---------------------------------------------------------------------------
  // Internal state
  // ---------------------------------------------------------------------------

  static SentinelCircuit? _circuit;
  static Future<void>? _initFuture;
  static SentinelConfig _config = const SentinelConfig();
  static SentinelSnapshotStore _snapshots = SentinelSnapshotStore.instance;

  /// Maximum distinct diagnostic tags retained in memory for telemetry.
  static const int maxTrackedTags = 128;
  static final Map<String, int> _tagCalls = <String, int>{};
  static final Map<String, int> _tagFailures = <String, int>{};
  static final Map<String, int> _tagBlocks = <String, int>{};

  static void _recordTagMetric(Map<String, int> bucket, String? safeTag) {
    if (safeTag == null || safeTag.isEmpty) return;
    if (!bucket.containsKey(safeTag) && bucket.length >= maxTrackedTags) {
      bucket.remove(bucket.keys.first);
    }
    bucket[safeTag] = (bucket[safeTag] ?? 0) + 1;
  }

  /// Sanitizes diagnostic strings (tags, reasons, error messages) so inline
  /// credentials and Bidi/control characters never leak into logs or UI.
  static String sanitizeDiagnosticText(String raw, {int maxChars = 300}) =>
      SentinelCircuit.sanitizeReason(raw, maxChars: maxChars);

  // ---------------------------------------------------------------------------
  // Initialization
  // ---------------------------------------------------------------------------

  /// Initializes the sentinel. Call once before using [guard].
  ///
  /// Safe to call multiple times or concurrently — subsequent calls await or
  /// reuse the active instance without duplicating circuits.
  static Future<void> init({
    SentinelConfig? config,
    SentinelHiveController? hive,
    SentinelSnapshotStore? snapshotStore,
  }) async {
    if (_circuit != null) return; // Already initialized
    if (_initFuture != null) return _initFuture!;

    final future = _performInit(
      config: config,
      hive: hive,
      snapshotStore: snapshotStore,
    );
    _initFuture = future;
    try {
      await future;
    } finally {
      if (identical(_initFuture, future)) {
        _initFuture = null;
      }
    }
  }

  static Future<void> _performInit({
    SentinelConfig? config,
    SentinelHiveController? hive,
    SentinelSnapshotStore? snapshotStore,
  }) async {
    if (_circuit != null) return;

    _config = config ?? const SentinelConfig();
    _snapshots = snapshotStore ?? SentinelSnapshotStore.instance;
    final circuit = SentinelCircuit(
      config: _config,
      hive: hive ?? SentinelHiveController(),
    );
    await circuit.init();
    try {
      await _snapshots.init();
    } catch (_) {
      // Snapshot store falls back to in-memory automatically.
    }
    circuit.onTrip = () => capture();
    _circuit = circuit;
    logger.i('SintSentinel initialized — $_config');
  }

  // ---------------------------------------------------------------------------
  // Guard API
  // ---------------------------------------------------------------------------

  /// Wraps [action] with circuit breaker + rate limiter protection.
  ///
  /// - If the circuit is **CLOSED** and within quota, executes [action]
  ///   and returns its result.
  /// - If the circuit is **OPEN** (or quota exceeded), throws
  ///   [SentinelBlockedException] — unless [fallback] is provided, in
  ///   which case its return value is used instead.
  /// - On success the circuit records a positive signal; on failure
  ///   (exception from [action]) it records a negative signal that may
  ///   trip the circuit.
  ///
  /// [isWrite] should be `true` for write operations so they count
  /// against the daily write quota.
  ///
  /// [tag] is an optional label for logging / diagnostics.
  ///
  /// [countFailureIf] optionally filters which thrown exceptions count toward
  /// tripping the circuit breaker (defaults to counting all exceptions).
  static Future<T> guard<T>(
    Future<T> Function() action, {
    T Function()? fallback,
    bool isWrite = false,
    String? tag,
    bool Function(Object error)? countFailureIf,
  }) async {
    final circuit = _circuit;

    // If sentinel is not initialized, pass through without protection
    if (circuit == null) return action();

    final safeTag = tag != null && tag.trim().isNotEmpty
        ? sanitizeDiagnosticText(tag, maxChars: 80)
        : null;

    // --- Check the circuit ---
    if (!await circuit.canExecute(isWrite: isWrite)) {
      _recordTagMetric(_tagBlocks, safeTag);
      final reason = sanitizeDiagnosticText(circuit.blockReason.value);
      logger.w(
        'Sentinel BLOCKED${safeTag != null ? ' [$safeTag]' : ''}: $reason',
      );
      if (fallback != null) return fallback();
      throw SentinelBlockedException(reason);
    }

    _recordTagMetric(_tagCalls, safeTag);

    // --- Execute the action ---
    try {
      final result = await action();
      await circuit.recordSuccess();
      if (safeTag != null) logger.t('Sentinel OK [$safeTag]');
      return result;
    } catch (e) {
      final shouldCount = countFailureIf == null || countFailureIf(e);
      if (shouldCount) {
        _recordTagMetric(_tagFailures, safeTag);
        await circuit.recordFailure();
      }
      final redactedErr = sanitizeDiagnosticText('$e');
      logger.e(
        'Sentinel FAILURE${safeTag != null ? ' [$safeTag]' : ''}: $redactedErr',
      );
      rethrow;
    }
  }

  /// Convenience wrapper around [guard] for write mutations (`isWrite: true`).
  static Future<T> guardWrite<T>(
    Future<T> Function() action, {
    T Function()? fallback,
    String? tag,
    bool Function(Object error)? countFailureIf,
  }) =>
      guard<T>(
        action,
        fallback: fallback,
        isWrite: true,
        tag: tag,
        countFailureIf: countFailureIf,
      );

  // ---------------------------------------------------------------------------
  // Accessors
  // ---------------------------------------------------------------------------

  /// The underlying [SentinelCircuit] instance, or `null` if not initialized.
  static SentinelCircuit? get circuit => _circuit;

  /// Current config.
  static SentinelConfig get config => _config;

  /// Whether the sentinel has been initialized.
  static bool get isInitialized => _circuit != null;

  /// Whether the circuit is currently open (blocking requests).
  static bool get isBlocking =>
      _circuit?.state.value == SentinelCircuitState.open;

  // ---------------------------------------------------------------------------
  // Status / Debug
  // ---------------------------------------------------------------------------

  /// Returns a full status map (circuit state, traffic snapshot, offenders).
  static Future<Map<String, dynamic>> getStatus() async {
    if (_circuit == null) {
      return {'initialized': false};
    }
    final status = await _circuit!.getStatus();
    status['config'] = _config.toString();
    status['tagMetrics'] = <String, dynamic>{
      'calls': Map<String, int>.from(_tagCalls),
      'failures': Map<String, int>.from(_tagFailures),
      'blocks': Map<String, int>.from(_tagBlocks),
    };
    return status;
  }

  // ---------------------------------------------------------------------------
  // Snapshots
  // ---------------------------------------------------------------------------

  static int _safeStatusInt(Object? raw) {
    if (raw is num && raw.isFinite) {
      final v = raw.toInt();
      return v < 0 ? 0 : v;
    }
    return 0;
  }

  /// Captures a snapshot of the current state and persists it to history.
  ///
  /// Called automatically on every circuit trip. Can also be called on
  /// demand by external consumers (e.g. AI context enrichment).
  static Future<SentinelSnapshot> capture() async {
    final status = await getStatus();
    final rawTraffic = status['traffic'];
    final traffic = rawTraffic is Map
        ? Map<String, dynamic>.from(rawTraffic)
        : const <String, dynamic>{};
    final minPctRaw = traffic['minuteUsagePercent'];
    final readPctRaw = traffic['dailyReadUsagePercent'];
    final rawOffenders = status['rebuildOffenders'];

    final snapshot = SentinelSnapshot(
      timestamp: DateTime.now(),
      circuitState: status['circuitState'] is String
          ? status['circuitState'] as String
          : 'closed',
      blockReason: status['blockReason'] is String
          ? status['blockReason'] as String
          : '',
      consecutiveFailures: _safeStatusInt(status['consecutiveFailures']),
      tripCount: _safeStatusInt(status['tripCount']),
      requestsLastMinute: _safeStatusInt(traffic['requestsLastMinute']),
      dailyReads: _safeStatusInt(traffic['dailyReads']),
      dailyWrites: _safeStatusInt(traffic['dailyWrites']),
      minuteUsagePercent: minPctRaw is num && minPctRaw.isFinite && minPctRaw >= 0
          ? minPctRaw.toDouble()
          : 0.0,
      dailyReadUsagePercent:
          readPctRaw is num && readPctRaw.isFinite && readPctRaw >= 0
          ? readPctRaw.toDouble()
          : 0.0,
      rebuildOffenders: rawOffenders is Iterable
          ? rawOffenders.map((e) => e.toString()).toList()
          : const <String>[],
    );

    await _snapshots.save(snapshot);
    return snapshot;
  }

  /// The most recent snapshot, or `null` if none captured yet.
  static Future<SentinelSnapshot?> get latestSnapshot =>
      _snapshots.getLatest();

  /// All stored snapshots (up to [SentinelSnapshotStore.maxSnapshots]).
  static Future<List<SentinelSnapshot>> get snapshotHistory =>
      _snapshots.getAll();

  /// Snapshots from the last [duration] (e.g. last hour).
  static Future<List<SentinelSnapshot>> recentSnapshots(Duration duration) =>
      _snapshots.getRecent(duration);

  // ---------------------------------------------------------------------------
  // Admin
  // ---------------------------------------------------------------------------

  /// Full reset — closes the circuit and clears all counters.
  static Future<void> reset() async {
    _tagCalls.clear();
    _tagFailures.clear();
    _tagBlocks.clear();
    await _circuit?.reset();
    logger.i('SintSentinel reset — circuit closed, counters cleared');
  }

  /// Disposes the sentinel (for app shutdown / testing).
  static void dispose() {
    _initFuture = null;
    _tagCalls.clear();
    _tagFailures.clear();
    _tagBlocks.clear();
    _circuit?.dispose();
    _circuit = null;
  }
}
