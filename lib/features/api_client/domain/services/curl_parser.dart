import 'dart:convert';

import '../models/api_request.dart';
import '../models/http_method.dart';
import '../models/key_value.dart';
import '../models/request_auth.dart';
import '../models/request_body.dart';
import 'url_utils.dart';

class CurlParseException implements Exception {
  const CurlParseException(this.message);
  final String message;

  @override
  String toString() => message;
}

/// Parses common `curl` invocations (bash/zsh quoting, Windows cmd `^`
/// continuations) into an [ApiRequest]. Unsupported flags are ignored and
/// reported through [CurlParseResult.warnings].
class CurlParser {
  const CurlParser();

  static const _ignoredFlags = {
    '-s',
    '--silent',
    '-S',
    '--show-error',
    '-v',
    '--verbose',
    '-i',
    '--include',
    '--compressed',
    '-k',
    '--insecure',
    '-f',
    '--fail',
    '--http1.0',
    '--http1.1',
    '--http2',
    '--http2-prior-knowledge',
    '--http3',
    '-N',
    '--no-buffer',
    '-#',
    '--progress-bar',
    '-g',
    '--globoff',
    '--tlsv1.2',
    '--tlsv1.3',
    '--ipv4',
    '-4',
    '--ipv6',
    '-6',
  };

  /// Flags that take a value we don't use.
  static const _ignoredWithValue = {
    '-o',
    '--output',
    '--connect-timeout',
    '--retry',
    '-w',
    '--write-out',
    '--cacert',
    '--cert',
    '--key',
    '-x',
    '--proxy',
    '-c',
    '--cookie-jar',
    '-r',
    '--range',
    '--limit-rate',
    '--resolve',
    '-T',
    '--upload-file',
  };

  static const _shortWithValue = {
    'X',
    'H',
    'd',
    'F',
    'u',
    'A',
    'b',
    'e',
    'm',
    'o',
    'x',
    'c',
    'r',
    'w',
    'T',
  };

  CurlParseResult parse(String input) {
    final tokens = tokenize(input);
    if (tokens.isEmpty) {
      throw const CurlParseException('The command is empty.');
    }
    if (tokens.first != 'curl' &&
        !tokens.first.endsWith('/curl') &&
        tokens.first != 'curl.exe') {
      throw const CurlParseException('The command must start with "curl".');
    }

    String? method;
    String? url;
    final headers = <KeyValue>[];
    final dataParts = <String>[];
    final urlEncodeParts = <String>[];
    final formFields = <FormDataField>[];
    String? binaryFile;
    var forceGet = false;
    var headOnly = false;
    bool? followRedirects;
    int? timeoutMs;
    RequestAuth auth = const NoAuth();
    final warnings = <String>[];

    final args = _expandShortFlags(tokens.skip(1).toList());
    for (var i = 0; i < args.length; i++) {
      var arg = args[i];
      String? inlineValue;
      if (arg.startsWith('--') && arg.contains('=')) {
        final eq = arg.indexOf('=');
        inlineValue = arg.substring(eq + 1);
        arg = arg.substring(0, eq);
      }

      String next() {
        if (inlineValue != null) return inlineValue;
        if (i + 1 >= args.length) {
          throw CurlParseException('Option $arg is missing a value.');
        }
        return args[++i];
      }

      switch (arg) {
        case '-X' || '--request':
          method = next().toUpperCase();
        case '--url':
          url = next();
        case '-H' || '--header':
          final raw = next();
          final colon = raw.indexOf(':');
          if (colon <= 0) {
            warnings.add('Ignored malformed header "$raw".');
            break;
          }
          headers.add(
            KeyValue(
              key: raw.substring(0, colon).trim(),
              value: raw.substring(colon + 1).trim(),
            ),
          );
        case '-d' || '--data' || '--data-raw' || '--data-ascii':
          final v = next();
          if (arg != '--data-raw' && v.startsWith('@')) {
            binaryFile = v.substring(1);
          } else {
            dataParts.add(v);
          }
        case '--data-binary':
          final v = next();
          if (v.startsWith('@')) {
            binaryFile = v.substring(1);
          } else {
            dataParts.add(v);
          }
        case '--data-urlencode':
          urlEncodeParts.add(next());
        case '--json':
          dataParts.add(next());
          headers
            ..add(KeyValue(key: 'Content-Type', value: 'application/json'))
            ..add(KeyValue(key: 'Accept', value: 'application/json'));
        case '-F' || '--form' || '--form-string':
          formFields.add(
            _parseFormField(next(), literal: arg == '--form-string'),
          );
        case '-u' || '--user':
          final v = next();
          final colon = v.indexOf(':');
          auth = colon == -1
              ? BasicAuth(username: v)
              : BasicAuth(
                  username: v.substring(0, colon),
                  password: v.substring(colon + 1),
                );
        case '--oauth2-bearer':
          auth = BearerAuth(token: next());
        case '-A' || '--user-agent':
          headers.add(KeyValue(key: 'User-Agent', value: next()));
        case '-b' || '--cookie':
          headers.add(KeyValue(key: 'Cookie', value: next()));
        case '-e' || '--referer':
          headers.add(KeyValue(key: 'Referer', value: next()));
        case '-G' || '--get':
          forceGet = true;
        case '-I' || '--head':
          headOnly = true;
        case '-L' || '--location':
          followRedirects = true;
        case '-m' || '--max-time':
          final seconds = double.tryParse(next());
          if (seconds != null) timeoutMs = (seconds * 1000).round();
        default:
          if (_ignoredFlags.contains(arg)) break;
          if (_ignoredWithValue.contains(arg)) {
            next();
            warnings.add('Ignored unsupported option $arg.');
            break;
          }
          if (arg.startsWith('-') && arg.length > 1) {
            warnings.add('Ignored unknown option $arg.');
            break;
          }
          if (url == null) {
            url = arg;
          } else {
            warnings.add('Ignored extra argument "$arg".');
          }
      }
    }

    if (url == null || url.trim().isEmpty) {
      throw const CurlParseException('No URL found in the cURL command.');
    }

    // Authorization headers become first-class auth configs.
    if (auth is NoAuth) {
      final authHeader = headers
          .where((h) => h.key.toLowerCase() == 'authorization')
          .firstOrNull;
      final value = authHeader?.value ?? '';
      if (value.toLowerCase().startsWith('bearer ')) {
        auth = BearerAuth(token: value.substring(7).trim());
        headers.remove(authHeader);
      } else if (value.toLowerCase().startsWith('basic ')) {
        final decoded = _tryDecodeBasic(value.substring(6).trim());
        if (decoded != null) {
          auth = decoded;
          headers.remove(authHeader);
        }
      }
    }

    final contentType = headers
        .where((h) => h.key.toLowerCase() == 'content-type')
        .map((h) => h.value.toLowerCase())
        .firstOrNull;

    var body = const RequestBody();
    final allData = [...dataParts, ...urlEncodeParts.map(_encodeDataUrlencode)];
    if (forceGet && allData.isNotEmpty) {
      final sep = url.contains('?') ? '&' : '?';
      url = '$url$sep${allData.join('&')}';
      allData.clear();
    }

    if (formFields.isNotEmpty) {
      body = RequestBody(type: BodyType.formData, formData: formFields);
      headers.removeWhere(
        (h) =>
            h.key.toLowerCase() == 'content-type' &&
            h.value.toLowerCase().startsWith('multipart/form-data'),
      );
    } else if (binaryFile != null) {
      body = RequestBody(type: BodyType.binary, binaryFilePath: binaryFile);
    } else if (allData.isNotEmpty) {
      final joined = allData.join('&');
      body = _bodyFromData(joined, contentType);
      if (body.type == BodyType.urlEncoded || body.type == BodyType.json) {
        headers.removeWhere(
          (h) =>
              h.key.toLowerCase() == 'content-type' &&
              (h.value.toLowerCase().contains('x-www-form-urlencoded') ||
                  h.value.toLowerCase() == 'application/json'),
        );
      }
    }

    final hasBody = body.type != BodyType.none;
    final resolvedMethod = headOnly
        ? HttpMethod.head
        : method != null
        ? HttpMethod.tryParse(method) ??
              (throw CurlParseException('Unsupported HTTP method "$method".'))
        : (hasBody && !forceGet ? HttpMethod.post : HttpMethod.get);

    final request = ApiRequest(
      name: _nameFromUrl(url),
      method: resolvedMethod,
      url: url,
      params: UrlUtils.paramsFromUrl(url, const []),
      headers: headers,
      body: body,
      auth: auth,
      options: RequestOptions(
        timeoutMs: timeoutMs,
        followRedirects: followRedirects,
      ),
    );
    return CurlParseResult(request, warnings);
  }

  RequestBody _bodyFromData(String data, String? contentType) {
    final trimmed = data.trim();
    final looksJson =
        (trimmed.startsWith('{') && trimmed.endsWith('}')) ||
        (trimmed.startsWith('[') && trimmed.endsWith(']'));
    if (contentType?.contains('json') ?? false) {
      return RequestBody(type: BodyType.json, text: data);
    }
    if (contentType == null && looksJson) {
      return RequestBody(type: BodyType.json, text: data);
    }
    if (contentType == null || contentType.contains('x-www-form-urlencoded')) {
      final pairs = UrlUtils.parseQuery(data);
      final isFormLike =
          data.split('&').every((part) => part.contains('=')) &&
          pairs.every((p) => p.$1.isNotEmpty && !p.$1.contains(RegExp(r'\s')));
      if (pairs.isNotEmpty && isFormLike) {
        return RequestBody(
          type: BodyType.urlEncoded,
          urlEncoded: [
            for (final (k, v) in pairs)
              KeyValue(key: _decode(k), value: _decode(v)),
          ],
        );
      }
    }
    final language = switch (contentType) {
      final ct? when ct.contains('xml') => RawLanguage.xml,
      final ct? when ct.contains('html') => RawLanguage.html,
      final ct? when ct.contains('javascript') => RawLanguage.javascript,
      _ => RawLanguage.text,
    };
    return RequestBody(type: BodyType.raw, text: data, rawLanguage: language);
  }

  static String _decode(String s) {
    try {
      return Uri.decodeQueryComponent(s);
    } catch (_) {
      return s;
    }
  }

  static String _encodeDataUrlencode(String v) {
    final eq = v.indexOf('=');
    if (eq == -1) return Uri.encodeQueryComponent(v);
    return '${v.substring(0, eq)}=${Uri.encodeQueryComponent(v.substring(eq + 1))}';
  }

  FormDataField _parseFormField(String raw, {required bool literal}) {
    final eq = raw.indexOf('=');
    if (eq <= 0) return FormDataField(key: raw);
    final key = raw.substring(0, eq);
    var value = raw.substring(eq + 1);
    if (!literal && value.startsWith('@')) {
      var path = value.substring(1);
      var type = '';
      final semi = path.indexOf(';');
      if (semi != -1) {
        final attrs = path.substring(semi + 1);
        path = path.substring(0, semi);
        final typeMatch = RegExp(r'type=([^;]+)').firstMatch(attrs);
        type = typeMatch?.group(1) ?? '';
      }
      return FormDataField(
        key: key,
        kind: FormFieldKind.file,
        filePath: path,
        contentType: type,
      );
    }
    if (!literal && value.startsWith('<')) value = value.substring(1);
    return FormDataField(key: key, value: value);
  }

  BasicAuth? _tryDecodeBasic(String encoded) {
    try {
      final decoded = utf8.decode(base64.decode(encoded));
      final colon = decoded.indexOf(':');
      if (colon == -1) return null;
      return BasicAuth(
        username: decoded.substring(0, colon),
        password: decoded.substring(colon + 1),
      );
    } catch (_) {
      return null;
    }
  }

  String _nameFromUrl(String url) {
    final base = UrlParts.split(url).base;
    final withoutScheme = base.replaceFirst(RegExp(r'^[a-zA-Z]+://'), '');
    final slash = withoutScheme.indexOf('/');
    final path = slash == -1 ? '' : withoutScheme.substring(slash);
    if (path.isEmpty || path == '/') {
      return withoutScheme.isEmpty ? 'Imported request' : withoutScheme;
    }
    return path;
  }

  /// `-sSL` → `-s -S -L`; `-XPOST` → `-X POST`.
  List<String> _expandShortFlags(List<String> args) {
    final out = <String>[];
    for (final a in args) {
      if (a.length > 2 && a.startsWith('-') && !a.startsWith('--')) {
        final flag = a[1];
        if (_shortWithValue.contains(flag)) {
          out
            ..add('-$flag')
            ..add(a.substring(2));
          continue;
        }
        for (var j = 1; j < a.length; j++) {
          final c = a[j];
          out.add('-$c');
          if (_shortWithValue.contains(c)) {
            final rest = a.substring(j + 1);
            if (rest.isNotEmpty) out.add(rest);
            break;
          }
        }
        continue;
      }
      out.add(a);
    }
    return out;
  }

  /// POSIX-ish shell tokenizer supporting single quotes, double quotes with
  /// backslash escapes, `$'…'` ANSI-C strings, backslash and caret line
  /// continuations.
  static List<String> tokenize(String input) {
    final source = input
        .replaceAll('\r\n', '\n')
        .replaceAll(RegExp(r'\\\n'), ' ')
        .replaceAll(RegExp(r'\^\n'), ' ')
        .replaceAll('^"', '"');
    final tokens = <String>[];
    final current = StringBuffer();
    var inToken = false;
    var i = 0;

    void flush() {
      if (inToken) tokens.add(current.toString());
      current.clear();
      inToken = false;
    }

    while (i < source.length) {
      final c = source[i];
      if (c == ' ' || c == '\t' || c == '\n') {
        flush();
        i++;
      } else if (c == "'") {
        inToken = true;
        final end = source.indexOf("'", i + 1);
        if (end == -1) {
          throw const CurlParseException('Unterminated single quote.');
        }
        current.write(source.substring(i + 1, end));
        i = end + 1;
      } else if (c == r'$' && i + 1 < source.length && source[i + 1] == "'") {
        inToken = true;
        i += 2;
        while (i < source.length && source[i] != "'") {
          if (source[i] == r'\' && i + 1 < source.length) {
            final n = source[i + 1];
            current.write(switch (n) {
              'n' => '\n',
              't' => '\t',
              'r' => '\r',
              _ => n,
            });
            i += 2;
          } else {
            current.write(source[i++]);
          }
        }
        if (i >= source.length) {
          throw const CurlParseException('Unterminated quote.');
        }
        i++;
      } else if (c == '"') {
        inToken = true;
        i++;
        while (i < source.length && source[i] != '"') {
          if (source[i] == r'\' &&
              i + 1 < source.length &&
              r'"\$`'.contains(source[i + 1])) {
            current.write(source[i + 1]);
            i += 2;
          } else {
            current.write(source[i++]);
          }
        }
        if (i >= source.length) {
          throw const CurlParseException('Unterminated double quote.');
        }
        i++;
      } else if (c == r'\' && i + 1 < source.length) {
        inToken = true;
        current.write(source[i + 1]);
        i += 2;
      } else {
        inToken = true;
        current.write(c);
        i++;
      }
    }
    flush();
    return tokens;
  }
}

class CurlParseResult {
  const CurlParseResult(this.request, this.warnings);
  final ApiRequest request;
  final List<String> warnings;
}
