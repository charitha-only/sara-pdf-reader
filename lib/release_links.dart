import 'package:flutter/services.dart';

const saraVersion = 'v1.14';
const latestReleaseUrl =
    'https://github.com/charitha-only/sara-pdf-reader/releases/latest';
const allReleasesUrl =
    'https://github.com/charitha-only/sara-pdf-reader/releases';
const incomingChannel = MethodChannel('pageflow_reader/incoming');

Future<void> openReleaseLink(String url) async {
  if (url != latestReleaseUrl && url != allReleasesUrl) {
    throw ArgumentError('Unsupported release link');
  }
  await incomingChannel.invokeMethod<void>('openReleaseLink', {'url': url});
}
