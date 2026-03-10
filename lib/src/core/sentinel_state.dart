/// Represents the three states of the Circuit Breaker pattern.
///
/// - [closed]: Normal operation. All requests pass through.
/// - [open]: Circuit is tripped. All requests are blocked immediately.
/// - [halfOpen]: Recovery probe. A limited number of test requests are allowed
///   to determine if the system has recovered.
enum SentinelCircuitState {
  /// Normal flow — all requests pass through.
  closed,

  /// Blocked — all requests fail immediately with [SentinelBlockedException].
  open,

  /// Recovery probe — allows [SentinelConfig.halfOpenTestRequests] test
  /// requests to verify the system has recovered.
  halfOpen,
}
