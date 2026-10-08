import 'dart:convert';
import 'dart:math';

import 'package:crypto/crypto.dart';

/// RFC 7636 Proof Key for Code Exchange.
class Pkce {
  Pkce._(this.verifier, this.challenge);

  factory Pkce.generate([Random? random]) {
    final rnd = random ?? Random.secure();
    final bytes = List<int>.generate(48, (_) => rnd.nextInt(256));
    final verifier = base64UrlEncode(bytes).replaceAll('=', '');
    return Pkce._(verifier, challengeFor(verifier));
  }

  final String verifier;
  final String challenge;
  String get method => 'S256';

  static String challengeFor(String verifier) => base64UrlEncode(
    sha256.convert(ascii.encode(verifier)).bytes,
  ).replaceAll('=', '');
}

String randomState([Random? random]) {
  final rnd = random ?? Random.secure();
  return base64UrlEncode(
    List<int>.generate(24, (_) => rnd.nextInt(256)),
  ).replaceAll('=', '');
}
