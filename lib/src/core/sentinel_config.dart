/// Configuration for the SintSentinel circuit breaker and rate limiter.
///
/// Use the named constructors for common presets:
/// - [SentinelConfig.development] — relaxed limits for local testing.
/// - [SentinelConfig.production] — balanced limits for production apps.
/// - [SentinelConfig.strict] — aggressive limits for anti-abuse scenarios.
class SentinelConfig {

  // ---------------------------------------------------------------------------
  // Traffic Watchdog
  // ---------------------------------------------------------------------------

  /// Maximum requests allowed within a sliding 60-second window.
  final int maxRequestsPerMinute;

  /// Maximum total read requests allowed per calendar day.
  final int maxDailyRequests;

  /// Maximum total write requests allowed per calendar day.
  final int maxDailyWrites;

  // ---------------------------------------------------------------------------
  // State Watchdog
  // ---------------------------------------------------------------------------

  /// Maximum widget rebuilds per second before triggering a warning.
  final int maxRebuildsPerSecond;

  /// Multiplier applied to [maxRebuildsPerSecond] to determine when a cyclic
  /// rebuild loop should **trip the circuit breaker**.
  ///
  /// For example, with a multiplier of 3 and maxRebuildsPerSecond of 30,
  /// the circuit trips after 90 throttled setState calls from a single widget.
  final int rebuildTripMultiplier;

  // ---------------------------------------------------------------------------
  // Circuit Breaker
  // ---------------------------------------------------------------------------

  /// Number of consecutive failures before the circuit trips to [open].
  final int failureThreshold;

  /// How long the circuit stays in [open] before transitioning to [halfOpen].
  final Duration openDuration;

  /// Number of test requests allowed while in [halfOpen] state.
  final int halfOpenTestRequests;

  // ---------------------------------------------------------------------------
  // Recovery
  // ---------------------------------------------------------------------------

  /// Duration after which daily counters are reset (default 24 h).
  final Duration dailyResetDuration;

  /// When `true`, the [openDuration] doubles with each consecutive trip
  /// (capped at 5 minutes).
  final bool enableExponentialBackoff;

  // ---------------------------------------------------------------------------
  // Constructor
  // ---------------------------------------------------------------------------

  const SentinelConfig({
    this.maxRequestsPerMinute = 60,
    this.maxDailyRequests = 3000,
    this.maxDailyWrites = 500,
    this.maxRebuildsPerSecond = 30,
    this.rebuildTripMultiplier = 3,
    this.failureThreshold = 5,
    this.openDuration = const Duration(seconds: 30),
    this.halfOpenTestRequests = 3,
    this.dailyResetDuration = const Duration(hours: 24),
    this.enableExponentialBackoff = true,
  });

  // ---------------------------------------------------------------------------
  // Presets
  // ---------------------------------------------------------------------------

  /// Relaxed limits suitable for development / debugging.
  factory SentinelConfig.development() => const SentinelConfig(
    maxRequestsPerMinute: 120,
    maxDailyRequests: 20000,
    maxDailyWrites: 2000,
    maxRebuildsPerSecond: 60,
    rebuildTripMultiplier: 5,
    failureThreshold: 10,
    openDuration: Duration(seconds: 15),
    halfOpenTestRequests: 5,
    enableExponentialBackoff: false,
  );

  /// Balanced limits for production applications.
  factory SentinelConfig.production() => const SentinelConfig();

  /// Aggressive limits for maximum abuse protection.
  factory SentinelConfig.strict() => const SentinelConfig(
    maxRequestsPerMinute: 30,
    maxDailyRequests: 1500,
    maxDailyWrites: 200,
    maxRebuildsPerSecond: 15,
    rebuildTripMultiplier: 2,
    failureThreshold: 3,
    openDuration: Duration(seconds: 60),
    halfOpenTestRequests: 2,
    enableExponentialBackoff: true,
  );

  @override
  String toString() => 'SentinelConfig('
      'rpm: $maxRequestsPerMinute, '
      'dailyReads: $maxDailyRequests, '
      'dailyWrites: $maxDailyWrites, '
      'rebuilds/s: $maxRebuildsPerSecond, '
      'tripMultiplier: ${rebuildTripMultiplier}x, '
      'failures: $failureThreshold, '
      'openDur: ${openDuration.inSeconds}s, '
      'halfOpenTests: $halfOpenTestRequests, '
      'backoff: $enableExponentialBackoff)';
}
