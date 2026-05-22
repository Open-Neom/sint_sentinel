// sint_sentinel: tests for the in-memory parts that don't need Hive.
// Covers StateWatchdog rebuild throttling, TrafficSnapshot computations,
// and SentinelConfig presets.
import 'package:flutter_test/flutter_test.dart';
import 'package:sint_sentinel/sint_sentinel.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('StateWatchdog.recordRebuild', () {
    test('returns true while under threshold', () {
      final w = StateWatchdog(
        config: const SentinelConfig(maxRebuildsPerSecond: 5),
      );
      for (var i = 0; i < 5; i++) {
        expect(w.recordRebuild('w1'), isTrue);
      }
    });

    test('returns false once strictly above threshold', () {
      final w = StateWatchdog(
        config: const SentinelConfig(maxRebuildsPerSecond: 3),
      );
      // First 3 ok, the 4th in the same second is excessive.
      expect(w.recordRebuild('w'), isTrue);
      expect(w.recordRebuild('w'), isTrue);
      expect(w.recordRebuild('w'), isTrue);
      expect(w.recordRebuild('w'), isFalse);
    });

    test('different widgets do not pollute each other', () {
      final w = StateWatchdog(
        config: const SentinelConfig(maxRebuildsPerSecond: 2),
      );
      for (var i = 0; i < 2; i++) {
        expect(w.recordRebuild('a'), isTrue);
        expect(w.recordRebuild('b'), isTrue);
      }
    });
  });

  group('StateWatchdog throttle counters', () {
    test('recordThrottle returns running total', () {
      final w = StateWatchdog(config: const SentinelConfig());
      expect(w.recordThrottle('w'), 1);
      expect(w.recordThrottle('w'), 2);
      expect(w.getThrottleCount('w'), 2);
    });

    test('getThrottleCount is 0 for unknown widget', () {
      final w = StateWatchdog(config: const SentinelConfig());
      expect(w.getThrottleCount('unknown'), 0);
    });

    test('isNotified / markNotified track first warning', () {
      final w = StateWatchdog(config: const SentinelConfig());
      expect(w.isNotified('w'), isFalse);
      w.markNotified('w');
      expect(w.isNotified('w'), isTrue);
    });
  });

  group('StateWatchdog cleanup', () {
    test('unregister removes widget from all maps', () {
      final w = StateWatchdog(config: const SentinelConfig());
      w.recordRebuild('w');
      w.recordThrottle('w');
      w.markNotified('w');
      w.unregister('w');
      expect(w.getRebuildsPerSecond('w'), 0);
      expect(w.getThrottleCount('w'), 0);
      expect(w.isNotified('w'), isFalse);
    });

    test('clear wipes everything', () {
      final w = StateWatchdog(config: const SentinelConfig());
      w.recordRebuild('a');
      w.recordRebuild('b');
      w.clear();
      expect(w.getRebuildsPerSecond('a'), 0);
      expect(w.getRebuildsPerSecond('b'), 0);
      expect(w.getOffenders(), isEmpty);
    });
  });

  group('StateWatchdog.getOffenders', () {
    test('reports widgets exceeding the threshold', () {
      final w = StateWatchdog(
        config: const SentinelConfig(maxRebuildsPerSecond: 2),
      );
      // Push w1 over the threshold (need > 2, so 4 within the same second).
      for (var i = 0; i < 4; i++) {
        w.recordRebuild('w1');
      }
      // w2 stays within threshold.
      w.recordRebuild('w2');
      final offenders = w.getOffenders();
      expect(offenders, contains('w1'));
      expect(offenders, isNot(contains('w2')));
    });
  });

  group('SentinelConfig presets', () {
    test('development is more permissive than production', () {
      final dev = SentinelConfig.development();
      final prod = SentinelConfig.production();
      expect(dev.maxRequestsPerMinute, greaterThanOrEqualTo(prod.maxRequestsPerMinute));
      expect(dev.maxDailyRequests, greaterThanOrEqualTo(prod.maxDailyRequests));
      expect(dev.failureThreshold, greaterThanOrEqualTo(prod.failureThreshold));
      expect(dev.enableExponentialBackoff, isFalse);
    });

    test('strict is more aggressive than production', () {
      final strict = SentinelConfig.strict();
      final prod = SentinelConfig.production();
      expect(strict.maxRequestsPerMinute, lessThanOrEqualTo(prod.maxRequestsPerMinute));
      expect(strict.failureThreshold, lessThanOrEqualTo(prod.failureThreshold));
      expect(strict.enableExponentialBackoff, isTrue);
    });

    test('default constructor matches documented production defaults', () {
      const cfg = SentinelConfig();
      expect(cfg.maxRequestsPerMinute, 60);
      expect(cfg.maxDailyRequests, 3000);
      expect(cfg.maxDailyWrites, 500);
      expect(cfg.maxRebuildsPerSecond, 30);
      expect(cfg.rebuildTripMultiplier, 3);
      expect(cfg.failureThreshold, 5);
      expect(cfg.openDuration, const Duration(seconds: 30));
      expect(cfg.halfOpenTestRequests, 3);
    });
  });

  group('TrafficSnapshot calculations', () {
    test('isHealthy is true when all sub-quotas pass', () {
      const s = TrafficSnapshot(
        requestsLastMinute: 10,
        dailyReads: 100,
        dailyWrites: 5,
        maxRequestsPerMinute: 60,
        maxDailyRequests: 1000,
        maxDailyWrites: 100,
      );
      expect(s.isHealthy, isTrue);
      expect(s.minuteUsagePercent, closeTo(10 / 60 * 100, 0.001));
      expect(s.dailyReadUsagePercent, closeTo(10.0, 0.001));
      expect(s.dailyWriteUsagePercent, closeTo(5.0, 0.001));
    });

    test('exactly at the limit is NOT within quota (strict less-than)', () {
      const s = TrafficSnapshot(
        requestsLastMinute: 60,
        dailyReads: 0,
        dailyWrites: 0,
        maxRequestsPerMinute: 60,
        maxDailyRequests: 1000,
        maxDailyWrites: 100,
      );
      expect(s.isWithinMinuteQuota, isFalse,
          reason: 'snapshot uses strict <, so == max is OUT');
      expect(s.isHealthy, isFalse);
    });

    test('over daily write quota fails health', () {
      const s = TrafficSnapshot(
        requestsLastMinute: 0,
        dailyReads: 0,
        dailyWrites: 200,
        maxRequestsPerMinute: 60,
        maxDailyRequests: 1000,
        maxDailyWrites: 100,
      );
      expect(s.isWithinDailyWriteQuota, isFalse);
      expect(s.dailyWriteUsagePercent, 200.0);
      expect(s.isHealthy, isFalse);
    });

    test('zero max yields 0% usage (no division by zero)', () {
      const s = TrafficSnapshot(
        requestsLastMinute: 5,
        dailyReads: 5,
        dailyWrites: 5,
        maxRequestsPerMinute: 0,
        maxDailyRequests: 0,
        maxDailyWrites: 0,
      );
      expect(s.minuteUsagePercent, 0);
      expect(s.dailyReadUsagePercent, 0);
      expect(s.dailyWriteUsagePercent, 0);
    });
  });

  group('SentinelCircuitState enum', () {
    test('exposes all 3 documented states', () {
      expect(SentinelCircuitState.values, hasLength(3));
      expect(SentinelCircuitState.values, contains(SentinelCircuitState.closed));
      expect(SentinelCircuitState.values, contains(SentinelCircuitState.open));
      expect(SentinelCircuitState.values, contains(SentinelCircuitState.halfOpen));
    });
  });
}
