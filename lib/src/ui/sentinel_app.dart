import 'package:flutter/material.dart';
import 'package:sint/sint.dart';

import '../core/sentinel_config.dart';
import '../core/sentinel_state.dart';
import '../guard/sint_sentinel_guard.dart';
import 'sentinel_maintenance_page.dart';

/// Top-level widget that wraps [SintMaterialApp] with circuit breaker
/// protection.
///
/// When the circuit is OPEN, `SentinelApp` replaces the child with a
/// maintenance page. When the circuit recovers (CLOSED or HALF_OPEN),
/// the child is shown again.
///
/// **Important**: The widget tree structure is kept consistent across builds
/// (always `Obx → child`) to prevent [SintRoot] from being unmounted and
/// losing its static controller reference.
///
/// ## Usage
///
/// ```dart
/// runApp(
///   SentinelApp(
///     config: SentinelConfig.production(),
///     child: SintMaterialApp(...),
///   ),
/// );
/// ```
class SentinelApp extends StatefulWidget {
  /// The main application widget (typically a [SintMaterialApp]).
  final Widget child;

  /// Sentinel configuration. Defaults to [SentinelConfig] (production).
  final SentinelConfig config;

  const SentinelApp({
    required this.child,
    this.config = const SentinelConfig(),
    super.key,
  });

  @override
  State<SentinelApp> createState() => _SentinelAppState();
}

class _SentinelAppState extends State<SentinelApp> {
  /// Reactive flag — Obx rebuilds when this changes.
  final RxBool _initialized = false.obs;

  @override
  void initState() {
    super.initState();
    _initSentinel();
  }

  Future<void> _initSentinel() async {
    await SintSentinel.init(config: widget.config);
    if (mounted) {
      _initialized.value = true;
    }
  }

  @override
  void dispose() {
    _initialized.close();
    // Do NOT dispose the singleton here — it lives for the entire app lifetime.
    // SintSentinel.dispose() is only for testing.
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    // Always wrap in Obx from the first build to keep the widget tree
    // structure consistent: `_SentinelAppState → Obx → child`.
    //
    // If the tree changes from `State → child` to `State → Obx → child`,
    // Flutter's reconciliation unmounts and recreates the child, which
    // disposes SintRoot and sets its static _controller to null — causing
    // "SintRoot is not part of the three" crash.
    return Obx(() {
      // Read the Rx value to register the Obx listener.
      final isReady = _initialized.value;

      if (isReady) {
        final circuitState = SintSentinel.circuit?.state.value;

        if (circuitState == SentinelCircuitState.open) {
          // Circuit is OPEN — show maintenance page.
          return MaterialApp(
            debugShowCheckedModeBanner: false,
            theme: ThemeData(
              brightness: Brightness.dark,
              fontFamily: 'OpenSans',
            ),
            home: SentinelMaintenancePage(
              reason: SintSentinel.circuit?.blockReason.value ?? '',
              onRetry: () => SintSentinel.circuit?.tryHalfOpen(),
            ),
          );
        }
      }

      // Circuit is CLOSED, HALF_OPEN, or not yet initialized — show the app.
      return widget.child;
    });
  }
}
