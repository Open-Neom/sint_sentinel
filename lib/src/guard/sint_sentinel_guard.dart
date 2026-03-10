import '../core/sentinel_circuit.dart';
import '../core/sentinel_config.dart';
import '../core/sentinel_state.dart';
import '../persistence/sentinel_hive_controller.dart';

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
  // Internal state
  // ---------------------------------------------------------------------------

  static SentinelCircuit? _circuit;
  static SentinelConfig _config = const SentinelConfig();

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
      if (fallback != null) return fallback();
      throw SentinelBlockedException(circuit.blockReason.value);
    }

    // --- Execute the action ---
    try {
      final result = await action();
      await circuit.recordSuccess();
      return result;
    } catch (e) {
      await circuit.recordFailure();
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
  // Admin
  // ---------------------------------------------------------------------------

  /// Full reset — closes the circuit and clears all counters.
  static Future<void> reset() async {
    await _circuit?.reset();
  }

  /// Disposes the sentinel (for app shutdown / testing).
  static void dispose() {
    _circuit?.dispose();
    _circuit = null;
  }
}
