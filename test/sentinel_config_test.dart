// Tests for `SentinelConfig` presets.

import 'package:flutter_test/flutter_test.dart';
import 'package:sint_sentinel/src/core/sentinel_config.dart';

void main() {
  group('SentinelConfig — defaults', () {
    test('valores default razonables', () {
      const c = SentinelConfig();
      expect(c.maxRequestsPerMinute, 60);
      expect(c.maxDailyRequests, 3000);
      expect(c.maxDailyWrites, 500);
      expect(c.maxRebuildsPerSecond, 30);
      expect(c.rebuildTripMultiplier, 3);
      expect(c.failureThreshold, 5);
      expect(c.openDuration, const Duration(seconds: 30));
      expect(c.halfOpenTestRequests, 3);
      expect(c.dailyResetDuration, const Duration(hours: 24));
      expect(c.enableExponentialBackoff, isTrue);
    });

    test('es const-constructible', () {
      const a = SentinelConfig();
      const b = SentinelConfig();
      expect(identical(a, b), isTrue);
    });
  });

  group('SentinelConfig.development preset', () {
    test('límites más relajados que default', () {
      final dev = SentinelConfig.development();
      const def = SentinelConfig();

      expect(dev.maxRequestsPerMinute, greaterThan(def.maxRequestsPerMinute));
      expect(dev.maxDailyRequests, greaterThan(def.maxDailyRequests));
      expect(dev.maxDailyWrites, greaterThan(def.maxDailyWrites));
      expect(dev.maxRebuildsPerSecond, greaterThan(def.maxRebuildsPerSecond));
      expect(dev.failureThreshold, greaterThan(def.failureThreshold));
    });

    test('exponentialBackoff DESACTIVADO en dev', () {
      expect(SentinelConfig.development().enableExponentialBackoff, isFalse);
    });

    test('openDuration menor que default (15s vs 30s)', () {
      expect(
        SentinelConfig.development().openDuration,
        const Duration(seconds: 15),
      );
    });
  });

  group('SentinelConfig.production preset', () {
    test('coincide con defaults', () {
      final prod = SentinelConfig.production();
      const def = SentinelConfig();
      expect(prod.maxRequestsPerMinute, def.maxRequestsPerMinute);
      expect(prod.maxDailyRequests, def.maxDailyRequests);
      expect(prod.maxDailyWrites, def.maxDailyWrites);
      expect(prod.failureThreshold, def.failureThreshold);
    });
  });

  group('SentinelConfig.strict preset', () {
    test('límites más agresivos que default', () {
      final strict = SentinelConfig.strict();
      const def = SentinelConfig();

      expect(strict.maxRequestsPerMinute, lessThan(def.maxRequestsPerMinute));
      expect(strict.maxDailyRequests, lessThan(def.maxDailyRequests));
      expect(strict.maxDailyWrites, lessThan(def.maxDailyWrites));
      expect(strict.maxRebuildsPerSecond, lessThan(def.maxRebuildsPerSecond));
      expect(strict.rebuildTripMultiplier, lessThan(def.rebuildTripMultiplier));
      expect(strict.failureThreshold, lessThan(def.failureThreshold));
    });

    test('exponentialBackoff ACTIVADO en strict', () {
      expect(SentinelConfig.strict().enableExponentialBackoff, isTrue);
    });

    test('openDuration mayor que default (60s vs 30s)', () {
      expect(
        SentinelConfig.strict().openDuration,
        const Duration(seconds: 60),
      );
    });
  });

  group('SentinelConfig.toString', () {
    test('contiene info clave del config', () {
      const c = SentinelConfig();
      final s = c.toString();
      expect(s, contains('rpm: 60'));
      expect(s, contains('failures: 5'));
      expect(s, contains('backoff: true'));
    });
  });
}
