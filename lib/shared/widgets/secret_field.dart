import 'package:flutter/material.dart';

import 'variable_field.dart';

/// A [VariableField] that masks its value until the user reveals it.
class SecretField extends StatefulWidget {
  const SecretField({
    super.key,
    required this.value,
    required this.onChanged,
    this.hint,
    this.monospace = true,
  });

  final String value;
  final ValueChanged<String> onChanged;
  final String? hint;
  final bool monospace;

  @override
  State<SecretField> createState() => _SecretFieldState();
}

class _SecretFieldState extends State<SecretField> {
  bool _revealed = false;

  @override
  Widget build(BuildContext context) => Row(
    children: [
      Expanded(
        child: VariableField(
          value: widget.value,
          onChanged: widget.onChanged,
          hint: widget.hint,
          monospace: widget.monospace,
          // Values that are only {{variable}} references are not secret.
          obscure: !_revealed && !widget.value.trim().startsWith('{{'),
        ),
      ),
      const SizedBox(width: 4),
      IconButton(
        tooltip: _revealed ? 'Hide value' : 'Reveal value',
        onPressed: () => setState(() => _revealed = !_revealed),
        icon: Icon(
          _revealed ? Icons.visibility_off_outlined : Icons.visibility_outlined,
        ),
      ),
    ],
  );
}
