import 'dart:async';
import 'dart:io';
import 'dart:math' as math;

import 'package:breez_sdk_spark_flutter/breez_sdk_spark.dart'
    show
        BreezSdk,
        Seed,
        defaultConfig,
        GetInfoRequest,
        SdkEvent,
        SdkEvent_Synced,
        SdkEvent_PaymentSucceeded,
        SdkEvent_PaymentPending,
        SdkEvent_PaymentFailed,
        SdkEvent_ClaimedDeposits,
        SdkEvent_NewDeposits,
        ListPaymentsRequest,
        PaymentType,
        SdkBuilder,
        SdkContextConfig,
        SyncWalletRequest,
        ConfigCopyWith,
        SdkEvent_UnclaimedDeposits,
        SdkEvent_AutoOptimization,
        AutoOptimizationEvent_Started,
        AutoOptimizationEvent_RoundCompleted,
        AutoOptimizationEvent_Completed,
        AutoOptimizationEvent_Cancelled,
        AutoOptimizationEvent_Failed,
        AutoOptimizationEvent_Skipped,
        SdkEvent_LightningAddressChanged,
        SdkEvent_UnilateralExitStateChanged,
        Network;
import 'package:breez_sdk_spark_flutter/src/rust/sdk_context.dart' show newSharedSdkContext, SdkContext;
import 'package:manna/config.dart';
import 'package:manna/globals.dart';
import 'package:manna/models/account.dart';
import 'package:manna/models/chat_message.dart';
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
import 'package:manna/utils/extensions.dart';
import 'package:manna/utils/toast_service.dart';
import 'package:manna/utils/util.dart';
import 'package:manna/widgets/bottom%20sheets/new_tx_notifier_bottom_sheet.dart';
import 'package:manna_core/manna_core.dart' as core show Network, Mnemonics, Descriptor, WalletType;
import 'package:path/path.dart' as path;
import 'package:path_provider/path_provider.dart';
import 'package:uuid/uuid.dart';

String liquidDerivationPath({core.Network? network}) =>
    "m/84'/${(network ?? Config.network) == core.Network.mainnet ? 1776 : 1}'/0'";

class WalletService {
  static SdkContext? sparkContext, sparkRegtestContext;
  // xpub : (spark wallet, event listener)
  static final Map<String, (BreezSdk, StreamSubscription)> sparkNodes = {};

  static Timer? _syncTimer;

  static Future<bool> initAllWallets() async {
    final activeWalletsIds = DB.activeAccounts.map((e) => e.id).nonNulls.toSet();
    final activeWalletsXpub = DB.allWallets
        .where((w) => activeWalletsIds.contains(w.accountId) && w.network == Config.network)
        .map((e) => e.xpub)
        .toSet();
    for (final xpub in activeWalletsXpub) {
      await sparkNodes[xpub]?.$1.disconnect();
      sparkNodes[xpub]?.$1.dispose();
      await sparkNodes[xpub]?.$2.cancel();
    }

    selectAccount();
    for (final xpub in activeWalletsXpub) {
      await initSpark(xpub: xpub);
    }

    disposeNonActiveWallets();
    startPeriodicSync();
    return activeWalletsXpub.every((xpub) => sparkNodes.containsKey(xpub));
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

  static Future<String> getSparkPath({required String accountId}) async {
    final appDir = await getApplicationSupportDirectory();
    String sparkPath = path.join(appDir.path, 'spark', accountId);

    if (Platform.isIOS) {
      try {
        final newDirPath = await getAppGroupPath(subPath: path.join('spark', accountId));
        if (newDirPath != null) {
          final newDir = Directory(newDirPath);
          if (!newDir.existsSync()) {
            await newDir.create(recursive: true);
          }
          sparkPath = newDir.path;
        }
      } catch (e, s) {
        logE(e, stackTrace: s);
      }
    }
    return sparkPath;
  }

  static Future<void> saveExitData(String xpub) async {
    // final sdk = sparkNodes[xpub]?.$1;
    // if (sdk == null) return;
    //
    // final data = (await sdk.exportUnilateralExitState()).exitState;
  }

  static Future<bool> initSpark({required String xpub, bool waitForSync = false}) async {
    final wallets = DB.allWallets.where((w) => w.xpub == xpub);
    if (wallets.isEmpty) return false;

    final w = wallets.first;

    try {
      sparkContext ??= await newSharedSdkContext(
        config: SdkContextConfig(network: Network.mainnet, apiKey: Config.breezApiKey),
      );
      sparkRegtestContext ??= await newSharedSdkContext(config: const SdkContextConfig(network: Network.regtest));

      final mnemonic = await w.account.getMnemonicSentence();
      if (mnemonic?.isEmpty ?? true) return false;

      var config = defaultConfig(network: w.network.to);
      if (w.network.to == Network.mainnet) {
        config = config.copyWith(apiKey: Config.breezApiKey);
      }
      SdkBuilder builder = SdkBuilder(
        config: config,
        seed: Seed.mnemonic(mnemonic: mnemonic!),
      );
      builder = builder.withDefaultStorage(storageDir: await getSparkPath(accountId: w.accountId));

      final context = w.network.to == Network.mainnet ? sparkContext : sparkRegtestContext;
      if (context != null) builder = builder.withSharedContext(context: context);

      final sdk = await builder.build();

      sparkNodes[w.xpub] = (sdk, sdk.addEventListener().map((event) => (w.uuid, event)).listen(_onEvent));

      if (waitForSync) await sync(xpub: xpub);
      if (!NewReceivedTxService.shouldShowBottomSheet) {
        NewReceivedTxService.shouldShowBottomSheet = true;
        GlobalListener.update(stream: .receivedTx);
      }
      return true;
    } catch (e, s) {
      logE(e, stackTrace: s);
    }
    return false;
  }

  static Future<void> _onEvent((String, SdkEvent) data) async {
    final walletId = data.$1;
    switch (data.$2) {
      case SdkEvent_Synced():
        final xpub = DB.allWallets.where((e) => e.uuid == walletId).firstOrNull?.xpub;
        if (xpub != null) {
          await partialSync(xpub: xpub);
        }
      case SdkEvent_PaymentSucceeded(:final payment):
        if (payment.paymentType == PaymentType.receive) {
          await NewReceivedTxService.add([IdWithWallet(walletId: walletId, id: payment.id)]);
        } else {
          GlobalListener.update(stream: .account);
        }
        logD('SdkEvent_PaymentSucceeded ${payment.id}');
      case SdkEvent_PaymentPending(:final payment):
        logD('SdkEvent_PaymentPending ${payment.id}');
      case SdkEvent_PaymentFailed(:final payment):
        GlobalListener.update(stream: .account);
        logD('SdkEvent_PaymentFailed ${payment.id}');
      case SdkEvent_ClaimedDeposits(:final claimedDeposits):
        logD('SdkEvent_ClaimedDeposits ${claimedDeposits.map((e) => e.txid)}');
      case SdkEvent_NewDeposits(:final newDeposits):
        logD('SdkEvent_NewDeposits ${newDeposits.map((e) => e.txid)}');
      case SdkEvent_UnclaimedDeposits(:final unclaimedDeposits):
        logD('SdkEvent_UnclaimedDeposits ${unclaimedDeposits.map((e) => e.txid)}');
      case SdkEvent_AutoOptimization(:final optimizationEvent):
        switch (optimizationEvent) {
          case AutoOptimizationEvent_Started():
          case AutoOptimizationEvent_RoundCompleted():
          case AutoOptimizationEvent_Completed():
          case AutoOptimizationEvent_Cancelled():
          case AutoOptimizationEvent_Failed():
          case AutoOptimizationEvent_Skipped():
        }
        logD('SdkEvent_AutoOptimization $optimizationEvent');
      case SdkEvent_LightningAddressChanged(:final lightningAddress):
        logD('SdkEvent_LightningAddressChanged ${lightningAddress?.lightningAddress}');
      case SdkEvent_UnilateralExitStateChanged():
        logD('SdkEvent_UnilateralExitStateChanged');
    }
  }

  static Future<void> partialSync({required String xpub, bool isPreSync = false}) async {
    final sdk = sparkNodes[xpub]?.$1;
    if (sdk == null) return;

    final xpubWallets = DB.allWallets.where((w) => w.xpub == xpub);

    // update wallet balance
    try {
      final balance = (await sdk.getInfo(request: const GetInfoRequest(ensureSynced: false))).balanceSats.i;
      if (balance != 0 || !isPreSync) {
        await Future.wait(xpubWallets.map((e) => e.update(balance: balance)));
      }
    } catch (e, s) {
      logE(e, stackTrace: s);
    }

    final List<IdWithWallet> newTxsIds = [];
    try {
      final transactions = (await sdk.listPayments(request: const ListPaymentsRequest(limit: 1000))).payments;
      final List<Future> saveFutures = [];

      if (transactions.isNotEmpty) {
        for (final w in xpubWallets) {
          for (final tx in transactions) {
            final existing = DB.allTransactions[IdWithWallet(walletId: w.uuid, id: tx.id)];

            if (existing != null) {
              if (existing.inner != tx) {
                saveFutures.add(existing.update(inner: tx));
              }
            } else {
              saveFutures.add(Transaction(txId: tx.id, network: w.network, walletId: w.uuid, inner: tx).save());
              newTxsIds.add(IdWithWallet(id: tx.id, walletId: w.uuid));
            }
          }
        }

        await Future.wait(saveFutures);
      }
    } catch (e, s) {
      logE(e, stackTrace: s);
    }

    if (newTxsIds.isNotEmpty) {
      final Set<IdWithWallet> newReceivedTxIds = {};
      for (final txId in newTxsIds) {
        final transaction = DB.allTransactions[txId];
        if (transaction == null) continue;

        if (transaction.inner.paymentType == PaymentType.receive) {
          for (final w in xpubWallets) {
            final acc = DB.fullWallets[w.uuid]?.account;
            if (acc == null) continue;
            // check if tx is either not confirmed (new)
            // skipping all tx noted within one minute of wallet creation to skip existing transactions.
            if (transaction.inner.timestamp.i * 1000 > acc.createdAtUTC.toLocal().millisecondsSinceEpoch + 60000) {
              newReceivedTxIds.add(IdWithWallet(id: transaction.txId, walletId: w.uuid));
            }
          }
        }
      }
      await NewReceivedTxService.add(newReceivedTxIds.toList());
      await DbService.linkMemosToTransactions(network: xpubWallets.firstOrNull?.network ?? Config.network);
      await DbService.cacheBTCPrices();
      GlobalListener.update(stream: .account);
    }
  }

  static final Map<String, MutexRun> syncMutex = {};
  static final Map<String, bool> syncingState = {};
  // force sync skips the mutex:
  static Future<void> sync({required String xpub, bool force = false}) async {
    final sdk = sparkNodes[xpub]?.$1;
    if (sdk == null) return;

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
        await sdk.syncWallet(request: const SyncWalletRequest());
      } catch (e, s) {
        logE(e, stackTrace: s);
      }
      await partialSync(xpub: xpub);
      syncingState[xpub] = false;
      for (final accId in wallets.map((e) => e.accountId).toSet()) {
        GlobalListener.update(stream: .account, data: accId);
      }
    });
  }

  static Future<void> syncAllWallets() => Future.wait(sparkNodes.keys.map((xpub) => sync(xpub: xpub)));

  // TransactionIdWithWallet string: counter
  static Map<String, int> syncCount = {};
  static void startPeriodicSync() {
    syncAllWallets().then((_) {
      stopPeriodicSync();
      _syncTimer = Timer.periodic(Config.liquidSyncInterval, (timer) {
        final activeXpubs = DB.activeAccounts.map((e) => e.currentWallet.xpub).toSet();
        Future.wait(
          sparkNodes.keys.map((xpub) async {
            if (activeXpubs.contains(xpub)) {
              await sync(xpub: xpub);
            }
          }),
        );
      });
    });
  }

  static void stopPeriodicSync() {
    _syncTimer?.cancel();
    _syncTimer = null;
  }

  // delete the actual files storing lwk data
  static Future<void> deleteWalletCache({required Wallet wallet}) async {
    final subPath = path.join('spark', wallet.accountId, wallet.network.name);
    final walletDirPath = Platform.isIOS
        ? await getAppGroupPath(subPath: subPath)
        : path.join((await getApplicationSupportDirectory()).path, subPath);

    if (walletDirPath != null) {
      final walletDir = Directory(walletDirPath);
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
    for (final xpub in sparkNodes.keys.toList()) {
      if (!activeWalletsXpub.any((e) => e == xpub)) {
        closeWallet(xpub: xpub);
      }
    }
  }

  static Future<void> closeWallet({required String xpub}) async {
    await sparkNodes[xpub]?.$1.disconnect();
    sparkNodes[xpub]?.$1.dispose();
    sparkNodes.remove(xpub);
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
        for (final c in DB.contacts.values.where((t) => t.walletId == w.uuid && t.walletType == w.type).toList()) {
          await c.delete();
        }
        for (final m in DB.chatBox.values.where((m) => w.uuid == m.senderId || w.uuid == m.receiverId)) {
          await m.delete();
        }
        await closeWallet(xpub: w.xpub);
        await deleteWalletCache(wallet: w);
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

      final xpubMain = (await core.Descriptor.extractXpub(descriptorStr: mainDescriptor))?.$1;
      if (xpubMain == null) {
        ToastService.show('Failed to extract xpub!');
        return false;
      }

      if (DB.fullWallets.values.any((e) => e.xpub == xpubMain && e.type == core.WalletType.full)) {
        ToastService.show('Wallet already exists!');
        return false;
      }

      final walletMain = Wallet(
        accountId: account.id,
        xpub: xpubMain,
        network: core.Network.mainnet,
        type: core.WalletType.full,
      );

      Wallet? walletRegtest;
      if (Config.isRegtestOn) {
        final regtestDescriptor = await core.Descriptor.newConfidential(
          network: core.Network.regtest,
          mnemonic: mnemonics.sentence,
        );

        final xpubRegtest = (await core.Descriptor.extractXpub(descriptorStr: regtestDescriptor))?.$1;
        if (xpubRegtest == null) {
          ToastService.show('Failed to extract xpub!');
          return false;
        }

        if (DB.fullWallets.values.any((e) => e.xpub == xpubRegtest && e.type == core.WalletType.full)) {
          ToastService.show('Wallet already exists!');
          return false;
        }

        walletRegtest = Wallet(
          accountId: account.id,
          xpub: xpubRegtest,
          network: core.Network.regtest,
          type: core.WalletType.full,
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
          if (await initSpark(xpub: wallet.xpub, waitForSync: true)) {
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

      if (DB.accounts.values.any((w) => w.name == accountName)) {
        ToastService.show('Wallet with this name already exists');
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

      final xpubMain = (await core.Descriptor.extractXpub(descriptorStr: mainDescriptor))?.$1;
      if (xpubMain == null) {
        ToastService.show('Failed to extract xpub!');
        return false;
      }

      if (DB.fullWallets.values.any((e) => e.xpub == xpubMain && e.type == core.WalletType.full)) {
        ToastService.show('Wallet already exists!');
        return false;
      }

      final walletMain = Wallet(
        accountId: account.id,
        xpub: xpubMain,
        network: core.Network.mainnet,
        type: core.WalletType.full,
      );

      Wallet? walletRegtest;
      if (Config.isRegtestOn) {
        final regtestDescriptor = await core.Descriptor.newConfidential(
          network: core.Network.regtest,
          mnemonic: mnemonics.sentence,
        );

        final xpubRegtest = (await core.Descriptor.extractXpub(descriptorStr: regtestDescriptor))?.$1;
        if (xpubRegtest == null) {
          ToastService.show('Failed to extract xpub!');
          return false;
        }

        if (DB.fullWallets.values.any((e) => e.xpub == xpubRegtest && e.type == core.WalletType.full)) {
          ToastService.show('Wallet already exists!');
          return false;
        }

        walletRegtest = Wallet(
          accountId: account.id,
          xpub: xpubRegtest,
          network: core.Network.regtest,
          type: core.WalletType.full,
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
          if (await initSpark(xpub: wallet.xpub, waitForSync: true)) {
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
