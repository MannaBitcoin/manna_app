import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;

import 'package:breez_sdk_spark_flutter/breez_sdk_spark.dart'
    show GetInfoRequest, PaymentDetails_Lightning, RegisterWebhookRequest, WebhookEventType, Webhook;
import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:html_rich_text/html_rich_text.dart';
import 'package:http/http.dart' as http;
import 'package:manna/app_state.dart';
import 'package:manna/config.dart';
import 'package:manna/globals.dart';
import 'package:manna/models/account.dart';
import 'package:manna/models/contact.dart';
import 'package:manna/models/misc.dart';
import 'package:manna/models/setting_history_cache.dart';
import 'package:manna/models/wallet.dart';
import 'package:manna/router.dart';
import 'package:manna/screens/menu_screen.dart';
import 'package:manna/services/connectivity_checker.dart';
import 'package:manna/services/db.dart';
import 'package:manna/services/jwt_service.dart';
import 'package:manna/services/log_service.dart';
import 'package:manna/services/nostr_service.dart';
import 'package:manna/services/notification_service.dart';
import 'package:manna/services/wallet_service.dart';
import 'package:manna/theme.dart';
import 'package:manna/utils/constants.dart';
import 'package:manna/utils/de_bouncer.dart';
import 'package:manna/utils/extensions.dart';
import 'package:manna/utils/parser.dart';
import 'package:manna/utils/toast_service.dart';
import 'package:manna/utils/util.dart';
import 'package:manna_core/manna_core.dart' hide Wallet;
import 'package:native_dio_adapter/native_dio_adapter.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:supabase_flutter/supabase_flutter.dart' hide MultipartFile;
import 'package:url_launcher/url_launcher_string.dart';
import 'package:uuid/uuid.dart';

//note: the batching for in filter query is to mitigate cloudflare's limit to process 32kb url params
class DbService {
  static SupabaseClient? _supabase;
  static SupabaseClient? _regtestSupabase;

  static final Map<String, double> currencyRates = {};
  static String lbtcAddressForFees = '';
  static double estimatedLiquidFeesPPM = 0.1;

  // Fees
  static int liquidFeeThreshold = 0;
  static double liquidFeePercent = 0;
  static double lnLbtcSwapFee = 0;
  static double btcLbtcSwapFee = 0;
  static double lbtcLnSwapFee = 0;
  static double lbtcBtcSwapFee = 0;

  static int tempSwapFeeThreshold = 0;
  static double tempSwapFeePercent = 0;

  static int failCount = 0;

  static Future<T?> useSupabase<T>(Future<T?> Function(SupabaseClient supabase) f, {Network? network}) async {
    network ??= Config.network;
    final supabase = switch (network) {
      Network.mainnet => _supabase,
      Network.testnet => null,
      Network.regtest => _regtestSupabase,
    };

    if (supabase == null) {
      ToastService.show("Can't connect to backend! Please try again after sometime!");
      logTrace();
    } else {
      if (!await ConnectivityChecker.checkConnection()) return null;
      try {
        final res = await f(supabase);
        failCount = 0;
        return res;
      } catch (e, s) {
        failCount++;
        logE(
          e,
          stackTrace: s,
          showToast: failCount > 4,
          title: 'Failed to communicate with backend service! (${network.name})',
        );
      }
    }
    return null;
  }

  static Future<void> init() async {
    try {
      logI('Initializing Supabase Service!');

      await _supabase?.dispose();
      _supabase = SupabaseClient(
        'https://${Config.of(Network.mainnet).supabase.projectRef}.supabase.co',
        Config.of(Network.mainnet).supabase.apiKey,
        accessToken: () => JWTService.getToken(network: Network.mainnet),
        httpClient: DioHttpClient(),
      );

      await _regtestSupabase?.dispose();
      if (Config.isRegtestOn) {
        _regtestSupabase = SupabaseClient(
          'https://${Config.of(Network.regtest).supabase.projectRef}.supabase.co',
          Config.of(Network.regtest).supabase.apiKey,
          accessToken: () => JWTService.getToken(network: Network.regtest),
          httpClient: DioHttpClient(),
        );
      }
    } catch (e, s) {
      logE(e, stackTrace: s);
    }

    unawaited(
      Future(() async {
        await syncSettings(fromInit: true);
        await fetchAndCacheSettingHistory();

        await syncEverything();
      }),
    );
  }

  static Future<void> syncSettings({bool fromInit = false}) async {
    await useSupabase((supabase) async {
      final settings = Map.fromEntries(
        (await supabase.from('settings').select('key, value')).map(
          (e) => MapEntry(parseString(e['key']), parseString(e['value'])),
        ),
      );

      lbtcAddressForFees = parseString(settings['lbtc_address_for_fees']);
      estimatedLiquidFeesPPM = parseDoubleN(settings['fee_rate']) ?? 0.1;

      liquidFeeThreshold = parseInt(settings['liquid_fee_threshold']).clamp(0, 99999999999);
      liquidFeePercent = parseDouble(settings['liquid_fee_percent']).clamp(0, 100);
      lnLbtcSwapFee = parseDouble(settings['app_ln_lbtc_swap_fee']).clamp(0, 100);
      btcLbtcSwapFee = parseDouble(settings['app_btc_lbtc_swap_fee']).clamp(0, 100);
      lbtcLnSwapFee = parseDouble(settings['app_lbtc_ln_swap_fee']).clamp(0, 100);
      lbtcBtcSwapFee = parseDouble(settings['app_lbtc_btc_swap_fee']).clamp(0, 100);

      tempSwapFeeThreshold = parseInt(settings['temp_swap_fee_threshold']).clamp(0, 99999999999);
      tempSwapFeePercent = parseDouble(settings['temp_swap_fee_percent']).clamp(0, 100);

      AppState.btcPrice = parseDouble(settings['btcPrice']);

      startBtcPriceListening();

      // Currencies
      final data = await supabase.from('currency_rates').select();
      currencyRates.clear();
      currencyRates.addAll(
        Map.fromEntries(
          data.map((e) => MapEntry(parseString(e['target_currency']).toLowerCase(), parseDouble(e['exchange_rate']))),
        ),
      );

      if (fromInit) {
        // System status dialog
        try {
          final systemStatusData = jsonDecode(settings['system_status_dialog'] ?? '{}');
          final title = parseString(systemStatusData['title']);
          final message = parseString(systemStatusData['message']);

          if (title.isNotEmpty && message.isNotEmpty && AppRouter.navigatorContext.mounted) {
            await showDialog(
              context: AppRouter.navigatorContext,
              builder: (context) => AlertDialog(
                title: Text(title),
                content: SingleChildScrollView(
                  child: HtmlRichText(
                    message,
                    onLinkTap: (url) => launchUrlString(url),
                    tagStyles: const {
                      'b': TextStyle(fontWeight: FontWeight.bold),
                      'i': TextStyle(fontStyle: FontStyle.italic),
                      'strong': TextStyle(fontWeight: FontWeight.w900, color: AppColors.primaryColor),
                      'u': TextStyle(decoration: TextDecoration.underline),
                    },
                  ),
                ),
                actions: [TextButton(child: const Text('Acknowledge'), onPressed: () => AppRouter.pop())],
              ),
            );
          }
        } catch (_) {}

        // Update dialog
        if (upgrader.shouldDisplayUpgrade()) {
          try {
            final updateDialogData = jsonDecode(settings['update_dialog'] ?? '{}');
            final title = parseString(updateDialogData['title']);
            final message = parseString(updateDialogData['message']);

            if (title.isNotEmpty && message.isNotEmpty && AppRouter.navigatorContext.mounted) {
              await showDialog(
                context: AppRouter.navigatorContext,
                builder: (context) => AlertDialog(
                  title: Text(title),
                  content: Text(message),
                  actions: [
                    TextButton(
                      child: const Text('Checkout'),
                      onPressed: () => AppRouter.replace(const MenuScreen(isFromUpdateDialog: true)),
                    ),
                  ],
                ),
              );
            }
          } catch (_) {}
        }
      }
    });
  }

  static final ValueNotifier<bool> isSyncing = ValueNotifier(false);
  static Future<void> syncEverything() async {
    isSyncing.value = true;
    await syncWalletData(network: Config.network);

    // sync wallet for secondary chain
    if (Config.isRegtestOn) {
      await syncWalletData(network: Config.network == Network.mainnet ? Network.regtest : Network.mainnet);
    }

    await cacheContacts();
    await cacheBTCPrices();
    isSyncing.value = false;
    GlobalListener.update(stream: .account);
  }

  static StreamSubscription<List<Map<String, dynamic>>>? btcPriceSubscription;
  static void startBtcPriceListening() {
    stopBtcPriceListening();
    useSupabase(
      (supabase) async => btcPriceSubscription = supabase
          .from('settings')
          .stream(primaryKey: ['key'])
          .eq('key', 'btcPrice')
          .listen(
            (event) {
              if (event.isNotEmpty) {
                AppState.btcPrice = parseDouble(event.first['value']);
              }
            },
            cancelOnError: false,
            onError: (e, s) => logD('btc price setting $e $s'),
          ),
    );
  }

  static void stopBtcPriceListening() {
    btcPriceSubscription?.cancel();
    btcPriceSubscription = null;
  }

  static Future<void> syncWalletData({Network? network}) async {
    final Map<Network, Set<String>> activeFullWalletIds = {};
    final List<Wallet> activeWallets = [];
    final activeAccountIds = DB.activeAccounts.map((e) => e.id).toSet();

    for (final w in DB.allWallets) {
      if (!activeAccountIds.contains(w.accountId)) continue;
      if (w.network == Network.regtest && !Config.isRegtestOn) continue;

      activeWallets.add(w);
      if (w.type == WalletType.full) {
        (activeFullWalletIds[w.network] ??= {}).add(w.uuid);
      }
    }

    if (network != null) {
      activeFullWalletIds.removeWhere((key, value) => key != network);
    }

    if (activeFullWalletIds.isEmpty) return;

    final deviceId = await getDeviceId();
    final fcmToken = await NotificationService.getFCMToken();

    // apply supabase to local db first
    await Future.wait([
      if (activeFullWalletIds.isNotEmpty)
        for (final e in activeFullWalletIds.entries)
          if (e.value.isNotEmpty)
            useSupabase((supabase) async {
              final rows = await supabase
                  .from('wallets')
                  .select('uuid, user_name, bolt11_short_desc, about, picture, banner')
                  .inFilter('uuid', e.value.toList());
              for (final e in parseList(rows, (e) => WalletMetaData.fromMap(e))) {
                walletDataMap['${e.uuid}_${WalletType.full.name}'] = e;
              }
            }, network: e.key),
    ]);

    GlobalListener.update(stream: .account);

    {
      // Update notification token
      final activeWalletIds = Map.of(activeFullWalletIds);
      if (fcmToken?.isNotEmpty == true && activeWalletIds.isNotEmpty) {
        final packageInfo = await PackageInfo.fromPlatform();

        await Future.wait([
          for (final e in activeWalletIds.entries)
            if (e.value.isNotEmpty)
              useSupabase((supabase) async {
                try {
                  await supabase
                      .from('devices')
                      .upsert(
                        e.value
                            .map(
                              (wId) => {
                                'wallet_uuid': wId,
                                'device_id': deviceId,
                                'fcm_token': fcmToken,
                                'platform': Platform.operatingSystem,
                                'last_active_at': DateTime.now(),
                                'app_version': '${packageInfo.version}+${packageInfo.buildNumber}',
                              }.toEncodeReady(),
                            )
                            .toList(),
                        defaultToNull: false,
                      );
                } catch (e, s) {
                  logE(e, stackTrace: s);
                }
              }, network: e.key),
        ]);
      }
    }

    await upsertWallets(
      Map.fromEntries(
        await Future.wait(
          activeWallets.map((wallet) async {
            final sp = wallet.spark;
            final account = wallet.account;
            return MapEntry(wallet, {
              if (sp != null) ...{
                'identity_pub_key': (await sp.getInfo(request: const GetInfoRequest())).identityPubkey,
              },
              if (account.chatKeyPair != null) 'chat_pubkey': base64Encode(account.chatKeyPair!.publicKey),
              if (account.nsec != null) 'npub': account.nsec!.nsecToNpub,
            });
          }),
        ),
      ),
    );

    {
      // setup webhooks for notification
      final webHookUrl = Config.sparkWebhookUrl;
      if (webHookUrl != null) {
        await Future.wait(
          activeWallets.where((w) => w.network == Config.network).map((w) async {
            for (final webhook in await w.spark?.listWebhooks() ?? <Webhook>[]) {
              if (webhook.eventTypes.contains(const WebhookEventType.lightningReceiveFinished())) return;
            }

            await w.spark?.registerWebhook(
              request: RegisterWebhookRequest(
                url: webHookUrl,
                secret: 'MANNATEAMISDOPEE',
                eventTypes: [
                  const WebhookEventType.staticDepositFinished(),
                  const WebhookEventType.coopExitFinished(),
                  const WebhookEventType.lightningReceiveFinished(),
                  const WebhookEventType.lightningSendFinished(),
                ],
              ),
            );
            logI('registered webhook: ${w.uuid}');
          }),
        );
      }
    }

    GlobalListener.update(stream: .account);
  }

  /// [wallets] is data to upsert for given wallet
  static Future<bool> upsertWallets(Map<Wallet, Map<String, dynamic>> wallets) async {
    if (wallets.isEmpty) return false;

    final Map<Network, Map<WalletType, List<Map<String, dynamic>>>> walletData = {};
    for (final MapEntry(key: wallet, value: data) in wallets.entries) {
      if (wallet.network == Network.regtest && !Config.isRegtestOn) continue;

      try {
        U8Array32? privateKey;
        if (wallet.type == WalletType.full) {
          privateKey = await getDerivationPrivKey(
            accountId: wallet.accountId,
            derivationPath: '${liquidDerivationPath(network: wallet.network)}/2',
          );
        }

        final payload = {
          ...data,

          'uuid': wallet.uuid,
          'wallet_xpub': wallet.xpub,
          'timestamp': DateTime.now().millisecondsSinceEpoch,
        };

        if (privateKey != null) {
          final signature = await Crypto.secp256K1Sign(
            privKey: privateKey,
            message: utf8.encode(sortedJsonEncode(payload)),
            returnDer: false,
            preHash: true,
          );
          final data = {...payload, 'signature': signature.toHexString};
          walletData.update(
            wallet.network,
            (value) => value..update(WalletType.full, (value) => value..add(data), ifAbsent: () => [data]),
            ifAbsent: () => {
              WalletType.full: [data],
            },
          );
        }
      } catch (e, s) {
        logE(e, stackTrace: s);
      }
    }

    if (walletData.isEmpty || walletData.values.every((e) => e.isEmpty || e.values.every((e) => e.isEmpty))) {
      return false;
    }

    try {
      final appSetId = await getDeviceId();
      final fcmToken = await NotificationService.getFCMToken();

      final futures = walletData.entries.map((e) async {
        final MapEntry(key: network, value: data) = e;

        final jwtToken = await JWTService.getToken(network: network);
        final payload = jsonEncode(
          {
            'walletData': data[WalletType.full] ?? [],
            'watchOnlyWalletData': [],
            // 'watchOnlyWalletData': data[WalletType.watchOnly] ?? [],
            'device_id': appSetId,
            'fcm_token': ?fcmToken,
            'platform': Platform.operatingSystem,
            'last_active_at': DateTime.now(),
          }.toEncodeReady(),
        );

        final res = await globalDio.post(
          Config.of(network).getServerApiEndpoint('upsertWallets'),
          options: Options(headers: {'Authorization': 'Bearer $jwtToken'}),
          data: payload,
        );

        if (res.isSuccess && res.data is List) {
          if (network == Config.network) {
            for (final e in res.data) {
              final walletData = WalletMetaData.fromMap(e);
              if (!parseBool(e['is_watch_only'])) {
                walletDataMap['${walletData.uuid}_${WalletType.full.name}'] = walletData;
              }
            }
          }
          return true;
        } else if (res.data is Map) {
          ToastService.show('Wallets (${network.name}): ${res.data['error'] ?? 'Something went wrong!'}');
          logE(res.data['error'], data: network);
        }
        return false;
      });
      return (await Future.wait(futures)).every((e) => e);
    } catch (e, s) {
      logE(e, stackTrace: s, showToast: true);
    }
    return false;
  }

  static Future<String?> uploadImage(File file, String bucket, {String path = 'uploads'}) async {
    final fileName = DateTime.timestamp().millisecondsSinceEpoch;
    try {
      return await useSupabase((supabase) async {
        final filePath = await supabase.storage
            .from(bucket)
            .upload(
              '$path/$fileName', // folder + filename
              file,
            );
        return '${supabase.storage.url}/object/public/$filePath';
      });
    } catch (e, s) {
      logE(e, stackTrace: s);
    }
    return null;
  }

  static Future<bool> submitBugReport({
    required String uuid,
    required String title,
    required String description,
    List<File> images = const [],
    File? logZip,
  }) async {
    try {
      final imageUrls = await Future.wait(images.map((e) async => await uploadImage(e, 'bug-images') ?? '').toList());
      final logZipUrl = logZip != null ? await uploadImage(logZip, 'logs') : null;

      return await useSupabase((supabase) async {
            await supabase.from('bug_report').insert({
              'wallet_id': uuid,
              'title': title,
              'description': description,
              'images': imageUrls,
              'log_file_url': logZipUrl,
            });
            return true;
          }) ??
          false;
    } catch (e, s) {
      logE(e, stackTrace: s);
    } finally {
      stopLoader();
    }
    return false;
  }

  static Future<String?> generateRandomUserName() async {
    try {
      final res = await globalDio.get(Config.current.getServerApiEndpoint('getRandomUserName'));
      if (res.isSuccess && res.data['username'] != null) return parseString(res.data['username']);
    } catch (e, s) {
      logE(e, stackTrace: s);
    }
    return null;
  }

  static Future<bool> updateUserName({required Wallet wallet, required String userName}) async {
    final name = userName.trim().toLowerCase();
    if (name.isEmpty || !Regexes.username.hasMatch(name.trim().toLowerCase())) {
      ToastService.show('Invalid Username!');
      return false;
    }
    final currentUserName = wallet.metaData?.userName;
    if (currentUserName != null) {
      if (currentUserName == name) return true;
      if (AppRouter.navigatorContext.mounted) {
        final res = await showDialog<bool>(
          context: AppRouter.navigatorContext,
          builder: (context) => AlertDialog(
            title: const Text('Confirm username update'),
            content: Text.rich(
              TextSpan(
                text: 'Changing your username will release the current username ',
                children: [
                  TextSpan(
                    text: '`$currentUserName`',
                    style: const TextStyle(fontWeight: FontWeight.bold),
                  ),
                  const TextSpan(text: ', making it available for others.\n\nAre you sure you want to continue?'),
                ],
              ),
            ),
            actions: [
              TextButton(child: const Text('Cancel ❌'), onPressed: () => AppRouter.pop(false)),
              TextButton(child: const Text('Continue ✔️'), onPressed: () => AppRouter.pop(true)),
            ],
          ),
        );
        if (!(res ?? false)) return false;
      }
    }

    final res = await useSupabase((supabase) => supabase.from('wallets').select('user_name').eq('user_name', name));
    if (res != null && res.isNotEmpty) {
      ToastService.show('Username already exists');
      return false;
    }

    return upsertWallets({
      wallet: {'user_name': name},
    });
  }

  static Future<Contact?> getContact({String? userName, String? uuid, String? identityKey, Wallet? wallet}) =>
      useSupabase((supabase) async {
        if (userName == null && uuid == null && identityKey == null) return null;
        final query = supabase
            .from('wallets')
            .select('uuid, user_name, picture, about, banner, npub, wallet_chat_keys(pubkey)');
        final data =
            await (userName != null
                    ? query.eq('user_name', userName)
                    : uuid != null
                    ? query.eq('uuid', uuid)
                    : query.eq('identity_pub_key', identityKey!))
                .maybeSingle();
        if (data != null) {
          return Contact.fromSupabaseMap(data, wallet ?? selectedWallet);
        }
        return null;
      });

  static Future<String?> getSparkAddress(String userName) async {
    return useSupabase((supabase) async {
      final res = await supabase.from('wallets').select('identity_pub_key').eq('user_name', userName).maybeSingle();
      final pubKey = res?['identity_pub_key'];

      if (pubKey is String && pubKey.length == 66) {
        try {
          return Crypto.encodeSparkAddress(identityPubKeyHex: pubKey, network: Config.network);
        } catch (e, s) {
          logE(e, stackTrace: s);
        }
      }

      ToastService.show('Cannot fetch receiver address!');
      return null;
    });
  }

  static Future<void> setNotificationsStatus({required Account account, required bool status}) async {
    try {
      final appSetId = await getDeviceId();
      final walletMain = DB.allWallets
          .where((w) => w.accountId == account.id && w.network == Network.mainnet)
          .firstOrNull;

      await Future.wait([
        if (walletMain != null)
          useSupabase(
            (supabase) async => await supabase.from('devices').update({'is_disabled': !status}).match({
              'wallet_uuid': walletMain.uuid,
              'device_id': appSetId,
            }),
            network: Network.mainnet,
          ),

        if (Config.isRegtestOn)
          useSupabase((supabase) async {
            final wallet = DB.allWallets
                .where((w) => w.accountId == account.id && w.network == Network.regtest)
                .firstOrNull;
            if (wallet != null) {
              await supabase.from('devices').update({'is_disabled': !status}).match({
                'wallet_uuid': wallet.uuid,
                'device_id': appSetId,
              });
            }
          }, network: Network.regtest),
      ]);
    } catch (e, s) {
      logE(e, stackTrace: s);
    }
  }

  static Future<void> saveTxData({
    required String senderUUID,
    required String receiverLnurl,
    required String txId,

    required String memo,
  }) async {
    // fetch receiver user's uuid if passed in lnurl username
    if (receiverLnurl.isMannaUserName && receiverLnurl.getUserName != null) {
      await useSupabase((s) async {
        final res = await s.from('wallets').select('uuid').eq('user_name', receiverLnurl.getUserName!).maybeSingle();
        if (res != null) {
          final receiverUUID = parseStringN(res['uuid']);
          await s.from('transaction_memos').insert({
            'tx_id': txId,
            'sender': senderUUID,
            'receiver': receiverUUID,
            'memo': memo,
          });
        }
      });
    }
  }

  static Future<void> fetchAndCacheSettingHistory() async {
    try {
      final net = Config.network;
      return await useSupabase((supabase) async {
        final lastId = DB.settingHistory.keys.fold(0, math.max);
        final res = await supabase.from('setting_history').select().gt('id', lastId);
        for (final h in res) {
          await SettingHistoryCache.fromMap(h, net).save();
        }
      }, network: net);
    } catch (e, s) {
      logE(e, stackTrace: s);
    }
  }

  static final _linkMemoMutexMain = MutexRun();
  static final _linkMemoMutexRegtest = MutexRun();
  static Future<void> linkMemosToTransactions({required Network network}) async {
    final nonSyncedTxs = DB.allTransactions.values.where((tx) => !tx.isMemoSynced && tx.network == network).toList();
    if (nonSyncedTxs.isEmpty) return;

    return (network == Network.mainnet ? _linkMemoMutexMain : _linkMemoMutexRegtest).run(() async {
      try {
        logD('(${network.name}) Linking ${nonSyncedTxs.length} memos');
        int count = 0;
        bool shouldCacheContacts = false;
        await useSupabase((supabase) async {
          // implement batch so that we don't hit the limit of supabase
          for (int i = 0; i < nonSyncedTxs.length; i += 100) {
            final batchTxs = nonSyncedTxs.sublist(i, math.min(i + 100, nonSyncedTxs.length));
            final txIds = batchTxs.map((e) => e.txId).toList();

            final data = await supabase
                .from('transaction_memos')
                .select('tx_id, sender, receiver, memo')
                .inFilter('tx_id', txIds);

            final Map<String, ({String? memo, String sender, String? receiver})> rows = Map.fromEntries(
              data.map(
                (e) => MapEntry(parseString(e['tx_id']), (
                  sender: parseString(e['sender']),
                  receiver: parseStringN(e['receiver']),
                  memo: parseStringN(e['memo']),
                )),
              ),
            );
            for (final tx in batchTxs) {
              final row = rows[tx.txId];
              final memo = row?.memo;
              final senderUUID = row?.sender;
              final receiverUUIDOrName = row?.receiver;

              await tx.update(
                memo: (memo?.isNotEmpty ?? false) ? memo : null,
                isMemoSynced: true,
                senderUUID: Nullable(senderUUID),
                receiverUserNameOrUUID: Nullable(receiverUUIDOrName),
              );

              if (senderUUID != null && senderUUID.isUUID) {
                final wallets = DB.allWallets.where((w) => w.uuid == senderUUID);
                if (wallets.length != DB.contacts.values.where((c) => c.walletId == senderUUID).length) {
                  shouldCacheContacts = true;
                }
              }
              if (receiverUUIDOrName != null && receiverUUIDOrName.isUUID) {
                final wallets = DB.allWallets.where((w) => w.uuid == receiverUUIDOrName);
                if (wallets.length != DB.contacts.values.where((c) => c.walletId == receiverUUIDOrName).length) {
                  shouldCacheContacts = true;
                }
              }

              if (memo?.isNotEmpty == true) count++;
            }
          }
        }, network: network);

        final List<Future> saveFutures = [];
        for (final tx in DB.transactions.values.where((tx) => tx.memo.isEmpty)) {
          if (tx.inner.details == null) {
            continue;
          } else if (tx.inner.details case PaymentDetails_Lightning(:final description)) {
            saveFutures.add(tx.update(memo: description));
            count++;
          }
        }
        await Future.wait(saveFutures);

        logD('(${network.name}) Linked $count memos!');
        GlobalListener.update(stream: .account);
        if (shouldCacheContacts) {
          await cacheContacts(network: network);
        }
      } catch (e, s) {
        logE(e, stackTrace: s);
      }
    });
  }

  static Future<void> cacheContacts({Network? network}) async {
    final net = network ?? Config.network;
    if (net == Network.regtest && !Config.isRegtestOn) return;

    if (DB.activeAccounts.isEmpty) return;

    final walletIds = DB.allWallets.where((w) => w.network == net).map((e) => e.uuid).toSet();
    final allUUIds = <(String, String)>{
      ...DB.conversationsBox.values
          .where((e) => walletIds.contains(e.myUUID) && e.contact == null)
          .map((e) => (e.otherUserUUID, e.myUUID)),
      ...DB.transactions.values
          .where((tx) => walletIds.contains(tx.walletId))
          .map(
            (e) => <(String, String)>[
              if (e.senderUUID != null) (e.senderUUID!, e.walletId),
              if (e.receiverUserNameOrUUID?.isUUID == true) (e.receiverUserNameOrUUID!, e.walletId),
            ],
          )
          .fold(<(String, String)>[], (p, e) => [...p, ...e])
          .toSet(),
      ...DB.contacts.values.where((c) => c.isMannaUser).map((e) => (e.uuid, e.walletId)),
    }.toList();
    if (allUUIds.isEmpty) return;

    int cacheCount = 0;

    // Cache manna users
    await useSupabase((supabase) async {
      for (int i = 0; i < allUUIds.length; i += 300) {
        final uuidBatch = allUUIds.sublist(i, math.min(i + 300, allUUIds.length));

        final data = await supabase
            .from('wallets')
            .select('uuid, user_name, picture, about, npub, wallet_chat_keys(pubkey)')
            .inFilter('uuid', uuidBatch.map((e) => e.$1).toList());
        for (final d in data) {
          final walletId = allUUIds.where((e) => e.$1 == d['uuid']).firstOrNull?.$2;
          final wallets = DB.allWallets.where((w) => w.uuid == walletId);
          for (final wallet in wallets.isNotEmpty ? wallets : [selectedWallet]) {
            final contact = Contact.fromSupabaseMap(d, wallet);
            await contact.save();
            cacheCount++;
          }
        }
      }
    });

    // Save non-manna wallets as contacts
    final Map<String, List<Wallet>> walletMap = {};
    for (final w in DB.allWallets) {
      (walletMap[w.uuid] ??= []).add(w);
    }

    final nonMannaLNURLMap = DB.transactions.values
        .where((t) => t.receiverUserNameOrUUID?.isUserName == true)
        .map((t) => (t.receiverUserNameOrUUID!, walletMap[t.walletId]))
        .toSet();

    await Future.wait(
      nonMannaLNURLMap.map((lnurl) async {
        if (DB.contacts.values.any(
          (c) =>
              c.lnurl() == lnurl.$1 && (lnurl.$2?.any((e) => c.walletId == e.uuid && c.walletType == e.type) ?? false),
        )) {
          return;
        }
        for (final w in lnurl.$2 ?? <Wallet>[]) {
          await Contact(
            uuid: const Uuid().v5(Namespace.url.value, lnurl.$1),
            walletId: w.uuid,
            walletType: w.type,
            name: lnurl.$1.getUserName ?? '',
            lnurl: lnurl.$1,
          ).save();
          cacheCount++;
        }
      }),
    );

    logD('Cached $cacheCount Contacts');
  }

  // cache btc historic price
  static Future<void> cacheBTCPrices() async {
    await useSupabase((supabase) async {
      final timesToFetch = [...DB.transactions.values.map((e) => e.timestamp.toUtc())];

      final Set<int> existingSeconds = DB.btcPriceHistoryBox.keys.cast<int>().toSet();
      final cutoff = DateTime(2025, 11);

      timesToFetch.removeWhere((t) => t.isBefore(cutoff));
      for (final e in existingSeconds) {
        timesToFetch.removeWhere((t) => (t.millisecondsSinceEpoch ~/ 1000 - e).abs() < 60);
      }

      if (timesToFetch.isEmpty) return;

      final res = await supabase.rpc(
        'get_nearest_prices',
        params: {'target_times': timesToFetch.map((dt) => dt.toIso8601String()).toList()},
      );

      if (res is! List || res.isEmpty) return;

      final Map<int, double> newEntries = {
        for (final e in res)
          parseDateTime(e['datetime']).toUtc().millisecondsSinceEpoch ~/ 1000: parseDouble(e['price']),
      };

      await DB.btcPriceHistoryBox.putAll(newEntries);
      logD('Cached ${res.length} BTC prices!');
    });
  }

  static final Map<String, String> swapEncKeyCache = {};
  static Future<String?> getWalletSwapEncryptionKey(String walletId) async {
    if (swapEncKeyCache.containsKey(walletId)) return swapEncKeyCache[walletId];

    return useSupabase((supabase) async {
      final res = await supabase.from('wallets').select('swap_enc_pub_key').eq('uuid', walletId);
      final key = parseStringN(res.firstOrNull?['swap_enc_pub_key']);
      if (key != null) {
        swapEncKeyCache[walletId] = key;
        return key;
      }
      return null;
    });
  }
}

class DioHttpClient extends http.BaseClient {
  DioHttpClient()
    : _dio = Dio(
        BaseOptions(
          validateStatus: (status) {
            if (status == 429) {
              ToastService.show('Too many requests, please try again later!');
            }
            return true;
          },
        ),
      )..httpClientAdapter = NativeAdapter();

  final Dio _dio;

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    final body = await _getRequestBody(request);
    final dioOptions = Options(method: request.method, headers: request.headers, responseType: ResponseType.stream);

    final response = await _dio.requestUri(request.url, data: body, options: dioOptions);

    final contentLengthHeader = response.headers.value('content-length');
    final contentLength = contentLengthHeader != null ? int.tryParse(contentLengthHeader) : null;

    return http.StreamedResponse(
      response.data.stream,
      response.statusCode ?? 500,
      headers: response.headers.map.map((k, v) => MapEntry(k, v.join(','))),
      reasonPhrase: response.statusMessage,
      request: request,
      contentLength: contentLength,
    );
  }

  Future<dynamic> _getRequestBody(http.BaseRequest request) async {
    // convert underlying http.MultipartRequest to Dio's Form.
    if (request is http.MultipartRequest) {
      final formData = FormData();

      for (final e in request.fields.entries) {
        formData.fields.add(e);
      }

      for (final file in request.files) {
        formData.files.add(
          MapEntry(
            file.field,
            MultipartFile.fromBytes(
              await file.finalize().fold([], (previous, element) => [...previous, ...element]),
              filename: file.filename,
              contentType: DioMediaType.parse(file.contentType.toString()),
            ),
          ),
        );
      }
      return formData;
    } else if (request is http.Request) {
      return request.body;
    } else if (request is http.StreamedRequest) {
      return request.finalize().toList();
    } else {
      return null;
    }
  }
}
