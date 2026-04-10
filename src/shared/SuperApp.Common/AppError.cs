namespace SuperApp.Common;

/// <summary>Error taxonomy shared by all services.</summary>
public abstract record AppError(string Code, string Message);

/// <summary>Request failed domain validation (HTTP 422).</summary>
public record ValidationError(string Code, string Message) : AppError(Code, Message);

/// <summary>Resource not found (HTTP 404).</summary>
public record NotFoundError(string Code, string Message) : AppError(Code, Message);

/// <summary>Caller lacks permission (HTTP 403).</summary>
public record ForbiddenError(string Code, string Message) : AppError(Code, Message);

/// <summary>Downstream service or infrastructure failure (HTTP 502/503).</summary>
public record InfrastructureError(string Code, string Message) : AppError(Code, Message);

/// <summary>Business rule violation (HTTP 409 or 422).</summary>
public record BusinessRuleError(string Code, string Message) : AppError(Code, Message);
