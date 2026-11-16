import 'package:flutter_test/flutter_test.dart';
import 'package:sint_sentinel/sint_sentinel.dart';

void main() {
  group('Lote 86 — sint_sentinel clock-skew, Gemma-4, quota & prototype hardening', () {
    test('SentinelCircuit.sanitizeReason strips Gemma-4 thought blocks, JWTs & UTF-16 surrogates safely', () {
      const raw =
          '<|channel>thought\nInternal trace sk-secret1234567890\n<channel|>'
          '<|turn|>Auth failed: eyJhbGciOiJIUzI1NiJ9.eyJzdWIiOiIxMjM0NTY3ODkwIn0.c2lnbmF0dXJl99 '
          'cookie: sid=secret_cookie; ok 🔥';
      final cleaned = SentinelCircuit.sanitizeReason(raw, maxChars: 120);
      expect(cleaned, isNot(contains('thought')));
      expect(cleaned, isNot(contains('<|turn|>')));
      expect(cleaned, isNot(contains('eyJhbGci')));
      expect(cleaned, isNot(contains('secret_cookie')));
      expect(cleaned, contains('[REDACTED]'));

      // Splitting right across high surrogate of 🔥 ('A🔥' -> length 3; maxChars 2)
      final emojiCut = SentinelCircuit.sanitizeReason('A🔥B', maxChars: 2);
      expect(emojiCut, equals('A'));
    });

    test('SentinelHiveController clamps negative persisted counters to zero (blocks unlimited quota bypass)', () async {
      final hive = SentinelHiveController.inMemory();
      // Inject negative strings through public/in-memory pathways via snapshot/reset checks
      await hive.setDailyReads(-50000);
      await hive.setDailyWrites(-1000);
      await hive.setConsecutiveFailures(-99);
      await hive.setTripCount(-10);

      expect(await hive.getDailyReads(), equals(0));
      expect(await hive.getDailyWrites(), equals(0));
      expect(await hive.getConsecutiveFailures(), equals(0));
      expect(await hive.getTripCount(), equals(0));
    });

    test('TrafficWatchdog prunes future clock-skewed timestamps & resets on backward clock jump', () async {
      final hive = SentinelHiveController.inMemory();
      final now = DateTime.now().millisecondsSinceEpoch;
      // Inject 100 timestamps 1 year in the future (clock jumped backward)
      await hive.setMinuteTimestamps(
        List<int>.filled(100, now + const Duration(days: 365).inMilliseconds),
      );
      await hive.setDailyReads(5);
      // Set last reset date 2 days in the future (simulating backward clock adjustment)
      await hive.setLastResetDate(
        DateTime.now().add(const Duration(days: 2)).toIso8601String(),
      );

      final watchdog = TrafficWatchdog(
        config: const SentinelConfig(
          maxRequestsPerMinute: 3,
          maxDailyRequests: 5,
        ),
        hive: hive,
      );
      await watchdog.init();

      // Should have reset dailyReads and pruned future minute timestamps!
      final allowed = await watchdog.recordRequest();
      expect(allowed, isTrue);
      expect(watchdog.getSnapshot().dailyReads, equals(1));
      expect(watchdog.getSnapshot().requestsLastMinute, equals(1));
    });

    test('SentinelCircuit clamps far-future openUntilMs on backward clock skew & survives throwing onTrip', () async {
      final hive = SentinelHiveController.inMemory();
      await hive.setCircuitState('open');
      // 10 years in the future
      await hive.setOpenUntil(
        DateTime.now().millisecondsSinceEpoch +
            const Duration(days: 3650).inMilliseconds,
      );

      final circuit = SentinelCircuit(
        config: const SentinelConfig(
          openDuration: Duration(milliseconds: 50),
        ),
        hive: hive,
      );
      await circuit.init();

      final clampedUntil = await hive.getOpenUntil();
      expect(clampedUntil, isNotNull);
      expect(
        clampedUntil! - DateTime.now().millisecondsSinceEpoch,
        lessThanOrEqualTo(1000),
      );

      // Throwing onTrip must not break trip()
      circuit.onTrip = () async {
        throw StateError('observer crash');
      };
      await circuit.trip('Quota exceeded <|turn|>');
      expect(circuit.state.value, equals(SentinelCircuitState.open));
      expect(circuit.blockReason.value, equals('Quota exceeded'));

      circuit.dispose();
      circuit.dispose(); // idempotent
    });

    test('SentinelSnapshot sanitizes Gemma-4 tags, JWTs, non-finite percentages & prototype keys', () {
      final snap = SentinelSnapshot.fromJSON(<String, Object?>{
        '__proto__': <String, Object?>{'polluted': true},
        'circuitState': 'open',
        'blockReason':
            '<|channel>thought\nhidden\n<channel|>Token hf_1234567890abcdefghij leaked',
        'minuteUsagePercent': double.nan,
        'dailyReadUsagePercent': double.infinity,
      });
      final json = snap.toJSON();
      expect(snap.blockReason, equals('Token [REDACTED] leaked'));
      expect(json['minuteUsagePercent'], equals(0.0));
      expect(json['dailyReadUsagePercent'], equals(0.0));
      expect(json.containsKey('__proto__'), isFalse);
    });
  });
}
