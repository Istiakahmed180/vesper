import 'package:flutter/foundation.dart';

import '../../../core/utils/json_read.dart';

@immutable
class GitHubAccount {
  const GitHubAccount({
    required this.login,
    required this.name,
    required this.avatarUrl,
    required this.htmlUrl,
  });

  final String login;
  final String name;
  final String avatarUrl;
  final String htmlUrl;

  factory GitHubAccount.fromJson(JsonMap json) => GitHubAccount(
    login: json.str('login'),
    name: json.str('name'),
    avatarUrl: json.str('avatar_url'),
    htmlUrl: json.str('html_url'),
  );

  JsonMap toJson() => {
    'login': login,
    'name': name,
    'avatar_url': avatarUrl,
    'html_url': htmlUrl,
  };
}

@immutable
class GitHubRepo {
  const GitHubRepo({
    required this.fullName,
    required this.isPrivate,
    required this.defaultBranch,
    this.description = '',
    this.canPush = false,
    this.updatedAt,
    this.htmlUrl = '',
  });

  final String fullName;
  final bool isPrivate;
  final String defaultBranch;
  final String description;
  final bool canPush;
  final DateTime? updatedAt;
  final String htmlUrl;

  String get owner => fullName.split('/').first;
  String get name => fullName.split('/').last;

  factory GitHubRepo.fromJson(JsonMap json) => GitHubRepo(
    fullName: json.str('full_name'),
    isPrivate: json.boolean('private'),
    defaultBranch: json.str('default_branch', 'main'),
    description: json.str('description'),
    canPush: json.obj('permissions').boolean('push'),
    updatedAt: DateTime.tryParse(json.str('updated_at')),
    htmlUrl: json.str('html_url'),
  );
}

/// The token and metadata persisted in the OS vault.
@immutable
class GitHubSession {
  const GitHubSession({
    required this.accessToken,
    required this.account,
    this.scopes = '',
    this.refreshToken,
    this.expiresAt,
  });

  final String accessToken;
  final GitHubAccount account;
  final String scopes;
  final String? refreshToken;
  final DateTime? expiresAt;

  bool get isExpired => expiresAt != null && DateTime.now().isAfter(expiresAt!);

  JsonMap toJson() => {
    'access_token': accessToken,
    'account': account.toJson(),
    'scopes': scopes,
    if (refreshToken != null) 'refresh_token': refreshToken,
    if (expiresAt != null) 'expires_at': expiresAt!.toIso8601String(),
  };

  factory GitHubSession.fromJson(JsonMap json) => GitHubSession(
    accessToken: json.str('access_token'),
    account: GitHubAccount.fromJson(json.obj('account')),
    scopes: json.str('scopes'),
    refreshToken: json.strOrNull('refresh_token'),
    expiresAt: DateTime.tryParse(json.str('expires_at')),
  );
}

/// Code the user enters at github.com/login/device.
@immutable
class DeviceCode {
  const DeviceCode({
    required this.deviceCode,
    required this.userCode,
    required this.verificationUri,
    required this.expiresIn,
    required this.interval,
  });

  final String deviceCode;
  final String userCode;
  final String verificationUri;
  final Duration expiresIn;
  final Duration interval;
}

/// Repository selected as the sync target.
@immutable
class SyncTarget {
  const SyncTarget({
    required this.repo,
    required this.branch,
    this.basePath = 'api-client',
  });

  final String repo;
  final String branch;
  final String basePath;

  String get remoteKey => 'github:$repo@$branch';

  JsonMap toJson() => {'repo': repo, 'branch': branch, 'basePath': basePath};

  factory SyncTarget.fromJson(JsonMap json) => SyncTarget(
    repo: json.str('repo'),
    branch: json.str('branch', 'main'),
    basePath: json.str('basePath', 'api-client'),
  );
}
