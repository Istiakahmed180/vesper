import 'package:flutter/foundation.dart';

import 'http_method.dart';

/// A fully resolved request, ready to be sent or rendered as cURL.
@immutable
class PreparedRequest {
  const PreparedRequest({
    required this.method,
    required this.url,
    required this.headers,
    required this.body,
    required this.timeout,
    required this.followRedirects,
    this.unresolvedVariables = const {},
  });

  final HttpMethod method;
  final String url;
  final List<MapEntry<String, String>> headers;
  final PreparedBody body;
  final Duration timeout;
  final bool followRedirects;
  final Set<String> unresolvedVariables;

  bool hasHeader(String name) {
    final lower = name.toLowerCase();
    return headers.any((h) => h.key.toLowerCase() == lower);
  }

  PreparedRequest withHeaders(List<MapEntry<String, String>> headers) =>
      PreparedRequest(
        method: method,
        url: url,
        headers: headers,
        body: body,
        timeout: timeout,
        followRedirects: followRedirects,
        unresolvedVariables: unresolvedVariables,
      );
}

@immutable
sealed class PreparedBody {
  const PreparedBody();
}

class NoBody extends PreparedBody {
  const NoBody();
}

class TextBody extends PreparedBody {
  const TextBody(this.text, this.contentType);
  final String text;
  final String contentType;
}

class UrlEncodedBody extends PreparedBody {
  const UrlEncodedBody(this.fields);
  final List<(String, String)> fields;

  String encode() => fields
      .map(
        (f) =>
            '${Uri.encodeQueryComponent(f.$1)}=${Uri.encodeQueryComponent(f.$2)}',
      )
      .join('&');
}

sealed class MultipartPart {
  const MultipartPart(this.name);
  final String name;
}

class MultipartTextPart extends MultipartPart {
  const MultipartTextPart(super.name, this.value);
  final String value;
}

class MultipartFilePart extends MultipartPart {
  const MultipartFilePart(super.name, this.path, {this.contentType = ''});
  final String path;
  final String contentType;
}

class MultipartBody extends PreparedBody {
  const MultipartBody(this.parts);
  final List<MultipartPart> parts;
}

class FileBody extends PreparedBody {
  const FileBody(this.path, this.contentType);
  final String path;
  final String contentType;
}
