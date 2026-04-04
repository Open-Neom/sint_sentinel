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
  static SentinelConfig _config = const SentinelConfig();
  static final SentinelSnapshotStore _snapshots = SentinelSnapshotStore.instance;

  // ---------------------------------------------------------------------------
  // Initialization
  // ---------------------------------------------------------------------------

  /// Initializes the sentinel. Call once before using [guard].
  ///
  /// Safe to call multiple times — subsequent calls are no-ops.
  static Future<void> init({SentinelConfig? config}) async {
    if (_circuit != null) return; // Already initialized

    _config = config ?? const SentinelConfig();
    _circuit = SentinelCircuit(
      config: _config,
      hive: SentinelHiveController(),
    );
    await _circuit!.init();
    await _snapshots.init();
    _circuit!.onTrip = () => capture();
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
  static Future<T> guard<T>(
    Future<T> Function() action, {
    T Function()? fallback,
    bool isWrite = false,
    String? tag,
  }) async {
    final circuit = _circuit;

    // If sentinel is not initialized, pass through without protection
    if (circuit == null) return action();

    // --- Check the circuit ---
    if (!await circuit.canExecute(isWrite: isWrite)) {
      final reason = circuit.blockReason.value;
      logger.w('Sentinel BLOCKED${tag != null ? ' [$tag]' : ''}: $reason');
      if (fallback != null) return fallback();
      throw SentinelBlockedException(reason);
    }

    // --- Execute the action ---
    try {
      final result = await action();
      await circuit.recordSuccess();
      if (tag != null) logger.t('Sentinel OK [$tag]');
      return result;
    } catch (e) {
      await circuit.recordFailure();
      logger.e('Sentinel FAILURE${tag != null ? ' [$tag]' : ''}',
          error: e);
      rethrow;
    }
  }

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
    return status;
  }

  // ---------------------------------------------------------------------------
  // Snapshots
  // ---------------------------------------------------------------------------

  /// Captures a snapshot of the current state and persists it to history.
  ///
  /// Called automatically on every circuit trip. Can also be called on
  /// demand by external consumers (e.g. AI context enrichment).
  static Future<SentinelSnapshot> capture() async {
    final status = await getStatus();
    final traffic = status['traffic'] as Map<String, dynamic>? ?? {};

    final snapshot = SentinelSnapshot(
      timestamp: DateTime.now(),
      circuitState: status['circuitState'] as String? ?? 'closed',
      blockReason: status['blockReason'] as String? ?? '',
      consecutiveFailures: status['consecutiveFailures'] as int? ?? 0,
      tripCount: status['tripCount'] as int? ?? 0,
      requestsLastMinute: traffic['requestsLastMinute'] as int? ?? 0,
      dailyReads: traffic['dailyReads'] as int? ?? 0,
      dailyWrites: traffic['dailyWrites'] as int? ?? 0,
      minuteUsagePercent: (traffic['minuteUsagePercent'] ?? 0).toDouble(),
      dailyReadUsagePercent: (traffic['dailyReadUsagePercent'] ?? 0).toDouble(),
      rebuildOffenders: List<String>.from(status['rebuildOffenders'] ?? []),
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
    await _circuit?.reset();
    logger.i('SintSentinel reset — circuit closed, counters cleared');
  }

  /// Disposes the sentinel (for app shutdown / testing).
  static void dispose() {
    _circuit?.dispose();
    _circuit = null;
  }
}
