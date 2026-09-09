import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;

import 'package:convert/convert.dart';
import 'package:crypto/crypto.dart';
import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:manna/app_state.dart';
import 'package:manna/config.dart';
import 'package:manna/globals.dart';
import 'package:manna/models/account.dart';
import 'package:manna/models/bolt12_offer.dart';
import 'package:manna/models/contact.dart';
import 'package:manna/models/misc.dart';
import 'package:manna/models/setting_history_cache.dart';
import 'package:manna/models/swap.dart';
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
import 'package:uuid/uuid.dart';
import 'package:http/http.dart' as http;

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
          includeErrorInToast: false,
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
                content: Text(message),
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
    await cacheBolt12Offers();

    await Future.wait([
      linkMemosToTransactions(network: Network.mainnet),
      if (Config.isRegtestOn) linkMemosToTransactions(network: Network.regtest),
    ]);

    await Future.wait([
      fetchCompletedLNURLSwaps(network: Network.mainnet),
      if (Config.isRegtestOn) fetchCompletedLNURLSwaps(network: Network.regtest),
    ]);
    await Future.wait([
      cacheSwaps(network: Network.mainnet),
      if (Config.isRegtestOn) cacheSwaps(network: Network.regtest),
    ]);
    await pushCompletedSwaps();

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

  static Future<int?> getSwapIndex(Wallet wallet) async {
    if (wallet.type == WalletType.watchOnly) {
      final row = await useSupabase(
        (supabase) async =>
            supabase.from('watch_only_wallets').select('swap_index').eq('wallet_uuid', wallet.uuid).maybeSingle(),
        network: wallet.network,
      );
      if (row != null && row['swap_index'] != null) return parseInt(row['swap_index']);
    }

    final row = await useSupabase(
      (supabase) async => supabase.from('wallets').select('swap_index').eq('uuid', wallet.uuid).maybeSingle(),
      network: wallet.network,
    );
    if (row != null && row['swap_index'] != null) return parseInt(row['swap_index']);
    return null;
  }

  static Future<void> syncWalletData({Network? network}) async {
    final Map<Network, Set<String>> activeFullWalletIds = {};
    final Map<Network, Set<String>> activeWoWalletIds = {};
    final activeAccountIds = DB.activeAccounts.map((e) => e.id).toSet();
    for (final w in DB.allWallets) {
      if (!activeAccountIds.contains(w.accountId)) continue;
      if (w.network == Network.regtest && !Config.isRegtestOn) continue;

      if (w.type == WalletType.full) {
        (activeFullWalletIds[w.network] ??= {}).add(w.uuid);
      } else if (w.type == WalletType.watchOnly) {
        (activeWoWalletIds[w.network] ??= {}).add(w.uuid);
      }
    }

    if (network != null) {
      activeFullWalletIds.removeWhere((key, value) => key != network);
      activeWoWalletIds.removeWhere((key, value) => key != network);
    }

    if (activeFullWalletIds.isEmpty && activeWoWalletIds.isEmpty) return;

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
                  .select('uuid, swap_index, use_trusted_lnurl, user_name, bolt11_short_desc, about, picture, banner')
                  .inFilter('uuid', e.value.toList());
              for (final e in parseList(rows, (e) => WalletMetaData.fromMap(e))) {
                walletDataMap['${e.uuid}_${WalletType.full.name}'] = e;
              }
            }, network: e.key),

      if (activeWoWalletIds.isNotEmpty)
        for (final e in activeWoWalletIds.entries)
          if (e.value.isNotEmpty)
            useSupabase((supabase) async {
              final rows = await supabase
                  .from('wallets')
                  .select(
                    'uuid, user_name, bolt11_short_desc, about, picture, banner, wo_swap_index: watch_only_wallets(swap_index), use_trusted_lnurl',
                  )
                  .eq('watch_only_wallets.device_id', deviceId)
                  .inFilter('uuid', e.value.toList());
              for (final e in parseList(rows, (e) => WalletMetaData.fromMapWO(e))) {
                walletDataMap['${e.uuid}_${WalletType.watchOnly.name}'] = e;
              }
            }, network: e.key),
    ]);

    // update local state of use_trusted_lnurl if it changed on other devices.
    final trustMinimizedLNURLAccounts = AppState.trustMinimizedLNURLAccounts;
    for (final MapEntry(key: wId, value: e) in walletDataMap.entries) {
      final idSplit = wId.split('_');
      final w = DB.allWallets.where((w) => w.uuid == idSplit[0] && w.type.name == idSplit[1]).firstOrNull;
      if (w == null) continue;

      if (e.useTrustedLNURL) {
        trustMinimizedLNURLAccounts.remove(w.accountId);
      } else {
        trustMinimizedLNURLAccounts.add(w.accountId);
      }
    }
    AppState.trustMinimizedLNURLAccounts = trustMinimizedLNURLAccounts.toList();

    GlobalListener.update(stream: .account);

    // account : data to update
    unawaited(
      upsertWallets({
        if (network != null)
          ...await getRecycledLNURLPool(network)
        else ...{
          ...await getRecycledLNURLPool(Network.mainnet),
          if (Config.isRegtestOn) ...await getRecycledLNURLPool(Network.regtest),
        },
      }),
    );

    // Update notification token
    final activeWalletIds = Map.of(activeFullWalletIds);
    for (final e in activeWoWalletIds.entries) {
      (activeWalletIds[e.key] ??= {}).addAll(e.value);
    }
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
        final swapEncPubKey = (await Crypto.getSwapEncryptionKey(
          swapMnemonic: await wallet.getSwapMnemonic(),
        ))?.publicKey;

        final payload = {
          ...data,

          'uuid': wallet.uuid,
          'wallet_xpub': wallet.xpub,
          if (swapEncPubKey != null) 'swap_enc_pub_key': hex.encode(swapEncPubKey),
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
        } else if (wallet.type == WalletType.watchOnly) {
          walletData.update(
            wallet.network,
            (value) => value..update(WalletType.watchOnly, (value) => value..add(payload), ifAbsent: () => [payload]),
            ifAbsent: () => {
              WalletType.watchOnly: [payload],
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
            'watchOnlyWalletData': data[WalletType.watchOnly] ?? [],
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
              if (parseBool(e['is_watch_only'])) {
                walletDataMap['${walletData.uuid}_${WalletType.watchOnly.name}'] = walletData;
              } else {
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

  static Future<void> cacheBolt12Offers() async {
    final Map<Network, List<Wallet>> wallets = {};
    final activeAccountIds = DB.activeAccounts.map((e) => e.id).toSet();
    for (final w in DB.allWallets) {
      if (!activeAccountIds.contains(w.accountId)) continue;
      if (w.network == Network.regtest && !Config.isRegtestOn) continue;

      (wallets[w.network] ??= []).add(w);
    }
    if (wallets.isEmpty) return;

    final trustMinimizedBolt12Accounts = AppState.trustMinimizedBolt12Accounts;

    await Future.wait([
      for (final e in wallets.entries)
        if (e.value.isNotEmpty)
          useSupabase((supabase) async {
            final rows = await supabase
                .from('bolt12_offers')
                .select('wallet_id, is_watch_only, offer, signing_key')
                .inFilter('wallet_id', e.value.map((e) => e.uuid).toList());
            for (final row in rows) {
              final offerStr = parseString(row['offer']);
              if (offerStr.trim().isEmpty) continue;

              final w = e.value
                  .where(
                    (w) =>
                        w.uuid == parseString(row['wallet_id']) &&
                        (parseBool(row['is_watch_only']) ? w.type == WalletType.watchOnly : w.type == WalletType.full),
                  )
                  .firstOrNull;
              if (w == null) continue;

              try {
                final signingKeyPair = await (await MasterSwapKey.fromMnemonic(
                  mnemonic: await w.getSwapMnemonic(),
                  network: w.network,
                )).getBolt12SigningKey(index: 0);
                final offer = Bolt12Offer(
                  walletId: w.uuid,
                  walletType: w.type,
                  offer: offerStr,
                  signingKey: signingKeyPair,
                );
                if (DB.bolt12Offers[offer.id] == null) {
                  await offer.save();
                }

                if (parseString(row['signing_key']).trim().isEmpty) {
                  trustMinimizedBolt12Accounts.add(w.accountId);
                } else {
                  trustMinimizedBolt12Accounts.remove(w.accountId);
                }
              } catch (e, s) {
                logE(e, stackTrace: s);
              }
            }
            AppState.trustMinimizedBolt12Accounts = trustMinimizedBolt12Accounts.toList();
          }, network: e.key),
    ]);
  }

  static Future<bool> upsertBolt12Offers(List<Bolt12Offer> offers) async {
    if (offers.isEmpty) return false;

    final trustMinimizedBolt12Accounts = AppState.trustMinimizedBolt12Accounts;
    final Map<Network, List<dynamic>> offerData = {};
    for (final offer in offers) {
      try {
        final wallet = DB.allWallets.where((w) => w.uuid == offer.walletId && w.type == offer.walletType).firstOrNull;
        if (wallet == null) continue;
        if (wallet.network == Network.regtest && !Config.isRegtestOn) continue;

        U8Array32? privateKey;
        if (wallet.type == WalletType.full) {
          privateKey = await getDerivationPrivKey(
            accountId: wallet.accountId,
            derivationPath: '${liquidDerivationPath(network: wallet.network)}/2',
          );
        }

        final payload = {
          'wallet_id': offer.walletId,
          'is_watch_only': wallet.type == WalletType.watchOnly,
          'offer': offer.offer,
          if (!trustMinimizedBolt12Accounts.contains(offer.wallet?.accountId))
            'signing_key': offer.signingKey.secretKey.toHexString,
          'timestamp': DateTime.now().millisecondsSinceEpoch,
        };

        if (privateKey != null) {
          final signature = await Crypto.secp256K1Sign(
            privKey: privateKey,
            message: utf8.encode(sortedJsonEncode(payload)),
            returnDer: false,
            preHash: true,
          );
          (offerData[wallet.network] ??= []).add({...payload, 'signature': signature.toHexString});
        }
      } catch (e, s) {
        logE(e, stackTrace: s);
      }
    }

    if (offerData.isEmpty) return false;
    try {
      final futures = offerData.entries.map((e) async {
        final MapEntry(key: network, value: offerData) = e;
        final res = await globalDio.post(
          Config.of(network).getServerApiEndpoint('upsertBolt12Offers'),
          options: Options(headers: {'Authorization': 'Bearer ${await JWTService.getToken(network: network)}'}),
          data: jsonEncode({'offers': offerData}.toEncodeReady()),
        );
        if (res.isSuccess) {
          return true;
        } else if (res.data is Map) {
          ToastService.show('Bolt12 (${network.name}): ${res.data['error'] ?? 'Something went wrong!'}');
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

  // returns wallet data map to update after recycling lnurl pool
  static Future<Map<Wallet, Map<String, dynamic>>> getRecycledLNURLPool(Network network) async {
    if (network == Network.regtest && !Config.isRegtestOn) return {};

    final Map<Wallet, Map<String, dynamic>> walletData = {};

    for (final account in DB.activeAccounts) {
      try {
        final wallet = DB.allWallets.where((w) => w.accountId == account.id && w.network == network).firstOrNull;
        if (wallet == null) continue;
        final liquidWallet = wallet.liquidWollet;
        if (liquidWallet == null) continue;

        // generate address pool
        final Map<int, String> addressPool = {};
        int? lastUsedIndex;
        for (int i = 0; i < 50; i++) {
          if (lastUsedIndex == null) {
            final a = await liquidWallet.addressLastUnused();
            lastUsedIndex = a.index;
            addressPool[a.index ?? 0] = a.confidential;
          } else {
            final a = await liquidWallet.address(index: ++lastUsedIndex);
            addressPool[a.index ?? 0] = a.confidential;
          }
        }

        // generate lnurl pool based on swap index while passing the address pool for signatures
        List<LnurlPoolEntry>? lnurlPool;
        final swapMnemonics = await wallet.getSwapMnemonic();
        int swapIndex = wallet.metaData?.swapIndex ?? 0;
        final lnurlIndices = List.generate(15, (_) => swapIndex++);
        if (lnurlIndices.length > addressPool.length) {
          throw Exception('address pool and lnurl pool panic');
        }

        lnurlPool = await Crypto.generateLnurlPool(
          swapMnemonics: swapMnemonics,
          network: network,
          indices: Uint64List.fromList(lnurlIndices),
          addresses: addressPool.entries.map((e) => (e.key.bigInt, e.value)).take(lnurlIndices.length).toList(),
        );

        walletData[wallet] = {
          'address_pool': addressPool.entries.map((e) => {'i': e.key, 'a': e.value}).toList(),
          'lnurl_pool': lnurlPool.map((e) => e.toUploadMap()).nonNulls.toList(),

          if (account.chatKeyPair != null) 'chat_pubkey': base64Encode(account.chatKeyPair!.publicKey),
          if (account.nsec != null) 'npub': account.nsec!.nsecToNpub,
        };
      } catch (e, s) {
        logE(e, stackTrace: s);
      }
    }
    return walletData;
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

  static Future<Contact?> getContact({String? userName, String? uuid, Wallet? wallet}) => useSupabase((supabase) async {
    if (userName == null && uuid == null) return null;
    final query = supabase
        .from('wallets')
        .select('uuid, user_name, picture, about, banner, npub, wallet_chat_keys(pubkey)');
    final data = await (userName != null ? query.eq('user_name', userName) : query.eq('uuid', uuid!)).maybeSingle();
    if (data != null) {
      return Contact.fromSupabaseMap(data, wallet ?? selectedWallet);
    }
    return null;
  });

  static Future<String?> getWalletLiquidAddress(String userName) async {
    return useSupabase((supabase) async {
      final res = await supabase
          .from('wallets')
          .select('wallet_xpub, addressEntry: address_pool->0')
          .eq('user_name', userName)
          .maybeSingle();
      if (res != null && res['wallet_xpub'] != null && res['addressEntry'] != null) {
        final xpub = parseString(res['wallet_xpub']);
        final address = parseString(res['addressEntry']?['a']);
        final addressIndex = parseInt(res['addressEntry']?['i']);

        if (await Crypto.validateLiquidAddress(
          xpub: xpub,
          address: address,
          index: addressIndex,
          network: Config.network,
        )) {
          return address;
        } else {
          ToastService.show('Cannot verify receiver address!');
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

        useSupabase((supabase) async {
          if (Config.isRegtestOn) {
            final wallet = DB.allWallets
                .where((w) => w.accountId == account.id && w.network == Network.regtest)
                .firstOrNull;
            if (wallet != null) {
              await supabase.from('devices').update({'is_disabled': !status}).match({
                'wallet_uuid': wallet.uuid,
                'device_id': appSetId,
              });
            }
          }
        }, network: Network.regtest),
      ]);
    } catch (e, s) {
      logE(e, stackTrace: s);
    }
  }

  static Future<void> saveTxData({
    required String txId,
    required String senderUUID,
    required String? receiverLnurl,
    required int amount,
    required List<int> addressIndexes,
    required String? note,
    required bool sendNotification,
  }) async {
    String? receiverUUID = receiverLnurl;
    // fetch receiver user's uuid if passed in lnurl username
    if (receiverLnurl != null && receiverLnurl.isMannaUserName && receiverLnurl.getUserName != null) {
      final res = await useSupabase(
        (s) => s.from('wallets').select('uuid').eq('user_name', receiverLnurl.getUserName!).maybeSingle(),
      );
      if (res != null) {
        receiverUUID = parseStringN(res['uuid']);
      }
    }

    try {
      final payload = {
        'txId': txId,
        'sender_uuid': senderUUID,
        'receiver_uuid': receiverUUID,
        'amount': amount,
        'note': note,
        'addressIndexes': addressIndexes,
        'sendNotification': sendNotification,
      };
      await globalDio.post(
        Config.current.getServerApiEndpoint('saveTxData'),
        options: Options(headers: {'Authorization': 'Bearer ${await JWTService.getToken()}'}),
        data: jsonEncode(payload),
      );
    } catch (e, s) {
      logE(e, stackTrace: s);
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

  static Future<void> registerSwapWebhook(List<Swap> swaps) => useSupabase((supabase) async {
    final fcmToken = await NotificationService.getFCMToken();
    if (fcmToken != null) {
      await supabase.from('swap_webhook').upsert([
        for (final swap in swaps) {'swap_id': swap.id, 'wallet_id': swap.walletId, 'fcm_token': fcmToken},
      ]);
    }
  });

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
                .from('transaction_data')
                .select('tx_id, note, sender, receiver')
                .inFilter('tx_id', txIds);

            final Map<String, ({String? note, String sender, String? receiver})> rows = Map.fromEntries(
              data.map(
                (e) => MapEntry(parseString(e['tx_id']), (
                  note: parseStringN(e['note']),
                  sender: parseString(e['sender']),
                  receiver: parseStringN(e['receiver']),
                )),
              ),
            );
            for (final tx in batchTxs) {
              final row = rows[tx.txId];
              final memo = row?.note ?? tx.linkedSwap?.note;
              final senderUUID = row?.sender;
              final receiverUUIDOrName = row?.receiver;

              await tx.update(
                memo: memo?.isNotEmpty == true ? memo : null,
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

  static final _cacheSwapMutexMain = MutexRun();
  static final _cacheSwapMutexRegtest = MutexRun();
  static Future<void> cacheSwaps({required Network network}) async {
    final walletIds = DB.allWallets.where((w) => w.network == network).map((w) => w.uuid).toSet();
    if (walletIds.isEmpty) return;

    return (network == Network.mainnet ? _cacheSwapMutexMain : _cacheSwapMutexRegtest).run(() async {
      try {
        final syncedSwapIds = DB.getSyncedSwapIds();
        // remove ids which doesn't exists locally
        syncedSwapIds.removeWhere((e) => DB.swaps[e] == null);
        final Set<String> newSyncedSwapIds = {};

        // Fetch already completed swaps that are not available on device
        final rows = await useSupabase(
          (supabase) =>
              supabase.rpc('get_swaps', params: {'wallet_ids': walletIds.toList(), 'swap_ids': syncedSwapIds}),
          network: network,
        );

        if (rows is List && rows.isNotEmpty) {
          final futures = rows.map((e) async {
            final swap = await SwapExtension.fromSupabaseRow(e, network);
            if (swap != null) {
              await swap.save();
              newSyncedSwapIds.add(swap.id);
            }
          });
          await Future.wait(futures);

          if (newSyncedSwapIds.isNotEmpty) {
            await DB.setSyncedSwapIds({...DB.getSyncedSwapIds(), ...newSyncedSwapIds}.toList());
            logD('(${network.name}) Fetched ${newSyncedSwapIds.length} swaps!');
            GlobalListener.update(stream: .account);
          }
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
      final timesToFetch = [
        ...DB.transactions.values.map((e) => e.txTimestamp.toUtc()),
        ...DB.swaps.values.map((e) => e.creationTimeUTC.toUtc()),
      ];

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

  static final pushSwapMutex = MutexRun();
  static Future<void> pushCompletedSwaps() async {
    // save encrypted completed swaps in backend.
    await pushSwapMutex.run(() async {
      try {
        final alreadyPushedSwaps = DB.getSyncedSwapIds();

        final Map<Network, List<Swap>> nonSyncedSwaps = {};
        final activeAccountIds = DB.activeAccounts.map((acc) => acc.id).toSet();
        final activeWalletMetaIds = DB.allWallets
            .where((w) => activeAccountIds.contains(w.accountId))
            .map((w) => '${w.uuid}_${w.type.index}');
        for (final swap in DB.swaps.values.where(
          (e) => e.isClosed && isFinalSwapState(swap: e).$2 && !alreadyPushedSwaps.contains(e.id),
        )) {
          if (!activeWalletMetaIds.contains('${swap.walletId}_${swap.walletType.index}')) continue;
          if (swap.network == Network.regtest && !Config.isRegtestOn) continue;

          (nonSyncedSwaps[swap.network] ??= []).add(swap);
        }
        if (nonSyncedSwaps.isEmpty) return;

        int count = 0;
        for (final MapEntry(key: network, value: swaps) in nonSyncedSwaps.entries) {
          final swapData = (await Future.wait(
            swaps.map((e) => e.encryptForSupabase()),
          )).nonNulls.map((e) => e.toEncodeReady()).toList();

          final txStatsDataMap = Map.fromEntries(
            swaps.map(
              (s) => MapEntry(
                s.id,
                {
                  'swap_hash': hex.encode(sha256.convert(utf8.encode(s.id)).bytes),
                  'amount': s.sendAmount,
                  // 1: ln->lbtc 2: btc->lbtc 3: lbtc->ln 4: lbtc->btc
                  'type': s.submarine != null
                      ? 3
                      : s.reverse != null
                      ? 1
                      : s.chain != null
                      ? s.chain!.direction == ChainSwapDirection.btcToLbtc
                            ? 2
                            : 4
                      : null,
                  'created_at': DateTime.fromMillisecondsSinceEpoch(s.creationTime.i),
                }.toEncodeReady(),
              ),
            ),
          );

          try {
            await useSupabase((supabase) async {
              for (int i = 0; i < swapData.length; i += 10) {
                final List<Map<String, dynamic>> batchData = swapData.sublist(i, math.min(i + 10, swapData.length));
                final swapIds = (await supabase.from('mobile_swaps').upsert(batchData).select('id'))
                    .map((e) => parseString(e['id']))
                    .toSet();
                await DB.setSyncedSwapIds({...DB.getSyncedSwapIds(), ...swapIds}.toList());
                count += swapIds.length;

                await supabase
                    .from('tx_stats')
                    .insert(swapIds.map((swapId) => txStatsDataMap[swapId]).nonNulls.toList());
              }
            }, network: network);
          } catch (_) {}
        }

        if (count > 0) {
          logI('Pushed $count swaps!');
        }
      } catch (_) {}
    });
  }

  static Future<void> fetchPendingLNURLSwaps(Network network) async {
    final token = await JWTService.getToken(network: network);
    if (token == null) return;

    logD('($network) fetching LNURL swaps');
    try {
      final fetchedSwaps = await LnurlUtil.fetchLnurlSwaps(
        liquidWallets: await Future.wait(
          DB.allWallets.where((w) => w.network == network).map((e) => e.getLiquidWallet()),
        ),
        network: network,
        apiConfig: Config.apiConfig,
        jwtToken: token,
        deviceId: await getDeviceId(),
      );

      if (fetchedSwaps.isNotEmpty) {
        await Future.wait(fetchedSwaps.map((e) => e.save()));
        await registerSwapWebhook(fetchedSwaps);

        logD('Fetched ${fetchedSwaps.length} LNURL swaps!');
        unawaited(upsertWallets(await getRecycledLNURLPool(network)));
      }
    } catch (e, s) {
      logE(e, stackTrace: s);
    }
  }

  // These are the trusted swaps
  static Future<void> fetchCompletedLNURLSwaps({Network? network}) async {
    final net = network ?? Config.network;
    if (net == Network.regtest && !Config.isRegtestOn) return;

    final wallets = DB.allWallets.where((w) => w.network == net && w.type == WalletType.full);
    if (wallets.isEmpty) return;

    final token = await JWTService.getToken(network: net);
    if (token == null) return;

    int savedSwapCount = 0;
    try {
      final trustedSwapIndexes = Map.fromEntries(
        (await useSupabase(
              (supabase) async => supabase
                  .from('wallets')
                  .select('uuid, trusted_swap_index')
                  .inFilter('uuid', wallets.map((e) => e.uuid).toList()),
              network: net,
            ))?.map((e) => MapEntry(parseString(e['uuid']), parseIntN(e['trusted_swap_index']) ?? -2)) ??
            <MapEntry<String, int>>[],
      );
      final initialSwapIndexes = Map.of(trustedSwapIndexes);

      final res = await globalDio.get(
        Config.of(net).getServerApiEndpoint('getCompletedLNURLSwaps'),
        options: Options(headers: {'Authorization': 'Bearer $token'}),
      );

      if (res.isSuccess && res.data['lnurlSwaps'] is List) {
        for (final row in res.data['lnurlSwaps']) {
          try {
            final swapId = parseStringN(row['swap_id']);
            if (swapId == null || swapId.isEmpty) continue;
            if (DB.swaps[swapId] != null) continue;

            final wallet = wallets.where((w) => w.uuid == parseString(row['wallet_id'])).firstOrNull;
            if (wallet == null) continue;
            final swapIndex = (trustedSwapIndexes[wallet.uuid] ?? -1) - 1;
            final claimData = row['claim_data'];

            final invoice = parseStringN(row['invoice']);
            if (invoice == null) continue;
            DecodedInvoice? invoiceData;
            try {
              invoiceData = decodeBolt11Invoice(invoice: invoice);
            } catch (_) {}

            try {
              invoiceData ??= decodeBolt12Invoice(invoice: invoice);
            } catch (e) {
              logE(e);
            }
            if (invoiceData == null) {
              throw Exception('Missing invoice');
            }

            final sendAmount = (invoiceData.msats.i / 1000).toInt();
            final onChainAmount = parseIntN(claimData?['onChainAmount']) ?? 0;
            final claimFee = parseIntN(claimData?['claimFee']) ?? 0;
            final boltzFee = parseIntN(claimData?['boltzFee']) ?? 0;
            final receiveAmount = onChainAmount - claimFee;
            final txId = parseString(row['claim_tx_id']);
            final note = parseStringN(claimData?['note']);

            await Swap(
              id: swapId,
              walletId: wallet.uuid,
              walletType: wallet.type,
              index: swapIndex,
              network: net,
              sendAmount: sendAmount.bigInt,
              receiveAmount: receiveAmount.bigInt,
              creationTime: parseDateTime(row['created_at']).millisecondsSinceEpoch.bigInt,
              completionTime: parseDateTimeN(row['completed_at'])?.millisecondsSinceEpoch.bigInt,
              boltzFee: boltzFee.bigInt,
              claimFee: claimFee.bigInt,
              lockupFee: (sendAmount - onChainAmount - boltzFee).bigInt,
              swapStatus: parseString(row['status']),
              note: note,
              preimage: await PreImage.fromString(preimage: parseString(claimData?['preImage'])),
              reverse: ReverseSwap(
                to: Chain.liquid,
                keys: KeyPair.fromPrivateKey(
                  privateKey: U8Array32(parseString(claimData?['claimPrivateKey']).hexStringToBytes),
                ),
                swapCreateRes: ReverseResponse(
                  invoice: invoice,
                  swapTree: claimData?['swapTree'] is Map
                      ? SwapTreeExtension.fromMap(claimData?['swapTree'])
                      : SwapTreeExtension.fromMap(jsonDecode(parseString(claimData?['swapTree']))),
                  lockupAddress: parseString(claimData?['lockupAddress']),
                  refundPublicKey: parseString(claimData?['refundPublicKey']),
                  timeoutBlockHeight: parseInt(claimData?['timeoutBlockHeight']),
                  onchainAmount: onChainAmount.bigInt,
                  blindingKey: parseString(claimData?['blindingKey']),
                ),
              ),
              transactions: [
                if (txId.isNotEmpty)
                  SwapTransaction(txId: txId, chain: Chain.liquid, txType: SwapTransactionType.claim, isUser: true),
              ],
              isExchangeSwap: false,
            ).save();

            trustedSwapIndexes.update(wallet.uuid, (value) => value - 1, ifAbsent: () => -2);
            savedSwapCount++;

            if (note != null) {
              await DB.transactions[IdWithWallet(walletId: wallet.uuid, id: txId)]?.update(
                memo: note,
                isMemoSynced: true,
              );
            }
          } catch (e, s) {
            logE(e, stackTrace: s);
          }
        }
      }

      if (savedSwapCount > 0) {
        logD('[${net.name}] Fetched $savedSwapCount completed LNURL swaps!');

        // update index in db to use later
        final payload = Map.fromEntries(
          trustedSwapIndexes.entries.where((e) => initialSwapIndexes[e.key] != e.value).map((e) {
            final w = wallets.where((w) => w.uuid == e.key).firstOrNull;
            if (w == null) return null;
            return MapEntry(w, {'trusted_swap_index': e.value});
          }).nonNulls,
        );
        if (payload.isNotEmpty) {
          await upsertWallets(payload.cast<Wallet, Map<String, dynamic>>());
        }
        await pushCompletedSwaps();
      }
    } catch (e, s) {
      logE(e, stackTrace: s);
    }
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
