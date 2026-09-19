import 'dart:async';

import 'package:app_links/app_links.dart';
import 'package:manna/router.dart';
import 'package:manna/screens/send_screen.dart';

import 'db.dart';

class DeepLinkService {
  // TODO test
  // bitcoin:bc1qwzrryqr3ja8w7hnja2spmkgfdcgvqwp5swz4af4ngsjecfz0w0pqud7k38?amount=0.000005&label=Luke-Jr
  // lightning:lnbc640u1p426pjjpp5yc84uzpsp9n7u46afr9ehns9t3smhkyvucm3a7ucyg4ng7lpknessp5m2lludrkzzjlqftmhhka58ph776yayjyztm99sv62wjs3c7wnu0qxq9z0rgqnp4qvyndeaqzman7h898jxm98dzkm0mlrsx36s93smrur7h0azyyuxc5rzjqwghf7zxvfkxq5a6sr65g0gdkv768p83mhsnt0msszapamzx2qvuxqqqqrt49lmtcqqqqqqqqqqq86qq9qcqzpudyuffskx6eq2d6xzcmtyppyy5fqyq5yvun9d9nksapqfphh2um9999xzcmtypfhgctr8gszgdfsyq59xetsyqcnstpqxgcryd3qxqen5vphypgy62fqvehhygrxw4h8svf6ys6nqzs2235hqgp6yqjrqt3s8q9q9qyyssql0mcuflk3095nsu7cp8um43v8czc8eqmzdhtkk3putdh94nkepx9gyjefsnd2vzlpvv3hp49uqtg8u9whqt9r3pa49c7kfuskvjtnegqn6e3yx
  // lightning:adam@mannabitcoin.com
  // lnurlp:adam@mannabitcoin.com
  // lnurlw:adam@mannabitcoin.com
  // lightning:LNURL1DP68GURN8GHJ7UM9WFMXJCM99E3K7MF0V9CXJ0M385EKVCENXC6R2C35XVUKXEFCV5MKVV34X5EKZD3EV56NYD3HXQURZEPEXEJXXEPNXSCRVWFNV9NXZCN9XQ6XYEFHVGCXXCMYXYMNSERXFQ5FNS

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
        // TODO implement
        // await handleLNURL(rawAddress: uri.toString(), network: Config.network);
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
