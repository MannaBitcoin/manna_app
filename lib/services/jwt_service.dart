import 'dart:async';
import 'dart:convert';
import 'package:dart_jsonwebtoken/dart_jsonwebtoken.dart';
import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';
import 'package:manna/config.dart';
import 'package:manna/services/db.dart';
import 'package:manna/services/log_service.dart';
import 'package:manna/services/secure_storage.dart';
import 'package:manna/services/wallet_service.dart';
import 'package:manna/utils/de_bouncer.dart';
import 'package:manna/utils/extensions.dart';
import 'package:manna/utils/parser.dart';
import 'package:manna/utils/util.dart';
import 'package:manna_core/manna_core.dart';
import 'package:manna/models/wallet.dart' as w;

class JWTService {
  static const Duration tokenExpirySkew = Duration(seconds: 60);
  static final Dio dio = globalDio.clone(options: globalDio.options.copyWith(contentType: Headers.jsonContentType));
  static final _mainnetMutex = MutexRun<String?>();
  static final _regtestMutex = MutexRun<String?>();

  static String _kTokenKey(Network network) => 'supabase_jwt_${network.index}';

  static Future<String?> getToken({Network? network}) {
    final net = network ?? Config.network;
    if (net == Network.mainnet) {
      return _mainnetMutex.run(() => _getJWT(net));
    } else if (Config.isRegtestOn) {
      return _regtestMutex.run(() => _getJWT(net));
    }
    return Future.value();
  }

  static Future<String?> _getJWT(Network network) async {
    try {
      // 1. check cached token
      final cachedJWT = await SecureStorage.fetch(_kTokenKey(network));

      final walletMap = Map.fromEntries(
        DB.allWallets.where((w) => w.network == network).map((w) => MapEntry(w.accountId, w)),
      );
      final wallets = DB.activeAccounts.map((acc) => walletMap[acc.id]).nonNulls.toList();

      if (cachedJWT != null) {
        String? jwt;
        try {
          jwt = utf8.decode(cachedJWT);
        } catch (_) {}

        if (jwt != null && await _verifyJwt(jwt, wallets)) return jwt;
      }

      if (wallets.isEmpty) return null;

      logD('minting token $network');
      Future<String?> validateRes({required Map<String, dynamic> apiRes, bool? throwOnNoToken}) async {
        if (apiRes['token'] != null) {
          final token = parseString(apiRes['token']);
          // validate locally
          final valid = await _verifyJwt(token, wallets);
          if (!valid) throw Exception('Invalid jwt token!');
          await SecureStorage.store(_kTokenKey(network), utf8.encode(token));
          return token;
        } else if (throwOnNoToken == true) {
          throw Exception('mint after verify did not return token');
        }
        return null;
      }

      // 2. Request mint (may return token or challenges)
      final mintRes = await _requestJWT(network: network, wallets: wallets);

      final token = await validateRes(apiRes: mintRes);
      if (token != null) return token;

      // if 'challenges' returned => sign them then call mint again
      final challenges = mintRes['challenges'] as List<dynamic>?;
      if (challenges == null || challenges.isEmpty) {
        throw Exception('mint response had no token and no challenges');
      }

      // Build payload for verify endpoint
      final List<JWTRequest> solvedChallenges = [];

      for (final r in parseList(
        challenges,
        (e) => JWTRequest(
          xpub: parseString(e['xpub']),
          challenge: parseString(e['challenge']),
          timestampMs: 0,
          signature: '',
        ),
      )) {
        final wallet = wallets.where((e) => e.xpub == r.xpub && e.type == WalletType.full).firstOrNull;
        if (wallet == null) continue;

        final privKey = await getDerivationPrivKey(
          accountId: wallet.accountId,
          derivationPath: '${liquidDerivationPath(network: wallet.network)}/3/5',
        );
        if (privKey == null) continue;

        final req = r.copyWith(timestampMs: DateTime.now().millisecondsSinceEpoch);
        final signature = await Crypto.secp256K1Sign(
          privKey: privKey,
          message: utf8.encode(sortedJsonEncode(req.toMapForSignature())),
          returnDer: false,
          preHash: true,
        );

        solvedChallenges.add(req.copyWith(signature: signature.toHexString));
      }

      // send to verify endpoint
      final mintRes2 = await _requestJWT(network: network, wallets: wallets, reqList: solvedChallenges);
      return await validateRes(apiRes: mintRes2);
    } catch (e, s) {
      logE(e, stackTrace: s);
    }
    return null;
  }

  static Future<bool> _verifyJwt(String token, List<w.Wallet> wallets) async {
    final jwt = JWT.tryDecode(token);

    if (jwt == null) return false;
    if (jwt.audience?.firstOrNull != 'authenticated') return false;
    if (jwt.payload['exp'] == null) return false;

    final now = DateTime.timestamp().millisecondsSinceEpoch ~/ 1000;
    final exp = parseInt(jwt.payload['exp']);
    if (now >= exp || (exp - now) <= tokenExpirySkew.inSeconds) return false;

    final tokenUuids = jwt.payload['wallet_uuids'];
    final tokenWoUuids = jwt.payload['watch_only_wallet_uuids'];
    if (tokenUuids == null || tokenUuids is! List || tokenWoUuids == null || tokenWoUuids is! List) return false;

    final fullUUIDs = wallets.where((w) => w.type == WalletType.full).map((e) => e.uuid).toSet();
    final woUUIDs = wallets.where((w) => w.type == WalletType.watchOnly).map((e) => e.uuid).toSet();

    if (!setEquals(tokenUuids.map((e) => parseString(e)).toSet(), fullUUIDs)) {
      return false;
    }
    if (!setEquals(tokenWoUuids.map((e) => parseString(e)).toSet(), woUUIDs)) {
      return false;
    }
    return true;
  }

  static Future<Map<String, dynamic>> _requestJWT({
    required Network network,
    required List<w.Wallet> wallets,
    List<JWTRequest>? reqList,
  }) async {
    final payload = {
      if (wallets.isNotEmpty)
        'wallets': wallets
            .map((e) => {'xpub': e.xpub, 'type': e.type == WalletType.watchOnly ? 'wo' : 'full'})
            .toList(),
      'challenges': ?reqList?.map((e) => e.toMap()).toList(),
      'device_id': await getDeviceId(),
    };
    final res = await dio.post(Config.of(network).getServerApiEndpoint('mint-jwt'), data: jsonEncode(payload));
    if (res.isSuccess && res.data is Map) {
      return res.data as Map<String, dynamic>;
    } else {
      throw Exception(res.data);
    }
  }

  static Future<void> deleteToken(Network network) => SecureStorage.delete(_kTokenKey(network));
}

class JWTRequest {
  JWTRequest({required this.xpub, required this.challenge, required this.timestampMs, required this.signature});

  final String xpub;
  final String challenge;
  final int timestampMs;
  final String signature;

  JWTRequest copyWith({String? xpub, String? challenge, int? timestampMs, String? signature}) => JWTRequest(
    xpub: xpub ?? this.xpub,
    challenge: challenge ?? this.challenge,
    timestampMs: timestampMs ?? this.timestampMs,
    signature: signature ?? this.signature,
  );

  Map<String, dynamic> toMapForSignature() => {'xpub': xpub, 'challenge': challenge, 'timestampMs': timestampMs};

  Map<String, dynamic> toMap() => {
    'xpub': xpub,
    'challenge': challenge,
    'timestampMs': timestampMs,
    'signature': signature,
  };
}
