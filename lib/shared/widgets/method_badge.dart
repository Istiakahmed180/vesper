import 'package:flutter/material.dart';

import '../../core/theme/app_colors.dart';
import '../../features/api_client/domain/models/http_method.dart';

extension MethodColor on HttpMethod {
  Color color(VesperColors c) => switch (this) {
    HttpMethod.get => c.methodGet,
    HttpMethod.post => c.methodPost,
    HttpMethod.put => c.methodPut,
    HttpMethod.patch => c.methodPatch,
    HttpMethod.delete => c.methodDelete,
    HttpMethod.head => c.methodHead,
    HttpMethod.options => c.methodOptions,
  };

  String get short => switch (this) {
    HttpMethod.delete => 'DEL',
    HttpMethod.options => 'OPT',
    HttpMethod.patch => 'PATCH',
    _ => value,
  };
}

class MethodBadge extends StatelessWidget {
  const MethodBadge(
    this.method, {
    super.key,
    this.width = 40,
    this.fontSize = 10.5,
  });

  final HttpMethod method;
  final double width;
  final double fontSize;

  @override
  Widget build(BuildContext context) => SizedBox(
    width: width,
    child: Text(
      method.short,
      maxLines: 1,
      overflow: TextOverflow.clip,
      style: TextStyle(
        color: method.color(context.colors),
        fontSize: fontSize,
        fontWeight: FontWeight.w700,
        letterSpacing: 0.3,
      ),
    ),
  );
}
