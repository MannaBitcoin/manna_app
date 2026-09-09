import 'dart:async';

import 'package:app_links/app_links.dart';
import 'package:manna/config.dart';
import 'package:manna/router.dart';
import 'package:manna/screens/send_screen.dart';
import 'package:manna/services/lnurl_service.dart';

import 'db.dart';

class DeepLinkService {
  static final appLinks = AppLinks();
  static StreamSubscription? sub;

  static Future<void> startListening() async {
    String? initialLink = DB.getInitialDeepLinkURI();
    await sub?.cancel();
    sub = appLinks.uriLinkStream.listen((uri) {
      // This is workaround, as sometime the stream pushes link that opened app, which we handle externally already.
      if (initialLink != uri.toString()) {
        processUri(uri);
      } else {
        initialLink = null;
      }
    });
  }

  /// returns true if URI is processed
  static Future<bool> processUri(Uri uri) async {
    if ({'lightning', 'lnurlw', 'lnurlp', 'keyauth'}.contains(uri.scheme)) {
      try {
        await handleLNURL(rawAddress: uri.toString(), network: Config.network);
        return true;
      } catch (_) {}
    }
    if ({'bitcoin', 'lightning', 'liquidnetwork'}.contains(uri.scheme)) {
      Future.delayed(
        const Duration(milliseconds: 200),
        () => AppRouter.replaceIfExists(SendScreen(address: uri.toString())),
      );
      return true;
    }
    return false;
  }

  static Future<void> storeInitialData() async {
    final initialData = await appLinks.getInitialLink();
    if (initialData != null) {
      await DB.setInitialDeepLinkURI(initialData.toString());
    }
  }

  static void handleInitialData() async {
    final initialURI = DB.getInitialDeepLinkURI();
    if (initialURI != null) {
      if (await processUri(Uri.parse(initialURI))) {
        await DB.setInitialDeepLinkURI(null);
      }
    }
  }
}
