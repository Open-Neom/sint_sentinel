import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sint_sentinel/sint_sentinel.dart';

class _ChildHost extends StatefulWidget {
  final VoidCallback onDisposed;

  const _ChildHost({required this.onDisposed});

  @override
  State<_ChildHost> createState() => _ChildHostState();
}

class _ChildHostState extends State<_ChildHost> {
  int tapCount = 0;

  @override
  void dispose() {
    widget.onDisposed();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      home: Scaffold(
        body: Center(
          child: ElevatedButton(
            onPressed: () => setState(() => tapCount++),
            child: Text('child-taps:$tapCount'),
          ),
        ),
      ),
    );
  }
}

class _MonitoredItem extends StatefulWidget {
  final String label;

  const _MonitoredItem({super.key, required this.label});

  @override
  State<_MonitoredItem> createState() => _MonitoredItemState();
}

class _MonitoredItemState extends State<_MonitoredItem>
    with SentinelRebuildMonitor {
  int count = 0;

  void triggerRebuild() => setState(() => count++);

  @override
  Widget build(BuildContext context) => Text('${widget.label}:$count');
}

void main() {
  setUp(() {
    SintSentinel.configureLogger(Logger(level: Level.off));
  });

  tearDown(() {
    SintSentinel.dispose();
  });

  group('SentinelApp state preservation across circuit transitions', () {
    testWidgets(
      'keeps child State mounted across closed -> open -> halfOpen -> closed',
      (tester) async {
        await SintSentinel.init(
          config: const SentinelConfig(
            halfOpenTestRequests: 1,
            openDuration: Duration(seconds: 30),
          ),
          hive: SentinelHiveController.inMemory(),
          snapshotStore: SentinelSnapshotStore.inMemory(),
        );

        var childDisposedCount = 0;
        await tester.pumpWidget(
          SentinelApp(
            config: const SentinelConfig(halfOpenTestRequests: 1),
            child: _ChildHost(onDisposed: () => childDisposedCount++),
          ),
        );
        await tester.pumpAndSettle();

        expect(find.text('child-taps:0'), findsOneWidget);
        await tester.tap(find.text('child-taps:0'));
        await tester.pump();
        expect(find.text('child-taps:1'), findsOneWidget);

        // Trip circuit -> OPEN: maintenance overlay appears, child stays mounted!
        await SintSentinel.circuit!.trip('Firestore burst');
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 50));

        expect(find.text('Servicio en pausa'), findsOneWidget);
        expect(childDisposedCount, 0, reason: 'Child app must NEVER unmount');

        // Tap Reintentar -> HALF_OPEN: maintenance overlay disappears, state=1 survives!
        await tester.tap(find.text('Reintentar'));
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 50));

        expect(
          SintSentinel.circuit!.state.value,
          SentinelCircuitState.halfOpen,
        );
        expect(find.text('Servicio en pausa'), findsNothing);
        expect(find.text('child-taps:1'), findsOneWidget);
        expect(childDisposedCount, 0);

        // Successful probe closes the circuit cleanly.
        await SintSentinel.guard<int>(() async => 42, tag: 'probe.ok');
        await tester.pump();
        expect(SintSentinel.circuit!.state.value, SentinelCircuitState.closed);
        expect(childDisposedCount, 0);
      },
    );
  });

  group('SentinelRebuildMonitor per-instance isolation', () {
    testWidgets(
      'sibling instances have unique IDs and disposing one preserves the other',
      (tester) async {
        await SintSentinel.init(
          config: const SentinelConfig(
            maxRebuildsPerSecond: 3,
            rebuildTripMultiplier: 10,
          ),
          hive: SentinelHiveController.inMemory(),
          snapshotStore: SentinelSnapshotStore.inMemory(),
        );

        final keyA = GlobalKey<_MonitoredItemState>();
        final keyB = GlobalKey<_MonitoredItemState>();
        var showB = true;

        await tester.pumpWidget(
          StatefulBuilder(
            builder: (context, setHostState) {
              return Directionality(
                textDirection: TextDirection.ltr,
                child: Column(
                  children: [
                    _MonitoredItem(key: keyA, label: 'A'),
                    if (showB) _MonitoredItem(key: keyB, label: 'B'),
                    GestureDetector(
                      onTap: () => setHostState(() => showB = false),
                      child: const Text('hide-B'),
                    ),
                  ],
                ),
              );
            },
          ),
        );

        final idA = keyA.currentState!.sentinelWidgetId;
        final idB = keyB.currentState!.sentinelWidgetId;
        expect(idA, isNot(equals(idB)));

        // Rebuild A 3 times and B 3 times — neither should throttle the other.
        for (var i = 0; i < 3; i++) {
          keyA.currentState!.triggerRebuild();
          keyB.currentState!.triggerRebuild();
        }
        await tester.pump();
        expect(find.text('A:3'), findsOneWidget);
        expect(find.text('B:3'), findsOneWidget);

        // Dispose B and verify A's rebuild tracking was NOT cleared.
        await tester.tap(find.text('hide-B'));
        await tester.pump();

        final watchdog = SintSentinel.circuit!.stateWatchdog;
        expect(watchdog.getRebuildsPerSecond(idB), 0);
        expect(watchdog.getRebuildsPerSecond(idA), 3);
      },
    );
  });

  group('SintSentinel concurrent init, guardWrite, countFailureIf & persistence', () {
    test('deduplicates concurrent init calls and persists write counters', () async {
      final hive = SentinelHiveController.inMemory();
      final store = SentinelSnapshotStore.inMemory();

      await Future.wait([
        SintSentinel.init(
          config: const SentinelConfig(failureThreshold: 2),
          hive: hive,
          snapshotStore: store,
        ),
        SintSentinel.init(
          config: const SentinelConfig(failureThreshold: 2),
          hive: hive,
          snapshotStore: store,
        ),
      ]);

      expect(SintSentinel.isInitialized, isTrue);

      await SintSentinel.guardWrite<void>(
        () async {},
        tag: 'Wallet.credit',
      );
      expect(await hive.getDailyWrites(), 1);
      expect(await hive.getDailyReads(), 1);

      // Domain validation errors filtered via countFailureIf do NOT trip circuit.
      await expectLater(
        SintSentinel.guard<void>(
          () async => throw ArgumentError('invalid input'),
          tag: 'Wallet.validate',
          countFailureIf: (e) => e is! ArgumentError,
        ),
        throwsArgumentError,
      );
      await expectLater(
        SintSentinel.guard<void>(
          () async => throw ArgumentError('invalid input 2'),
          tag: 'Wallet.validate',
          countFailureIf: (e) => e is! ArgumentError,
        ),
        throwsArgumentError,
      );
      expect(SintSentinel.isBlocking, isFalse);

      final status = await SintSentinel.getStatus();
      final tagMetrics = status['tagMetrics'] as Map<String, dynamic>;
      final calls = tagMetrics['calls'] as Map<String, int>;
      expect(calls['Wallet.credit'], 1);
      expect(calls['Wallet.validate'], 2);
    });
  });
}
