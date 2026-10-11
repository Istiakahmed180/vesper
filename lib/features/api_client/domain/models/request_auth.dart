import 'package:flutter/foundation.dart';

import '../../../../core/utils/json_read.dart';

enum AuthType {
  inherit('Inherit auth from parent'),
  none('No Auth'),
  bearer('Bearer Token'),
  basic('Basic Auth'),
  apiKey('API Key'),
  oauth2('OAuth 2.0');

  const AuthType(this.label);
  final String label;
}

enum ApiKeyLocation { header, query }

enum OAuth2GrantType {
  authorizationCode('Authorization Code (PKCE)'),
  clientCredentials('Client Credentials');

  const OAuth2GrantType(this.label);
  final String label;
}

/// Request authorization. Secret fields are split out via [secrets] /
/// [withSecrets] so repositories can store them in the OS vault while the
/// rest of the configuration lives in SQLite.
@immutable
sealed class RequestAuth {
  const RequestAuth();

  AuthType get type;

  /// Field name → secret value.
  Map<String, String> get secrets;

  RequestAuth withSecrets(Map<String, String> secrets);

  RequestAuth get withoutSecrets => withSecrets(const {});

  JsonMap toJson({bool includeSecrets = false});

  static RequestAuth fromJson(JsonMap json) {
    switch (json.str('type')) {
      case 'inherit':
        return const InheritAuth();
      case 'bearer':
        return BearerAuth(token: json.str('token'));
      case 'basic':
        return BasicAuth(
          username: json.str('username'),
          password: json.str('password'),
        );
      case 'apiKey':
        return ApiKeyAuth(
          key: json.str('key'),
          value: json.str('value'),
          location: json.str('location') == 'query'
              ? ApiKeyLocation.query
              : ApiKeyLocation.header,
        );
      case 'oauth2':
        return OAuth2Auth(
          grantType: json.str('grantType') == 'clientCredentials'
              ? OAuth2GrantType.clientCredentials
              : OAuth2GrantType.authorizationCode,
          authUrl: json.str('authUrl'),
          tokenUrl: json.str('tokenUrl'),
          clientId: json.str('clientId'),
          clientSecret: json.str('clientSecret'),
          scope: json.str('scope'),
          headerPrefix: json.str('headerPrefix', 'Bearer'),
          accessToken: json.str('accessToken'),
          refreshToken: json.str('refreshToken'),
          expiresAt: DateTime.tryParse(json.str('expiresAt')),
        );
      default:
        return const NoAuth();
    }
  }

  static RequestAuth empty(AuthType type) => switch (type) {
    AuthType.inherit => const InheritAuth(),
    AuthType.none => const NoAuth(),
    AuthType.bearer => const BearerAuth(),
    AuthType.basic => const BasicAuth(),
    AuthType.apiKey => const ApiKeyAuth(),
    AuthType.oauth2 => const OAuth2Auth(),
  };
}

/// Uses the authorization of the request's collection when it is sent.
class InheritAuth extends RequestAuth {
  const InheritAuth();

  @override
  AuthType get type => AuthType.inherit;

  @override
  Map<String, String> get secrets => const {};

  @override
  RequestAuth withSecrets(Map<String, String> secrets) => this;

  @override
  JsonMap toJson({bool includeSecrets = false}) => {'type': 'inherit'};

  /// The authorization actually sent: [inherited] for [InheritAuth].
  static RequestAuth effective(RequestAuth auth, RequestAuth? inherited) =>
      auth is InheritAuth ? (inherited ?? const NoAuth()) : auth;

  @override
  bool operator ==(Object other) => other is InheritAuth;

  @override
  int get hashCode => 1;
}

class NoAuth extends RequestAuth {
  const NoAuth();

  @override
  AuthType get type => AuthType.none;

  @override
  Map<String, String> get secrets => const {};

  @override
  RequestAuth withSecrets(Map<String, String> secrets) => this;

  @override
  JsonMap toJson({bool includeSecrets = false}) => {'type': 'none'};

  @override
  bool operator ==(Object other) => other is NoAuth;

  @override
  int get hashCode => 0;
}

class BearerAuth extends RequestAuth {
  const BearerAuth({this.token = ''});

  final String token;

  @override
  AuthType get type => AuthType.bearer;

  @override
  Map<String, String> get secrets => {if (token.isNotEmpty) 'token': token};

  @override
  BearerAuth withSecrets(Map<String, String> secrets) =>
      BearerAuth(token: secrets['token'] ?? '');

  @override
  JsonMap toJson({bool includeSecrets = false}) => {
    'type': 'bearer',
    if (includeSecrets) 'token': token,
  };

  @override
  bool operator ==(Object other) => other is BearerAuth && other.token == token;

  @override
  int get hashCode => token.hashCode;
}

class BasicAuth extends RequestAuth {
  const BasicAuth({this.username = '', this.password = ''});

  final String username;
  final String password;

  @override
  AuthType get type => AuthType.basic;

  @override
  Map<String, String> get secrets => {
    if (password.isNotEmpty) 'password': password,
  };

  @override
  BasicAuth withSecrets(Map<String, String> secrets) =>
      BasicAuth(username: username, password: secrets['password'] ?? '');

  BasicAuth copyWith({String? username, String? password}) => BasicAuth(
    username: username ?? this.username,
    password: password ?? this.password,
  );

  @override
  JsonMap toJson({bool includeSecrets = false}) => {
    'type': 'basic',
    'username': username,
    if (includeSecrets) 'password': password,
  };

  @override
  bool operator ==(Object other) =>
      other is BasicAuth &&
      other.username == username &&
      other.password == password;

  @override
  int get hashCode => Object.hash(username, password);
}

class ApiKeyAuth extends RequestAuth {
  const ApiKeyAuth({
    this.key = '',
    this.value = '',
    this.location = ApiKeyLocation.header,
  });

  final String key;
  final String value;
  final ApiKeyLocation location;

  @override
  AuthType get type => AuthType.apiKey;

  @override
  Map<String, String> get secrets => {if (value.isNotEmpty) 'value': value};

  @override
  ApiKeyAuth withSecrets(Map<String, String> secrets) =>
      ApiKeyAuth(key: key, value: secrets['value'] ?? '', location: location);

  ApiKeyAuth copyWith({String? key, String? value, ApiKeyLocation? location}) =>
      ApiKeyAuth(
        key: key ?? this.key,
        value: value ?? this.value,
        location: location ?? this.location,
      );

  @override
  JsonMap toJson({bool includeSecrets = false}) => {
    'type': 'apiKey',
    'key': key,
    'location': location.name,
    if (includeSecrets) 'value': value,
  };

  @override
  bool operator ==(Object other) =>
      other is ApiKeyAuth &&
      other.key == key &&
      other.value == value &&
      other.location == location;

  @override
  int get hashCode => Object.hash(key, value, location);
}

class OAuth2Auth extends RequestAuth {
  const OAuth2Auth({
    this.grantType = OAuth2GrantType.authorizationCode,
    this.authUrl = '',
    this.tokenUrl = '',
    this.clientId = '',
    this.clientSecret = '',
    this.scope = '',
    this.headerPrefix = 'Bearer',
    this.accessToken = '',
    this.refreshToken = '',
    this.expiresAt,
  });

  final OAuth2GrantType grantType;
  final String authUrl;
  final String tokenUrl;
  final String clientId;
  final String clientSecret;
  final String scope;
  final String headerPrefix;
  final String accessToken;
  final String refreshToken;
  final DateTime? expiresAt;

  bool get isExpired => expiresAt != null && DateTime.now().isAfter(expiresAt!);

  @override
  AuthType get type => AuthType.oauth2;

  @override
  Map<String, String> get secrets => {
    if (clientSecret.isNotEmpty) 'clientSecret': clientSecret,
    if (accessToken.isNotEmpty) 'accessToken': accessToken,
    if (refreshToken.isNotEmpty) 'refreshToken': refreshToken,
  };

  @override
  OAuth2Auth withSecrets(Map<String, String> secrets) => copyWith(
    clientSecret: secrets['clientSecret'] ?? '',
    accessToken: secrets['accessToken'] ?? '',
    refreshToken: secrets['refreshToken'] ?? '',
  );

  OAuth2Auth copyWith({
    OAuth2GrantType? grantType,
    String? authUrl,
    String? tokenUrl,
    String? clientId,
    String? clientSecret,
    String? scope,
    String? headerPrefix,
    String? accessToken,
    String? refreshToken,
    DateTime? Function()? expiresAt,
  }) => OAuth2Auth(
    grantType: grantType ?? this.grantType,
    authUrl: authUrl ?? this.authUrl,
    tokenUrl: tokenUrl ?? this.tokenUrl,
    clientId: clientId ?? this.clientId,
    clientSecret: clientSecret ?? this.clientSecret,
    scope: scope ?? this.scope,
    headerPrefix: headerPrefix ?? this.headerPrefix,
    accessToken: accessToken ?? this.accessToken,
    refreshToken: refreshToken ?? this.refreshToken,
    expiresAt: expiresAt != null ? expiresAt() : this.expiresAt,
  );

  @override
  JsonMap toJson({bool includeSecrets = false}) => {
    'type': 'oauth2',
    'grantType': grantType.name,
    'authUrl': authUrl,
    'tokenUrl': tokenUrl,
    'clientId': clientId,
    'scope': scope,
    'headerPrefix': headerPrefix,
    if (expiresAt != null) 'expiresAt': expiresAt!.toIso8601String(),
    if (includeSecrets) ...{
      'clientSecret': clientSecret,
      'accessToken': accessToken,
      'refreshToken': refreshToken,
    },
  };

  @override
  bool operator ==(Object other) =>
      other is OAuth2Auth &&
      other.grantType == grantType &&
      other.authUrl == authUrl &&
      other.tokenUrl == tokenUrl &&
      other.clientId == clientId &&
      other.clientSecret == clientSecret &&
      other.scope == scope &&
      other.headerPrefix == headerPrefix &&
      other.accessToken == accessToken &&
      other.refreshToken == refreshToken &&
      other.expiresAt == expiresAt;

  @override
  int get hashCode => Object.hash(
    grantType,
    authUrl,
    tokenUrl,
    clientId,
    clientSecret,
    scope,
    headerPrefix,
    accessToken,
    refreshToken,
    expiresAt,
  );
}
