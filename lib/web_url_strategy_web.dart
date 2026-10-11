import 'package:flutter_web_plugins/flutter_web_plugins.dart';

/// Uses browser paths such as /aktivitaeten instead of hash-only URLs.
void configureWebUrlStrategy() => usePathUrlStrategy();
