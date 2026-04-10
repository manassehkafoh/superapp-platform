namespace SuperApp.Common;

/// <summary>
/// Provides the current request correlation ID for distributed tracing.
/// Propagated via X-Correlation-ID HTTP header through all service calls.
/// </summary>
public interface ICorrelationIdAccessor
{
    string CorrelationId { get; }
}
