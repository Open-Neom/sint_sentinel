import 'dart:math' as math;

import 'package:sint/sint.dart';

import '../persistence/sentinel_hive_controller.dart';
import '../watchdogs/state_watchdog.dart';
import '../watchdogs/traffic_watchdog.dart';
import 'sentinel_config.dart';
import 'sentinel_state.dart';

/// The Circuit Breaker state machine.
///
/// Transitions:
/// ```
/// CLOSED ──(quota exceeded / N failures)──▶ OPEN
/// OPEN   ──(openDuration expires)──────────▶ HALF_OPEN
/// HALF_OPEN ──(test succeeds)──────────────▶ CLOSED
/// HALF_OPEN ──(test fails)─────────────────▶ OPEN
/// ```
///
/// The circuit's [state] is an `Rx<SentinelCircuitState>` so the UI can
/// reactively listen for changes (e.g. to show the maintenance page).
class SentinelCircuit {
  final SentinelConfig config;
  final SentinelHiveController _hive;
  final TrafficWatchdog trafficWatchdog;
  final StateWatchdog stateWatchdog;

  // ---------------------------------------------------------------------------
  // Observable state (used by SentinelApp to react)
  // ---------------------------------------------------------------------------

  /// Current circuit state (reactive — UI can listen via Obx).
  final Rx<SentinelCircuitState> state = SentinelCircuitState.closed.obs;

  /// Human-readable reason for the current block (empty when CLOSED).
  final RxString blockReason = ''.obs;

  // ---------------------------------------------------------------------------
  // Internal counters
  // ---------------------------------------------------------------------------

  int _consecutiveFailures = 0;
  int _halfOpenSuccesses = 0;
  int _tripCount = 0;
  int? _openUntilMs;

  // ---------------------------------------------------------------------------
  // Constructor
  // ---------------------------------------------------------------------------

  SentinelCircuit({
    required this.config,
    SentinelHiveController? hive,
  })  : _hive = hive ?? SentinelHiveController(),
        trafficWatchdog = TrafficWatchdog(
          config: config,
          hive: hive ?? SentinelHiveController(),
        ),
        stateWatchdog = StateWatchdog(config: config);

  // ---------------------------------------------------------------------------
  // Initialization
  // ---------------------------------------------------------------------------

  /// Restores persisted state from Hive. Call once at app startup.
  Future<void> init() async {
    await _hive.init();
    await trafficWatchdog.init();

    // Restore circuit state
    final savedState = await _hive.getCircuitState();
    state.value = _parseState(savedState);

    _consecutiveFailures = await _hive.getConsecutiveFailures();
    _tripCount = await _hive.getTripCount();
    _openUntilMs = await _hive.getOpenUntil();

    // If we were OPEN but the timeout has expired, move to HALF_OPEN
    if (state.value == SentinelCircuitState.open && _openUntilMs != null) {
      if (DateTime.now().millisecondsSinceEpoch >= _openUntilMs!) {
        await _transitionTo(SentinelCircuitState.halfOpen);
      }
    }
  }

  // ---------------------------------------------------------------------------
  // Guard entry point
  // ---------------------------------------------------------------------------

  /// Returns `true` if a request is **allowed** to execute.
  ///
  /// Handles state transitions (OPEN → HALF_OPEN on timeout) and verifies
  /// traffic quotas when CLOSED.
  Future<bool> canExecute({bool isWrite = false}) async {
    switch (state.value) {

      case SentinelCircuitState.open:
        // Check if the open duration has expired
        if (_openUntilMs != null &&
            DateTime.now().millisecondsSinceEpoch >= _openUntilMs!) {
          await _transitionTo(SentinelCircuitState.halfOpen);
          _halfOpenSuccesses = 0;
          return true; // Allow first test request
        }
        return false; // Still blocked

      case SentinelCircuitState.halfOpen:
        // Allow up to N test requests
        if (_halfOpenSuccesses < config.halfOpenTestRequests) {
          return true;
        }
        return false;

      case SentinelCircuitState.closed:
        // Check traffic watchdog
        final withinQuota = await trafficWatchdog.recordRequest(
          isWrite: isWrite,
        );
        if (!withinQuota) {
          await trip(trafficWatchdog.violationReason ?? 'Traffic quota exceeded');
          return false;
        }
        return true;
    }
  }

  // ---------------------------------------------------------------------------
  // Result recording
  // ---------------------------------------------------------------------------

  /// Call after a guarded request **succeeds**.
  Future<void> recordSuccess() async {
    switch (state.value) {

      case SentinelCircuitState.halfOpen:
        _halfOpenSuccesses++;
        if (_halfOpenSuccesses >= config.halfOpenTestRequests) {
          // All test requests succeeded — recovery confirmed
          await _transitionTo(SentinelCircuitState.closed);
          _consecutiveFailures = 0;
          _tripCount = 0;
          await _hive.setConsecutiveFailures(0);
          await _hive.setTripCount(0);
          await _hive.setOpenUntil(null);
        }

      case SentinelCircuitState.closed:
        // Reset consecutive failures on success
        if (_consecutiveFailures > 0) {
          _consecutiveFailures = 0;
          await _hive.setConsecutiveFailures(0);
        }

      case SentinelCircuitState.open:
        break; // Should not happen — requests are blocked
    }
  }

  /// Call after a guarded request **fails**.
  Future<void> recordFailure() async {
    _consecutiveFailures++;
    await _hive.setConsecutiveFailures(_consecutiveFailures);

    switch (state.value) {

      case SentinelCircuitState.halfOpen:
        // Recovery probe failed — back to OPEN
        await trip('Recovery probe failed');

      case SentinelCircuitState.closed:
        if (_consecutiveFailures >= config.failureThreshold) {
          await trip('Consecutive failures: $_consecutiveFailures');
        }

      case SentinelCircuitState.open:
        break; // Already open
    }
  }

  // ---------------------------------------------------------------------------
  // State transitions
  // ---------------------------------------------------------------------------

  /// Trips the circuit to OPEN and starts the cooldown timer.
  Future<void> trip(String reason) async {
    _tripCount++;
    await _hive.setTripCount(_tripCount);

    // Calculate open duration with optional exponential backoff
    Duration openDur = config.openDuration;
    if (config.enableExponentialBackoff && _tripCount > 1) {
      final multiplier = math.pow(2, _tripCount - 1).toInt();
      openDur = Duration(
        milliseconds: math.min(
          openDur.inMilliseconds * multiplier,
          const Duration(minutes: 5).inMilliseconds, // Cap at 5 minutes
        ),
      );
    }

    _openUntilMs = DateTime.now().millisecondsSinceEpoch + openDur.inMilliseconds;
    await _hive.setOpenUntil(_openUntilMs!);

    blockReason.value = reason;
    await _transitionTo(SentinelCircuitState.open);
  }

  /// Attempts to move from OPEN to HALF_OPEN for manual retry (from UI).
  Future<void> tryHalfOpen() async {
    if (state.value == SentinelCircuitState.open) {
      _halfOpenSuccesses = 0;
      await _transitionTo(SentinelCircuitState.halfOpen);
    }
  }

  /// Full reset — returns to CLOSED and clears all counters.
  Future<void> reset() async {
    _consecutiveFailures = 0;
    _halfOpenSuccesses = 0;
    _tripCount = 0;
    _openUntilMs = null;
    blockReason.value = '';

    await _hive.setConsecutiveFailures(0);
    await _hive.setTripCount(0);
    await _hive.setOpenUntil(null);
    await trafficWatchdog.resetCounters();
    await _transitionTo(SentinelCircuitState.closed);
  }

  // ---------------------------------------------------------------------------
  // Status / Debug
  // ---------------------------------------------------------------------------

  /// Returns a map with the full sentinel status.
  Future<Map<String, dynamic>> getStatus() async {
    final traffic = trafficWatchdog.getSnapshot();
    return {
      'circuitState': state.value.name,
      'blockReason': blockReason.value,
      'consecutiveFailures': _consecutiveFailures,
      'tripCount': _tripCount,
      'openUntil': _openUntilMs != null
          ? DateTime.fromMillisecondsSinceEpoch(_openUntilMs!).toIso8601String()
          : null,
      'traffic': {
        'requestsLastMinute': traffic.requestsLastMinute,
        'dailyReads': traffic.dailyReads,
        'dailyWrites': traffic.dailyWrites,
        'minuteUsage': '${traffic.minuteUsagePercent.toStringAsFixed(1)}%',
        'dailyReadUsage': '${traffic.dailyReadUsagePercent.toStringAsFixed(1)}%',
        'dailyWriteUsage': '${traffic.dailyWriteUsagePercent.toStringAsFixed(1)}%',
      },
      'rebuildOffenders': stateWatchdog.getOffenders(),
    };
  }

  // ---------------------------------------------------------------------------
  // Disposal
  // ---------------------------------------------------------------------------

  void dispose() {
    state.close();
    blockReason.close();
    stateWatchdog.clear();
  }

  // ---------------------------------------------------------------------------
  // Private helpers
  // ---------------------------------------------------------------------------

  Future<void> _transitionTo(SentinelCircuitState newState) async {
    state.value = newState;
    await _hive.setCircuitState(newState.name);

    if (newState == SentinelCircuitState.closed) {
      blockReason.value = '';
    }
  }

  SentinelCircuitState _parseState(String name) {
    switch (name) {
      case 'open':
        return SentinelCircuitState.open;
      case 'halfOpen':
        return SentinelCircuitState.halfOpen;
      default:
        return SentinelCircuitState.closed;
    }
  }
}
