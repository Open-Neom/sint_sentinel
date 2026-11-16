import 'dart:async';
import 'dart:math' as math;

import 'package:sint/core/sint_core.dart';

import '../persistence/sentinel_hive_controller.dart';
import '../watchdogs/state_watchdog.dart';
import '../watchdogs/traffic_watchdog.dart';
import 'sentinel_config.dart';
import 'sentinel_state.dart';

/// The Circuit Breaker state machine.
class SentinelCircuit {
  final SentinelConfig config;
  final SentinelHiveController _hive;
  final TrafficWatchdog trafficWatchdog;
  final StateWatchdog stateWatchdog;

  /// Current circuit state (reactive — UI can listen via Obx).
  final Rx<SentinelCircuitState> state = SentinelCircuitState.closed.obs;

  /// Human-readable reason for the current block (empty when CLOSED).
  final RxString blockReason = ''.obs;

  int _consecutiveFailures = 0;
  int _halfOpenSuccesses = 0;
  int _halfOpenAdmitted = 0;
  int _tripCount = 0;
  int? _openUntilMs;
  bool _disposed = false;

  /// Optional callback invoked after every circuit trip.
  Future<void> Function()? onTrip;

  factory SentinelCircuit({
    required SentinelConfig config,
    SentinelHiveController? hive,
  }) {
    final sharedHive = hive ?? SentinelHiveController();
    return SentinelCircuit._(
      config: config,
      hive: sharedHive,
    );
  }

  SentinelCircuit._({
    required this.config,
    required SentinelHiveController hive,
  })  : _hive = hive,
        trafficWatchdog = TrafficWatchdog(
          config: config,
          hive: hive,
        ),
        stateWatchdog = StateWatchdog(config: config);

  /// Restores persisted state from Hive. Call once at app startup.
  Future<void> init() async {
    await _hive.init();
    await trafficWatchdog.init();

    final savedState = await _hive.getCircuitState();
    state.value = _parseState(savedState);

    _consecutiveFailures = await _hive.getConsecutiveFailures();
    _tripCount = await _hive.getTripCount();
    _openUntilMs = await _hive.getOpenUntil();

    if (state.value == SentinelCircuitState.open && _openUntilMs != null) {
      await _clampClockSkewedOpenUntilIfNeeded();
      if (DateTime.now().millisecondsSinceEpoch >= _openUntilMs!) {
        _halfOpenSuccesses = 0;
        _halfOpenAdmitted = 0;
        await _transitionTo(SentinelCircuitState.halfOpen);
      }
    }
  }

  int get _maxAllowedOpenHorizonMs {
    final baseMs = math.max(0, config.openDuration.inMilliseconds);
    final fiveMinMs = const Duration(minutes: 5).inMilliseconds;
    return math.max(fiveMinMs * 2, baseMs * 2);
  }

  Future<void> _clampClockSkewedOpenUntilIfNeeded() async {
    final until = _openUntilMs;
    if (until == null) return;
    final now = DateTime.now().millisecondsSinceEpoch;
    if (until - now > _maxAllowedOpenHorizonMs) {
      final fallbackMs = math.min(
        math.max(0, config.openDuration.inMilliseconds),
        const Duration(minutes: 5).inMilliseconds,
      );
      _openUntilMs = now + fallbackMs;
      await _hive.setOpenUntil(_openUntilMs);
    }
  }

  /// Returns `true` if a request is **allowed** to execute.
  Future<bool> canExecute({bool isWrite = false}) async {
    switch (state.value) {
      case SentinelCircuitState.open:
        if (_openUntilMs != null) {
          await _clampClockSkewedOpenUntilIfNeeded();
        }
        if (_openUntilMs != null &&
            DateTime.now().millisecondsSinceEpoch >= _openUntilMs!) {
          _halfOpenSuccesses = 0;
          _halfOpenAdmitted = 0;
          await _transitionTo(SentinelCircuitState.halfOpen);
          if (config.halfOpenTestRequests <= 0) return false;
          _halfOpenAdmitted = 1;
          return true;
        }
        return false;

      case SentinelCircuitState.halfOpen:
        // Strictly bound concurrent in-flight + completed probes!
        if (_halfOpenAdmitted < config.halfOpenTestRequests) {
          _halfOpenAdmitted++;
          return true;
        }
        return false;

      case SentinelCircuitState.closed:
        final withinQuota = await trafficWatchdog.recordRequest(
          isWrite: isWrite,
        );
        if (!withinQuota) {
          await trip(
            trafficWatchdog.violationReason ?? 'Traffic quota exceeded',
          );
          return false;
        }
        return true;
    }
  }

  /// Call after a guarded request **succeeds**.
  Future<void> recordSuccess() async {
    switch (state.value) {
      case SentinelCircuitState.halfOpen:
        _halfOpenSuccesses++;
        if (_halfOpenSuccesses >= config.halfOpenTestRequests) {
          _halfOpenAdmitted = 0;
          await _transitionTo(SentinelCircuitState.closed);
          _consecutiveFailures = 0;
          _tripCount = 0;
          await _hive.setConsecutiveFailures(0);
          await _hive.setTripCount(0);
          await _hive.setOpenUntil(null);
        }

      case SentinelCircuitState.closed:
        if (_consecutiveFailures > 0) {
          _consecutiveFailures = 0;
          await _hive.setConsecutiveFailures(0);
        }

      case SentinelCircuitState.open:
        break;
    }
  }

  /// Call after a guarded request **fails**.
  Future<void> recordFailure() async {
    _consecutiveFailures++;
    await _hive.setConsecutiveFailures(_consecutiveFailures);

    switch (state.value) {
      case SentinelCircuitState.halfOpen:
        await trip('Recovery probe failed');

      case SentinelCircuitState.closed:
        if (_consecutiveFailures >= config.failureThreshold) {
          await trip('Consecutive failures: $_consecutiveFailures');
        }

      case SentinelCircuitState.open:
        break;
    }
  }

  static final RegExp _reasonInternalTags = RegExp(
    r'<\|channel>\s*thought\b[\s\S]*?(?:<channel\|>|$)|<\|turn\|>|<\|im_(?:start|end)\|>|<\s*(think|thinking|thought|memory_recall|system_context|auto_memory)\b[^>]*>[\s\S]*?(?:<\s*/\s*\1\s*>|$)|</?(?:think|thinking|thought|system_context|memory_recall|auto_memory)\b[^>]*>|\[\s*/?\s*(?:MEMORY_RECALL|AUTO_MEMORY|SYSTEM_CONTEXT|BIOCHIP)\b[^\]]*\]',
    caseSensitive: false,
  );
  static final RegExp _reasonControlAndBidi = RegExp(
    r'[\x00-\x1F\x7F-\x9F\u0085\u061C\u200B-\u200F\u2028-\u202E\u2060\u2066-\u2069\uFEFF]',
  );
  static final RegExp _reasonInlineSecret = RegExp(
    r'(?:Bearer\s+[A-Za-z0-9._\-~+/]+=*|Basic\s+[A-Za-z0-9._\-~+/]+=*|eyJ[A-Za-z0-9_\-]{8,}\.eyJ[A-Za-z0-9_\-]{8,}\.[A-Za-z0-9_\-]{8,}|(?:sk_live_|sk_test_|rk_live_|rk_test_|sk-)[A-Za-z0-9_\-]{8,}|hf_[A-Za-z0-9]{16,}|AIza[0-9A-Za-z_\-]{20,}|gh[pousr]_[A-Za-z0-9_]{20,}|xox[baprs]-[A-Za-z0-9\-]{10,}|(?:cookie|set-cookie)\s*:\s*[^\r\n;]+|(?:[?&](?:key|api_key|token|access_token|id_token|refresh_token|secret|password)=)[^&\s]+)',
    caseSensitive: false,
  );

  static String sanitizeReason(String raw, {int maxChars = 300}) {
    final safeCap = maxChars.isFinite ? maxChars : 300;
    if (safeCap <= 0) return '';
    final cleaned = raw
        .replaceAll(_reasonInternalTags, ' ')
        .replaceAll(_reasonInlineSecret, '[REDACTED]')
        .replaceAll(_reasonControlAndBidi, ' ')
        .replaceAll(RegExp(r'\s+'), ' ')
        .trim();
    if (cleaned.length <= safeCap) return cleaned;
    var end = safeCap;
    final lastCode = cleaned.codeUnitAt(end - 1);
    if (lastCode >= 0xD800 && lastCode <= 0xDBFF) end--;
    return end <= 0 ? '' : cleaned.substring(0, end);
  }

  /// Trips the circuit to OPEN and starts the cooldown timer without 64-bit /
  /// JS `Infinity.toInt()` exponential backoff overflow.
  Future<void> trip(String reason) async {
    _tripCount++;
    _halfOpenSuccesses = 0;
    _halfOpenAdmitted = 0;
    await _hive.setTripCount(_tripCount);
    await trafficWatchdog.flushCounters();

    final baseMs = math.max(0, config.openDuration.inMilliseconds);
    final maxCapMs = const Duration(minutes: 5).inMilliseconds;
    var openMs = baseMs;
    if (config.enableExponentialBackoff && _tripCount > 1 && baseMs > 0) {
      // Clamping shift to [0, 16] (`2^16 = 65536`) avoids both 64-bit signed
      // wraparound to negative values and JS `double.infinity.toInt()` crashes.
      final shift = (_tripCount - 1).clamp(0, 16);
      final multiplier = 1 << shift;
      final scaled = baseMs * multiplier;
      openMs = scaled > maxCapMs || scaled < 0 ? maxCapMs : scaled;
    }

    _openUntilMs = DateTime.now().millisecondsSinceEpoch + openMs;
    await _hive.setOpenUntil(_openUntilMs!);

    blockReason.value = sanitizeReason(reason);
    await _transitionTo(SentinelCircuitState.open);

    try {
      await onTrip?.call();
    } catch (_) {
      // Never allow an observer failure to abort or destabilize circuit trip.
    }
  }

  /// Attempts to move from OPEN to HALF_OPEN for manual retry (from UI).
  Future<void> tryHalfOpen() async {
    if (state.value == SentinelCircuitState.open) {
      _halfOpenSuccesses = 0;
      _halfOpenAdmitted = 0;
      await _transitionTo(SentinelCircuitState.halfOpen);
    }
  }

  /// Full reset — returns to CLOSED and clears all counters.
  Future<void> reset() async {
    _consecutiveFailures = 0;
    _halfOpenSuccesses = 0;
    _halfOpenAdmitted = 0;
    _tripCount = 0;
    _openUntilMs = null;
    blockReason.value = '';

    await _hive.setConsecutiveFailures(0);
    await _hive.setTripCount(0);
    await _hive.setOpenUntil(null);
    await trafficWatchdog.resetCounters();
    await _transitionTo(SentinelCircuitState.closed);
  }

  Future<Map<String, dynamic>> getStatus() async {
    final traffic = trafficWatchdog.getSnapshot();
    final safeOpenUntil =
        (_openUntilMs != null && _openUntilMs!.abs() <= 8640000000000000)
        ? DateTime.fromMillisecondsSinceEpoch(_openUntilMs!).toIso8601String()
        : null;
    final minPct = traffic.minuteUsagePercent.isFinite
        ? traffic.minuteUsagePercent
        : 0.0;
    final readPct = traffic.dailyReadUsagePercent.isFinite
        ? traffic.dailyReadUsagePercent
        : 0.0;
    final writePct = traffic.dailyWriteUsagePercent.isFinite
        ? traffic.dailyWriteUsagePercent
        : 0.0;
    return {
      'circuitState': state.value.name,
      'blockReason': blockReason.value,
      'consecutiveFailures': _consecutiveFailures,
      'tripCount': _tripCount,
      'openUntil': safeOpenUntil,
      'traffic': {
        'requestsLastMinute': traffic.requestsLastMinute,
        'dailyReads': traffic.dailyReads,
        'dailyWrites': traffic.dailyWrites,
        'minuteUsagePercent': minPct,
        'dailyReadUsagePercent': readPct,
        'dailyWriteUsagePercent': writePct,
        'minuteUsage': '${minPct.toStringAsFixed(1)}%',
        'dailyReadUsage': '${readPct.toStringAsFixed(1)}%',
        'dailyWriteUsage': '${writePct.toStringAsFixed(1)}%',
      },
      'rebuildOffenders': stateWatchdog.getOffenders(),
    };
  }

  void dispose() {
    if (_disposed) return;
    _disposed = true;
    state.close();
    blockReason.close();
    stateWatchdog.clear();
  }

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
