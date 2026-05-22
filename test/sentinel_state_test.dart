// Tests for `SentinelCircuitState` enum.

import 'package:flutter_test/flutter_test.dart';
import 'package:sint_sentinel/src/core/sentinel_state.dart';

void main() {
  group('SentinelCircuitState enum', () {
    test('tiene exactamente 3 estados', () {
      expect(SentinelCircuitState.values.length, 3);
    });

    test('contiene closed, open, halfOpen', () {
      expect(SentinelCircuitState.values,
          containsAll([
            SentinelCircuitState.closed,
            SentinelCircuitState.open,
            SentinelCircuitState.halfOpen,
          ]));
    });

    test('closed es el primero (estado por defecto)', () {
      expect(SentinelCircuitState.values.first, SentinelCircuitState.closed);
    });

    test('cada estado tiene name único', () {
      final names = SentinelCircuitState.values.map((s) => s.name).toSet();
      expect(names.length, 3);
    });
  });
}
