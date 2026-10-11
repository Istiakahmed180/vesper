import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart' show ThemeMode;

import '../../../core/constants/app_constants.dart';
import '../../../core/utils/json_read.dart';

enum StartupBehavior { restoreTabs, blankTab }

@immutable
class ProxySettings {
  const ProxySettings({
    this.enabled = false,
    this.host = '',
    this.port = 8080,
    this.bypass = 'localhost,127.0.0.1',
  });

  final bool enabled;
  final String host;
  final int port;

  /// Comma separated hosts that skip the proxy.
  final String bypass;

  bool get isUsable => enabled && host.trim().isNotEmpty && port > 0;

  List<String> get bypassHosts => bypass
      .split(',')
      .map((e) => e.trim().toLowerCase())
      .where((e) => e.isNotEmpty)
      .toList();

  ProxySettings copyWith({
    bool? enabled,
    String? host,
    int? port,
    String? bypass,
  }) => ProxySettings(
    enabled: enabled ?? this.enabled,
    host: host ?? this.host,
    port: port ?? this.port,
    bypass: bypass ?? this.bypass,
  );

  JsonMap toJson() => {
    'enabled': enabled,
    'host': host,
    'port': port,
    'bypass': bypass,
  };

  factory ProxySettings.fromJson(JsonMap json) => ProxySettings(
    enabled: json.boolean('enabled'),
    host: json.str('host'),
    port: json.integer('port', 8080),
    bypass: json.str('bypass', 'localhost,127.0.0.1'),
  );

  @override
  bool operator ==(Object other) =>
      other is ProxySettings &&
      other.enabled == enabled &&
      other.host == host &&
      other.port == port &&
      other.bypass == bypass;

  @override
  int get hashCode => Object.hash(enabled, host, port, bypass);
}

/// Network behaviour shared by every request.
@immutable
class NetworkSettings {
  const NetworkSettings({
    this.timeoutMs = AppConstants.defaultTimeoutMs,
    this.followRedirects = true,
    this.maxRedirects = AppConstants.defaultMaxRedirects,
    this.verifySsl = true,
    this.sendCookies = true,
    this.proxy = const ProxySettings(),
  });

  final int timeoutMs;
  final bool followRedirects;
  final int maxRedirects;
  final bool verifySsl;

  /// Automatically store response cookies and send them on later requests.
  final bool sendCookies;
  final ProxySettings proxy;

  NetworkSettings copyWith({
    int? timeoutMs,
    bool? followRedirects,
    int? maxRedirects,
    bool? verifySsl,
    bool? sendCookies,
    ProxySettings? proxy,
  }) => NetworkSettings(
    timeoutMs: timeoutMs ?? this.timeoutMs,
    followRedirects: followRedirects ?? this.followRedirects,
    maxRedirects: maxRedirects ?? this.maxRedirects,
    verifySsl: verifySsl ?? this.verifySsl,
    sendCookies: sendCookies ?? this.sendCookies,
    proxy: proxy ?? this.proxy,
  );

  JsonMap toJson() => {
    'timeoutMs': timeoutMs,
    'followRedirects': followRedirects,
    'maxRedirects': maxRedirects,
    'verifySsl': verifySsl,
    'sendCookies': sendCookies,
    'proxy': proxy.toJson(),
  };

  factory NetworkSettings.fromJson(JsonMap json) => NetworkSettings(
    timeoutMs: json
        .integer('timeoutMs', AppConstants.defaultTimeoutMs)
        .clamp(1000, 600000),
    followRedirects: json.boolean('followRedirects', true),
    maxRedirects: json
        .integer('maxRedirects', AppConstants.defaultMaxRedirects)
        .clamp(0, 50),
    verifySsl: json.boolean('verifySsl', true),
    sendCookies: json.boolean('sendCookies', true),
    proxy: ProxySettings.fromJson(json.obj('proxy')),
  );

  @override
  bool operator ==(Object other) =>
      other is NetworkSettings &&
      other.timeoutMs == timeoutMs &&
      other.followRedirects == followRedirects &&
      other.maxRedirects == maxRedirects &&
      other.verifySsl == verifySsl &&
      other.sendCookies == sendCookies &&
      other.proxy == proxy;

  @override
  int get hashCode => Object.hash(
    timeoutMs,
    followRedirects,
    maxRedirects,
    verifySsl,
    sendCookies,
    proxy,
  );
}

@immutable
class AppSettings {
  const AppSettings({
    this.themeMode = ThemeMode.dark,
    this.startupBehavior = StartupBehavior.restoreTabs,
    this.network = const NetworkSettings(),
    this.historyEnabled = true,
    this.historyRetentionDays = AppConstants.defaultHistoryRetentionDays,
    this.historyMaxEntries = AppConstants.defaultHistoryMaxEntries,
  });

  final ThemeMode themeMode;
  final StartupBehavior startupBehavior;
  final NetworkSettings network;
  final bool historyEnabled;

  /// 0 = keep forever.
  final int historyRetentionDays;
  final int historyMaxEntries;

  AppSettings copyWith({
    ThemeMode? themeMode,
    StartupBehavior? startupBehavior,
    NetworkSettings? network,
    bool? historyEnabled,
    int? historyRetentionDays,
    int? historyMaxEntries,
  }) => AppSettings(
    themeMode: themeMode ?? this.themeMode,
    startupBehavior: startupBehavior ?? this.startupBehavior,
    network: network ?? this.network,
    historyEnabled: historyEnabled ?? this.historyEnabled,
    historyRetentionDays: historyRetentionDays ?? this.historyRetentionDays,
    historyMaxEntries: historyMaxEntries ?? this.historyMaxEntries,
  );

  static const schemaVersion = 1;

  JsonMap toJson() => {
    'version': schemaVersion,
    'themeMode': themeMode.name,
    'startupBehavior': startupBehavior.name,
    'network': network.toJson(),
    'historyEnabled': historyEnabled,
    'historyRetentionDays': historyRetentionDays,
    'historyMaxEntries': historyMaxEntries,
  };

  factory AppSettings.fromJson(JsonMap json) => AppSettings(
    themeMode: ThemeMode.values.firstWhere(
      (m) => m.name == json.str('themeMode'),
      orElse: () => ThemeMode.dark,
    ),
    startupBehavior: json.str('startupBehavior') == 'blankTab'
        ? StartupBehavior.blankTab
        : StartupBehavior.restoreTabs,
    network: NetworkSettings.fromJson(json.obj('network')),
    historyEnabled: json.boolean('historyEnabled', true),
    historyRetentionDays: json
        .integer(
          'historyRetentionDays',
          AppConstants.defaultHistoryRetentionDays,
        )
        .clamp(0, 3650),
    historyMaxEntries: json
        .integer('historyMaxEntries', AppConstants.defaultHistoryMaxEntries)
        .clamp(10, 100000),
  );
}
