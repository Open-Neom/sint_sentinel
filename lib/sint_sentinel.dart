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

export 'sint_sentinel_core.dart';

// UI
export 'src/ui/sentinel_app.dart';
export 'src/ui/sentinel_maintenance_page.dart';
export 'src/ui/sentinel_rebuild_monitor.dart';
