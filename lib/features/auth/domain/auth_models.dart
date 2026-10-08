import 'package:flutter/foundation.dart';

import '../../../core/oauth/oauth2_client.dart';
import '../../../core/utils/json_read.dart';

@immutable
class UserAccount {
  const UserAccount({
    required this.id,
    required this.email,
    required this.name,
    this.pictureUrl,
    required this.provider,
  });

  final String id;
  final String email;
  final String name;
  final String? pictureUrl;

  /// e.g. "google".
  final String provider;

  String get initials {
    final parts = (name.isEmpty ? email : name).trim().split(RegExp(r'\s+'));
    return parts.take(2).map((p) => p.isEmpty ? '' : p[0].toUpperCase()).join();
  }

  JsonMap toJson() => {
    'id': id,
    'email': email,
    'name': name,
    if (pictureUrl != null) 'picture': pictureUrl,
    'provider': provider,
  };

  factory UserAccount.fromJson(JsonMap json) => UserAccount(
    id: json.str('id'),
    email: json.str('email'),
    name: json.str('name'),
    pictureUrl: json.strOrNull('picture'),
    provider: json.str('provider', 'google'),
  );
}

@immutable
class AuthSession {
  const AuthSession({
    required this.account,
    required this.token,
    this.offline = false,
  });

  final UserAccount account;
  final OAuth2Token token;

  /// True when the session was restored without reaching the provider.
  final bool offline;

  JsonMap toJson() => {'account': account.toJson(), 'token': token.toJson()};

  factory AuthSession.fromJson(JsonMap json) => AuthSession(
    account: UserAccount.fromJson(json.obj('account')),
    token: OAuth2Token.fromStored(json.obj('token')),
  );
}
