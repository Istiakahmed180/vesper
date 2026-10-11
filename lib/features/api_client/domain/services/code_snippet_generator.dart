import 'dart:convert';

import '../../../../core/constants/app_constants.dart';
import '../models/http_method.dart';
import '../models/prepared_request.dart';
import 'curl_generator.dart';

/// Languages and libraries a request can be rendered in.
enum SnippetLanguage {
  curl('cURL', 'Shell'),
  http('HTTP', 'Raw request'),
  javascriptFetch('JavaScript', 'fetch'),
  nodeAxios('Node.js', 'Axios'),
  pythonRequests('Python', 'requests'),
  dartHttp('Dart', 'http'),
  dartDio('Dart', 'Dio'),
  goNative('Go', 'net/http'),
  phpCurl('PHP', 'cURL'),
  swiftUrlSession('Swift', 'URLSession'),
  javaOkHttp('Java', 'OkHttp'),
  csharpHttpClient('C#', 'HttpClient'),
  powershell('PowerShell', 'Invoke-WebRequest');

  const SnippetLanguage(this.language, this.library);
  final String language;
  final String library;

  String get label => '$language – $library';
}

/// Renders a [PreparedRequest] (variables resolved, authorization applied)
/// as ready-to-run code. Vesper's default User-Agent and `Accept: */*`
/// headers are left out, as are multipart content types (libraries add the
/// boundary themselves).
class CodeSnippetGenerator {
  const CodeSnippetGenerator();

  String generate(PreparedRequest request, SnippetLanguage language) =>
      switch (language) {
        SnippetLanguage.curl => const CurlGenerator().generate(request),
        SnippetLanguage.http => _http(request),
        SnippetLanguage.javascriptFetch => _fetch(request),
        SnippetLanguage.nodeAxios => _axios(request),
        SnippetLanguage.pythonRequests => _python(request),
        SnippetLanguage.dartHttp => _dartHttp(request),
        SnippetLanguage.dartDio => _dartDio(request),
        SnippetLanguage.goNative => _go(request),
        SnippetLanguage.phpCurl => _php(request),
        SnippetLanguage.swiftUrlSession => _swift(request),
        SnippetLanguage.javaOkHttp => _java(request),
        SnippetLanguage.csharpHttpClient => _csharp(request),
        SnippetLanguage.powershell => _powershell(request),
      };

  // ---------------------------------------------------------------- helpers

  static List<MapEntry<String, String>> _headers(PreparedRequest r) => [
    for (final h in r.headers)
      if (!(h.key.toLowerCase() == 'user-agent' &&
              h.value == AppConstants.userAgent) &&
          !(h.key.toLowerCase() == 'accept' && h.value == '*/*') &&
          !(r.body is MultipartBody && h.key.toLowerCase() == 'content-type'))
        h,
  ];

  static String? _contentType(PreparedRequest r) {
    for (final h in r.headers) {
      if (h.key.toLowerCase() == 'content-type') return h.value;
    }
    return null;
  }

  static String _fileName(String path) =>
      path.split(RegExp(r'[/\\]')).where((p) => p.isNotEmpty).lastOrNull ??
      path;

  /// Text sent for text and URL-encoded bodies; null for other bodies.
  static String? _textPayload(PreparedBody body) => switch (body) {
    TextBody(:final text) => text,
    final UrlEncodedBody b => b.encode(),
    _ => null,
  };

  /// JSON-style double-quoted literal; valid in JavaScript, Python and Go.
  static String _json(String s) => jsonEncode(s);

  /// Double-quoted literal with C-style escapes (Java, C#, Swift).
  static String _cQuoted(String s, {bool swift = false}) {
    final out = StringBuffer('"');
    for (final rune in s.runes) {
      switch (rune) {
        case 0x5C:
          out.write(r'\\');
        case 0x22:
          out.write(r'\"');
        case 0x0A:
          out.write(r'\n');
        case 0x0D:
          out.write(r'\r');
        case 0x09:
          out.write(r'\t');
        default:
          if (rune < 0x20) {
            out.write(
              swift
                  ? '\\u{${rune.toRadixString(16)}}'
                  : '\\u${rune.toRadixString(16).padLeft(4, '0')}',
            );
          } else {
            out.writeCharCode(rune);
          }
      }
    }
    out.write('"');
    return out.toString();
  }

  static String _dart(String s) {
    final escaped = s
        .replaceAll(r'\', r'\\')
        .replaceAll("'", r"\'")
        .replaceAll(r'$', r'\$')
        .replaceAll('\n', r'\n')
        .replaceAll('\r', r'\r')
        .replaceAll('\t', r'\t');
    return "'$escaped'";
  }

  static String _phpStr(String s) =>
      "'${s.replaceAll(r'\', r'\\').replaceAll("'", r"\'")}'";

  static String _ps(String s) => "'${s.replaceAll("'", "''")}'";

  static String _goString(String s) =>
      s.contains('\n') && !s.contains('`') ? '`$s`' : _json(s);

  static String _indent(String text, String prefix) =>
      text.split('\n').map((l) => l.isEmpty ? l : '$prefix$l').join('\n');

  /// Pretty JSON when [text] parses as JSON, otherwise null.
  static String? _prettyJson(String text, {String indent = '  '}) {
    try {
      return JsonEncoder.withIndent(indent).convert(jsonDecode(text));
    } catch (_) {
      return null;
    }
  }

  // ------------------------------------------------------------------- HTTP

  String _http(PreparedRequest r) {
    final uri = Uri.tryParse(r.url);
    final target = uri == null || uri.host.isEmpty
        ? r.url
        : '${uri.path.isEmpty ? '/' : uri.path}${uri.hasQuery ? '?${uri.query}' : ''}';
    final lines = <String>['${r.method.value} $target HTTP/1.1'];
    if (uri != null && uri.host.isNotEmpty) {
      lines.add('Host: ${uri.hasPort ? '${uri.host}:${uri.port}' : uri.host}');
    }
    final headers = _headers(r);
    const boundary = '----VesperBoundary';
    for (final h in headers) {
      lines.add('${h.key}: ${h.value}');
    }
    final body = switch (r.body) {
      NoBody() => null,
      TextBody(:final text) => text,
      final UrlEncodedBody b => b.encode(),
      FileBody(:final path) => '<contents of $path>',
      MultipartBody(:final parts) => [
        for (final p in parts) ...[
          '--$boundary',
          switch (p) {
            MultipartTextPart(:final name, :final value) =>
              'Content-Disposition: form-data; name="$name"\n\n$value',
            MultipartFilePart(:final name, :final path, :final contentType) =>
              'Content-Disposition: form-data; name="$name"; '
                  'filename="${_fileName(path)}"\n'
                  'Content-Type: ${contentType.isEmpty ? 'application/octet-stream' : contentType}'
                  '\n\n<contents of $path>',
          },
        ],
        '--$boundary--',
      ].join('\n'),
    };
    if (r.body is MultipartBody) {
      lines.add('Content-Type: multipart/form-data; boundary=$boundary');
    }
    return body == null ? lines.join('\n') : '${lines.join('\n')}\n\n$body';
  }

  // -------------------------------------------------------------- JS fetch

  String _fetch(PreparedRequest r) {
    final b = StringBuffer();
    final headers = _headers(r);
    if (headers.isNotEmpty) {
      b.writeln('const headers = new Headers();');
      for (final h in headers) {
        b.writeln('headers.append(${_json(h.key)}, ${_json(h.value)});');
      }
      b.writeln();
    }
    String? bodyExpr;
    switch (r.body) {
      case NoBody():
        break;
      case TextBody(:final text):
        final pretty = _prettyJson(text);
        bodyExpr = pretty == null ? _json(text) : 'JSON.stringify($pretty)';
      case final UrlEncodedBody body:
        b.writeln('const body = new URLSearchParams();');
        for (final (k, v) in body.fields) {
          b.writeln('body.append(${_json(k)}, ${_json(v)});');
        }
        b.writeln();
        bodyExpr = 'body';
      case MultipartBody(:final parts):
        b.writeln('const body = new FormData();');
        for (final p in parts) {
          switch (p) {
            case MultipartTextPart(:final name, :final value):
              b.writeln('body.append(${_json(name)}, ${_json(value)});');
            case MultipartFilePart(:final name, :final path):
              b.writeln(
                '// Pick ${_fileName(path)} with an <input type="file">.\n'
                'body.append(${_json(name)}, fileInput.files[0], ${_json(_fileName(path))});',
              );
          }
        }
        b.writeln();
        bodyExpr = 'body';
      case FileBody(:final path):
        b.writeln(
          '// The contents of ${_fileName(path)}, e.g. from an <input type="file">.',
        );
        b.writeln('const body = fileInput.files[0];\n');
        bodyExpr = 'body';
    }
    b.writeln('const response = await fetch(${_json(r.url)}, {');
    b.writeln('  method: ${_json(r.method.value)},');
    if (headers.isNotEmpty) b.writeln('  headers,');
    if (bodyExpr != null) {
      b.writeln('  body: ${_indent(bodyExpr, '  ').trimLeft()},');
    }
    if (!r.followRedirects) b.writeln('  redirect: "manual",');
    b.writeln('});');
    b.write('console.log(await response.text());');
    return b.toString();
  }

  // ----------------------------------------------------------- Node axios

  String _axios(PreparedRequest r) {
    final b = StringBuffer();
    final needsFs = r.body is FileBody || r.body is MultipartBody;
    b.writeln("const axios = require('axios');");
    if (r.body is MultipartBody) {
      b.writeln("const FormData = require('form-data');");
    }
    if (needsFs) b.writeln("const fs = require('fs');");
    b.writeln();
    String? data;
    switch (r.body) {
      case NoBody():
        break;
      case TextBody(:final text):
        data = _prettyJson(text) ?? _json(text);
      case final UrlEncodedBody body:
        data = [
          'new URLSearchParams([',
          for (final (k, v) in body.fields) '  [${_json(k)}, ${_json(v)}],',
          '])',
        ].join('\n');
      case MultipartBody(:final parts):
        b.writeln('const data = new FormData();');
        for (final p in parts) {
          switch (p) {
            case MultipartTextPart(:final name, :final value):
              b.writeln('data.append(${_json(name)}, ${_json(value)});');
            case MultipartFilePart(:final name, :final path):
              b.writeln(
                'data.append(${_json(name)}, fs.createReadStream(${_json(path)}));',
              );
          }
        }
        b.writeln();
        data = 'data';
      case FileBody(:final path):
        data = 'fs.readFileSync(${_json(path)})';
    }
    final headers = _headers(r);
    b.writeln('axios');
    b.writeln('  .request({');
    b.writeln('    method: ${_json(r.method.value.toLowerCase())},');
    b.writeln('    url: ${_json(r.url)},');
    if (headers.isNotEmpty || r.body is MultipartBody) {
      b.writeln('    headers: {');
      for (final h in headers) {
        b.writeln('      ${_json(h.key)}: ${_json(h.value)},');
      }
      if (r.body is MultipartBody) b.writeln('      ...data.getHeaders(),');
      b.writeln('    },');
    }
    if (data != null) {
      b.writeln('    data: ${_indent(data, '    ').trimLeft()},');
    }
    if (!r.followRedirects) b.writeln('    maxRedirects: 0,');
    b.writeln('  })');
    b.writeln('  .then((response) => console.log(response.data))');
    b.write('  .catch((error) => console.error(error));');
    return b.toString();
  }

  // ------------------------------------------------------- Python requests

  String _python(PreparedRequest r) {
    final b = StringBuffer('import requests\n\n');
    b.writeln('url = ${_json(r.url)}');
    final headers = _headers(r);
    final args = <String>[];
    if (headers.isNotEmpty) {
      b.writeln('headers = {');
      for (final h in headers) {
        b.writeln('    ${_json(h.key)}: ${_json(h.value)},');
      }
      b.writeln('}');
      args.add('headers=headers');
    }
    switch (r.body) {
      case NoBody():
        break;
      case TextBody(:final text):
        b.writeln('payload = ${_json(text)}');
        args.add('data=payload');
      case final UrlEncodedBody body:
        b.writeln('payload = {');
        for (final (k, v) in body.fields) {
          b.writeln('    ${_json(k)}: ${_json(v)},');
        }
        b.writeln('}');
        args.add('data=payload');
      case MultipartBody(:final parts):
        final fields = parts.whereType<MultipartTextPart>().toList();
        final files = parts.whereType<MultipartFilePart>().toList();
        if (fields.isNotEmpty) {
          b.writeln('payload = {');
          for (final f in fields) {
            b.writeln('    ${_json(f.name)}: ${_json(f.value)},');
          }
          b.writeln('}');
          args.add('data=payload');
        }
        if (files.isNotEmpty) {
          b.writeln('files = [');
          for (final f in files) {
            final type = f.contentType.isEmpty
                ? ''
                : ', ${_json(f.contentType)}';
            b.writeln(
              '    (${_json(f.name)}, (${_json(_fileName(f.path))}, '
              'open(${_json(f.path)}, "rb")$type)),',
            );
          }
          b.writeln(']');
          args.add('files=files');
        }
      case FileBody(:final path):
        b.writeln('payload = open(${_json(path)}, "rb")');
        args.add('data=payload');
    }
    if (!r.followRedirects) args.add('allow_redirects=False');
    b.writeln();
    final extra = args.isEmpty ? '' : ', ${args.join(', ')}';
    b.writeln(
      'response = requests.request(${_json(r.method.value)}, url$extra)',
    );
    b.write('print(response.text)');
    return b.toString();
  }

  // -------------------------------------------------------------- Dart http

  String _dartHttp(PreparedRequest r) {
    final b = StringBuffer();
    final headers = _headers(r);
    final multipart = r.body is MultipartBody;
    if (r.body is FileBody) b.writeln("import 'dart:io';\n");
    b.writeln("import 'package:http/http.dart' as http;\n");
    b.writeln('Future<void> main() async {');
    b.writeln(
      '  final request = http.${multipart ? 'Multipart' : ''}Request(\n'
      '    ${_dart(r.method.value)},\n'
      '    Uri.parse(${_dart(r.url)}),\n'
      '  );',
    );
    if (headers.isNotEmpty) {
      b.writeln('  request.headers.addAll({');
      for (final h in headers) {
        b.writeln('    ${_dart(h.key)}: ${_dart(h.value)},');
      }
      b.writeln('  });');
    }
    switch (r.body) {
      case NoBody():
        break;
      case TextBody(:final text):
        b.writeln('  request.body = ${_dart(text)};');
      case final UrlEncodedBody body:
        b.writeln('  request.bodyFields = {');
        for (final (k, v) in body.fields) {
          b.writeln('    ${_dart(k)}: ${_dart(v)},');
        }
        b.writeln('  };');
      case MultipartBody(:final parts):
        for (final p in parts) {
          switch (p) {
            case MultipartTextPart(:final name, :final value):
              b.writeln('  request.fields[${_dart(name)}] = ${_dart(value)};');
            case MultipartFilePart(:final name, :final path):
              b.writeln(
                '  request.files.add(\n'
                '    await http.MultipartFile.fromPath(${_dart(name)}, ${_dart(path)}),\n'
                '  );',
              );
          }
        }
      case FileBody(:final path):
        b.writeln(
          '  request.bodyBytes = await File(${_dart(path)}).readAsBytes();',
        );
    }
    if (!r.followRedirects && !multipart) {
      b.writeln('  request.followRedirects = false;');
    }
    b.writeln();
    b.writeln('  final response = await http.Response.fromStream(');
    b.writeln('    await request.send(),');
    b.writeln('  );');
    b.writeln('  print(response.statusCode);');
    b.writeln('  print(response.body);');
    b.write('}');
    return b.toString();
  }

  // --------------------------------------------------------------- Dart Dio

  String _dartDio(PreparedRequest r) {
    final b = StringBuffer();
    final headers = _headers(r);
    if (r.body is FileBody) b.writeln("import 'dart:io';\n");
    b.writeln("import 'package:dio/dio.dart';\n");
    b.writeln('Future<void> main() async {');
    String? data;
    switch (r.body) {
      case NoBody():
        break;
      case TextBody(:final text):
        data = _dart(text);
      case final UrlEncodedBody body:
        data = [
          '{',
          for (final (k, v) in body.fields) '  ${_dart(k)}: ${_dart(v)},',
          '}',
        ].join('\n');
      case MultipartBody(:final parts):
        b.writeln('  final data = FormData.fromMap({');
        for (final p in parts) {
          switch (p) {
            case MultipartTextPart(:final name, :final value):
              b.writeln('    ${_dart(name)}: ${_dart(value)},');
            case MultipartFilePart(:final name, :final path):
              b.writeln(
                '    ${_dart(name)}: await MultipartFile.fromFile(${_dart(path)}),',
              );
          }
        }
        b.writeln('  });\n');
        data = 'data';
      case FileBody(:final path):
        data = 'File(${_dart(path)}).openRead()';
    }
    b.writeln('  final response = await Dio().request<String>(');
    b.writeln('    ${_dart(r.url)},');
    if (data != null) {
      b.writeln('    data: ${_indent(data, '    ').trimLeft()},');
    }
    b.writeln('    options: Options(');
    b.writeln('      method: ${_dart(r.method.value)},');
    if (headers.isNotEmpty) {
      b.writeln('      headers: {');
      for (final h in headers) {
        b.writeln('        ${_dart(h.key)}: ${_dart(h.value)},');
      }
      b.writeln('      },');
    }
    if (r.body is UrlEncodedBody) {
      b.writeln('      contentType: Headers.formUrlEncodedContentType,');
    }
    if (!r.followRedirects) b.writeln('      followRedirects: false,');
    b.writeln('    ),');
    b.writeln('  );');
    b.writeln('  print(response.statusCode);');
    b.writeln('  print(response.data);');
    b.write('}');
    return b.toString();
  }

  // ---------------------------------------------------------------------- Go

  String _go(PreparedRequest r) {
    final imports = <String>{'fmt', 'io', 'net/http'};
    final setup = StringBuffer();
    var bodyVar = 'nil';
    var multipartType = false;
    switch (r.body) {
      case NoBody():
        break;
      case TextBody(:final text):
        imports.add('strings');
        setup.writeln('\tpayload := strings.NewReader(${_goString(text)})\n');
        bodyVar = 'payload';
      case final UrlEncodedBody body:
        imports.add('strings');
        setup.writeln(
          '\tpayload := strings.NewReader(${_json(body.encode())})\n',
        );
        bodyVar = 'payload';
      case MultipartBody(:final parts):
        imports.addAll({'bytes', 'mime/multipart'});
        setup.writeln('\tpayload := &bytes.Buffer{}');
        setup.writeln('\twriter := multipart.NewWriter(payload)');
        var files = 0;
        for (final p in parts) {
          switch (p) {
            case MultipartTextPart(:final name, :final value):
              setup.writeln(
                '\t_ = writer.WriteField(${_json(name)}, ${_json(value)})',
              );
            case MultipartFilePart(:final name, :final path):
              imports.addAll({'os', 'path/filepath'});
              final n = ++files;
              setup
                ..writeln('\tfile$n, _ := os.Open(${_json(path)})')
                ..writeln(
                  '\tpart$n, _ := writer.CreateFormFile(${_json(name)}, filepath.Base(${_json(path)}))',
                )
                ..writeln('\t_, _ = io.Copy(part$n, file$n)')
                ..writeln('\tfile$n.Close()');
          }
        }
        setup.writeln('\twriter.Close()\n');
        bodyVar = 'payload';
        multipartType = true;
      case FileBody(:final path):
        imports.add('os');
        setup.writeln('\tpayload, err := os.Open(${_json(path)})');
        setup.writeln('\tif err != nil {\n\t\tpanic(err)\n\t}');
        setup.writeln('\tdefer payload.Close()\n');
        bodyVar = 'payload';
    }
    final b = StringBuffer('package main\n\nimport (\n');
    for (final i in imports.toList()..sort()) {
      b.writeln('\t"$i"');
    }
    b.writeln(')\n');
    b.writeln('func main() {');
    b.write(setup);
    b.writeln(
      '\treq, err := http.NewRequest(${_json(r.method.value)}, ${_json(r.url)}, $bodyVar)',
    );
    b.writeln('\tif err != nil {\n\t\tpanic(err)\n\t}');
    for (final h in _headers(r)) {
      b.writeln('\treq.Header.Add(${_json(h.key)}, ${_json(h.value)})');
    }
    if (multipartType) {
      b.writeln(
        '\treq.Header.Set("Content-Type", writer.FormDataContentType())',
      );
    }
    b.writeln();
    if (r.followRedirects) {
      b.writeln('\tclient := &http.Client{}');
    } else {
      b.writeln('\tclient := &http.Client{');
      b.writeln(
        '\t\tCheckRedirect: func(*http.Request, []*http.Request) error { return http.ErrUseLastResponse },',
      );
      b.writeln('\t}');
    }
    b.writeln('\tres, err := client.Do(req)');
    b.writeln('\tif err != nil {\n\t\tpanic(err)\n\t}');
    b.writeln('\tdefer res.Body.Close()\n');
    b.writeln('\tbody, _ := io.ReadAll(res.Body)');
    b.writeln('\tfmt.Println(res.Status)');
    b.writeln('\tfmt.Println(string(body))');
    b.write('}');
    return b.toString();
  }

  // --------------------------------------------------------------- PHP cURL

  String _php(PreparedRequest r) {
    final b = StringBuffer('<?php\n\n\$curl = curl_init();\n\n');
    b.writeln('curl_setopt_array(\$curl, [');
    b.writeln('  CURLOPT_URL => ${_phpStr(r.url)},');
    b.writeln('  CURLOPT_RETURNTRANSFER => true,');
    if (r.method == HttpMethod.head) {
      b.writeln('  CURLOPT_NOBODY => true,');
    } else {
      b.writeln('  CURLOPT_CUSTOMREQUEST => ${_phpStr(r.method.value)},');
    }
    if (r.followRedirects) b.writeln('  CURLOPT_FOLLOWLOCATION => true,');
    switch (r.body) {
      case NoBody():
        break;
      case TextBody(:final text):
        b.writeln('  CURLOPT_POSTFIELDS => ${_phpStr(text)},');
      case final UrlEncodedBody body:
        b.writeln('  CURLOPT_POSTFIELDS => ${_phpStr(body.encode())},');
      case MultipartBody(:final parts):
        b.writeln('  CURLOPT_POSTFIELDS => [');
        for (final p in parts) {
          switch (p) {
            case MultipartTextPart(:final name, :final value):
              b.writeln('    ${_phpStr(name)} => ${_phpStr(value)},');
            case MultipartFilePart(
              :final name,
              :final path,
              :final contentType,
            ):
              final type = contentType.isEmpty
                  ? ''
                  : ', ${_phpStr(contentType)}';
              b.writeln(
                '    ${_phpStr(name)} => new CURLFile(${_phpStr(path)}$type),',
              );
          }
        }
        b.writeln('  ],');
      case FileBody(:final path):
        b.writeln(
          '  CURLOPT_POSTFIELDS => file_get_contents(${_phpStr(path)}),',
        );
    }
    final headers = _headers(r);
    if (headers.isNotEmpty) {
      b.writeln('  CURLOPT_HTTPHEADER => [');
      for (final h in headers) {
        b.writeln('    ${_phpStr('${h.key}: ${h.value}')},');
      }
      b.writeln('  ],');
    }
    b.writeln(']);\n');
    b.writeln('\$response = curl_exec(\$curl);');
    b.writeln('curl_close(\$curl);\n');
    b.write('echo \$response;');
    return b.toString();
  }

  // ------------------------------------------------------ Swift URLSession

  String _swift(PreparedRequest r) {
    String q(String s) => _cQuoted(s, swift: true);
    final b = StringBuffer('import Foundation\n\n');
    b.writeln('var request = URLRequest(url: URL(string: ${q(r.url)})!)');
    b.writeln('request.httpMethod = ${q(r.method.value)}');
    for (final h in _headers(r)) {
      b.writeln(
        'request.addValue(${q(h.value)}, forHTTPHeaderField: ${q(h.key)})',
      );
    }
    switch (r.body) {
      case NoBody():
        break;
      case TextBody(:final text):
        b.writeln('request.httpBody = ${q(text)}.data(using: .utf8)');
      case final UrlEncodedBody body:
        b.writeln('request.httpBody = ${q(body.encode())}.data(using: .utf8)');
      case MultipartBody(:final parts):
        b.writeln('\nlet boundary = "Boundary-\\(UUID().uuidString)"');
        b.writeln(
          'request.addValue("multipart/form-data; boundary=\\(boundary)", '
          'forHTTPHeaderField: "Content-Type")',
        );
        b.writeln('var body = Data()');
        for (final p in parts) {
          b.writeln('body.append("--\\(boundary)\\r\\n".data(using: .utf8)!)');
          switch (p) {
            case MultipartTextPart(:final name, :final value):
              b.writeln(
                'body.append(${q('Content-Disposition: form-data; name="$name"\r\n\r\n$value\r\n')}.data(using: .utf8)!)',
              );
            case MultipartFilePart(
              :final name,
              :final path,
              :final contentType,
            ):
              final type = contentType.isEmpty
                  ? 'application/octet-stream'
                  : contentType;
              b.writeln(
                'body.append(${q('Content-Disposition: form-data; name="$name"; filename="${_fileName(path)}"\r\nContent-Type: $type\r\n\r\n')}.data(using: .utf8)!)',
              );
              b.writeln(
                'body.append(try! Data(contentsOf: URL(fileURLWithPath: ${q(path)})))',
              );
              b.writeln('body.append("\\r\\n".data(using: .utf8)!)');
          }
        }
        b.writeln('body.append("--\\(boundary)--\\r\\n".data(using: .utf8)!)');
        b.writeln('request.httpBody = body');
      case FileBody(:final path):
        b.writeln(
          'request.httpBody = try! Data(contentsOf: URL(fileURLWithPath: ${q(path)}))',
        );
    }
    b.writeln();
    b.writeln(
      'let (data, response) = try await URLSession.shared.data(for: request)',
    );
    b.writeln('print((response as? HTTPURLResponse)?.statusCode ?? 0)');
    b.write('print(String(data: data, encoding: .utf8) ?? "")');
    return b.toString();
  }

  // ------------------------------------------------------------ Java OkHttp

  String _java(PreparedRequest r) {
    const q = _cQuoted;
    final b = StringBuffer();
    final contentType = _contentType(r);
    final client = r.followRedirects
        ? 'new OkHttpClient()'
        : 'new OkHttpClient.Builder().followRedirects(false).build()';
    b.writeln('OkHttpClient client = $client;');
    String body;
    switch (r.body) {
      case NoBody():
        body = r.method.allowsBody ? 'RequestBody.create(new byte[0])' : 'null';
      case TextBody(:final text):
        b.writeln(
          'MediaType mediaType = MediaType.parse(${q(contentType ?? 'text/plain')});',
        );
        b.writeln(
          'RequestBody body = RequestBody.create(${q(text)}, mediaType);',
        );
        body = 'body';
      case final UrlEncodedBody form:
        b.writeln('RequestBody body = new FormBody.Builder()');
        for (final (k, v) in form.fields) {
          b.writeln('    .add(${q(k)}, ${q(v)})');
        }
        b.writeln('    .build();');
        body = 'body';
      case MultipartBody(:final parts):
        b.writeln('RequestBody body = new MultipartBody.Builder()');
        b.writeln('    .setType(MultipartBody.FORM)');
        for (final p in parts) {
          switch (p) {
            case MultipartTextPart(:final name, :final value):
              b.writeln('    .addFormDataPart(${q(name)}, ${q(value)})');
            case MultipartFilePart(
              :final name,
              :final path,
              :final contentType,
            ):
              final type = contentType.isEmpty
                  ? 'application/octet-stream'
                  : contentType;
              b.writeln(
                '    .addFormDataPart(${q(name)}, ${q(_fileName(path))},\n'
                '        RequestBody.create(new File(${q(path)}), MediaType.parse(${q(type)})))',
              );
          }
        }
        b.writeln('    .build();');
        body = 'body';
      case FileBody(:final path):
        b.writeln(
          'RequestBody body = RequestBody.create(new File(${q(path)}), '
          'MediaType.parse(${q(contentType ?? 'application/octet-stream')}));',
        );
        body = 'body';
    }
    b.writeln('Request request = new Request.Builder()');
    b.writeln('    .url(${q(r.url)})');
    b.writeln('    .method(${q(r.method.value)}, $body)');
    for (final h in _headers(r)) {
      b.writeln('    .addHeader(${q(h.key)}, ${q(h.value)})');
    }
    b.writeln('    .build();');
    b.writeln('try (Response response = client.newCall(request).execute()) {');
    b.writeln('    System.out.println(response.body().string());');
    b.write('}');
    return b.toString();
  }

  // --------------------------------------------------------- C# HttpClient

  static const _contentHeaders = {
    'content-type',
    'content-length',
    'content-encoding',
    'content-language',
    'content-disposition',
  };

  String _csharp(PreparedRequest r) {
    const q = _cQuoted;
    final b = StringBuffer();
    if (r.body is TextBody || r.body is FileBody) {
      b.writeln('using System.Net.Http.Headers;\n');
    }
    if (r.followRedirects) {
      b.writeln('using var client = new HttpClient();');
    } else {
      b.writeln(
        'using var client = new HttpClient(new HttpClientHandler { AllowAutoRedirect = false });',
      );
    }
    b.writeln(
      'var request = new HttpRequestMessage(new HttpMethod(${q(r.method.value)}), ${q(r.url)});',
    );
    final headers = _headers(r);
    for (final h in headers) {
      if (_contentHeaders.contains(h.key.toLowerCase())) continue;
      b.writeln(
        'request.Headers.TryAddWithoutValidation(${q(h.key)}, ${q(h.value)});',
      );
    }
    final contentType = _contentType(r);
    switch (r.body) {
      case NoBody():
        break;
      case TextBody(:final text):
        b.writeln('request.Content = new StringContent(${q(text)});');
      case final UrlEncodedBody form:
        b.writeln('request.Content = new FormUrlEncodedContent(new[]');
        b.writeln('{');
        for (final (k, v) in form.fields) {
          b.writeln('    new KeyValuePair<string, string>(${q(k)}, ${q(v)}),');
        }
        b.writeln('});');
      case MultipartBody(:final parts):
        b.writeln('var content = new MultipartFormDataContent();');
        for (final p in parts) {
          switch (p) {
            case MultipartTextPart(:final name, :final value):
              b.writeln(
                'content.Add(new StringContent(${q(value)}), ${q(name)});',
              );
            case MultipartFilePart(:final name, :final path):
              b.writeln(
                'content.Add(new StreamContent(File.OpenRead(${q(path)})), ${q(name)}, ${q(_fileName(path))});',
              );
          }
        }
        b.writeln('request.Content = content;');
      case FileBody(:final path):
        b.writeln(
          'request.Content = new ByteArrayContent(File.ReadAllBytes(${q(path)}));',
        );
    }
    if (contentType != null && (r.body is TextBody || r.body is FileBody)) {
      b.writeln(
        'request.Content.Headers.ContentType = MediaTypeHeaderValue.Parse(${q(contentType)});',
      );
    }
    for (final h in headers) {
      final name = h.key.toLowerCase();
      if (name == 'content-type' || !_contentHeaders.contains(name)) continue;
      if (r.body is NoBody) continue;
      b.writeln(
        'request.Content.Headers.TryAddWithoutValidation(${q(h.key)}, ${q(h.value)});',
      );
    }
    b.writeln();
    b.writeln('var response = await client.SendAsync(request);');
    b.writeln('Console.WriteLine((int)response.StatusCode);');
    b.write('Console.WriteLine(await response.Content.ReadAsStringAsync());');
    return b.toString();
  }

  // ------------------------------------------------------------ PowerShell

  String _powershell(PreparedRequest r) {
    final b = StringBuffer();
    final headers = [
      for (final h in _headers(r))
        if (h.key.toLowerCase() != 'content-type') h,
    ];
    final args = <String>[
      '-Uri ${_ps(r.url)}',
      '-Method ${_ps(r.method.value)}',
    ];
    if (headers.isNotEmpty) {
      b.writeln('\$headers = @{');
      for (final h in headers) {
        b.writeln('    ${_ps(h.key)} = ${_ps(h.value)}');
      }
      b.writeln('}');
      args.add('-Headers \$headers');
    }
    final contentType = _contentType(r);
    if (contentType != null && r.body is! MultipartBody) {
      args.add('-ContentType ${_ps(contentType)}');
    }
    final text = _textPayload(r.body);
    switch (r.body) {
      case MultipartBody(:final parts):
        b.writeln('\$form = @{');
        for (final p in parts) {
          switch (p) {
            case MultipartTextPart(:final name, :final value):
              b.writeln('    ${_ps(name)} = ${_ps(value)}');
            case MultipartFilePart(:final name, :final path):
              b.writeln('    ${_ps(name)} = Get-Item -Path ${_ps(path)}');
          }
        }
        b.writeln('}');
        args.add('-Form \$form');
      case FileBody(:final path):
        args.add('-InFile ${_ps(path)}');
      default:
        if (text != null) {
          b.writeln('\$body = ${_ps(text)}');
          args.add('-Body \$body');
        }
    }
    if (!r.followRedirects) args.add('-MaximumRedirection 0');
    if (b.isNotEmpty) b.writeln();
    b.writeln('\$response = Invoke-WebRequest ${args.join(' `\n    ')}');
    b.write('\$response.Content');
    return b.toString();
  }
}
