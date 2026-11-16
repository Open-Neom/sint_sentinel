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
    try {
      await SintSentinel.init(config: widget.config);
    } catch (e) {
      SintSentinel.logger.w(
        'SentinelApp init fallback: ${SintSentinel.sanitizeDiagnosticText('$e')}',
      );
    }
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
    // Keep `widget.child` permanently mounted at the exact same element slot
    // across all circuit transitions (uninitialized -> closed -> open ->
    // halfOpen -> closed). Replacing `widget.child` with a separate widget
    // would unmount `SintRoot`, null out its static controller, and destroy
    // active navigation stacks and controllers.
    return Stack(
      textDirection: TextDirection.ltr,
      children: [
        Obx(() {
          final isOpen = _initialized.value &&
              SintSentinel.circuit?.state.value == SentinelCircuitState.open;
          return IgnorePointer(
            ignoring: isOpen,
            child: ExcludeSemantics(
              excluding: isOpen,
              child: TickerMode(
                enabled: !isOpen,
                child: widget.child,
              ),
            ),
          );
        }),
        Obx(() {
          final isReady = _initialized.value;
          final circuitState =
              isReady ? SintSentinel.circuit?.state.value : null;
          if (circuitState != SentinelCircuitState.open) {
            return const SizedBox.shrink();
          }
          return Positioned.fill(
            child: MaterialApp(
              debugShowCheckedModeBanner: false,
              theme: ThemeData(
                brightness: Brightness.dark,
                useMaterial3: true,
              ),
              home: SentinelMaintenancePage(
                reason: SintSentinel.circuit?.blockReason.value ?? '',
                onRetry: () => SintSentinel.circuit?.tryHalfOpen(),
              ),
            ),
          );
        }),
      ],
    );
  }
}
