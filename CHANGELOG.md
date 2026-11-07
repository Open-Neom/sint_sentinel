# Changelog

## 1.1.1

- Widen `sint` compatibility constraint (`>=1.3.0 <3.0.0`) for seamless `sint 2.1` resolution and add `@Open-Neom` GitHub Sponsors `funding` metadata.

## 1.1.0

### Logger Integration — Application-Level Logging

sint_sentinel is now the **centralized logger** for your entire Flutter application.

- **`SintSentinel.logger`**: Static `Logger` instance available everywhere via `SintSentinel.logger.d()`, `.i()`, `.w()`, `.e()`, `.t()`, `.f()`.
- **`SintSentinel.configureLogger()`**: Replace the default logger with a custom `Logger` instance (custom printers, output, filters).
- **Re-exports**: `Logger`, `Level`, `PrettyPrinter`, `LogPrinter`, `DateTimeFormat` from `package:logger` — consumers don't need a separate `logger` dependency.
- **Guard logging**: `SintSentinel.guard()` now logs blocked calls, successful calls, and failures automatically with tags.
- **Init logging**: `SintSentinel.init()` logs initialization and circuit state on startup.

### Dependencies

- Added `logger: ^2.7.0` as a dependency.

## 1.0.1

- Fix: Replaced `hive` direct dependency with `hive_flutter` (re-exports all of `hive`).
- Fix: Description length for pub.dev compliance.
- Added WASM compatibility roadmap to README.
- Added platform support table to README.
- Added `.pubignore` to exclude build artifacts.

## 1.0.0

- Initial stable release.
- **Circuit Breaker**: Three-state machine (CLOSED / OPEN / HALF_OPEN) with configurable thresholds.
- **TrafficWatchdog**: Sliding 60-second request rate limiter + daily read/write quotas.
- **StateWatchdog**: Widget rebuild frequency monitor to detect infinite loops.
- **SentinelRebuildMonitor**: Mixin for `State` subclasses with three-tier response (throttle, warn, trip).
- **SentinelApp**: Drop-in root widget that shows a maintenance page when the circuit is open.
- **SintSentinel.guard()**: Generic async wrapper that gates any operation through the circuit.
- **SentinelSnapshot**: Immutable point-in-time capture of circuit state, traffic metrics, and rebuild offenders.
- **SentinelSnapshotStore**: Persistent ring buffer (Hive, last 50) with auto-capture on every trip.
- **Snapshot API**: `SintSentinel.capture()`, `.latestSnapshot`, `.snapshotHistory`, `.recentSnapshots(duration)`.
- **Exponential backoff**: Open duration doubles on each trip (capped at 5 minutes).
- **Hive persistence**: Circuit state, counters, traffic history, and snapshots survive app restarts.
- **Three config presets**: `development()`, `production()`, `strict()`.
- **Benchmark suite**: Cold init, guard throughput, watchdog overhead, Rx propagation.
