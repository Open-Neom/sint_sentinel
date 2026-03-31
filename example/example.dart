/// sint_sentinel example — Circuit Breaker & Rate Limiter for Flutter.
///
/// This example demonstrates the three main features:
/// 1. Wrapping your app with SentinelApp
/// 2. Guarding async operations with SintSentinel.guard()
/// 3. Detecting infinite rebuild loops with SentinelRebuildMonitor
library;

import 'package:flutter/material.dart';
import 'package:sint_sentinel/sint_sentinel.dart';

// ─────────────────────────────────────────────────────────────
// 1. WRAP YOUR APP
// ─────────────────────────────────────────────────────────────

void main() {
  runApp(
    SentinelApp(
      // Choose a preset or create a custom config:
      //   SentinelConfig.development()  — relaxed, for debugging
      //   SentinelConfig.production()   — balanced (default)
      //   SentinelConfig.strict()       — aggressive protection
      config: SentinelConfig.production(),
      child: const MyApp(),
    ),
  );
}

class MyApp extends StatelessWidget {
  const MyApp({super.key});

  @override
  Widget build(BuildContext context) {
    return const MaterialApp(
      home: DemoPage(),
    );
  }
}

// ─────────────────────────────────────────────────────────────
// 2. GUARD ASYNC OPERATIONS
// ─────────────────────────────────────────────────────────────

class DemoPage extends StatefulWidget {
  const DemoPage({super.key});

  @override
  State<DemoPage> createState() => _DemoPageState();
}

/// Adding SentinelRebuildMonitor detects infinite setState loops.
class _DemoPageState extends State<DemoPage> with SentinelRebuildMonitor {
  String _status = 'Ready';
  Map<String, dynamic> _sentinel = {};

  Future<void> _fetchData() async {
    setState(() => _status = 'Loading...');

    try {
      // Wrap any async call — reads count against the per-minute
      // and daily read quotas automatically.
      final result = await SintSentinel.guard(
        () => _simulateApiCall(),
        tag: 'Demo.fetch',
      );

      setState(() => _status = 'Got: $result');
    } on SentinelBlockedException catch (e) {
      // Circuit is OPEN — too many failures or quota exceeded.
      setState(() => _status = 'Blocked: ${e.reason}');
    } catch (e) {
      // The guarded operation itself threw an error.
      // The failure was recorded; circuit may trip if threshold reached.
      setState(() => _status = 'Error: $e');
    }
  }

  Future<void> _writeData() async {
    try {
      // Mark as write to count against daily write quota.
      await SintSentinel.guard(
        () => _simulateApiWrite(),
        isWrite: true,
        tag: 'Demo.write',
      );

      setState(() => _status = 'Write OK');
    } on SentinelBlockedException catch (e) {
      setState(() => _status = 'Blocked: ${e.reason}');
    }
  }

  Future<void> _fetchWithFallback() async {
    // Provide a fallback for when the circuit is open.
    // Instead of throwing SentinelBlockedException, the fallback runs.
    final result = await SintSentinel.guard(
      () => _simulateApiCall(),
      fallback: () => 'cached-data',
      tag: 'Demo.fetchWithFallback',
    );

    setState(() => _status = 'Got: $result');
  }

  Future<void> _checkStatus() async {
    final status = await SintSentinel.getStatus();
    setState(() => _sentinel = status);
  }

  // Simulate a network call
  Future<String> _simulateApiCall() async {
    await Future.delayed(const Duration(milliseconds: 100));
    return 'item_${DateTime.now().millisecondsSinceEpoch}';
  }

  Future<void> _simulateApiWrite() async {
    await Future.delayed(const Duration(milliseconds: 50));
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('sint_sentinel demo')),
      body: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            // Status display
            Container(
              padding: const EdgeInsets.all(16),
              decoration: BoxDecoration(
                color: SintSentinel.isBlocking ? Colors.red.shade50 : Colors.green.shade50,
                borderRadius: BorderRadius.circular(12),
              ),
              child: Column(
                children: [
                  Text(
                    SintSentinel.isBlocking ? 'CIRCUIT OPEN' : 'CIRCUIT CLOSED',
                    style: TextStyle(
                      fontWeight: FontWeight.bold,
                      color: SintSentinel.isBlocking ? Colors.red : Colors.green,
                    ),
                  ),
                  const SizedBox(height: 8),
                  Text(_status),
                ],
              ),
            ),
            const SizedBox(height: 24),

            // Action buttons
            ElevatedButton(
              onPressed: _fetchData,
              child: const Text('Guard a Read'),
            ),
            const SizedBox(height: 8),
            ElevatedButton(
              onPressed: _writeData,
              child: const Text('Guard a Write'),
            ),
            const SizedBox(height: 8),
            ElevatedButton(
              onPressed: _fetchWithFallback,
              child: const Text('Fetch with Fallback'),
            ),
            const SizedBox(height: 8),
            OutlinedButton(
              onPressed: _checkStatus,
              child: const Text('Check Sentinel Status'),
            ),
            const SizedBox(height: 8),
            OutlinedButton(
              onPressed: () => SintSentinel.reset(),
              child: const Text('Reset Circuit'),
            ),
            const SizedBox(height: 16),

            // Status details
            if (_sentinel.isNotEmpty)
              Expanded(
                child: SingleChildScrollView(
                  child: Text(
                    _sentinel.entries.map((e) => '${e.key}: ${e.value}').join('\n'),
                    style: const TextStyle(fontFamily: 'monospace', fontSize: 12),
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }
}
