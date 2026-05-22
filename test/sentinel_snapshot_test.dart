// Tests for `SentinelSnapshot` (modelo) — round-trip JSON sin tocar Hive.

import 'package:flutter_test/flutter_test.dart';
import 'package:sint_sentinel/src/persistence/sentinel_snapshot.dart';

void main() {
  group('SentinelSnapshot — defaults', () {
    test('constructor con required mínimo', () {
      final s = SentinelSnapshot(
        timestamp: DateTime(2024, 1, 1),
        circuitState: 'closed',
      );
      expect(s.timestamp.year, 2024);
      expect(s.circuitState, 'closed');
      expect(s.blockReason, '');
      expect(s.consecutiveFailures, 0);
      expect(s.tripCount, 0);
      expect(s.requestsLastMinute, 0);
      expect(s.dailyReads, 0);
      expect(s.dailyWrites, 0);
      expect(s.minuteUsagePercent, 0);
      expect(s.dailyReadUsagePercent, 0);
      expect(s.rebuildOffenders, isEmpty);
    });
  });

  group('SentinelSnapshot.securityStatus', () {
    test('closed → CLEAN', () {
      final s = SentinelSnapshot(
        timestamp: DateTime.now(),
        circuitState: 'closed',
      );
      expect(s.securityStatus, 'CLEAN');
    });

    test('open → ALERT_open', () {
      final s = SentinelSnapshot(
        timestamp: DateTime.now(),
        circuitState: 'open',
      );
      expect(s.securityStatus, 'ALERT_open');
    });

    test('halfOpen → ALERT_halfOpen', () {
      final s = SentinelSnapshot(
        timestamp: DateTime.now(),
        circuitState: 'halfOpen',
      );
      expect(s.securityStatus, 'ALERT_halfOpen');
    });
  });

  group('SentinelSnapshot.isClean', () {
    test('closed → true', () {
      expect(
        SentinelSnapshot(
          timestamp: DateTime.now(),
          circuitState: 'closed',
        ).isClean,
        isTrue,
      );
    });

    test('open → false', () {
      expect(
        SentinelSnapshot(
          timestamp: DateTime.now(),
          circuitState: 'open',
        ).isClean,
        isFalse,
      );
    });
  });

  group('SentinelSnapshot — round-trip JSON', () {
    test('preserva todos los campos', () {
      final original = SentinelSnapshot(
        timestamp: DateTime.utc(2024, 1, 15, 12),
        circuitState: 'open',
        blockReason: 'rate_limit',
        consecutiveFailures: 5,
        tripCount: 2,
        requestsLastMinute: 60,
        dailyReads: 1500,
        dailyWrites: 300,
        minuteUsagePercent: 85.5,
        dailyReadUsagePercent: 50.0,
        rebuildOffenders: ['HomePage', 'AudioPlayer'],
      );
      final restored = SentinelSnapshot.fromJSON(original.toJSON());
      expect(restored.timestamp.year, original.timestamp.year);
      expect(restored.timestamp.month, original.timestamp.month);
      expect(restored.timestamp.day, original.timestamp.day);
      expect(restored.timestamp.hour, original.timestamp.hour);
      expect(restored.circuitState, original.circuitState);
      expect(restored.blockReason, original.blockReason);
      expect(restored.consecutiveFailures, original.consecutiveFailures);
      expect(restored.tripCount, original.tripCount);
      expect(restored.requestsLastMinute, original.requestsLastMinute);
      expect(restored.dailyReads, original.dailyReads);
      expect(restored.dailyWrites, original.dailyWrites);
      expect(restored.minuteUsagePercent, original.minuteUsagePercent);
      expect(restored.dailyReadUsagePercent, original.dailyReadUsagePercent);
      expect(restored.rebuildOffenders, original.rebuildOffenders);
    });

    test('toJSON incluye securityStatus computed', () {
      final s = SentinelSnapshot(
        timestamp: DateTime.now(),
        circuitState: 'open',
      );
      expect(s.toJSON()['securityStatus'], 'ALERT_open');
    });

    test('mapa vacío usa defaults', () {
      final s = SentinelSnapshot.fromJSON(<dynamic, dynamic>{});
      expect(s.circuitState, 'closed');
      expect(s.blockReason, '');
      expect(s.consecutiveFailures, 0);
      expect(s.rebuildOffenders, isEmpty);
    });

    test('timestamp inválido cae a DateTime.now()', () {
      final s = SentinelSnapshot.fromJSON({
        'timestamp': 'not_a_date',
        'circuitState': 'closed',
      });
      // No crashea, devuelve algo cercano a now (test laxo)
      expect(s.timestamp.year, greaterThan(2020));
    });

    test('valores num int se convierten a double', () {
      final s = SentinelSnapshot.fromJSON({
        'circuitState': 'closed',
        'minuteUsagePercent': 50,
        'dailyReadUsagePercent': 80,
      });
      expect(s.minuteUsagePercent, 50.0);
      expect(s.dailyReadUsagePercent, 80.0);
    });
  });
}
