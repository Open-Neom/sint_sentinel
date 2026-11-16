/// Headless core barrel for SintSentinel (circuit breaker, rate limiter,
/// persistence, and watchdogs) without UI navigation widgets.
///
/// Safe to import from pure data/API layers, CLI tools, and standalone tests
/// that do not configure SINT navigation UI packages.
library;

export 'package:logger/logger.dart'
    show Logger, Level, PrettyPrinter, LogPrinter, DateTimeFormat;

export 'src/core/sentinel_circuit.dart';
export 'src/core/sentinel_config.dart';
export 'src/core/sentinel_state.dart';
export 'src/guard/sint_sentinel_guard.dart';
export 'src/persistence/sentinel_hive_controller.dart';
export 'src/persistence/sentinel_snapshot.dart';
export 'src/watchdogs/state_watchdog.dart';
export 'src/watchdogs/traffic_watchdog.dart';
