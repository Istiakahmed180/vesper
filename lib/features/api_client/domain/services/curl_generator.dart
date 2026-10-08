import '../../../../core/constants/app_constants.dart';
import '../models/http_method.dart';
import '../models/prepared_request.dart';

/// Renders a [PreparedRequest] as a POSIX shell `curl` command.
class CurlGenerator {
  const CurlGenerator();

  String generate(PreparedRequest request, {bool multiline = true}) {
    final args = <String>['curl'];
    if (request.method == HttpMethod.head) {
      args.add('--head');
    } else if (!(request.method == HttpMethod.get && request.body is NoBody)) {
      args.add('--request ${request.method.value}');
    }
    args.add('--url ${quote(request.url)}');
    if (request.followRedirects) args.add('--location');

    final isMultipart = request.body is MultipartBody;
    for (final h in request.headers) {
      final name = h.key.toLowerCase();
      if (name == 'user-agent' && h.value == AppConstants.userAgent) continue;
      if (name == 'accept' && h.value == '*/*') continue;
      if (isMultipart && name == 'content-type') continue;
      args.add('--header ${quote('${h.key}: ${h.value}')}');
    }

    switch (request.body) {
      case NoBody():
        break;
      case TextBody(:final text):
        args.add('--data-raw ${quote(text)}');
      case final UrlEncodedBody body:
        for (final (k, v) in body.fields) {
          args.add('--data-urlencode ${quote('$k=$v')}');
        }
      case MultipartBody(parts: final multipart):
        for (final part in multipart) {
          switch (part) {
            case MultipartTextPart(:final name, :final value):
              // --form-string stops curl interpreting a leading @ or <.
              args.add('--form-string ${quote('$name=$value')}');
            case MultipartFilePart(
              :final name,
              :final path,
              :final contentType,
            ):
              final type = contentType.isEmpty ? '' : ';type=$contentType';
              args.add('--form ${quote('$name=@$path$type')}');
          }
        }
      case FileBody(:final path):
        args.add('--data-binary ${quote('@$path')}');
    }

    return multiline ? args.join(' \\\n  ') : args.join(' ');
  }

  static final _safe = RegExp(r'^[A-Za-z0-9_\-.,/:=@%+]+$');

  /// Single-quotes [value] for POSIX shells.
  static String quote(String value) {
    if (value.isEmpty) return "''";
    if (_safe.hasMatch(value)) return value;
    return "'${value.replaceAll("'", r"'\''")}'";
  }
}
