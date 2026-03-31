# Changelog

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
