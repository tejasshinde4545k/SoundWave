sealed class ApiError implements Exception {
  const ApiError(this.message);

  final String message;

  @override
  String toString() => message;
}

class RailwayNetworkError extends ApiError {
  const RailwayNetworkError([
    super.message = 'Network connection failed.',
    this.endpoint,
    this.originalError,
  ]);

  final String? endpoint;
  final Object? originalError;

  @override
  String toString() =>
      'RailwayNetworkError: $message${endpoint != null ? ' ($endpoint)' : ''}';
}

class RailwayTimeoutError extends ApiError {
  const RailwayTimeoutError([
    super.message = 'The request timed out.',
    this.endpoint,
    this.timeoutSeconds,
  ]);

  final String? endpoint;
  final int? timeoutSeconds;

  @override
  String toString() =>
      'RailwayTimeoutError: $message${endpoint != null ? ' ($endpoint)' : ''}';
}

class RailwayHttpError extends ApiError {
  RailwayHttpError(
    this.statusCode, [
    super.message = 'HTTP Error',
    this.endpoint,
    this.requestUrl,
    this.responseBody,
    this.retryAfter,
    DateTime? timestamp,
  ]) : timestamp = timestamp ?? DateTime.now();

  final int statusCode;
  final String? endpoint;
  final String? requestUrl;
  final String? responseBody;
  final String? retryAfter;
  final DateTime timestamp;

  @override
  String toString() =>
      'RailwayHttpError: $statusCode - $message (endpoint: ${endpoint ?? 'unknown'})';
}

class RailwayRateLimitError extends RailwayHttpError {
  RailwayRateLimitError({
    String? endpoint,
    String? requestUrl,
    String? responseBody,
    String? retryAfter,
    DateTime? timestamp,
  }) : super(
          429,
          'Too many requests.',
          endpoint,
          requestUrl,
          responseBody,
          retryAfter,
          timestamp,
        );
}

class RailwayServerError extends RailwayHttpError {
  RailwayServerError(
    super.statusCode, [
    super.message = 'The music service is unavailable.',
    super.endpoint,
    super.requestUrl,
    super.responseBody,
    super.retryAfter,
    super.timestamp,
  ]);
}

class RailwayInvalidResponseError extends ApiError {
  const RailwayInvalidResponseError([
    super.message = 'The music service returned invalid data.',
  ]);
}

class RailwayParseError extends ApiError {
  const RailwayParseError([
    super.message = 'Failed to parse the music service response.',
  ]);
}

class NotFoundError extends RailwayHttpError {
  NotFoundError([
    String? endpoint,
    String? requestUrl,
    String? responseBody,
  ]) : super(
          404,
          'The requested music was not found.',
          endpoint,
          requestUrl,
          responseBody,
        );
}

class StreamUnavailableError extends ApiError {
  const StreamUnavailableError([
    super.message = 'A stream is not available for this song.',
  ]);
}

class PlaybackError extends ApiError {
  const PlaybackError([
    super.message = 'Unable to play this song right now.',
  ]);
}
