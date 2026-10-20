import 'dart:convert';
import 'dart:io' show Platform;
import 'dart:typed_data';

import 'package:flutter_inappwebview/flutter_inappwebview.dart';

import '../workspace/workspace.dart';

/// Loads a workspace into the WebView.
///
/// The two platforms deliberately diverge:
///
/// - **Android** — `WebViewAssetLoader` with an `InternalStoragePathHandler`,
///   served from the virtual `https://appassets.androidplatform.net/` origin.
///   This is Google's own recommendation: a real origin keeps the same-origin
///   policy working and avoids loosening any `file://` security flags.
/// - **iOS** — `loadUrl(..., allowingReadAccessTo:)`, which maps to
///   `WKWebView.loadFileURL`. A custom scheme handler is **not** used: on
///   iOS 26 WebKit terminates pages that are loaded through a custom scheme
///   and contain scripts.
abstract final class ViewerBridge {
  /// Virtual path the workspace is served from on Android.
  static const String _androidVirtualPath = '/ws/';
  static const String _androidDomain = 'appassets.androidplatform.net';

  /// Channel name; `bridge.js` uses the same string.
  static const String channelName = 'evrak';

  /// Chunk size used when streaming document bytes over the bridge.
  ///
  /// One huge base64 string both slows `atob` down and doubles peak memory.
  /// 256 KB is the measured balance between transfer latency and memory.
  static const int _chunkBytes = 256 * 1024;

  /// WebView settings for this workspace.
  static InAppWebViewSettings settingsFor(Workspace workspace) {
    return InAppWebViewSettings(
      // The engines are JavaScript; disabling it would make rendering impossible.
      javaScriptEnabled: true,
      // Local assets are intercepted before network loads. Without this flag,
      // Android WebView attempts to enable networking and throws in the offline
      // release, which intentionally has no INTERNET permission.
      blockNetworkLoads: true,
      useShouldOverrideUrlLoading: true,

      // — hardening —
      javaScriptCanOpenWindowsAutomatically: false,
      supportMultipleWindows: false,
      allowFileAccessFromFileURLs: false,
      allowUniversalAccessFromFileURLs: false,
      mediaPlaybackRequiresUserGesture: true,
      // The document surface stays white in both themes; the host UI carries the theme.
      transparentBackground: false,

      // — reading experience —
      supportZoom: true,
      builtInZoomControls: true,
      displayZoomControls: false,
      // Text selection and screen readers are deliberately left enabled.
      disableContextMenu: false,
      useHybridComposition: true,

      // — Android: serve the workspace from the virtual https origin —
      webViewAssetLoader: Platform.isAndroid
          ? WebViewAssetLoader(
              domain: _androidDomain,
              pathHandlers: <PathHandler>[
                InternalStoragePathHandler(
                  directory: workspace.root.path,
                  path: _androidVirtualPath,
                ),
              ],
            )
          : null,
    );
  }

  /// Loads the shell.
  static Future<void> load(
    InAppWebViewController controller,
    Workspace workspace,
  ) async {
    if (Platform.isAndroid) {
      await controller.loadUrl(
        urlRequest: URLRequest(
          url: WebUri(
            'https://$_androidDomain${_androidVirtualPath}viewer.html',
          ),
        ),
      );
      return;
    }

    // iOS/macOS: a file URL plus the root we grant read access to.
    final String root = workspace.root.path;
    await controller.loadUrl(
      urlRequest: URLRequest(url: WebUri('file://$root/viewer.html')),
      allowingReadAccessTo: WebUri('file://$root/'),
    );
  }

  /// Sends a message to the shell.
  static Future<void> send(
    InAppWebViewController controller,
    BridgeMessage message,
  ) async {
    final String payload = jsonEncode(message.encode());
    await controller.evaluateJavascript(
      source: 'window.__evrakReceive($payload);',
    );
  }

  /// Streams the document bytes to the shell in chunks.
  ///
  /// On iOS, `fetch` from a `file://` origin is blocked by CORS. Rather than
  /// enabling `allowFileAccessFromFileURLs`, the bytes travel over this
  /// channel: the security posture stays intact and the result is the same.
  static Future<void> pushBytes(
    InAppWebViewController controller,
    Uint8List bytes,
  ) async {
    await send(
      controller,
      BridgeMessage('bytesBegin', <String, Object?>{'total': bytes.length}),
    );

    for (int offset = 0; offset < bytes.length; offset += _chunkBytes) {
      final int end = (offset + _chunkBytes < bytes.length)
          ? offset + _chunkBytes
          : bytes.length;
      await send(
        controller,
        BridgeMessage('bytesChunk', <String, Object?>{
          'data': base64Encode(Uint8List.sublistView(bytes, offset, end)),
        }),
      );
    }

    await send(controller, const BridgeMessage('bytesEnd'));
  }

  /// Rejects every request that leaves the workspace root.
  ///
  /// Remote references embedded in a document are already blocked by the CSP;
  /// this is the second layer, and a measurable one — anything trying to leave
  /// shows up here.
  static NavigationActionPolicy decidePolicy(WebUri? url) {
    if (url == null) {
      return NavigationActionPolicy.CANCEL;
    }
    final bool allowed = Platform.isAndroid
        ? url.host == _androidDomain
        : url.scheme == 'file';
    return allowed ? NavigationActionPolicy.ALLOW : NavigationActionPolicy.CANCEL;
  }
}
