namespace SuperApp.Common;

/// <summary>
/// Discriminated union for operation results — avoids throwing exceptions across service boundaries.
/// Usage: return Result.Ok(dto); or return Result.Fail(new ValidationError("code","msg"));
/// </summary>
public class Result<T>
{
    public bool IsSuccess { get; }
    public T? Value { get; }
    public AppError? Error { get; }

    private Result(T value)          { IsSuccess = true;  Value = value; }
    private Result(AppError error)   { IsSuccess = false; Error = error; }

    public static Result<T> Ok(T value)         => new(value);
    public static Result<T> Fail(AppError error) => new(error);

    public TOut Match<TOut>(Func<T, TOut> onSuccess, Func<AppError, TOut> onFailure)
        => IsSuccess ? onSuccess(Value!) : onFailure(Error!);
}

public static class Result
{
    public static Result<T> Ok<T>(T value)          => Result<T>.Ok(value);
    public static Result<T> Fail<T>(AppError error)  => Result<T>.Fail(error);
}
