/// SintSentinel — Circuit Breaker & Rate Limiter for the SINT Framework.
///
/// Protects Open Neom apps against excessive Firebase calls, DoS scenarios,
/// infinite rebuild loops, and cascading failures.
///
/// ## Quick Start
///
/// ```dart
/// // 1. Wrap your app
/// runApp(SentinelApp(
///   config: SentinelConfig.production(),
///   child: SintMaterialApp(...),
/// ));
///
/// // 2. Guard Firebase calls
/// final doc = await SintSentinel.guard(
///   () => firestore.doc('items/$id').get(),
///   tag: 'Item.fetch',
/// );
///
/// // 3. (Optional) Monitor widget rebuilds
/// class _MyState extends State<MyWidget> with SentinelRebuildMonitor { ... }
/// ```
library;

// Re-export Logger so consumers can use SintSentinel.logger without
// importing package:logger separately.
export 'package:logger/logger.dart' show Logger, Level, PrettyPrinter, LogPrinter, DateTimeFormat;

// Core
export 'src/core/sentinel_circuit.dart';
export 'src/core/sentinel_config.dart';
export 'src/core/sentinel_state.dart';

// Guard (main API)
export 'src/guard/sint_sentinel_guard.dart';

// Persistence
export 'src/persistence/sentinel_hive_controller.dart';
export 'src/persistence/sentinel_snapshot.dart';

// UI
export 'src/ui/sentinel_app.dart';
export 'src/ui/sentinel_maintenance_page.dart';
export 'src/ui/sentinel_rebuild_monitor.dart';

// Watchdogs
export 'src/watchdogs/state_watchdog.dart';
export 'src/watchdogs/traffic_watchdog.dart';
