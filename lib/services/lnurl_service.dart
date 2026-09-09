import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:convert/convert.dart';
import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:manna/globals.dart';
import 'package:manna/models/account.dart';
import 'package:manna/models/enums.dart';
import 'package:manna/models/misc.dart';
import 'package:manna/models/transaction.dart';
import 'package:manna/router.dart';
import 'package:manna/services/db.dart';
import 'package:manna/services/log_service.dart';
import 'package:manna/services/transaction_service.dart';
import 'package:manna/utils/constants.dart';
import 'package:manna/utils/extensions.dart';
import 'package:manna/utils/parser.dart';
import 'package:manna/utils/state_extension.dart';
import 'package:manna/utils/toast_service.dart';
import 'package:manna/utils/util.dart';
import 'package:manna/widgets/dialogs/lnurl_auth_dialog.dart';
import 'package:manna/widgets/dialogs/lnurl_withdraw_dialog.dart';
import 'package:manna_core/manna_core.dart';
import 'package:url_launcher/url_launcher_string.dart';
import 'package:cryptography_plus/cryptography_plus.dart';

class LnurlAuthService {
  /// returns true if string is valid LNURL auth
  static Future<bool> handleLNURLAuth(String rawAddress) async {
    try {
      Uri? uri = Uri.tryParse(rawAddress.trim().toLowerCase());
      if (uri == null) return false;

      if (uri.scheme == 'keyauth' && uri.host.isNotEmpty) {
        uri = uri.replace(scheme: uri.host.endsWith('onion') ? 'http' : 'https');
      } else if ({'http', 'https'}.contains(uri.scheme) && uri.host.isNotEmpty) {
        // already in expected format
      } else {
        uri = Uri.tryParse(LnurlUtil.decode(lnurl: uri.path));
      }

      if (uri == null || uri.queryParameters['tag'] != 'login' || uri.queryParameters['k1']?.length != 64) {
        return false;
      }

      if (AppRouter.navigatorContext.mounted) {
        postFrameCallBack(
          () => showDialog(
            context: AppRouter.navigatorContext,
            builder: (context) => LNURLAuthDialog(uri: uri!),
          ),
        );
        // this return is to notify caller that schema is correct for LNURL auth.
        return true;
      }
    } catch (_) {}
    return false;
  }

  static Future<void> onLNURLAuth(Account account, Uri uri) async {
    if (!await account.hasMnemonic) {
      return ToastService.show('Watch only wallets cannot be used for logins.');
    }
    try {
      final k1Hex = uri.queryParameters['k1'].toString();
      final service = uri.host;

      startLoader();
      final mnemonic = await account.getMnemonicSentence();
      if (mnemonic == null) return;

      final root = await Bip32.fromMnemonics(mnemonic: mnemonic);
      final hashingKey = root.derivePath(path: "m/138'/0").getPrivateKey();
      if (hashingKey == null) {
        return ToastService.show('Watch only wallets cannot be used for logins.');
      }
      final derivationPath = await LnurlUtil.getSigningDerivationPath(hashingKey: hashingKey, lnurl: uri.toString());

      final linkingNode = (await Bip32.fromMnemonics(mnemonic: mnemonic)).derivePath(path: 'm/$derivationPath');
      final sigHex = await _signChallenge(linkingNode, k1Hex);

      if (sigHex == null) return;
      final queryParams = Map<String, String>.from(uri.queryParameters);
      queryParams['sig'] = sigHex;
      queryParams['key'] = Uint8List.fromList(linkingNode.getPubKey()).toHexString;

      final res = await globalDio
          .clone(
            options: globalDio.options.copyWith(
              receiveTimeout: const Duration(seconds: 10),
              connectTimeout: const Duration(seconds: 10),
            ),
          )
          .getUri(uri.replace(queryParameters: queryParams));
      if (res.isSuccess) {
        if (parseString(res.data['status']).toLowerCase() == 'ok') {
          ToastService.show('Successfully logged into $service');
          AppRouter.pop(true);
        } else if (parseString(res.data['status']).toLowerCase() == 'error' &&
            parseString(res.data['reason']).isNotEmpty) {
          ToastService.show('Failed to login, reason : ${parseString(res.data['reason'])}');
          AppRouter.pop(false);
        }
      }
    } catch (e, s) {
      if (e is DioException) {
        ToastService.show('Lightning service is not responding!');
      }
      logE(e, stackTrace: s);
    } finally {
      stopLoader();
    }
  }

  static Future<String?> _signChallenge(Bip32 linkingNode, String challengeHex) async {
    try {
      final privateKey = linkingNode.getPrivateKey();
      if (privateKey == null) return null;
      return (await Crypto.secp256K1Sign(
        privKey: privateKey,
        message: challengeHex.hexStringToBytes,
        returnDer: true,
      )).toHexString;
    } catch (e, s) {
      logE(e, stackTrace: s, showToast: true);
    }
    return null;
  }
}

class LnurlWithdrawService {
  /// returns true if string is valid LNURLW
  static Future<bool> handleLNURLW({required String rawAddress, Map<String, dynamic>? data}) async {
    Uri? uri = Uri.tryParse(rawAddress.trim().toLowerCase());
    if (uri == null) return false;

    if (uri.scheme == 'lnurlw' && uri.host.isNotEmpty) {
      uri = uri.replace(scheme: uri.host.endsWith('onion') ? 'http' : 'https');
    } else if ({'http', 'https'}.contains(uri.scheme) && uri.host.isNotEmpty) {
      // already in expected format
    } else {
      uri = Uri.tryParse(LnurlUtil.decode(lnurl: uri.path));
    }

    try {
      if (uri == null) return false;

      Map<String, dynamic>? lnurlData = data;
      try {
        lnurlData ??= await callLNURL(uri);
      } on AddressParsingException catch (e) {
        ToastService.show(e.message);
        return false;
      } catch (e) {
        return false;
      }

      final callback = parseString(lnurlData['callback']);
      final k1 = parseString(lnurlData['k1']);
      final minWithdrawable = (parseIntN(lnurlData['minWithdrawable']) ?? 0) / 1000;
      final maxWithdrawable = (parseIntN(lnurlData['maxWithdrawable']) ?? 0) / 1000;
      final desc = parseStringN(lnurlData['defaultDescription']);

      if (callback.isNotEmpty &&
          k1.isNotEmpty &&
          maxWithdrawable > 0 &&
          minWithdrawable < maxWithdrawable &&
          AppRouter.navigatorContext.mounted) {
        final res = await showDialog(
          context: AppRouter.navigatorContext,
          builder: (context) => LNURLWithdrawDialog(
            serviceName: uri!.host,
            callback: callback,
            k1: k1,
            minWithdrawable: minWithdrawable.floor(),
            maxWithdrawable: maxWithdrawable.floor(),
            desc: desc,
          ),
        );
        if (res is bool) {
          // pop again to jump to wallet screen instead of send screen
          AppRouter.popIfExists('SendScreen');
        }

        // this return is to notify caller that LNURLW is handled.
        return true;
      }
    } catch (_) {}
    return false;
  }
}

/// return response data from LNURL call
Future<Map<String, dynamic>> callLNURL(Uri uri) async {
  if (!{'http', 'https'}.contains(uri.scheme)) throw AddressParsingException('Invalid LNURL');

  try {
    final res = await globalDio.getUri(
      uri,
      options: Options(
        sendTimeout: const Duration(seconds: 3),
        receiveTimeout: const Duration(seconds: 3),
        headers: {'User-Agent': 'MannaWallet(${Platform.operatingSystem})'},
      ),
    );
    if (!res.isSuccess) throw AddressParsingException('Invalid LNURL');

    if (res.data is Map) {
      if (parseStringN(res.data['status'])?.toLowerCase() == 'error') {
        throw AddressParsingException(parseStringN(res.data['reason']) ?? 'Invalid LNURL');
      }

      if ({'payRequest', 'withdrawRequest'}.contains(parseString(res.data['tag']))) return res.data;
    }
  } on DioException catch (_) {
    throw AddressParsingException('Invalid LNURL');
  } catch (e) {
    rethrow;
  }

  throw AddressParsingException('Invalid LNURL');
}

Future<AddressData?> handleLNURL({
  required String rawAddress,
  required Network network,
  bool validateOnly = false,
}) async {
  final address = rawAddress.trim().toLowerCase();
  Uri lnurlToHttpScheme(Uri uri) => uri.replace(scheme: uri.host.endsWith('onion') ? 'http' : 'https');

  String? convertPayReqURIToUserName(Uri uri) {
    if (uri.host.isNotEmpty &&
        uri.queryParameters.isEmpty &&
        uri.pathSegments.length == 3 &&
        uri.pathSegments[0] == '.well-known' &&
        uri.pathSegments[1] == 'lnurlp') {
      return '${uri.pathSegments[2]}@${uri.host}';
    }
    return null;
  }

  // if username convert it to LNURL format
  if (address.isUserName) {
    final data = AddressData(addressType: AddressType.lnurl, address: address);
    if (validateOnly) return data;

    try {
      final match = Regexes.internetAddress.firstMatch(address);
      final username = match?.group(1);
      final domain = match?.group(2);
      if (username != null && domain != null) {
        final lnurlData = await callLNURL(Uri.parse('https://$domain/.well-known/lnurlp/$username'));
        return data.copyWith(lnurlData: Nullable(lnurlData));
      }
    } catch (_) {}

    // username: bolt12
    if ((await fetchBolt12OfferUriFromUsername(network: network, username: address)) != null) {
      return data;
    }
  }

  final uri = Uri.tryParse(address);
  if (uri == null) {
    return null;
  }

  final validateData = AddressData(addressType: AddressType.lnurl, address: address);
  if (uri.scheme == 'lnurlw') {
    if (validateOnly) return validateData;
    if (await LnurlWithdrawService.handleLNURLW(rawAddress: lnurlToHttpScheme(uri).toString())) {
      return null;
    }
    throw AddressParsingException('Invalid LNURLW format!');
  } else if (uri.scheme == 'keyauth') {
    if (validateOnly) return validateData;
    if (await LnurlAuthService.handleLNURLAuth(lnurlToHttpScheme(uri).toString())) {
      return null;
    }
    throw AddressParsingException('Invalid LNURL-Auth format!');
  } else if (uri.scheme == 'lnurlp') {
    if (validateOnly) return validateData;
    final payReqUri = lnurlToHttpScheme(uri);
    final lnurlData = await callLNURL(payReqUri);
    return AddressData(
      addressType: AddressType.lnurl,
      address: convertPayReqURIToUserName(payReqUri) ?? address,
      lnurlData: lnurlData,
    );
  }

  // lnurl
  if (uri.pathSegments.firstOrNull?.startsWith('lnurl') ?? false) {
    try {
      final decodedLNURL = LnurlUtil.decode(lnurl: uri.pathSegments.firstOrNull ?? address);
      final lnurlUri = Uri.tryParse(decodedLNURL);
      if (lnurlUri == null) {
        return null;
      }

      if (validateOnly) return AddressData(addressType: AddressType.lnurl, address: address);

      if (lnurlUri.queryParameters['tag'] == 'login') {
        if (await LnurlAuthService.handleLNURLAuth(decodedLNURL)) {
          return null;
        }
        throw AddressParsingException('Invalid LNURL-Auth format!');
      } else {
        final lnurlData = await callLNURL(lnurlUri);
        switch (parseString(lnurlData['tag'])) {
          case 'withdrawRequest':
            if (await LnurlWithdrawService.handleLNURLW(rawAddress: decodedLNURL, data: lnurlData)) {
              return null;
            }
            throw AddressParsingException('Invalid LNURLW format!');
          case 'payRequest':
            return AddressData(
              addressType: AddressType.lnurl,
              address: convertPayReqURIToUserName(lnurlUri) ?? address,
              lnurlData: lnurlData,
            );
        }
      }
    } on AddressParsingException catch (_) {
      rethrow;
    }
  }

  return null;
}

void processLNURLSuccessActionAllTransactions() {
  DB.transactions.values
      .where((tx) => !tx.isIncoming && tx.extraMetadata.isNotEmpty)
      .map((tx) => handleLNURLSuccessAction(tx));
}

/// [PayOutData.lnurlSuccessActionData] is stored in [Transaction.extraMetadata] with key 'lnurlSuccessAction'
/// this function calls that action if not done already.
void handleLNURLSuccessAction(Transaction tx) async {
  final swap = tx.linkedSwap;
  if (swap == null || swap.submarine == null) return;

  final successAction = tx.extraMetadata['lnurlSuccessAction'];
  if (successAction is Map && successAction.isNotEmpty && successAction['acted'] == null) {
    switch (parseString(successAction['tag']).toLowerCase()) {
      case 'message':
        final message = parseString(successAction['message']).trim();
        if (message.isNotEmpty) {
          if (AppRouter.navigatorContext.mounted) {
            await showDialog(
              context: AppRouter.navigatorContext,
              builder: (context) => AlertDialog(
                title: Text('Invoice ${swap.submarine!.invoice.shortenAddress()} paid.'),
                content: Text(message),
                actions: [TextButton(onPressed: () => AppRouter.pop(), child: const Text('Ok'))],
              ),
            );
          }
          await tx.update(
            extraMetadata: tx.extraMetadata.update('lnurlSuccessAction', (value) => {...successAction, 'acted': true}),
          );
        }
      case 'url':
        final url = parseString(successAction['url']).trim();
        final description = parseString(successAction['description']).trim();
        if (AppRouter.navigatorContext.mounted) {
          await showDialog(
            context: AppRouter.navigatorContext,
            builder: (context) => AlertDialog(
              title: Text('Invoice ${swap.submarine!.invoice.shortenAddress()} paid.'),
              content: Column(
                children: [
                  Text(description),
                  const Divider(),
                  Text(
                    url,
                    style: TextStyle(
                      decoration: TextDecoration.underline,
                      color: Colors.blue.shade600,
                      decorationColor: Colors.blue.shade600,
                    ),
                  ),
                ],
              ),
              actions: [
                TextButton(onPressed: () => AppRouter.pop(), child: const Text('Cancel')),
                TextButton(onPressed: () => launchUrlString(url), child: const Text('Open')),
              ],
            ),
          );
        }
        await tx.update(
          extraMetadata: tx.extraMetadata.update('lnurlSuccessAction', (value) => {...successAction, 'acted': true}),
        );
      case 'aes':
        final preimage = swap.preimage.value;
        if (preimage.isEmpty) return;

        try {
          final description = parseString(successAction['description']).trim();
          final cipherBytes = base64Decode(parseString(successAction['ciphertext']).trim());
          final ivBytes = base64Decode(parseString(successAction['iv']).trim());

          final algorithm = AesCbc.with256bits(macAlgorithm: MacAlgorithm.empty);
          final plainText = await algorithm.decryptString(
            SecretBox(cipherBytes, nonce: ivBytes, mac: Mac.empty),
            secretKey: await algorithm.newSecretKeyFromBytes(hex.decode(preimage)),
          );

          await tx.update(
            extraMetadata: tx.extraMetadata.update(
              'lnurlSuccessAction',
              (value) => {...successAction, 'plainText': plainText, 'acted': true},
            ),
          );

          if (AppRouter.navigatorContext.mounted) {
            await showDialog(
              context: AppRouter.navigatorContext,
              builder: (context) => AlertDialog(
                title: Text('Invoice ${swap.submarine!.invoice.shortenAddress()} paid.'),
                content: Column(
                  children: [
                    Text(description),
                    const Divider(),
                    Text(
                      plainText,
                      style: TextStyle(
                        decoration: TextDecoration.underline,
                        color: Colors.blue.shade600,
                        decorationColor: Colors.blue.shade600,
                        fontSize: 16,
                      ),
                    ),
                  ],
                ),
                actions: [TextButton(onPressed: () => AppRouter.pop(), child: const Text('Ok'))],
              ),
            );
          }
        } catch (e, s) {
          logE(e, stackTrace: s);
        }
    }
  }
}
