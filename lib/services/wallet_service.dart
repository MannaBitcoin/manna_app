import 'dart:async';
import 'dart:io';
import 'dart:math' as math;

import 'package:manna/config.dart';
import 'package:manna/globals.dart';
import 'package:manna/models/account.dart';
import 'package:manna/models/chat_message.dart';
import 'package:manna/models/misc.dart';
import 'package:manna/models/transaction.dart';
import 'package:manna/models/wallet.dart';
import 'package:manna/router.dart';
import 'package:manna/screens/splash_screen.dart';
import 'package:manna/services/chat_service.dart';
import 'package:manna/services/connectivity_checker.dart';
import 'package:manna/services/db.dart';
import 'package:manna/services/db_service.dart';
import 'package:manna/services/log_service.dart';
import 'package:manna/services/nostr_service.dart';
import 'package:manna/utils/de_bouncer.dart';
import 'package:manna/utils/toast_service.dart';
import 'package:manna/utils/util.dart';
import 'package:manna/widgets/bottom sheets/new_tx_notifier_bottom_sheet.dart';
import 'package:manna/widgets/bottom sheets/receiving_tx_bottom_sheet.dart';
import 'package:manna_core/manna_core.dart' as core;
import 'package:path/path.dart' as path;
import 'package:path_provider/path_provider.dart';
import 'package:manna/models/swap.dart';
import 'package:uuid/uuid.dart';

String liquidDerivationPath({core.Network? network}) =>
    "m/84'/${(network ?? Config.network) == core.Network.mainnet ? 1776 : 1}'/0'";

class WalletService {
  // xpub : liquid wallet
  static final Map<String, core.Wallet> liquidNodes = {};

  static Timer? _syncTimer, _intermittentSyncTimer;

  static Future<bool> initAllWallets() async {
    final activeWalletsIds = DB.activeAccounts.map((e) => e.id).nonNulls.toSet();
    final activeWalletsXpub = DB.allWallets
        .where((w) => activeWalletsIds.contains(w.accountId))
        .map((e) => e.xpub)
        .toSet();
    for (final xpub in activeWalletsXpub) {
      liquidNodes[xpub]?.dispose();
    }

    selectAccount();
    for (final xpub in activeWalletsXpub) {
      await liquidInit(xpub: xpub);
    }

    disposeNonActiveWallets();
    startPeriodicSync();
    return activeWalletsXpub.every((xpub) => liquidNodes.containsKey(xpub));
  }

  static Future<String> getLWKPath() async {
    final appDir = await getApplicationSupportDirectory();
    String lwkPath = path.join(appDir.path, 'lwk');

    if (Platform.isIOS) {
      try {
        final oldDir = Directory(lwkPath);
        if (oldDir.existsSync()) {
          final newDirPath = await getAppGroupPath(subPath: 'lwk');
          if (newDirPath != null) {
            final newDir = Directory(newDirPath);
            if (!newDir.existsSync()) {
              await newDir.create(recursive: true);
              copyDirectory(oldDir, newDir);
              oldDir.deleteSync(recursive: true);
            }
            lwkPath = newDir.path;
          }
        }
      } catch (e, s) {
        logE(e, stackTrace: s);
      }
    }
    return lwkPath;
  }

  static Future<bool> liquidInit({required String xpub, bool waitForSync = false, int depth = 1}) async {
    final wallets = DB.allWallets.where((w) => w.xpub == xpub);
    if (wallets.isEmpty) return false;

    if (depth > 2) {
      await Future.wait(wallets.map((e) => e.update(isCorrupted: true)));
      return false;
    }

    final w = wallets.first;
    if (w.descriptor.isEmpty) return false;

    try {
      final wollet = await core.Wallet.init(
        descriptorStr: w.descriptor,
        network: w.network,
        dbpath: await getLWKPath(),
      );
      liquidNodes[w.xpub] = wollet;

      if (w.isCorrupted) {
        await Future.wait(wallets.map((e) => e.update(isCorrupted: false)));
      }

      if (waitForSync) await sync(xpub: xpub);
      if (!ReceivingTxService.shouldShowBottomSheet) {
        ReceivingTxService.shouldShowBottomSheet = true;
        GlobalListener.update(stream: .receivingTx);
      }
      if (!NewReceivedTxService.shouldShowBottomSheet) {
        NewReceivedTxService.shouldShowBottomSheet = true;
        GlobalListener.update(stream: .receivedTx);
      }
      return true;
    } on core.LwkError catch (e, s) {
      logE(e, stackTrace: s);
      // cache is mangled, delete the cache and try again
      await deleteWalletCache(descriptor: w.descriptor, network: w.network);
      return liquidInit(xpub: w.xpub, depth: depth + 1);
    } catch (e, s) {
      logE(e, stackTrace: s);
    }
    return false;
  }

  static Iterable<IdWithWallet> getNewTxIds() =>
      (DB.generalBox.get('newTxIds') as List? ?? []).map((e) => IdWithWallet.fromString(e));

  static Future<void> setNewTxIds(List<IdWithWallet> newTxIds) =>
      DB.generalBox.put('newTxIds', newTxIds.map((e) => e.toString()).toList());

  // mutex
  static Future<void> partialSync({required String xpub, bool isPreSync = false}) async {
    final wollet = liquidNodes[xpub];
    if (wollet == null) return;

    final network = wollet.network();
    final xpubWallets = DB.allWallets.where((w) => w.xpub == xpub);
    try {
      // update wallet balance
      final balance =
          (await wollet.balances()).where((e) => e.assetId == Config.lBtcId(network: network)).firstOrNull?.value ?? 0;
      if (balance != 0 || !isPreSync) {
        await Future.wait(xpubWallets.map((e) => e.update(balance: balance)));
      }
    } catch (e, s) {
      logE(e, stackTrace: s);
    }

    try {
      final liquidTransactions = await wollet.txs();
      final List<Future> saveFutures = [];

      if (liquidTransactions.isNotEmpty) {
        final List<IdWithWallet> newTxs = [];
        for (final w in xpubWallets) {
          for (final tx in liquidTransactions) {
            final amount =
                tx.balances.where((e) => e.assetId == Config.lBtcId(network: network)).firstOrNull?.value ?? 0;
            final existing = DB.allTransactions[IdWithWallet(walletId: w.uuid, id: tx.txid)];

            if (existing != null) {
              // skip redundant updates

              if (existing.liquidTx != tx) {
                saveFutures.add(existing.update(liquidTx: Nullable(tx), amount: amount));
              } else if (existing.amount != amount) {
                saveFutures.add(existing.update(amount: amount));
              }
            } else {
              saveFutures.add(
                Transaction(
                  txId: tx.txid,
                  network: w.network,
                  walletId: w.uuid,
                  timestamp: DateTime.now(),
                  isIncoming: tx.kind.toLowerCase() == 'incoming',
                  amount: amount,
                  liquidTx: tx,
                ).save(),
              );
              newTxs.add(IdWithWallet(id: tx.txid, walletId: w.uuid));
            }
          }
        }
        await Future.wait(saveFutures);
        await setNewTxIds({...getNewTxIds(), ...newTxs}.toList());
      }
    } catch (e, s) {
      logE(e, stackTrace: s);
    }

    if (getNewTxIds().isNotEmpty) {
      bool isAnyNewReceived = false;

      final Set<IdWithWallet> newReceivedTxIds = {};
      for (final txId in getNewTxIds()) {
        final transaction = DB.allTransactions[txId];
        if (transaction == null) continue;

        if (transaction.isIncoming) {
          isAnyNewReceived = true;
          for (final w in xpubWallets) {
            final acc = DB.fullWallets[w.uuid]?.account ?? DB.woWallets[w.uuid]?.account;
            if (acc == null) continue;
            // check if tx is either not confirmed (new)
            // skipping all tx noted within one minute of wallet creation to skip existing transactions.
            if (transaction.confirmationTimestamp == null ||
                (
                // transaction.confirmDateTime!.isAfter(DateTime.now().subtract(const Duration(days: 1))) &&
                transaction.confirmationTimestamp!.isAfter(
                  acc.createdAtUTC.toLocal().add(const Duration(minutes: 1)),
                ))) {
              newReceivedTxIds.add(IdWithWallet(id: transaction.txId, walletId: w.uuid));
            }
          }
        }
      }
      await NewReceivedTxService.add(newReceivedTxIds.toList());
      await setNewTxIds([]);
      if (isAnyNewReceived) {
        await DbService.fetchCompletedLNURLSwaps(
          network: network,
        ).then((_) => DbService.linkMemosToTransactions(network: network));
      } else {
        await DbService.linkMemosToTransactions(network: network);
      }
      await DbService.cacheBTCPrices();
    }

    if (NewReceivedTxService.getNewReceivedTxs().isNotEmpty) {
      // resync the wallet in db to update address pool and index.
      await DbService.syncWalletData(network: network);
    }
  }

  static final Map<String, MutexRun> syncMutex = {};
  static final Map<String, bool> syncingState = {};
  // force sync skips the mutex:
  static Future<void> sync({required String xpub, bool force = false}) async {
    final wollet = liquidNodes[xpub];
    if (wollet == null) return;

    if (!globalState.value.isAppForeground) return;
    if (!await ConnectivityChecker.checkConnection()) return;

    syncMutex[xpub] ??= MutexRun();

    final wallets = DB.allWallets.where((w) => w.xpub == xpub);
    return syncMutex[xpub]!.run(() async {
      syncingState[xpub] = true;
      for (final accId in wallets.map((e) => e.accountId).toSet()) {
        GlobalListener.update(stream: .account, data: accId);
      }
      await partialSync(xpub: xpub, isPreSync: true);
      try {
        final electrumUrl = Config.of(wollet.network()).liquid.electrum;
        if (electrumUrl.isNotEmpty) {
          await wollet.sync_(electrumUrl: electrumUrl);
        }
      } catch (e, s) {
        logE(e, stackTrace: s);
        if (e is core.LwkError && e.msg.contains('UpdateHeightTooOld')) {
          for (final w in wallets) {
            // cache is mangled, delete the cache and try again
            await deleteWalletCache(descriptor: w.descriptor, network: w.network);
          }
          closeWallet(xpub: xpub);
          await liquidInit(xpub: xpub, waitForSync: true);
        }
      }
      await partialSync(xpub: xpub);
      syncingState[xpub] = false;
      for (final accId in wallets.map((e) => e.accountId).toSet()) {
        GlobalListener.update(stream: .account, data: accId);
      }
    });
  }

  static Future<void> syncAllWallets() => Future.wait(liquidNodes.keys.map((xpub) => sync(xpub: xpub)));

  // TransactionIdWithWallet string: counter
  static Map<String, int> syncCount = {};
  static void startPeriodicSync() {
    syncAllWallets().then((_) {
      stopPeriodicSync();
      _syncTimer = Timer.periodic(Config.liquidSyncInterval, (timer) {
        final activeXpubs = DB.activeAccounts.map((e) => e.currentWallet.xpub).toSet();
        Future.wait(
          liquidNodes.keys.map((xpub) async {
            if (activeXpubs.contains(xpub)) {
              await sync(xpub: xpub);
            }
          }),
        );
      });

      _intermittentSyncTimer?.cancel();
      _intermittentSyncTimer = null;
      _intermittentSyncTimer = Timer.periodic(const Duration(seconds: 5), (timer) async {
        await ReceivingTxService.cleanUp();

        final txsToSync = Map.fromEntries({
          ...DB.allTransactions.values.where((e) => e.liquidTx == null).map((e) => MapEntry(e.txId, e.walletId)),
          ...ReceivingTxService.getReceivingTxs()
              .map((e) => e.txId == null && e.walletId == null ? null : MapEntry(e.txId, e.walletId))
              .nonNulls,
        });

        // clean up synced txs counter
        final keys = txsToSync.entries
            .map((e) => IdWithWallet(id: e.key.toString(), walletId: e.value.toString()).toString())
            .toSet();
        syncCount.removeWhere((key, value) => !keys.contains(key));

        final Set<String> xpubsToSync = {};
        for (final MapEntry(key: txId, value: walletId) in txsToSync.entries) {
          final id = IdWithWallet(id: txId.toString(), walletId: walletId.toString());
          final key = id.toString();

          syncCount.update(key, (value) => value + 1, ifAbsent: () => 1);
          final count = syncCount[key];
          if (count == null) continue;

          // sync after: 5, 5, 10, 20 and 30,... seconds
          if ({1, 2, 4, 8, 14}.contains(count) || (count > 14 && (count - 14) % 6 == 0)) {
            final walletXpub = DB.allWallets.where((w) => w.uuid == walletId).firstOrNull?.xpub;
            if (walletXpub == null) continue;
            xpubsToSync.add(walletXpub);
          }
          // give up after 160 seconds
          if (count >= 32) {
            await DB.allTransactions[id]?.delete();
            syncCount.remove(key);
          }
        }

        if (xpubsToSync.isNotEmpty) {
          xpubsToSync.map((xpub) => sync(xpub: xpub));
          logD('syncing unscanned txs $syncCount');
        }
      });
    });
  }

  static void stopPeriodicSync() {
    _syncTimer?.cancel();
    _syncTimer = null;
  }

  static Future<(String?, core.DecodedPset?)> buildTx({
    required String walletId,
    required String outAddress,
    required int outAmount,
    double? fees,
    bool drain = false,
    bool isSwapLockup = false,
    bool showError = true,
  }) async {
    final wollet = liquidNodes[DB.allWallets.where((w) => w.uuid == walletId).firstOrNull?.xpub];
    if (wollet == null) return (null, null);

    try {
      final recipients = [(outAddress, BigInt.from(outAmount))];
      // Manna fees
      if (!drain && DbService.lbtcAddressForFees.isNotEmpty) {
        if (isSwapLockup) {
          // lbtc->btc/ln
          if (DbService.lbtcBtcSwapFee <= 0 &&
              DbService.lbtcLnSwapFee <= 0 &&
              outAmount >= DbService.tempSwapFeeThreshold) {
            recipients.add((
              DbService.lbtcAddressForFees,
              BigInt.from((outAmount * DbService.tempSwapFeePercent / 100).round()),
            ));
          }
        } else {
          // Regular lbtc->lbtc send manna fee
          if (outAmount >= DbService.liquidFeeThreshold) {
            recipients.add((
              DbService.lbtcAddressForFees,
              BigInt.from((outAmount * DbService.liquidFeePercent / 100).round()),
            ));
          }
        }
      }

      final pset = await wollet.buildLbtcTx(
        recipients: recipients,
        feeRate: (fees ?? DbService.estimatedLiquidFeesPPM) * 1000,
        drain: drain,
      );
      final amounts = await wollet.decodeTx(psetString: pset);
      return (pset, amounts);
    } on core.LwkError catch (e, s) {
      if (!e.msg.contains('InsufficientFunds')) {
        logE(e, stackTrace: s, showToast: showError);
      } else if (showError) {
        ToastService.show('Insufficient balance!');
      }
    } catch (e, s) {
      logE(e, stackTrace: s, showToast: showError);
    }
    return (null, null);
  }

  static Future<String?> signTx({required String walletId, required String pset}) async {
    final wallet = DB.allWallets.where((w) => w.uuid == walletId).firstOrNull;
    if (wallet == null) return null;
    final wollet = liquidNodes[wallet.xpub];
    if (wollet == null) return null;

    final mnemonic = await wallet.account.getMnemonicSentence();
    if (mnemonic == null) {
      ToastService.show('The selected wallet is watch-only, cannot spend from watch-only wallet.');
      return null;
    }

    try {
      return wollet.signTx(network: wallet.network, pset: pset, mnemonic: mnemonic);
    } catch (e, s) {
      logE(e, stackTrace: s, showToast: true);
    }
    return null;
  }

  // delete the actual files storing lwk data
  static Future<void> deleteWalletCache({required String descriptor, required core.Network network}) async {
    final walletDirPath = Platform.isIOS ? await getAppGroupPath() : (await getApplicationSupportDirectory()).path;

    final lwkWalletDirPath = await core.Wallet.getWalletFsPath(network: network, descriptor: descriptor);

    if (walletDirPath != null) {
      final walletDir = Directory(path.join(walletDirPath, 'lwk', lwkWalletDirPath));
      if (walletDir.existsSync()) {
        await walletDir.delete(recursive: true);
      }
    }
  }

  static void disposeNonActiveWallets() {
    final activeAccountIds = DB.activeAccounts.map((e) => e.id).toSet();
    final activeWalletsXpub = DB.allWallets
        .where((w) => activeAccountIds.contains(w.accountId))
        .map((e) => e.xpub)
        .toSet();
    for (final xpub in liquidNodes.keys.toList()) {
      if (!activeWalletsXpub.any((e) => e == xpub)) {
        closeWallet(xpub: xpub);
      }
    }
  }

  static void closeWallet({required String xpub}) {
    liquidNodes[xpub]?.dispose();
    liquidNodes.remove(xpub);
    syncMutex.remove(xpub);
  }

  static Future<bool> deleteAccount(String accountId) async {
    try {
      final account = DB.accounts[accountId];
      if (account == null) return false;
      startLoader();

      final wallets = DB.allWallets.where((e) => e.accountId == account.id);

      for (final w in wallets) {
        final appSetId = await getDeviceId();
        try {
          await DbService.useSupabase(
            (supabase) async =>
                await supabase.from('devices').delete().eq('wallet_uuid', w.uuid).eq('device_id', appSetId),
            network: w.network,
          );
        } catch (_) {}

        for (final t in DB.allTransactions.values.where((t) => t.walletId == w.uuid).toList()) {
          await t.delete();
        }
        for (final s in DB.swaps.values.where((t) => t.walletId == w.uuid && t.walletType == w.type).toList()) {
          await s.delete();
        }
        for (final c in DB.contacts.values.where((t) => t.walletId == w.uuid && t.walletType == w.type).toList()) {
          await c.delete();
        }
        for (final m in DB.chatBox.values.where((m) => w.uuid == m.senderId || w.uuid == m.receiverId)) {
          await m.delete();
        }
        closeWallet(xpub: w.xpub);
        await deleteWalletCache(descriptor: w.descriptor, network: w.network);
        await w.delete();
      }

      await updateConversation();
      await account.delete();

      DB.loadAllData();

      if (DB.activeAccounts.isEmpty) {
        AppRouter.replaceAll(const SplashScreen());
      } else if (account.isMainAccount) {
        await DB.activeAccounts.first.update(isMainAccount: true);
      }
      selectAccount();
      GlobalListener.update(stream: .account);
      ToastService.show('Wallet deleted successfully!');
    } finally {
      stopLoader();
    }
    return true;
  }

  /// creates account with 2 wallets for mainnet and regtest env.
  static Future<bool> createAccount({required String accountName}) async {
    if (!await ConnectivityChecker.checkConnection()) return false;
    try {
      startLoader();
      final mnemonics = await core.Mnemonics.generate();

      final account = Account(
        id: const Uuid().v4(),
        name: accountName,
        createdAtUTC: DateTime.timestamp(),
        isMainAccount: DB.activeAccounts.isEmpty,
        isDisabled: false,
        isBackedUp: false,
        isSendAnonymously: false,
        isSendNotification: true,
        sortOrder: DB.accounts.values.map((e) => e.sortOrder).fold(-1, (p, e) => math.max(p, e)) + 1,
        mnemonicSentence: mnemonics.sentence,
        chatKeyPair: await Account.generateChatKeyPair(mnemonics),
        nsec: await NostrService.generateNsecFromSeed(mnemonics.seedBytes),
      );

      final mainDescriptor = await core.Descriptor.newConfidential(
        network: core.Network.mainnet,
        mnemonic: mnemonics.sentence,
      );
      if (DB.fullWallets.values.any((e) => e.descriptor == mainDescriptor && e.type == core.WalletType.full)) {
        ToastService.show('Wallet already exists!');
        return false;
      }

      final xpubMain = (await core.Descriptor.extractXpub(descriptorStr: mainDescriptor))?.$1;
      if (xpubMain == null) {
        ToastService.show('Failed to extract xpub!');
        return false;
      }
      final walletMain = Wallet(
        accountId: account.id,
        descriptor: mainDescriptor,
        xpub: xpubMain,
        network: core.Network.mainnet,
        type: core.WalletType.full,
      );
      await walletMain.initSwapMnemonic(
        (await core.MasterSwapKey.fromWalletMnemonic(
          walletMnemonic: mnemonics.sentence,
          network: core.Network.mainnet,
        )).toMnemonicString(),
      );

      Wallet? walletRegtest;
      if (Config.isRegtestOn) {
        final regtestDescriptor = await core.Descriptor.newConfidential(
          network: core.Network.regtest,
          mnemonic: mnemonics.sentence,
        );
        if (DB.fullWallets.values.any((e) => e.descriptor == regtestDescriptor && e.type == core.WalletType.full)) {
          ToastService.show('Wallet already exists!');
          return false;
        }
        final xpubRegtest = (await core.Descriptor.extractXpub(descriptorStr: regtestDescriptor))?.$1;
        if (xpubRegtest == null) {
          ToastService.show('Failed to extract xpub!');
          return false;
        }
        walletRegtest = Wallet(
          accountId: account.id,
          descriptor: regtestDescriptor,
          xpub: xpubRegtest,
          network: core.Network.regtest,
          type: core.WalletType.full,
        );
        await walletRegtest.initSwapMnemonic(
          (await core.MasterSwapKey.fromWalletMnemonic(
            walletMnemonic: mnemonics.sentence,
            network: core.Network.regtest,
          )).toMnemonicString(),
        );
      }

      // save temporarily
      await account.save();
      await walletMain.save();
      await walletRegtest?.save();

      final wallet = switch (Config.network) {
        core.Network.mainnet => walletMain,
        core.Network.testnet => null,
        core.Network.regtest => walletRegtest,
      };
      if (wallet == null) {
        ToastService.show('WTH');
        return false;
      }

      try {
        if (await DbService.upsertWallets({walletMain: {}, ?walletRegtest: {}})) {
          if (await liquidInit(xpub: wallet.xpub, waitForSync: true)) {
            startPeriodicSync();
            selectAccount(account.id);
            GlobalListener.update(stream: .account);
            unawaited(DbService.syncEverything());

            unawaited(ChatService.sync(walletId: wallet.uuid, entire: true));
            unawaited(ChatService.startListener());
            ToastService.show('Wallet created successfully!');
            return true;
          }
        } else {
          ToastService.show('Sorry, Its not you, its us!');
          await account.delete();
        }
      } catch (e, s) {
        logE(e, stackTrace: s, showToast: true);
        await account.delete();
      }
    } catch (e, s) {
      logE(e, stackTrace: s);
    } finally {
      stopLoader();
    }
    return false;
  }

  static Future<bool> importWatchOnlyWallet({
    required String accountName,
    required String walletDescriptor,
    bool makeMain = false,
  }) async {
    try {
      startLoader();
      globalState.update(restoreSyncProgress: 0.01);

      if (DB.woWallets.values.any((e) => e.descriptor == walletDescriptor && e.type == core.WalletType.watchOnly)) {
        ToastService.show('Wallet already exists!');
        return false;
      }

      final res = await core.Descriptor.extractXpub(descriptorStr: walletDescriptor);
      if (res == null) {
        ToastService.show('Failed to extract xpub!');
        return false;
      }
      final (xpub, derivationPath) = res;
      if ('m/$derivationPath' != liquidDerivationPath()) {
        ToastService.show('The wallet you trying to import is of different network!');
        return false;
      }

      final account = Account(
        id: const Uuid().v4(),
        name: accountName,
        createdAtUTC: DateTime.timestamp(),
        isMainAccount: makeMain || DB.accounts.isEmpty,
        isDisabled: false,
        isBackedUp: true,
        isSendAnonymously: true,
        isSendNotification: false,
        sortOrder: DB.accounts.values.map((e) => e.sortOrder).fold(-1, (p, e) => math.max(p, e)) + 1,
      );

      final wallet = Wallet(
        accountId: account.id,
        descriptor: walletDescriptor,
        xpub: xpub,
        network: Config.network,
        type: core.WalletType.watchOnly,
      );
      await wallet.initSwapMnemonic(null);
      // save temporarily
      await account.save();
      await wallet.save();

      try {
        // mint temporary token
        if (await DbService.upsertWallets({wallet: {}})) {
          if (makeMain) {
            for (final acc in DB.accounts.values) {
              await acc.update(isMainAccount: false);
            }
          }

          if (await liquidInit(xpub: wallet.xpub, waitForSync: true)) {
            startPeriodicSync();
            selectAccount(account.id);
            GlobalListener.update(stream: .account);

            startLoader();
            await DbService.syncEverything();
            globalState.update(restoreSyncProgress: 1);
            await Future.delayed(const Duration(milliseconds: 300));
            globalState.update(restoreSyncProgress: 0);

            ToastService.show('Watch-only wallet created successfully!');
            return true;
          }
        } else {
          ToastService.show('Sorry, Its not you, its us!');
          await account.delete();
        }
      } catch (e, s) {
        logE(e, stackTrace: s, showToast: true);
        await account.delete();
      }
    } catch (e, s) {
      logE(e, stackTrace: s);
    } finally {
      globalState.update(restoreSyncProgress: 0);
      stopLoader();
    }
    return false;
  }

  static Future<bool> restoreAccount({
    required List<String> mnemonicWords,
    required String accountName,
    bool makeMain = false,
  }) async {
    if (!await ConnectivityChecker.checkConnection()) return false;
    try {
      startLoader();
      globalState.update(restoreSyncProgress: 0.01);

      final mnemonics = await core.Mnemonics.newInstance(mnemonic: mnemonicWords.join(' '));
      final descriptor = await core.Descriptor.newConfidential(network: Config.network, mnemonic: mnemonics.sentence);

      if (DB.accounts.values.any((w) => w.name == accountName)) {
        ToastService.show('Wallet with this name already exists');
        return false;
      }

      if (DB.fullWallets.values.any((e) => e.descriptor == descriptor && e.type == core.WalletType.full)) {
        ToastService.show('Wallet already exists!');
        return false;
      }

      final account = Account(
        id: const Uuid().v4(),
        name: accountName,
        createdAtUTC: DateTime.timestamp(),
        isMainAccount: makeMain || DB.accounts.isEmpty,
        isDisabled: false,
        isBackedUp: true,
        isSendAnonymously: false,
        isSendNotification: true,
        sortOrder: DB.accounts.values.map((e) => e.sortOrder).fold(-1, (p, e) => math.max(p, e)) + 1,
        mnemonicSentence: mnemonics.sentence,
        chatKeyPair: await Account.generateChatKeyPair(mnemonics),
        nsec: await NostrService.generateNsecFromSeed(mnemonics.seedBytes),
      );

      final mainDescriptor = await core.Descriptor.newConfidential(
        network: core.Network.mainnet,
        mnemonic: mnemonics.sentence,
      );
      if (DB.fullWallets.values.any((e) => e.descriptor == mainDescriptor && e.type == core.WalletType.full)) {
        ToastService.show('Wallet already exists!');
        return false;
      }

      final xpubMain = (await core.Descriptor.extractXpub(descriptorStr: mainDescriptor))?.$1;
      if (xpubMain == null) {
        ToastService.show('Failed to extract xpub!');
        return false;
      }
      final walletMain = Wallet(
        accountId: account.id,
        descriptor: mainDescriptor,
        xpub: xpubMain,
        network: core.Network.mainnet,
        type: core.WalletType.full,
      );
      await walletMain.initSwapMnemonic(
        (await core.MasterSwapKey.fromWalletMnemonic(
          walletMnemonic: mnemonics.sentence,
          network: core.Network.mainnet,
        )).toMnemonicString(),
      );

      Wallet? walletRegtest;
      if (Config.isRegtestOn) {
        final regtestDescriptor = await core.Descriptor.newConfidential(
          network: core.Network.regtest,
          mnemonic: mnemonics.sentence,
        );
        if (DB.fullWallets.values.any((e) => e.descriptor == regtestDescriptor && e.type == core.WalletType.full)) {
          ToastService.show('Wallet already exists!');
          return false;
        }

        final xpubRegtest = (await core.Descriptor.extractXpub(descriptorStr: regtestDescriptor))?.$1;
        if (xpubRegtest == null) {
          ToastService.show('Failed to extract xpub!');
          return false;
        }
        walletRegtest = Wallet(
          accountId: account.id,
          descriptor: regtestDescriptor,
          xpub: xpubRegtest,
          network: core.Network.regtest,
          type: core.WalletType.full,
        );
        await walletRegtest.initSwapMnemonic(
          (await core.MasterSwapKey.fromWalletMnemonic(
            walletMnemonic: mnemonics.sentence,
            network: core.Network.regtest,
          )).toMnemonicString(),
        );
      }

      // save temporarily
      await account.save();
      await walletMain.save();
      await walletRegtest?.save();
      DB.loadWallets();

      final wallet = switch (Config.network) {
        core.Network.mainnet => walletMain,
        core.Network.testnet => null,
        core.Network.regtest => walletRegtest,
      };
      if (wallet == null) {
        ToastService.show('Congrats! you managed to break the system!');
        return false;
      }

      try {
        if (await DbService.upsertWallets({walletMain: {}, ?walletRegtest: {}})) {
          if (makeMain) {
            for (final acc in DB.accounts.values) {
              await acc.update(isMainAccount: false);
            }
          }

          DB.loadAllData();
          if (await liquidInit(xpub: wallet.xpub, waitForSync: true)) {
            startPeriodicSync();
            selectAccount(account.id);
            GlobalListener.update(stream: .account);

            startLoader();
            await DbService.syncEverything();
            globalState.update(restoreSyncProgress: 1);
            await Future.delayed(const Duration(milliseconds: 300));
            globalState.update(restoreSyncProgress: 0);

            unawaited(ChatService.sync(walletId: wallet.uuid, entire: true));
            unawaited(ChatService.startListener());
            ToastService.show('Wallet restored successfully!');
            return true;
          }
        } else {
          ToastService.show('Sorry, Its not you, its us!');
          await account.delete();
        }
      } catch (e, s) {
        logE(e, stackTrace: s, showToast: true);
        await account.delete();
      }
    } catch (e, s) {
      logE(e, stackTrace: s, showToast: true);
    } finally {
      DB.loadWallets();
      globalState.update(restoreSyncProgress: 0);
      stopLoader();
    }
    return false;
  }
}
