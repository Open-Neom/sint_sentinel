# sint_sentinel

<p align="center">
  <img src="https://firebasestorage.googleapis.com/v0/b/cyberneom-edd2d.appspot.com/o/AppStatics%2FSint%20Sentinel.png?alt=media&token=145b7c27-9251-4648-be85-f3a6d8e74618" alt="SINT Sentinel" width="280"/>
</p>

[![pub package](https://img.shields.io/pub/v/sint_sentinel.svg)](https://pub.dev/packages/sint_sentinel)
[![License: MIT](https://img.shields.io/badge/license-MIT-blue.svg)](https://opensource.org/licenses/MIT)

**Circuit Breaker, Rate Limiter & Snapshot Auditor for Flutter.**

Born from a real incident where a single Flutter widget generated **165,000 Firestore reads in 4 hours** due to a `StreamBuilder` inside `build()`. That bug cost real money and could have bankrupted the project. sint_sentinel makes sure it never happens again.

```dart
// Before (vulnerable): one infinite loop = unlimited billing
FirebaseFirestore.instance.collection('users').get();

// After (protected): one infinite loop = 3,000 reads max, then auto-block
SintSentinel.guard(() => FirebaseFirestore.instance.collection('users').get());
```

---

## Why sint_sentinel?

Most backend circuit breakers protect servers. **sint_sentinel protects the client** — your Flutter app, your Firebase budget, and your users' experience.

| Threat | Without Sentinel | With Sentinel |
|--------|-----------------|---------------|
| `StreamBuilder` in `build()` | 1.1M reads/day (real incident) | 3,000 reads, then auto-block |
| Infinite `setState` loop | UI frozen, app killed by OS | Loop throttled in <1 second |
| Runaway polling timer | Thousands of API calls/min | 60/min cap, circuit trips |
| Developer pushes bad code | Unlimited cost until hotfix | Instant local protection |

---

## Features

- **Circuit Breaker** — Three-state machine (CLOSED / OPEN / HALF_OPEN) that blocks traffic when quotas are exceeded or failures accumulate.
- **Traffic Watchdog** — Sliding 60-second rate limiter + daily read/write quotas. Catches runaway Firestore listeners, accidental polling, bot abuse.
- **State Watchdog** — Monitors widget rebuild frequency per widget ID. Detects and throttles infinite `setState` loops before they freeze the UI.
- **Rebuild Monitor** — Drop-in `State` mixin with three-tier response: silently drop excess rebuilds, warn in console, trip circuit if sustained.
- **Snapshot Auditor** — Persistent history of circuit state snapshots. Auto-captured on every trip. Queryable by consumers (AI, analytics, debugging).
- **Maintenance Page** — Full-screen UI shown automatically when the circuit trips. User can retry; circuit recovers with exponential backoff.
- **Hive Persistence** — Everything survives app restarts: circuit state, counters, traffic history, snapshot ring buffer.
- **Zero Config** — Works out of the box with `SentinelConfig.production()`. Three presets for dev/prod/strict.

---

## Quick Start

### 1. Install

```yaml
dependencies:
  sint_sentinel: ^1.0.0
```

### 2. Wrap your app

```dart
import 'package:sint_sentinel/sint_sentinel.dart';

void main() {
  runApp(
    SentinelApp(
      config: SentinelConfig.production(),
      child: MyApp(),
    ),
  );
}
```

### 3. Guard your calls

```dart
// Read operation (counts against per-minute rate + daily read quota)
final doc = await SintSentinel.guard(
  () => FirebaseFirestore.instance.doc('users/$uid').get(),
  tag: 'User.fetch',
);

// Write operation (counts against daily write quota)
await SintSentinel.guard(
  () => FirebaseFirestore.instance.doc('logs/$id').set(data),
  isWrite: true,
  tag: 'Log.write',
);

// With fallback — returns cached data instead of throwing when blocked
final items = await SintSentinel.guard(
  () => api.fetchItems(),
  fallback: () => localCache.getItems(),
  tag: 'Items.fetch',
);
```

### 4. Protect widgets (optional)

```dart
class _MyPageState extends State<MyPage> with SentinelRebuildMonitor {
  @override
  Widget build(BuildContext context) {
    return Text('Safe from infinite rebuilds');
  }
}
```

When a widget exceeds 30 rebuilds/second:
1. Excess `setState` calls are **dropped** silently (UI stays responsive).
2. A console warning fires once: `SintSentinel: Cyclic rebuild detected in MyPage`.
3. If abuse continues (90+ throttled calls), the circuit **trips** and a snapshot is captured automatically.

---

## Snapshots

Every time the circuit trips, sint_sentinel captures a `SentinelSnapshot` — a frozen picture of everything that was happening at that moment. Snapshots are persisted in Hive and available to any consumer.

```dart
// Capture a snapshot on demand
final snapshot = await SintSentinel.capture();
print(snapshot.securityStatus);     // "CLEAN" or "ALERT_open"
print(snapshot.requestsLastMinute); // 58
print(snapshot.dailyReads);         // 2847
print(snapshot.rebuildOffenders);   // ["MyBrokenWidget"]

// Query history
final history = await SintSentinel.snapshotHistory;     // Last 50 snapshots
final latest  = await SintSentinel.latestSnapshot;       // Most recent
final recent  = await SintSentinel.recentSnapshots(      // Last hour
  Duration(hours: 1),
);
```

**Use cases:**
- **AI integration** — Feed snapshots to your AI agent so it understands app health and can reason about what happened.
- **Crash forensics** — After a user reports an issue, check what the circuit was doing at the time.
- **Analytics** — Track trip frequency, most common block reasons, which widgets cause loops.

Each snapshot contains:

```dart
SentinelSnapshot(
  timestamp: DateTime,
  circuitState: 'closed' | 'open' | 'halfOpen',
  blockReason: 'Rate limit exceeded: 61/60 req/min',
  consecutiveFailures: 3,
  tripCount: 2,
  requestsLastMinute: 61,
  dailyReads: 2450,
  dailyWrites: 89,
  minuteUsagePercent: 101.6,
  dailyReadUsagePercent: 81.6,
  rebuildOffenders: ['StreamBuilderWidget'],
)
```

---

## How It Works

### Circuit Breaker State Machine

```
                  quota exceeded
                  or N failures
CLOSED ─────────────────────────────> OPEN ──> [snapshot captured]
  ^                                     |
  |   test requests succeed             | openDuration expires
  |                                     v
  <──────────────────────────────── HALF_OPEN
           test fails ──────────────> OPEN ──> [snapshot captured]
```

- **CLOSED**: All requests pass through. Failures and traffic are counted.
- **OPEN**: All requests blocked immediately. Maintenance page shown. Snapshot captured. Timer counts down.
- **HALF_OPEN**: Limited test requests allowed. If they succeed, circuit recovers. If they fail, circuit trips again.

### Exponential Backoff

Each consecutive trip increases the blocking duration:

| Trip | Duration |
|------|----------|
| 1st  | 30s      |
| 2nd  | 60s      |
| 3rd  | 120s     |
| 4th  | 240s     |
| 5th+ | 300s (cap) |

A full reset (`SintSentinel.reset()`) clears the trip counter.

### Dual Watchdog System

**Traffic Watchdog** monitors outbound requests:
- Sliding 60-second window (rate limit)
- Daily read counter (auto-resets every 24h)
- Daily write counter (separate quota)
- When exceeded: `"Rate limit exceeded: 61/60 req/min"` or `"Daily read quota exceeded: 3001/3000"`

**State Watchdog** monitors inbound rebuilds:
- Per-widget rebuild timestamps (pruned to last 1 second)
- When threshold exceeded, `setState` calls are dropped
- Throttle count accumulated; trips circuit when multiplier reached

---

## Configuration

Three presets cover most use cases:

```dart
SentinelConfig.development()  // Relaxed — 120 req/min, 20k daily, no backoff
SentinelConfig.production()   // Balanced — 60 req/min, 3k daily, backoff on
SentinelConfig.strict()       // Aggressive — 30 req/min, 1.5k daily
```

### Full Configuration

```dart
SentinelConfig(
  maxRequestsPerMinute: 100,
  maxDailyRequests: 5000,
  maxDailyWrites: 1000,
  maxRebuildsPerSecond: 40,
  rebuildTripMultiplier: 3,       // 40 * 3 = 120 throttled calls to trip
  failureThreshold: 5,
  openDuration: Duration(seconds: 30),
  halfOpenTestRequests: 3,
  enableExponentialBackoff: true,
)
```

| Parameter | Dev | Prod | Strict | What it controls |
|-----------|:---:|:----:|:------:|-----------------|
| `maxRequestsPerMinute` | 120 | 60 | 30 | Sliding window rate limit |
| `maxDailyRequests` | 20,000 | 3,000 | 1,500 | Daily read quota |
| `maxDailyWrites` | 5,000 | 500 | 200 | Daily write quota |
| `maxRebuildsPerSecond` | 60 | 30 | 15 | Widget rebuild threshold |
| `failureThreshold` | 10 | 5 | 3 | Consecutive failures to trip |
| `openDuration` | 10s | 30s | 60s | Base blocking duration |
| `enableExponentialBackoff` | off | on | on | Double duration each trip |

---

## Error Handling

```dart
try {
  final result = await SintSentinel.guard(() => riskyCall());
} on SentinelBlockedException catch (e) {
  // Circuit is OPEN — show cached data or retry later
  showSnackbar('Service paused: ${e.reason}');
} catch (e) {
  // The guarded operation itself threw
  // (failure recorded, circuit may trip if threshold reached)
  showSnackbar('Error: $e');
}
```

---

## Real-Time Monitoring

```dart
// Full status map
final status = await SintSentinel.getStatus();
// {
//   "circuitState": "closed",
//   "blockReason": "",
//   "tripCount": 0,
//   "traffic": {
//     "requestsLastMinute": 23,
//     "dailyReads": 456,
//     "dailyWrites": 12,
//     "minuteUsagePercent": 38.3,
//     "isHealthy": true
//   },
//   "rebuildOffenders": []
// }

// Quick checks
if (SintSentinel.isBlocking) {
  showMaintenanceBanner();
}

// React to state changes in UI (GetX Rx)
Obx(() {
  final state = SintSentinel.circuit!.state.value;
  return Icon(
    state == SentinelCircuitState.closed ? Icons.shield : Icons.warning,
  );
});
```

---

## Architecture

```
                        ┌──────────────────┐
                        |    SentinelApp    |  Root widget
                        |  (shows maintenance|  when OPEN)
                        └────────┬─────────┘
                                 |
                        ┌────────v─────────┐
                        |   SintSentinel   |  Static API
                        |    .guard()      |  .capture()
                        |    .getStatus()  |  .snapshotHistory
                        └────────┬─────────┘
                                 |
                   ┌─────────────v──────────────┐
                   |     SentinelCircuit         |
                   |  CLOSED / OPEN / HALF_OPEN  |
                   |  Rx<State> for reactive UI  |
                   └──┬──────────┬──────────┬───┘
                      |          |          |
              ┌───────v──┐ ┌────v─────┐ ┌──v──────────┐
              | Traffic   | | State    | | Snapshot    |
              | Watchdog  | | Watchdog | | Store       |
              | (req/min  | | (rebuild | | (Hive ring  |
              |  daily)   | |  /sec)   | |  buffer x50)|
              └───────────┘ └──────────┘ └─────────────┘
                      |          |          |
                 ┌────v──────────v──────────v────┐
                 |       Hive Persistence        |
                 |  sint_sentinel (state/traffic) |
                 |  sint_sentinel_snapshots (log) |
                 └───────────────────────────────┘
```

---

## Performance

Benchmark results (release mode, Apple M1):

| Operation | Overhead | Impact |
|-----------|----------|--------|
| `SintSentinel.guard()` per call | 50-300 us | Negligible |
| `TrafficWatchdog.recordRequest()` | 10-50 us | Minimal |
| `StateWatchdog.recordRebuild()` | 1-5 us | Negligible |
| Cold init from Hive | 5-20 ms | One-time |
| `SentinelApp` per-frame (CLOSED) | 0 us | Zero cost |
| Snapshot capture | ~1 ms | Only on trips |

The sentinel adds **zero overhead per frame** when the circuit is closed (normal operation). The `Obx` listener in `SentinelApp` only triggers a rebuild when the circuit state actually changes — a rare event.

---

## The Incident That Started It All

On February 18, 2026, a Samsung S25 running the Open Neom app generated **165,000 Firestore document reads in under 4 hours** while sitting idle on a desk. The cause: a `StreamBuilder` initialized inside `build()`, creating an infinite reconnection loop at ~700 requests/minute.

The total monthly bill had already reached **15 million reads in 30 days**, with a single-day spike of **1.1 million reads**. This wasn't a cyberattack — it was a coding mistake that simulated one.

sint_sentinel was built so that this can never happen again. Not in our apps, and not in yours.

---

## Requirements

- Dart SDK `>=3.4.0 <4.0.0`
- Flutter `>=3.22.0`
- [sint](https://pub.dev/packages/sint) `^1.3.0`
- [hive](https://pub.dev/packages/hive) `^2.2.3`

## License

MIT. See [LICENSE](LICENSE).

## Links

- [SINT Framework](https://pub.dev/packages/sint) — The state management framework sint_sentinel extends.
- [Open Neom](https://github.com/Open-Neom) — The ecosystem where sint_sentinel was born and battle-tested.
- [Changelog](CHANGELOG.md)
