import 'package:flutter_test/flutter_test.dart';
import 'package:vesper/shared/widgets/code/code_editor.dart';

void main() {
  test('beautify keeps quoted and unquoted variables', () {
    final out = JsonTools.beautify(
      '{"id":{{id}},"name":"{{name}}","tag":"pre-{{t}}"}',
    );
    expect(
      out,
      '{\n  "id": {{id}},\n  "name": "{{name}}",\n  "tag": "pre-{{t}}"\n}',
    );
  });

  test('validate reports line numbers', () {
    expect(JsonTools.validate('{"a": 1}'), isNull);
    expect(JsonTools.validate('{"a": {{x}}}'), isNull);
    expect(JsonTools.validate('{\n"a": 1,\n}'), contains('line'));
  });
}
