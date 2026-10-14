import '../enums/fastpix_prerender_error_code.dart';
import '../enums/fastpix_prerender_status.dart';

/// What a prerender request came to.
class FastPixPrerenderResult {
  /// The status the request reached, or the existing entry's status for a
  /// duplicate request.
  final FastPixPrerenderStatus status;

  /// Why it did not reach frame-ready; set when [status] is
  /// [FastPixPrerenderStatus.skipped] (declined by policy) or
  /// [FastPixPrerenderStatus.failed] (started but could not finish).
  final FastPixPrerenderErrorCode? errorCode;

  const FastPixPrerenderResult({
    required this.status,
    this.errorCode,
  });

  @override
  String toString() => 'FastPixPrerenderResult(${status.value}'
      '${errorCode == null ? '' : ', error: ${errorCode!.value}'})';
}
