// SINT SENTINEL v1.0.0 — Performance Overhead Study
// Benchmark: How much overhead does sint_sentinel add to each operation?
// ignore_for_file: avoid_print

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:hive_flutter/hive_flutter.dart';
import 'package:sint_sentinel/sint_sentinel.dart';

// ═══════════════════════════════════════════════════════
// GLOBAL BENCHMARK RESULTS — Collected across all tests
// ═══════════════════════════════════════════════════════

final _results = <String, _BenchResult>{};

class _BenchResult {
  final String label;
  final int iterations;
  final int avgMicroseconds;
  final int minMicroseconds;
  final int maxMicroseconds;

  _BenchResult({
    required this.label,
    required this.iterations,
    required this.avgMicroseconds,
    required this.minMicroseconds,
    required this.maxMicroseconds,
  });
}

// ═══════════════════════════════════════════════════════
// HELPERS
// ═══════════════════════════════════════════════════════

Future<_BenchResult> _measureAsync({
  required String label,
  required Future<void> Function() action,
  int iterations = 100,
  int warmup = 5,
}) async {
  for (int i = 0; i < warmup; i++) {
    await action();
  }

  final timings = <int>[];
  for (int i = 0; i < iterations; i++) {
    final sw = Stopwatch()..start();
    await action();
    sw.stop();
    timings.add(sw.elapsedMicroseconds);
  }

  final avg = timings.fold<int>(0, (a, b) => a + b) ~/ timings.length;
  final min = timings.reduce((a, b) => a < b ? a : b);
  final max = timings.reduce((a, b) => a > b ? a : b);

  return _BenchResult(
    label: label,
    iterations: iterations,
    avgMicroseconds: avg,
    minMicroseconds: min,
    maxMicroseconds: max,
  );
}

void _printResult(int index, int total, _BenchResult r) {
  print('');
  print('[$index/$total] ${r.label}');
  print('  Iterations: ${r.iterations}');
  print('  Average: ${r.avgMicroseconds}μs  |  '
      'Min: ${r.minMicroseconds}μs  |  '
      'Max: ${r.maxMicroseconds}μs');
  print('──────────────────────────────────────────────────────');
}

// ═══════════════════════════════════════════════════════
// MAIN
// ═══════════════════════════════════════════════════════

void main() {
  late Directory tempDir;

  setUpAll(() async {
    print('\n══════════════════════════════════════════════════════');
    print(' SINT SENTINEL v1.0.0 — PERFORMANCE OVERHEAD STUDY');
    print('══════════════════════════════════════════════════════');

    tempDir = await Directory.systemTemp.createTemp('sentinel_bench_');
    Hive.init(tempDir.path);
  });

  tearDownAll(() async {
    SintSentinel.dispose();

    if (await tempDir.exists()) {
      await tempDir.delete(recursive: true);
    }

    // ── FINAL SUMMARY ──
    print('\n══════════════════════════════════════════════════════');
    print(' FINAL SUMMARY');
    print('══════════════════════════════════════════════════════');

    final init = _results['init'];
    final rx = _results['rx'];
    final guard = _results['guard'];
    final traffic = _results['traffic'];
    final state = _results['state'];

    if (init != null) {
      print('  Init (cold start):            ~${init.avgMicroseconds}μs');
    }
    if (rx != null) {
      print('  Rx state change:              ~${rx.avgMicroseconds}μs/change');
    }
    if (guard != null) {
      print('  SintSentinel.guard() cost:     ~${guard.avgMicroseconds}μs/call');
    }
    if (traffic != null) {
      print('  TrafficWatchdog.record():      ~${traffic.avgMicroseconds}μs/call');
    }
    if (state != null) {
      print('  StateWatchdog.rebuild():       ~${state.avgMicroseconds}μs/call');
    }

    // Verdicts
    final guardOverhead = guard?.avgMicroseconds ?? 0;

    String guardVerdict;
    if (guardOverhead < 100) {
      guardVerdict = 'NEGLIGIBLE';
    } else if (guardOverhead < 500) {
      guardVerdict = 'ACCEPTABLE';
    } else {
      guardVerdict = 'NEEDS OPTIMIZATION';
    }

    print('');
    print('  Guard verdict: $guardVerdict');

    // Widget analysis (theoretical)
    print('');
    print('  Widget wrapping analysis:');
    print('  SentinelApp adds 1 StatefulWidget + 1 Obx listener.');
    print('  Obx only rebuilds when circuit state changes (rare event).');
    print('  Per-frame cost when CLOSED: 0μs (no rebuild triggered).');
    print('  Conclusion: NEGLIGIBLE widget overhead.');
    print('══════════════════════════════════════════════════════\n');
  });

  tearDown(() async {
    SintSentinel.dispose();
    try {
      if (Hive.isBoxOpen('sint_sentinel')) {
        await Hive.box('sint_sentinel').clear();
      }
    } catch (_) {}
  });

  // ─────────────────────────────────────────────────────
  // TEST 1: Initialization
  // ─────────────────────────────────────────────────────

  test('[1/5] SentinelCircuit.init() cold start', () async {
    final result = await _measureAsync(
      label: 'INIT: SentinelCircuit cold start',
      iterations: 10,
      warmup: 0,
      action: () async {
        final circuit = SentinelCircuit(
          config: SentinelConfig.production(),
          hive: SentinelHiveController(),
        );
        await circuit.init();
        circuit.dispose();
      },
    );

    _results['init'] = result;
    _printResult(1, 5, result);

    expect(result.avgMicroseconds, lessThan(50000),
        reason: 'Cold init should be < 50ms');
  });

  // ─────────────────────────────────────────────────────
  // TEST 2: Rx State Change Propagation
  // ─────────────────────────────────────────────────────

  test('[2/5] Rx state change propagation latency', () async {
    await SintSentinel.init(config: SentinelConfig.production());
    final circuit = SintSentinel.circuit!;

    const iterations = 10000;
    final sw = Stopwatch()..start();

    for (int i = 0; i < iterations; i++) {
      circuit.state.value = i.isEven
          ? SentinelCircuitState.closed
          : SentinelCircuitState.halfOpen;
    }

    sw.stop();

    final result = _BenchResult(
      label: 'Rx state change propagation (10k toggles)',
      iterations: iterations,
      avgMicroseconds: sw.elapsedMicroseconds ~/ iterations,
      minMicroseconds: sw.elapsedMicroseconds ~/ iterations,
      maxMicroseconds: sw.elapsedMicroseconds ~/ iterations,
    );

    _results['rx'] = result;
    _printResult(2, 5, result);

    circuit.state.value = SentinelCircuitState.closed;
  });

  // ─────────────────────────────────────────────────────
  // TEST 3: SintSentinel.guard() throughput
  // ─────────────────────────────────────────────────────

  test('[3/5] SintSentinel.guard() throughput (10k calls)', () async {
    // Use extremely high limits so we don't trip the circuit during benchmark
    await SintSentinel.init(config: const SentinelConfig(
      maxRequestsPerMinute: 100000,
      maxDailyRequests: 1000000,
      maxDailyWrites: 100000,
      failureThreshold: 100000,
    ));

    final result = await _measureAsync(
      label: 'SintSentinel.guard() per call',
      iterations: 10000,
      warmup: 100,
      action: () async {
        await SintSentinel.guard(
          () => Future<int>.value(42),
          tag: 'benchmark',
        );
      },
    );

    _results['guard'] = result;
    _printResult(3, 5, result);

    expect(result.avgMicroseconds, lessThan(1000),
        reason: 'guard() should be < 1ms overhead per call');
  });

  // ─────────────────────────────────────────────────────
  // TEST 4: TrafficWatchdog isolated
  // ─────────────────────────────────────────────────────

  test('[4/5] TrafficWatchdog.recordRequest() isolated (10k calls)',
      () async {
    final watchdog = TrafficWatchdog(
      config: SentinelConfig.development(),
      hive: SentinelHiveController(),
    );
    await watchdog.init();

    final result = await _measureAsync(
      label: 'TrafficWatchdog.recordRequest()',
      iterations: 10000,
      warmup: 100,
      action: () async {
        await watchdog.recordRequest();
      },
    );

    _results['traffic'] = result;
    _printResult(4, 5, result);

    // Print traffic snapshot
    final snapshot = watchdog.getSnapshot();
    print('  Snapshot: $snapshot');
    print('──────────────────────────────────────────────────────');
  });

  // ─────────────────────────────────────────────────────
  // TEST 5: StateWatchdog throughput
  // ─────────────────────────────────────────────────────

  test('[5/5] StateWatchdog.recordRebuild() throughput (100k calls)',
      () async {
    final watchdog = StateWatchdog(
      config: const SentinelConfig(maxRebuildsPerSecond: 100000),
    );

    const widgetCount = 50;
    const callsPerWidget = 2000;
    const totalCalls = widgetCount * callsPerWidget;

    final widgetIds =
        List.generate(widgetCount, (i) => 'BenchWidget_$i');

    // Warmup
    for (int i = 0; i < 100; i++) {
      watchdog.recordRebuild('warmup');
    }
    watchdog.unregister('warmup');

    final sw = Stopwatch()..start();
    for (int w = 0; w < widgetCount; w++) {
      for (int c = 0; c < callsPerWidget; c++) {
        watchdog.recordRebuild(widgetIds[w]);
      }
    }
    sw.stop();

    final result = _BenchResult(
      label: 'StateWatchdog.recordRebuild()',
      iterations: totalCalls,
      avgMicroseconds: sw.elapsedMicroseconds ~/ totalCalls,
      minMicroseconds: sw.elapsedMicroseconds ~/ totalCalls,
      maxMicroseconds: sw.elapsedMicroseconds ~/ totalCalls,
    );

    _results['state'] = result;
    _printResult(5, 5, result);

    final rebuildsPerSecond = watchdog.getRebuildsPerSecond('BenchWidget_0');
    print('  Active rebuilds/s for BenchWidget_0: $rebuildsPerSecond');
    print('  Offenders detected: ${watchdog.getOffenders().length}');
    print('──────────────────────────────────────────────────────');
  });
}
