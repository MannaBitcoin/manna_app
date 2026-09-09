import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:manna/config.dart';
import 'package:manna/globals.dart';
import 'package:manna/models/account.dart';
import 'package:manna/models/bolt12_offer.dart';
import 'package:manna/models/swap.dart';
import 'package:manna/models/transaction.dart';
import 'package:manna/models/wallet.dart';
import 'package:manna/router.dart';
import 'package:manna/screens/swap_detail_screen.dart';
import 'package:manna/services/db.dart';
import 'package:manna/services/db_service.dart';
import 'package:manna/services/lnurl_service.dart';
import 'package:manna/services/log_service.dart';
import 'package:manna/services/wallet_service.dart';
import 'package:manna/utils/extensions.dart';
import 'package:manna/utils/parser.dart';
import 'package:manna/utils/toast_service.dart';
import 'package:manna/utils/util.dart';
import 'package:manna/widgets/bottom sheets/receiving_tx_bottom_sheet.dart';
import 'package:manna/widgets/bottom%20sheets/new_tx_notifier_bottom_sheet.dart';
import 'package:manna_core/manna_core.dart' hide Wallet;
import 'package:manna_core/manna_core.dart' as core;
import 'package:web_socket_channel/io.dart';

import 'connectivity_checker.dart';

class BoltzService {
  static final boltzManager = BoltzManager(apiConfig: Config.apiConfig);

  static Future<void> init() async {
    await Future.wait([
      processPendingSwaps(network: Network.mainnet, lnurlSwapIdsToProcess: []),
      if (Config.isRegtestOn) processPendingSwaps(network: Network.regtest, lnurlSwapIdsToProcess: []),
    ]);
    if (Config.isBolt12ReceiveEnabled) {
      await Future.wait([
        listenBolt12(network: Network.mainnet),
        if (Config.isRegtestOn) listenBolt12(network: Network.regtest),
      ]);
    }

    // fetch swap transactions for stale swaps.
    final missingTxSwaps = DB.swaps.values.where(
      (swap) =>
          swap.transactions.length < swap.expectedNoTransaction &&
          (swap.isClosed ? false : !swap.swapStatus.contains('expired')) &&
          (swap.network == Network.regtest ? Config.isRegtestOn : true),
    );

    if (await ConnectivityChecker.checkConnection()) {
      unawaited(
        Future(() async {
          for (int i = 0; i < (missingTxSwaps.length ~/ 10) + 1; i++) {
            for (final swap in missingTxSwaps.skip(i * 10).take(10)) {
              try {
                await (await fetchAndLinkSwapTransactions(swap: swap, apiConfig: Config.apiConfig)).save();
              } catch (e, s) {
                logE(e, stackTrace: s, data: swap.id);
                break;
              }
            }
          }
        }),
      );
    }
  }

  static Future<void> setupBolt12(Wallet wallet, {bool deleteOld = false}) async {
    if (!Config.isBolt12ReceiveEnabled) return;
    try {
      final existingOffer = DB.bolt12Offers['${wallet.uuid}_${wallet.type.index}'];
      if (existingOffer != null) {
        if (deleteOld) {
          await existingOffer.delete();
        } else {
          return;
        }
      }

      final desc = wallet.metaData?.bolt11ShortDesc
          .replaceAll(r'$UserName', wallet.metaData!.userName)
          .replaceAll(r'$Timestamp', '')
          .trim();

      final offerRes = await boltzManager.createBolt12Offer(
        network: wallet.network,
        params: [
          Bolt12OfferCreationParam(
            liquidWallet: await wallet.getLiquidWallet(),
            issuerName: wallet.metaData == null ? null : '${wallet.metaData!.userName} (Manna)'.trim(),
            description: desc?.isNotEmpty == true ? desc : null,
          ),
        ],
      );

      if (offerRes.isEmpty) return;

      final offers = (await Future.wait(
        offerRes.map((e) async {
          final (liquidWallet, offer, signingKey) = e;

          final w = DB.allWallets
              .where((w) => w.uuid == liquidWallet.uuid && w.type == liquidWallet.walletType)
              .firstOrNull;
          if (w == null) return null;

          final config = Config.of(w.network);
          await globalDio.delete(
            '${config.boltzUrl}/lightning/BTC/bolt12',
            data: jsonEncode({'offer': offer, 'signature': await signSchnorr(data: 'DELETE', signingKey: e.$3)}),
          );
          final res = await globalDio.post(
            '${config.boltzUrl}/lightning/BTC/bolt12',
            data: jsonEncode({'offer': offer, 'url': config.getServerApiEndpoint('bolt12Webhook/${w.uuid}')}),
          );
          if (res.statusCode == 200 || res.statusCode == 201) {
            logI(
              'registered bolt12 offer for webhook: $offer: ${config.getServerApiEndpoint('bolt12Webhook/${w.uuid}')}',
            );
          } else {
            logE(res.data['error']);
          }

          return Bolt12Offer(walletId: w.uuid, walletType: w.type, offer: offer, signingKey: signingKey);
        }),
      )).nonNulls.toList();

      if (await DbService.upsertBolt12Offers(offers)) {
        await Future.wait(offers.map((o) => o.save()));
        await Future.wait([
          listenBolt12(network: Network.mainnet),
          if (Config.isRegtestOn) listenBolt12(network: Network.regtest),
        ]);
      }
    } catch (e, s) {
      logE(e, stackTrace: s);
    }
  }

  // State tracking maps to handle multiple networks dynamically
  static final Map<Network, BoltzWebSocket> _offerUpdateSockets = {};
  static final Map<Network, StreamSubscription> _offerSubscriptions = {};
  static final Map<Network, Set<String>> _activeSubscribedOfferIds = {};

  /// Pass empty list to force fetch swaps
  static Future<void> listenBolt12({required Network network}) async {
    if (!Config.isBolt12ReceiveEnabled) return;
    if (!await ConnectivityChecker.checkConnection()) return;

    final Map<Network, Set<Bolt12Offer>> offers = {};
    for (final offer in DB.bolt12Offers.values) {
      final w = offer.wallet;
      if (w == null) continue;
      (offers[w.network] ??= {}).add(offer);
    }

    final targetOffers = offers[network] ?? {};

    try {
      if (targetOffers.isEmpty) {
        await _cleanupSwapSocket(network);
        return;
      }
      if (_offerUpdateSockets[network] == null) {
        final socket = BoltzWebSocket.create(Config.of(network).boltzUrl);
        _offerUpdateSockets[network] = socket;
        _activeSubscribedOfferIds[network] = {};

        _offerSubscriptions[network] = socket.stream
            .asyncMap(handleOfferSocketUpdate)
            .listen(
              (event) {
                try {
                  if (kDebugMode) {
                    print(jsonDecode(event));
                  }
                } catch (_) {}
              },
              onError: (err) {
                logE(err, title: 'Offer Socket error on $network. Cleaning up...');
                _cleanupOfferSocket(network);
              },
              onDone: () {
                logD('Offer Socket closed by remote host on $network.');
                _cleanupOfferSocket(network);
              },
            );
      }

      final alreadySubscribed = _activeSubscribedOfferIds[network]!;
      final newOffers = targetOffers.difference(alreadySubscribed);

      if (newOffers.isNotEmpty) {
        final signedPayload = Map.fromEntries(
          await Future.wait(
            newOffers.map(
              (e) async => MapEntry(e.offer, await signSchnorr(data: 'SUBSCRIBE', signingKey: e.signingKey)),
            ),
          ),
        );

        _offerUpdateSockets[network]?.subscribeBolt12(signedPayload);
        alreadySubscribed.addAll(newOffers.map((e) => e.id));
      }

      _activeSubscribedOfferIds[network]?.retainAll(targetOffers.map((e) => e.id));
    } catch (e, s) {
      logE(
        e,
        stackTrace: s,
        title: 'Failed to reach Boltz API',
        solution: 'Check your internet connection',
        showToast: true,
      );
      await _cleanupOfferSocket(network);
    }
  }

  static Future<void> _cleanupOfferSocket(Network network) async {
    await _offerSubscriptions[network]?.cancel();
    _offerSubscriptions.remove(network);

    await _offerUpdateSockets[network]?.dispose();
    _offerUpdateSockets.remove(network);

    _activeSubscribedOfferIds.remove(network);
  }

  static Future<dynamic> handleOfferSocketUpdate(dynamic event) async {
    try {
      final data = jsonDecode(event);
      if (data is Map && data['event'] == 'request' && data['channel'] == 'invoice.request' && data['args'] is List) {
        for (final s in data['args']) {
          final requestId = parseString(s['id']);
          final offer = parseString(s['offer']);
          final invoiceRequestHexStr = parseString(s['invoiceRequest']);

          logI('[$requestId] Boltz bolt12 invoice request.');

          final bolt12Offer = DB.bolt12Offers.values.where((o) => o.offer == offer).firstOrNull;
          if (bolt12Offer == null) {
            logD('bolt12 offer not found');
            return event;
          }

          final w = bolt12Offer.wallet;
          if (w == null) {
            logD('wallet not found');
            return event;
          }
          if (w.liquidWollet == null) {
            logD('liquid wallet not initialized');
            return event;
          }

          try {
            // TODO show bottomSheet that says generating bolt12 invoice
            final decoded = DecodedBolt12InvoiceRequest.decode(invoiceRequestHex: invoiceRequestHexStr);
            if (decoded.amountMsats == null) {
              _offerUpdateSockets[w.network]?.sendBolt12InvoiceError(
                requestId: requestId,
                errorMessage: 'Missing amount',
              );
              logD('missing amount in request');
              return event;
            }
            final liquidAddress = (await w.liquidWollet!.addressLastUnused()).confidential;
            final index = await DbService.getSwapIndex(w);

            final pool = await Crypto.generateLnurlPool(
              swapMnemonics: await w.getSwapMnemonic(),
              network: w.network,
              indices: core.Uint64List.fromList([index]),
            );
            if (pool.isEmpty) {
              _offerUpdateSockets[w.network]?.sendBolt12InvoiceError(
                requestId: requestId,
                errorMessage: 'Receiver unavailable',
              );
              logD('lnurl pool generation failed');
              return event;
            }

            final (bolt12Invoice, addressSignature) = await boltzManager.createBol12Invoice(
              offerStr: bolt12Offer.offer,
              invoiceRequestHex: invoiceRequestHexStr,
              signingKey: bolt12Offer.signingKey,
              network: decoded.network,
              preimageHash: pool.first.preimage.sha256,
              liquidAddress: liquidAddress,
            );

            final swap = await createLightningToLbtcSwap(
              w.account,
              liquidAddress,
              bolt12Invoice: bolt12Invoice,
              addressSignature: addressSignature,
            );
            if (swap == null) {
              _offerUpdateSockets[w.network]?.sendBolt12InvoiceError(
                requestId: requestId,
                errorMessage: 'Failed to generate invoice',
              );
              logD('swap creation failed');
              return event;
            }
            _offerUpdateSockets[w.network]?.sendBolt12InvoiceReply(requestId: requestId, invoice: bolt12Invoice);
            logI('[$requestId] invoice response :$bolt12Invoice');
          } catch (e, s) {
            logE(e, stackTrace: s);
            _offerUpdateSockets[w.network]?.sendBolt12InvoiceError(
              requestId: requestId,
              errorMessage: 'Failed to generate invoice',
            );
          }
        }
      }
    } catch (e, s) {
      logE(e, stackTrace: s);
    }
    return event;
  }

  static Future<bool> _catchBoltzIndexError(BoltzError e, {required Wallet wallet, required int currentIndex}) async {
    if (e.message.contains('already') && e.message.contains('exists') && e.message.contains('preimage')) {
      await DbService.upsertWallets({
        wallet: {'swap_index': currentIndex + 1},
      });
      ToastService.show('Please try again!');
      return true;
    }
    return false;
  }

  static Future<Swap?> createLbtcToLightningSwap(Account acc, String boltInvoice, {String? note}) async {
    final w = acc.currentWallet;

    final existingSwap = DB.swaps.values
        .where(
          (e) =>
              e.network == Config.network &&
              e.walletId == w.uuid &&
              e.walletType == w.type &&
              e.swapStatus == 'swap.created' &&
              e.submarine?.invoice == boltInvoice &&
              e.note == note,
        )
        .firstOrNull;
    if (existingSwap != null) return existingSwap;

    final index = await DbService.getSwapIndex(w);
    if (index == null) {
      ToastService.show('Failed to create swap.\nReason: cannot fetch swap index.');
      return null;
    }

    try {
      final swap = await boltzManager.newSubmarine(
        wallet: await w.getLiquidWallet(),
        network: Config.network,
        from: Chain.liquid,
        index: index.bigInt,
        invoice: boltInvoice,
        note: note,
        extraSwapFee: DbService.lbtcLnSwapFee > 0
            ? ExtraSwapFee(id: 'app_lbtc_ln', percentage: DbService.lbtcLnSwapFee)
            : null,
        webHook: Config.boltzSwapWebhookUrl == null
            ? null
            : WebHook(
                url: Config.boltzSwapWebhookUrl!,
                statuses: [
                  SubSwapStatus.transactionClaimPending.jsonName,
                  SubSwapStatus.invoiceFailedToPay.jsonName,
                  SubSwapStatus.swapExpired.jsonName,
                  SubSwapStatus.transactionLockupFailed.jsonName,
                ],
              ),
      );
      await swap.save();
      unawaited(
        Future.wait([
          DbService.upsertWallets({
            w: {'swap_index': index + 1},
          }),
          DbService.registerSwapWebhook([swap]),
        ]),
      );

      unawaited(processPendingSwaps());
      return swap;
    } catch (e, s) {
      if (e is BoltzError) {
        if (await _catchBoltzIndexError(e, wallet: w, currentIndex: index)) return null;
      }
      logE(e, stackTrace: s, title: 'Error creating Lbtc to Lightning swap!', showToast: true);
    }
    return null;
  }

  // Either pass bolt12 invoice and address signature or amount and note
  static Future<Swap?> createLightningToLbtcSwap(
    Account acc,
    String lbtcAddress, {
    String? bolt12Invoice,
    String? addressSignature,
    int? amount,
    String? note,
  }) async {
    if (bolt12Invoice == null && amount == null) throw Exception('Either bolt12 invoice or amount required');
    final w = acc.currentWallet;

    final description = note?.split('').where((e) => e.codeUnitAt(0) < 128).join().replaceAll('\n', '  ');
    final notes = description == null || description.length <= 639
        ? description
        : '${description.substring(0, 636)}...';
    final existingSwap = DB.swaps.values
        .where(
          (e) =>
              e.network == Config.network &&
              e.walletId == w.uuid &&
              e.walletType == w.type &&
              e.sendAmount.i == amount &&
              e.note == notes &&
              e.swapStatus == 'swap.created',
        )
        .firstOrNull;
    if (existingSwap != null) return existingSwap;

    final index = await DbService.getSwapIndex(w);
    if (index == null) {
      ToastService.show('Failed to create swap.\nReason: cannot fetch swap index.');
      return null;
    }

    try {
      final swap = await boltzManager.newReverse(
        wallet: await w.getLiquidWallet(),
        network: Config.network,
        to: Chain.liquid,
        index: index.bigInt,
        address: lbtcAddress,
        addressSignature: addressSignature,
        bolt12Invoice: bolt12Invoice,
        amount: amount?.bigInt,
        note: notes,
        extraSwapFee: DbService.lnLbtcSwapFee > 0
            ? ExtraSwapFee(id: 'app_ln_lbtc', percentage: DbService.lnLbtcSwapFee)
            : null,
        webHook: Config.boltzSwapWebhookUrl == null
            ? null
            : WebHook(
                url: Config.boltzSwapWebhookUrl!,
                statuses: [
                  RevSwapStatus.transactionMempool.jsonName,
                  RevSwapStatus.transactionConfirmed.jsonName,
                  RevSwapStatus.transactionFailed.jsonName,
                  RevSwapStatus.transactionRefunded.jsonName,
                ],
              ),
      );
      await swap.save();

      unawaited(
        Future.wait([
          DbService.upsertWallets({
            w: {'swap_index': index + 1},
          }),
          DbService.registerSwapWebhook([swap]),
        ]),
      );

      unawaited(processPendingSwaps());
      return swap;
    } catch (e, s) {
      if (e is BoltzError) {
        if (await _catchBoltzIndexError(e, wallet: w, currentIndex: index)) return null;
      }
      logE(e, stackTrace: s, title: 'Error creating Lightning to Lbtc swap!', showToast: true);
    }
    return null;
  }

  static Future<Swap?> createBtcToLBtcSwap(Account acc, int amount, {String? note}) async {
    final w = acc.currentWallet;

    final existingSwap = DB.swaps.values
        .where(
          (e) =>
              e.network == Config.network &&
              e.walletId == w.uuid &&
              e.walletType == w.type &&
              e.sendAmount.i == amount &&
              e.note == note &&
              e.swapStatus == 'swap.created' &&
              e.chain != null &&
              e.chain!.direction == ChainSwapDirection.btcToLbtc,
        )
        .firstOrNull;

    if (existingSwap != null) return existingSwap;

    final index = await DbService.getSwapIndex(w);
    if (index == null) {
      ToastService.show('Failed to create swap.\nReason: cannot fetch swap index.');
      return null;
    }

    try {
      final swap = await boltzManager.newChain(
        wallet: await w.getLiquidWallet(),
        network: Config.network,
        index: index.bigInt,
        direction: ChainSwapDirection.btcToLbtc,
        amount: amount.bigInt,
        note: note,
        extraSwapFee: DbService.btcLbtcSwapFee > 0
            ? ExtraSwapFee(id: 'app_btc_lbtc', percentage: DbService.btcLbtcSwapFee)
            : null,
        webHook: Config.boltzSwapWebhookUrl == null
            ? null
            : WebHook(
                url: Config.boltzSwapWebhookUrl!,
                statuses: [
                  ChainSwapStatus.transactionServerMempool.jsonName,
                  ChainSwapStatus.transactionServerConfirmed.jsonName,
                  ChainSwapStatus.transactionLockupFailed.jsonName,
                  ChainSwapStatus.transactionFailed.jsonName,
                  ChainSwapStatus.transactionRefunded.jsonName,
                ],
              ),
      );
      await swap.save();
      unawaited(
        Future.wait([
          DbService.upsertWallets({
            w: {'swap_index': index + 2},
          }),
          DbService.registerSwapWebhook([swap]),
        ]),
      );

      unawaited(processPendingSwaps());
      return swap;
    } catch (e, s) {
      if (e is BoltzError) {
        if (await _catchBoltzIndexError(e, wallet: w, currentIndex: index)) return null;
      }
      logE(e, stackTrace: s, title: 'Error creating Lbtc to btc swap!', showToast: true);
    }
    return null;
  }

  static Future<Swap?> createLbtcToBtcSwap(Account acc, int amount, String address, {String? note}) async {
    final w = acc.currentWallet;

    final existingSwap = DB.swaps.values
        .where(
          (e) =>
              e.network == Config.network &&
              e.walletId == w.uuid &&
              e.walletType == w.type &&
              e.sendAmount.i == amount &&
              e.note == note &&
              e.swapStatus == 'swap.created' &&
              e.chain != null &&
              e.chain!.direction == ChainSwapDirection.lbtcToBtc,
        )
        .firstOrNull;
    if (existingSwap != null) return existingSwap;

    final index = await DbService.getSwapIndex(w);
    if (index == null) {
      ToastService.show('Failed to create swap.\nReason: cannot fetch swap index.');
      return null;
    }

    try {
      final swap = await boltzManager.newChain(
        wallet: await w.getLiquidWallet(),
        network: Config.network,
        index: index.bigInt,
        direction: ChainSwapDirection.lbtcToBtc,
        amount: amount.bigInt,
        note: note,
        extraSwapFee: DbService.lbtcBtcSwapFee > 0
            ? ExtraSwapFee(id: 'app_lbtc_btc', percentage: DbService.lbtcBtcSwapFee)
            : null,
        webHook: Config.boltzSwapWebhookUrl == null
            ? null
            : WebHook(
                url: Config.boltzSwapWebhookUrl!,
                statuses: [
                  ChainSwapStatus.transactionServerMempool.jsonName,
                  ChainSwapStatus.transactionServerConfirmed.jsonName,
                  ChainSwapStatus.transactionLockupFailed.jsonName,
                  ChainSwapStatus.transactionFailed.jsonName,
                  ChainSwapStatus.transactionRefunded.jsonName,
                ],
              ),
      );
      swap.chain?.claimDetails.claimAddress = address;
      await swap.save();

      unawaited(
        Future.wait([
          DbService.upsertWallets({
            w: {'swap_index': index + 2},
          }),
          DbService.registerSwapWebhook([swap]),
        ]),
      );

      unawaited(processPendingSwaps());

      return swap;
    } catch (e, s) {
      if (e is BoltzError) {
        if (await _catchBoltzIndexError(e, wallet: w, currentIndex: index)) return null;
      }
      logE(e, stackTrace: s, title: 'Error creating Lbtc to btc swap!', showToast: true);
    }
    return null;
  }

  // State tracking maps to handle multiple networks dynamically
  static final Map<Network, BoltzWebSocket> _swapUpdateSockets = {};
  static final Map<Network, StreamSubscription> _swapSubscriptions = {};
  static final Map<Network, Set<String>> _activeSubscribedSwapIds = {};

  /// Pass empty list to force fetch swaps
  static Future<void> processPendingSwaps({Network? network, List<String>? lnurlSwapIdsToProcess}) async {
    if (!await ConnectivityChecker.checkConnection()) return;

    final net = network ?? Config.network;
    if (net == Network.regtest && !Config.isRegtestOn) return;

    bool shouldFetch = false;
    if (lnurlSwapIdsToProcess != null) {
      shouldFetch = lnurlSwapIdsToProcess.isEmpty || lnurlSwapIdsToProcess.any((e) => DB.swaps[e] == null);
    }
    if (shouldFetch) {
      await DbService.fetchPendingLNURLSwaps(net);
    }

    // Gather all pending swap IDs across all networks
    final Map<Network, Set<String>> pendingSwapIds = {};
    for (final s in DB.swaps.values.where((e) => !e.isClosed)) {
      final res = isFinalSwapState(swap: s);
      await res.$1.save();
      if (!res.$2) {
        (pendingSwapIds[s.network] ??= {}).add(s.id);
      }
    }

    final targetIds = pendingSwapIds[net] ?? {};

    try {
      // If there are no pending swaps for this network, close the socket to save resources
      if (targetIds.isEmpty) {
        await _cleanupSwapSocket(net);
        return;
      }

      // Initialize the socket ONLY if it doesn't already exist
      if (_swapUpdateSockets[net] == null) {
        final socket = BoltzWebSocket.create(Config.of(net).boltzUrl);
        _swapUpdateSockets[net] = socket;
        _activeSubscribedSwapIds[net] = {};

        _swapSubscriptions[net] = socket.stream
            .asyncMap(handleSwapSocketUpdate)
            .listen(
              (event) {
                try {
                  if (kDebugMode) {
                    print(jsonDecode(event));
                  }
                } catch (_) {}
              },
              onError: (err) {
                logE(err, title: 'Swap Socket error on $net. Cleaning up...');
                _cleanupSwapSocket(net);
              },
              onDone: () {
                logD('Swap Socket closed by remote host on $net.');
                _cleanupSwapSocket(net);
              },
            );
      }

      // Only subscribe to NEW swap IDs that aren't already actively being tracked
      final alreadySubscribed = _activeSubscribedSwapIds[net]!;
      final newIds = targetIds.difference(alreadySubscribed);

      if (newIds.isNotEmpty) {
        _swapUpdateSockets[net]?.subscribe(newIds.toList());
        alreadySubscribed.addAll(newIds);
      }

      // Sync our tracking set with current pending swaps (remove settled ones from tracking)
      _activeSubscribedSwapIds[net]?.retainAll(targetIds);
    } catch (e, s) {
      logE(
        e,
        stackTrace: s,
        title: 'Failed to reach Boltz API',
        solution: 'Check your internet connection',
        showToast: true,
      );
      await _cleanupSwapSocket(net);
    }
  }

  static Future<void> _cleanupSwapSocket(Network network) async {
    await _swapSubscriptions[network]?.cancel();
    _swapSubscriptions.remove(network);

    await _swapUpdateSockets[network]?.dispose();
    _swapUpdateSockets.remove(network);

    _activeSubscribedSwapIds.remove(network);
  }

  static Future<dynamic> handleSwapSocketUpdate(dynamic event) async {
    try {
      final data = jsonDecode(event);
      if (data is Map && data['event'] == 'update' && data['channel'] == 'swap.update' && data['args'] is List) {
        for (final s in data['args']) {
          try {
            final id = parseString(s['id']);
            final statusStr = parseString(s['status']);
            final failureReason = parseStringN(s['failureReason']);

            final swap = DB.swaps[id];

            if (swap == null) return event;

            swap.swapStatus = swap.swapStatus == 'swap.refunded' ? 'swap.refunded' : statusStr;
            swap.failureReason ??= failureReason;
            await swap.save();

            await processSwap(id);
          } catch (e, s) {
            logE(e, stackTrace: s);
          }
        }
      }
    } catch (e, s) {
      logE(e, stackTrace: s);
    }
    return event;
  }

  /// used to update swap status of single swap using REST endpoint.
  static Future<void> updateSwapStatus(String id) async {
    final swap = DB.swaps[id];
    if (swap == null) return;

    final statusRes = await globalDio.get('${Config.of(swap.network).boltzUrl}/swap/${swap.id}');
    final statusStr = parseString(statusRes.data?['status']);
    final failureReason = parseStringN(statusRes.data?['failureReason']);

    swap.swapStatus = swap.swapStatus == 'swap.refunded' ? 'swap.refunded' : statusStr;
    swap.failureReason ??= failureReason;
    await swap.save();
  }

  static final Set<String> processingSwapIds = {};
  static Future<void> processSwap(String swapId) async {
    final swap = DB.swaps[swapId];
    if (swap == null) return;
    try {
      Swap? updatedSwap;
      bool? isRefundableOrNegotiable;
      try {
        if (processingSwapIds.contains(swapId)) return;
        processingSwapIds.add(swapId);
        final res = await core.processSwap(
          swap: swap,
          boltzManager: boltzManager,
          lwkPath: await WalletService.getLWKPath(),
          liquidWallets: (await Future.wait(
            DB.allWallets.map((e) async {
              return LiquidWallet(
                uuid: e.uuid,
                walletType: e.type,
                descriptor: e.descriptor,
                swapMnemonic: await e.getSwapMnemonic(),
              );
            }),
          )).nonNulls.toList(),
          onReceivingClaimStart: (s) async {
            logD('onReceivingClaimStart ${s.id}');
            if (s.chain == null || s.chain!.direction == ChainSwapDirection.btcToLbtc) {
              await ReceivingTxService.addReceivingTxs([ReceivingTx(swapId: swap.id)]);
            }
          },
          onReceivingClaimComplete: (s) async {
            logD('onReceivingClaimComplete ${s.id}');
            if (s.chain == null || s.chain!.direction == ChainSwapDirection.btcToLbtc) {
              // This code is fake tx injection to let user see the transaction until the wallet syncs.
              final t = s.transactions.where((e) => e.isUser && e.txType == SwapTransactionType.claim).firstOrNull;
              if (t == null) return;

              final tx = Transaction(
                txId: t.txId,
                amount: swap.receiveAmount.toInt(),
                timestamp: DateTime.timestamp(),
                isIncoming: true,
                network: swap.network,
                walletId: swap.walletId,
                memo: swap.note ?? '',
              );
              await tx.save();
              await WalletService.setNewTxIds(
                {...WalletService.getNewTxIds(), IdWithWallet(id: tx.txId, walletId: tx.walletId)}.toList(),
              );
              await ReceivingTxService.removeReceivingTx(swap.id);
              await NewReceivedTxService.add([IdWithWallet(id: tx.txId, walletId: tx.walletId)]);
            }
            if (swap.network == Config.network) {
              final wallet = DB.allWallets.where((w) => w.uuid == swap.walletId).firstOrNull;
              if (wallet != null) {
                // sync twice cause in practice first sync doesn't sync latest tx due to delay with electrum
                unawaited(WalletService.sync(xpub: wallet.xpub).then((_) => WalletService.sync(xpub: wallet.xpub)));
              }
            }
          },
          deviceId: await getDeviceId(),
        );
        if (res != null) {
          (updatedSwap, isRefundableOrNegotiable) = res;
        }
      } catch (e, s) {
        await ReceivingTxService.removeReceivingTx(swap.id);
        logE(e, stackTrace: s);
      } finally {
        processingSwapIds.remove(swapId);
      }

      if (isRefundableOrNegotiable != null) {
        AppRouter.pushIfNotExists(SwapDetailScreen(swapId: swap.id));
      }

      if (updatedSwap != null) {
        bool isCompleted;
        (updatedSwap, isCompleted) = isFinalSwapState(swap: updatedSwap);
        await updatedSwap.save();

        if (isCompleted) {
          if (updatedSwap.submarine != null) {
            final lockUpTxId = updatedSwap.transactions
                .where((e) => e.isUser && e.chain == Chain.liquid && e.txType == SwapTransactionType.lockup)
                .firstOrNull
                ?.txId;
            if (lockUpTxId != null) {
              final lockupTx = DB.transactions[IdWithWallet(walletId: updatedSwap.walletId, id: lockUpTxId)];
              if (lockupTx != null) {
                handleLNURLSuccessAction(lockupTx);
              }
            }
          }

          // De-register swap webhook
          await DbService.useSupabase((sup) => sup.from('swap_webhook').delete().eq('swap_id', swap.id));

          if (globalState.value.isAppForeground) {
            unawaited(DbService.pushCompletedSwaps());
          }
        }
      }
    } catch (e, s) {
      await ReceivingTxService.removeReceivingTx(swap.id);
      logE(e, stackTrace: s);
    }
  }
}

class BoltzWebSocket {
  late final IOWebSocketChannel _socketChannel;
  late final StreamController _broadcastController;

  Stream get stream => _broadcastController.stream;

  static BoltzWebSocket create(String boltzUrl) {
    final instance = BoltzWebSocket();
    instance._broadcastController = StreamController.broadcast();
    instance._socketChannel = IOWebSocketChannel.connect(instance.prepareWssUrl('$boltzUrl/ws'));
    instance._socketChannel.stream.pipe(instance._broadcastController);
    return instance;
  }

  void subscribe(List<String> swapIds) =>
      _socketChannel.sink.add(jsonEncode({'op': 'subscribe', 'channel': 'swap.update', 'args': swapIds}));

  void unsubscribe(List<String> swapIds) =>
      _socketChannel.sink.add(jsonEncode({'op': 'unsubscribe', 'channel': 'swap.update', 'args': swapIds}));

  /// [bolt12Offers] - offer string - schnorr signature of sha256('SUBSCRIBE') with signing key
  void subscribeBolt12(Map<String, String> bolt12Offers) => _socketChannel.sink.add(
    jsonEncode({
      'op': 'subscribe',
      'channel': 'invoice.request',
      'args': bolt12Offers.entries.map((e) => {'offer': e.key, 'signature': e.value}).toList(),
    }),
  );

  void sendBolt12InvoiceReply({required String requestId, required String invoice}) =>
      _socketChannel.sink.add(jsonEncode({'op': 'invoice', 'id': requestId, 'invoice': invoice}));

  void sendBolt12InvoiceError({required String requestId, required String errorMessage}) =>
      _socketChannel.sink.add(jsonEncode({'op': 'invoice.error', 'id': requestId, 'error': errorMessage}));

  void unsubscribeBolt12(List<String> bolt12Offers) =>
      _socketChannel.sink.add(jsonEncode({'op': 'unsubscribe', 'channel': 'invoice.request', 'args': bolt12Offers}));

  Future<void> dispose() async {
    try {
      await _broadcastController.sink.close();
      await _broadcastController.close();
      await _socketChannel.sink.close();
    } catch (_) {}
  }

  String prepareWssUrl(String url) {
    const wsProtocols = ['wss://', 'ws://'];
    const httpProtocols = ['http://', 'https://'];
    String strippedUrl = url;
    for (final e in wsProtocols) {
      strippedUrl = strippedUrl.replaceFirst(e, '');
    }
    for (final e in httpProtocols) {
      strippedUrl = strippedUrl.replaceFirst(e, '');
    }
    return 'wss://$strippedUrl';
  }
}
