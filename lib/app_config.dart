import 'package:flutter/foundation.dart';

/// Web uses the same origin as the site; native builds can override API_URL.
abstract final class AppConfig {
  static const _override = String.fromEnvironment('API_URL');

  static String get apiBaseUrl {
    if (_override.isNotEmpty) return _override.replaceFirst(RegExp(r'/$'), '');
    return kIsWeb ? Uri.base.origin : 'http://94.228.173.229:8000';
  }
}
