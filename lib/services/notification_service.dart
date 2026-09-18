import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;

import 'package:convert/convert.dart';
import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:manna/app_state.dart';
import 'package:manna/config.dart';
import 'package:manna/models/account.dart';
import 'package:manna/router.dart';
import 'package:manna/screens/chat_screen.dart';
import 'package:manna/screens/contact_screen.dart';
import 'package:manna/screens/menu_screen.dart';
import 'package:manna/screens/transaction_detail_screen.dart';
import 'package:manna/services/connectivity_checker.dart';
import 'package:manna/services/db.dart';
import 'package:manna/services/log_service.dart';
import 'package:manna/services/secure_storage.dart';
import 'package:manna/services/wallet_service.dart';
import 'package:manna/utils/extensions.dart';
import 'package:manna/utils/parser.dart';
import 'package:manna/utils/util.dart';
import 'package:manna_core/manna_core.dart';
import 'package:path_provider/path_provider.dart';

class ActiveNotification {
  ActiveNotification({
    required this.id,
    required this.title,
    required this.body,
    required this.channelId,
    required this.groupId,
    required this.data,
    required this.timestamp,
  });

  factory ActiveNotification.fromMap(Map<dynamic, dynamic> data) => ActiveNotification(
    id: parseString(data['id']),
    title: parseString(data['title']),
    body: parseString(data['body']),
    channelId: parseString(data['channelId']),
    groupId: parseString(data['groupId']),
    data: parseMap(data['data'], (k, v) => MapEntry(parseString(k), v)),
    timestamp: DateTime.fromMillisecondsSinceEpoch(parseIntN(data['timestamp']) ?? 0),
  );

  /// [id] String on ios, int on android
  final String id;
  final String title;
  final String body;
  final String channelId;
  final String groupId;
  final Map<String, dynamic> data;
  final DateTime? timestamp;
}

class NotificationService {
  static const MethodChannel _channel = MethodChannel('com.lightning.manna/notifications');

  static bool get isSupported =>
      defaultTargetPlatform == TargetPlatform.android || defaultTargetPlatform == TargetPlatform.iOS;

  static Future<String?> getFCMToken() async {
    if (!isSupported) return null;
    if (!await ConnectivityChecker.checkConnection()) return null;

    try {
      return FirebaseMessaging.instance.getToken();
    } catch (e, s) {
      logE(e, stackTrace: s);
    }
    return null;
  }

  static Future<bool> isPermissionGranted() async {
    if (!isSupported) return false;
    try {
      final result = await _channel.invokeMethod<bool>('isPermissionGranted');
      return result ?? false;
    } catch (e, s) {
      logE(e, stackTrace: s);
      return false;
    }
  }

  static Future<void> setChatActiveUUID(String? uuid) async {
    if (!isSupported) return;
    try {
      await _channel.invokeMethod('setActiveChatUUID', {'uuid': uuid});
    } catch (e, s) {
      logE(e, stackTrace: s);
      return;
    }
  }

  /// [channelId] Android only
  static Future<bool> showNotification({
    required String title,
    String? body,
    Map<String, dynamic>? data,
    String? channelId,
    String? groupId,
    int? notificationId,
  }) async {
    if (!isSupported) return false;
    try {
      final arguments = <String, dynamic>{
        'title': title,
        'body': body,
        'data': data,
        'channelId': channelId,
        'groupId': groupId,
        'notificationId': notificationId,
      };

      final result = await _channel.invokeMethod<bool>('showNotification', arguments);
      return result ?? false;
    } catch (e, s) {
      logE(e, stackTrace: s);
      return false;
    }
  }

  /// pass null [notificationId] to cancel all notifications
  static Future<bool> cancelNotification({String? notificationId}) async {
    if (!isSupported) return false;
    try {
      final result = await _channel.invokeMethod<bool>('cancelNotification', {'notificationId': notificationId});
      return result ?? false;
    } catch (e, s) {
      logE(e, stackTrace: s);
      return false;
    }
  }

  static Future<List<ActiveNotification>> getActiveNotifications() async {
    if (!isSupported) return [];
    try {
      final result = await _channel.invokeMethod<List<dynamic>>('getActiveNotifications');
      if (result == null) return [];

      return result.map((e) => ActiveNotification.fromMap(e)).toList();
    } catch (e, s) {
      logE(e, stackTrace: s);
      return [];
    }
  }

  static Future<void> initialize() async {
    try {
      if (isSupported) {
        _channel.setMethodCallHandler((call) async {
          switch (call.method) {
            case 'onForegroundMessage':
              await handleFCMMessage((call.arguments as Map).cast<String, dynamic>());
              break;
            case 'onNotificationClicked':
              // foreground only
              final data = (call.arguments as Map).cast<String, dynamic>();
              await handleNotificationClick(jsonEncode(data));
              break;
          }
        });

        await FirebaseMessaging.instance.requestPermission();
      }
    } catch (e, s) {
      logE(e, stackTrace: s);
    }
  }

  static Future<void> storeInitialNotification() async {
    if (!isSupported) return;

    final initialNotificationData = await _channel.invokeMethod('getInitialClickedNotification');
    if (initialNotificationData is Map) {
      final payload = jsonEncode(initialNotificationData);
      await DB.setInitialNotificationPayload(payload);
    }
  }

  /// Process saved notification data which invoked app
  static void handleInitialNotification() async {
    final payload = DB.getInitialNotificationPayload();
    if (payload != null) {
      await handleNotificationClick(payload);
      await DB.setInitialNotificationPayload(null);
    }

    await cancelNotification();
  }

  static Future<void> handleNotificationClick(String payload) async {
    try {
      final data = jsonDecode(payload);
      final networkString = parseString(data['network']);
      final network = switch (networkString) {
        'mainnet' => Network.mainnet,
        _ => Network.regtest,
      };
      if (networkString.isNotEmpty && network != Config.network) {
        final res = await showDialog(
          context: AppRouter.navigatorContext,
          builder: (context) => AlertDialog(
            title: const Text('Attention'),
            content: Text(
              'You clicked a notification for ${network == Network.regtest ? 'Mannanet' : 'Mainnet'}, but you are on ${Config.network == Network.regtest ? 'Mannanet' : 'Mainnet'} right now.\nDo you want to change network?',
            ),
            actions: [
              TextButton(onPressed: () => AppRouter.pop(false), child: const Text('Ignore')),
              TextButton(onPressed: () => AppRouter.pop(true), child: const Text('Change')),
            ],
          ),
        );
        if (res is bool && res) {
          await updateNetwork(network);
        }
      }
      final type = parseString(data['type']);
      switch (type) {
        case 'new_message_chat':
          final senderId = parseString(data['senderId']);
          final receiverId = parseString(data['receiverId']);
          final contact =
              DB.contacts[IdWithWalletAndType(id: senderId, walletId: receiverId, walletType: WalletType.full)];

          // Select wallet so that relevant screen shows data that belongs to receiver wallet
          final accId = DB.fullWallets.values.where((w) => w.uuid == receiverId).firstOrNull?.accountId;
          if (accId != null) {
            selectAccount(accId);
          }

          Timer.run(() {
            if (contact != null) {
              AppRouter.replaceIfExists(ChatScreen(contact: contact));
            } else {
              AppRouter.replaceIfExists(const ContactScreen());
            }
          });
        case 'received_tx':
          final txId = parseString(data['txId']);
          final receiverWalletId = parseString(data['receiverId']);
          final amount = parseIntN(data['amount']);
          final receiverWallet = DB.allWallets.where((w) => w.uuid == receiverWalletId).firstOrNull;

          if (receiverWallet != null) {
            await WalletService.partialSync(xpub: receiverWallet.xpub);
            if (DB.transactions[IdWithWallet(walletId: receiverWalletId, id: txId)] == null) {
              // await ReceivingTxService.addReceivingTxs([
              //   ReceivingTx(walletId: receiverWalletId, txId: txId, amount: amount),
              // ], forNotificationClick: true);
              await WalletService.sync(xpub: receiverWallet.xpub);
            } else {
              AppRouter.replaceIfExists(
                TransactionDetailScreen(
                  id: IdWithWallet(walletId: receiverWalletId, id: txId),
                ),
              );
            }
          }

        // case 'swap_detail':
        //   final swapId = parseString(data['swapId']);
        //   if (swapId.isNotEmpty) {
        //     unawaited(AppRouter.push(SwapDetailScreen(swapId: swapId)));
        //   }
      }
    } catch (e, s) {
      logE(e, stackTrace: s);
    }
  }

  // static final lnurlNotificationThrottle = Throttler(const Duration(seconds: 10));

  static Future<void> handleFCMMessage(Map<String, dynamic> messageData) async {
    if (messageData.isNotEmpty && messageData['type'] != null) {
      final type = parseString(messageData['type']);
      final network = switch (parseString(messageData['network'])) {
        'mainnet' => Network.mainnet,
        _ => Network.regtest,
      };
      logI('Handling FCM message foreground: $type, $network');

      switch (type) {
        case 'new_message_chat':
        // Nothing here cause when app is in foreground, the realtime will craft notification.

        // case 'lnurl':
        //   List<String> ids = [];
        //   try {
        //     if (messageData['swapIds'] is String) {
        //       final swapIds = jsonDecode(messageData['swapIds']);
        //       if (swapIds is List && swapIds.isNotEmpty) {
        //         ids = parseList(swapIds, (e) => parseString(e));
        //       }
        //     }
        //   } catch (e, s) {
        //     logE(e, stackTrace: s);
        //   }
        //   await lnurlNotificationThrottle.run(() async {
        //     await BoltzService.processPendingSwaps(network: network, lnurlSwapIdsToProcess: ids);
        //   });
        //
        // case 'swap_webhook':
        //   await BoltzService.processPendingSwaps(network: network);

        case 'received_tx':
          final txId = parseString(messageData['txId']);
          final receiverWalletId = parseString(messageData['receiverId']);
          final amount = parseIntN(messageData['amount']);

          final receiverWallet = DB.allWallets.where((w) => w.uuid == receiverWalletId).firstOrNull;
          if (receiverWallet != null) {
            if (DB.transactions[IdWithWallet(walletId: receiverWalletId, id: txId)] == null) {
              // await ReceivingTxService.addReceivingTxs([
              //   ReceivingTx(walletId: receiverWalletId, txId: txId, amount: amount),
              // ]);
              await WalletService.sync(xpub: receiverWallet.xpub);
            } else {
              // await ReceivingTxService.removeReceivingTx(txId);
              AppRouter.replaceIfExists(
                TransactionDetailScreen(
                  id: IdWithWallet(walletId: receiverWalletId, id: txId),
                ),
              );
            }
          }
      }
    } else {
      final title = parseStringN(messageData['title']);
      final body = parseStringN(messageData['body']);
      if (title != null) {
        await showNotification(title: title, body: body, data: messageData.containsKey('type') ? messageData : null);
      }
    }
  }
}

// This is storage layer service to share data with Notification Service Extension on iOS.
class AppGroupSharedService {
  static Uint8List? _passwordCache;
  static String? _groupContainerPathCache;

  static int walletLength = 0, woWalletLength = 0;

  static Future<void> startSync() async {
    if (!(Platform.isIOS || Platform.isAndroid)) return;

    if (_passwordCache == null) {
      _passwordCache = await SecureStorage.fetch('sharedFilePassword');
      if (_passwordCache == null || _passwordCache?.length != 32) {
        final random = math.Random.secure();
        _passwordCache = Uint8List.fromList(List.generate(32, (index) => random.nextInt(256)));
        await SecureStorage.store('sharedFilePassword', Uint8List.fromList(_passwordCache!));
      }
    }

    if (_groupContainerPathCache == null) {
      final groupContainerPath = Platform.isIOS
          ? await getAppGroupPath()
          : (await getApplicationSupportDirectory()).path;
      if (groupContainerPath != null && groupContainerPath.isNotEmpty) {
        _groupContainerPathCache = groupContainerPath;
      }
    }

    if (_passwordCache == null) return;
    if (_groupContainerPathCache == null) return;

    await _syncWalletFile();
    await _syncChatFile();

    DB.walletBox.watch().listen((event) async {
      // only handle new or deleted events
      if (walletLength != DB.fullWallets.length) {
        walletLength = DB.fullWallets.length;
        await _syncWalletFile();
        await _syncChatFile();
      }
    });

    DB.contactsBox.watch().listen((event) => _syncChatFile());
  }

  static Future<void> _syncWalletFile() async {
    try {
      final Map<String, dynamic> walletFile = {};
      walletFile['api_config'] = jsonDecode(Config.apiConfig.toJson());
      walletFile['bitcoin_display_style'] = AppState.bitcoinDisplayStyle;
      walletFile['device_id'] = await getDeviceId();
      walletFile['wallets'] = await Future.wait(
        DB.allWallets.where((w) => w.account.isDisabled == false).map((e) async {
          String? privateKeyHex;
          try {
            final t = await getDerivationPrivKey(
              accountId: e.accountId,
              derivationPath: '${liquidDerivationPath(network: e.network)}/2',
            );
            if (t != null) {
              privateKeyHex = hex.encode(t);
            }
          } catch (e, s) {
            logE(e, stackTrace: s);
          }
          return {
            'uuid': e.uuid,
            'wallet_type': e.type.name.capitalize,
            if (e.type == WalletType.full) 'upsert_derivation_private_key_hex': privateKeyHex,
            'wallet_name': e.account.name,
          };
        }),
      );
      await _writeData(fileName: 'wallets', data: walletFile);
    } catch (e, s) {
      logE(e, stackTrace: s);
    }
  }


  static Future<void> _syncChatFile() async {
    try {
      final Map<String, dynamic> chatFile = {};
      chatFile['wallet_chat_keys'] = Map.fromEntries(
        DB.fullWallets.values
            .where((wallet) => !wallet.account.isDisabled && wallet.account.chatKeyPair != null)
            .map((w) => MapEntry(w.uuid, base64Encode(w.account.chatKeyPair!.secretKey))),
      );
      chatFile['contacts_data'] = DB.contacts.values
          .map((c) => [c.uuid, c.walletId, c.walletType.index, c.name(), c.chatPubKeyBase64, c.picture()])
          .toList();
      await _writeData(fileName: 'chat', data: chatFile);
    } catch (e, s) {
      logE(e, stackTrace: s);
    }
  }

  static Future<void> _writeData({required String fileName, required Map<String, dynamic> data}) async {
    try {
      final encrypted = await Crypto.aesEncrypt(
        key: U8Array32(_passwordCache!),
        plaintext: utf8.encode(jsonEncode(data)),
      );
      await File('$_groupContainerPathCache/$fileName.json.enc').writeAsBytes(encrypted, flush: true);
    } catch (e, s) {
      logE(e, stackTrace: s);
    }
  }

  static Future<Map<String, dynamic>> _readData({required String fileName}) async {
    final file = File('$_groupContainerPathCache/$fileName.json.enc');
    try {
      if (!file.existsSync()) return {};
      final encrypted = await file.readAsBytes();
      if (encrypted.isNotEmpty) {
        final plainText = await Crypto.aesDecrypt(key: U8Array32(_passwordCache!), payload: encrypted);
        return jsonDecode(utf8.decode(plainText));
      }
    } on MannaError catch (e, s) {
      if (e.kind == 'AES-GCM' && file.existsSync()) {
        await file.delete();
      } else {
        logE(e, stackTrace: s);
      }
    } catch (e, s) {
      logE(e, stackTrace: s);
    }
    return {};
  }
}
