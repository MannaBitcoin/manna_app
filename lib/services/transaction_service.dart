import 'dart:async';
import 'dart:convert';
import 'dart:math' as math;

import 'package:csv/csv.dart';
import 'package:file_saver/file_saver.dart';
import 'package:intl/intl.dart';
import 'package:manna/app_state.dart';
import 'package:manna/config.dart';
import 'package:manna/models/account.dart';
import 'package:manna/models/boltz_fees.dart';
import 'package:manna/models/contact.dart';
import 'package:manna/models/misc.dart';
import 'package:manna/models/swap.dart';
import 'package:manna/models/transaction.dart';
import 'package:manna/models/wallet.dart';
import 'package:manna/services/biometric_services.dart';
import 'package:manna/services/db.dart';
import 'package:manna/services/db_service.dart';
import 'package:manna/services/lnurl_service.dart';
import 'package:manna/services/log_service.dart';
import 'package:manna/services/wallet_service.dart';
import 'package:manna/utils/constants.dart';
import 'package:manna/utils/extensions.dart';

import 'package:manna/utils/parser.dart';
import 'package:manna/utils/sats_extension.dart';
import 'package:manna/utils/toast_service.dart';
import 'package:manna/widgets/amount_text.dart';
import 'package:manna_core/manna_core.dart' hide Wallet;
import 'package:manna/utils/util.dart';
import 'boltz_service.dart';

// Transaction type
enum TraType {
  // submarine
  btcToLbtc,
  lnToLbtc,
  // direct
  lbtcToLbtcSend,
  lbtcToLbtcReceive,
  // reverse
  lbtcToBtc,
  lbtcToLN,
}

class TransactionService {
  // use only for swaps
  // status 1:success 2:failed 3:fee not met 4:failed with increased fee
  // (status, txId)
  static Future<(int, String?)> payLbtc({
    required PayOutData paymentData,
    required bool notifyReceiver,
    required bool isPrivate,
    double? feeRate,
  }) async {
    Wallet? wallet;
    try {
      wallet = paymentData.account.currentWallet;
      if (wallet.type == WalletType.watchOnly) {
        ToastService.show('You cannot spend from a watch-only wallet.');
        return (2, null);
      }
    } catch (_) {
      ToastService.show('Error while paying address, cannot find wallet!');
      return (2, null);
    }

    final transaction = await WalletService.buildTx(
      walletId: wallet.uuid,
      outAddress: paymentData.liquidLockupAddress,
      outAmount: paymentData.calculation.sendAmount,
      fees: feeRate,
      drain: paymentData.sendAll ?? false,
      isSwapLockup: paymentData.swap != null,
    );
    final pset = transaction.$1;

    try {
      if (pset != null) {
        final tx = await WalletService.signTx(walletId: wallet.uuid, pset: pset);
        if (tx == null) return (0, null);
        final txId = await Blockchain.broadcastSignedPset(electrumUrl: Config.current.liquid.electrum, signedPset: tx);
        if (txId.isNotEmpty) {
          // temporary transaction
          await Transaction(
            txId: txId,
            amount: -(paymentData.calculation.sendAmount + (transaction.$2?.fees.first.value.toInt() ?? 0)),
            timestamp: DateTime.timestamp(),
            isIncoming: false,
            network: Config.network,
            walletId: wallet.uuid,
            memo: paymentData.memo ?? '',
            note: paymentData.note ?? '',
            categories: paymentData.category ?? {},
            senderUUID: wallet.uuid,
            receiverUserNameOrUUID: paymentData.userEnteredAddress.isUserName
                ? paymentData.userEnteredAddress
                : paymentData.receiverDetail?.uuid,
            extraMetadata: {
              'lnurlSuccessAction': paymentData.lnurlSuccessActionData,
              if (paymentData.brantaData != null) 'brantaData': paymentData.brantaData!.toMap(),
            },
          ).save();

          // sync wallet
          unawaited(WalletService.sync(xpub: wallet.xpub));

          unawaited(DbService.cacheContacts());

          if (paymentData.swap != null) {
            // push to stats
            unawaited(
              DbService.useSupabase(
                (supabase) => supabase
                    .from('tx_stats')
                    .insert(
                      {
                        'amount': paymentData.calculation.sendAmount,
                        'type': 5,
                        'created_at': DateTime.now(),
                      }.toEncodeReady(),
                    ),
              ),
            );
            if ({SwapType.chain, SwapType.submarine}.contains(paymentData.swap!.swapType) &&
                !paymentData.swap!.transactions.any(
                  (tx) => tx.chain == Chain.liquid && tx.txType == SwapTransactionType.lockup && tx.isUser,
                )) {
              paymentData.swap!.transactions.add(
                SwapTransaction(txId: txId, chain: Chain.liquid, txType: SwapTransactionType.lockup, isUser: true),
              );
              await paymentData.swap!.save();
            }
          }

          // this function also verifies receiver and remove address from pool and send notification
          if (!isPrivate) {
            unawaited(
              DbService.saveTxData(
                txId: txId,
                senderUUID: wallet.uuid,
                receiverLnurl: paymentData.userEnteredAddress.isUserName
                    ? paymentData.userEnteredAddress
                    : paymentData.receiverDetail?.lnurl(),
                amount: paymentData.calculation.sendAmount,
                note: paymentData.memo ?? paymentData.swap?.note,
                addressIndexes:
                    transaction.$2?.inputAddressDerivations.map((e) => parseInt(e.split('/').last)).toList() ?? [],
                sendNotification: notifyReceiver,
              ),
            );
          }

          return (1, txId);
        }
      } else {
        ToastService.show('Error while paying transaction, please try after some time!');
      }
    } on LwkError catch (e, s) {
      if (e.msg.contains('min relay fee not met')) {
        // try again with increased fees
        if (DbService.estimatedLiquidFeesPPM * 1.2 == feeRate) {
          ToastService.show('Minimum relay fee not met, Try to increase fees!');
          return (4, null);
        } else {
          ToastService.show('Fee not met, trying again with increased fees!');
          return (3, null);
        }
      }
      logE(e.msg, stackTrace: s, showToast: true);
    } catch (e, s) {
      logE(e, stackTrace: s, showToast: true);
    }
    return (2, null);
  }

  static Future<String?> generateQrData({
    required Account account,
    required int amount,
    required TraType type,
    bool asBIP21 = true,
    String? memo,
    bool doesSenderPayFee = true,
  }) async {
    try {
      String? invoice;

      final swapLockUpAmount = (await calculateFeeAndAmounts(
        wallet: account.currentWallet,
        amount: amount,
        type: type,
        isAmountTarget: doesSenderPayFee,
      )).sendAmount;

      if (type == TraType.lbtcToLbtcReceive) {
        invoice = await account.currentWallet.getConfidentialAddress();
      } else if (type == TraType.btcToLbtc) {
        final chainPair = BoltzFees.getChainFeesAndLimits();
        final minimum = chainPair.btcLimits.minimal;
        final maximum = chainPair.btcLimits.maximal;
        if (amount < minimum || amount > maximum) {
          ToastService.show(
            'For on-chain transactions, amount must be between '
            '${getSatInBitcoinStyle(minimum)} (${minimum.satsToFiat().formatFiat()})'
            ' and '
            '${getSatInBitcoinStyle(maximum)} (${maximum.satsToFiat().formatFiat()}).'
            ' Please increase amount or use Lightning or Liquid.',
          );
          return null;
        }

        final swap = await BoltzService.createBtcToLBtcSwap(account, swapLockUpAmount, note: memo);
        invoice = swap?.chain?.lockupDetails.lockupAddress;
      } else if (type == TraType.lnToLbtc) {
        final reversePair = BoltzFees.getReverseFeesAndLimits();
        final minimum = reversePair.lbtcLimits.minimal;
        final maximum = reversePair.lbtcLimits.maximal;
        if (amount < minimum || amount > maximum) {
          ToastService.show(
            'Amount must be between '
            '${getSatInBitcoinStyle(minimum)} (${minimum.satsToFiat().formatFiat()})'
            ' and '
            '${getSatInBitcoinStyle(maximum)} (${maximum.satsToFiat().formatFiat()}).',
          );
          return null;
        }

        final liquidAddress = await account.currentWallet.getConfidentialAddress();
        if (liquidAddress == null) {
          ToastService.show('Failed to fetch liquid address');
          return null;
        }
        final swap = await BoltzService.createLightningToLbtcSwap(
          account,
          liquidAddress,
          amount: swapLockUpAmount,
          note: memo,
        );
        invoice = swap?.reverse?.swapCreateRes.invoice;
      }

      if (invoice != null) {
        if (asBIP21) {
          return createBIP21Address(address: invoice, type: type, amount: amount, memo: memo ?? '');
        }
        return invoice;
      } else {
        ToastService.show('Failed to generate invoice');
      }
    } catch (e, s) {
      logE(e, stackTrace: s);
    }

    return null;
  }

  static String createBIP21Address({
    required String address,
    required TraType type,
    required int amount,
    required String memo,
  }) {
    final path = Uri.tryParse(address)?.path ?? address;
    final queryParams = {
      if (amount > 0) 'amount': amount.toBtc.toStringAsFixed(10),
      if (memo.isNotEmpty) 'label': memo,
    };
    if (type == TraType.btcToLbtc) {
      // return address;
      return Uri(scheme: 'bitcoin', path: path, queryParameters: queryParams.isEmpty ? null : queryParams).toString();
    } else if ({TraType.lbtcToLbtcReceive, TraType.lbtcToLbtcSend}.contains(type)) {
      return Uri(
        scheme: 'liquidnetwork',
        path: path,
        queryParameters: queryParams.isEmpty ? null : {...queryParams, 'assetid': Config.lBtcId()},
      ).toString();
    } else if (TraType.lnToLbtc == type) {
      return Uri(scheme: 'lightning', path: path).toString();
    }
    return path;
  }

  static Future<PayOutData?> createPayOut({
    required Account account,
    required FeesAndAmounts calculation,
    required AddressData addressData,
    required bool sendAll,
    Contact? receiverContact,
    String? note,
    Set<String>? categories,
  }) async {
    // btc
    // username-> liquid (manna), bolt11 lightning, bolt12 offer
    // bolt12 offer -> bolt12 invoice (optional liquid MRH)
    // bolt11 invoice (optional liquid MRH)
    // liquid
    if (addressData.addressType == AddressType.unknown) {
      ToastService.show('Invalid address');
      return null;
    }

    AddressData data = addressData;
    // prioritize lightning even if its fallback.
    if (data.fallback != null && data.fallback!.addressType == AddressType.bolt11Invoice) {
      data = data.copyWith(address: data.fallback!.address, addressType: AddressType.bolt11Invoice, lockAmount: true);
    }

    final returnData = PayOutData(
      account: account,
      userEnteredAddress: data.address,
      liquidLockupAddress: data.address,
      calculation: calculation,
      memo: data.memo,
      note: note,
      category: categories,
      receiverDetail: receiverContact,
      sendAll: sendAll,
      lnurlSuccessActionData: data.successAction,
    );

    try {
      if (data.addressType == AddressType.bitcoin) {
        final chainPair = BoltzFees.getChainFeesAndLimits();
        final minimum = chainPair.btcLimits.minimal;
        final maximum = chainPair.btcLimits.maximal;
        if (calculation.sendAmount < minimum) {
          ToastService.show(
            'You are attempting to make an on-chain transaction to a Layer-1 address. '
            'For small amounts, please use Lightning or Liquid or increase the amount to more than '
            '${getSatInBitcoinStyle(minimum)} (${minimum.satsToFiat().formatFiat()}).',
          );
          return null;
        }
        if (calculation.sendAmount > maximum) {
          ToastService.show('Amount must be less than ${getSatInBitcoinStyle(maximum)}.');
          return null;
        }

        final btcSwap = await BoltzService.createLbtcToBtcSwap(
          account,
          calculation.sendAmount,
          data.address,
          note: data.memo,
        );
        if (btcSwap == null || (btcSwap.chain?.lockupDetails.lockupAddress.isEmpty ?? true)) return null;
        return returnData.copyWith(
          account: account,
          liquidLockupAddress: btcSwap.chain!.lockupDetails.lockupAddress,
          swap: Nullable(btcSwap),
          sendAll: sendAll,
        );
      }

      final userName = data.address.getUserName;
      if (data.addressType == AddressType.lnurl) {
        if (userName == null) return null;
        // manna to manna
        if (data.address.isMannaUserName) {
          final liquidAddress = await DbService.getWalletLiquidAddress(userName);
          if (liquidAddress != null) {
            return returnData.copyWith(
              liquidLockupAddress: liquidAddress,
              calculation: await calculateFeeAndAmounts(
                wallet: account.currentWallet,
                amount: calculation.sendAmount,
                type: TraType.lbtcToLbtcSend,
                address: liquidAddress,
                isSendAll: sendAll,
              ),
            );
          }
        }

        // bolt11 invoice for given username
        final (bolt11Invoice, successAction) = await generateInvoiceFromLNURL(
          lightningAddress: data.address,
          amount: calculation.receiveAmount * 1000,
          memo: data.memo,
        );
        if (bolt11Invoice != null) {
          data = data.copyWith(
            addressType: AddressType.bolt11Invoice,
            address: bolt11Invoice,
            amount: calculation.receiveAmount,
            lockAmount: true,
            successAction: Nullable(successAction),
          );
        } else {
          if (Config.isBolt12SendEnabled) {
            // fetch bolt12 offer from username
            try {
              final offerUri = await fetchBolt12OfferUriFromUsername(network: Config.network, username: data.address);
              if (offerUri != null) {
                final offer = Uri.tryParse(offerUri.trim().toLowerCase())?.queryParameters['lno'];
                if (offer != null) {
                  final decodedOffer = await decodeBolt12Offer(offer: offer);
                  if (decodedOffer.networks.contains(Config.network) && !decodedOffer.isExpired) {
                    data = data.copyWith(addressType: AddressType.bolt12Offer, address: offer);
                  }
                }
              }
            } catch (_) {}
          }
        }
      }

      if (data.addressType == AddressType.bolt12Offer) {
        if (Config.isBolt12SendEnabled) {
          try {
            final res = await BoltzService.boltzManager.generateBolt12InvoiceForSend(
              network: Config.network,
              offer: data.address,
              amount: calculation.receiveAmount.bigInt,
              note: data.memo,
            );
            // MRH in bolt12 invoice
            if (res.$2 != null) {
              try {
                data = await processAddress(rawAddress: res.$2!);
                if (data.addressType == AddressType.liquid) {
                  return returnData.copyWith(
                    liquidLockupAddress: data.address,
                    calculation: await calculateFeeAndAmounts(
                      wallet: account.currentWallet,
                      amount: data.amount,
                      type: TraType.lbtcToLbtcSend,
                      address: data.address,
                      isSendAll: sendAll,
                    ),
                  );
                }
              } catch (_) {}
            }

            final bolt12Invoice = decodeBolt12Invoice(invoice: res.$1);
            data = data.copyWith(
              address: res.$1,
              addressType: AddressType.bolt12Invoice,
              amount: (bolt12Invoice.msats.i / 1000).toInt(),
              memo: Nullable(bolt12Invoice.description),
              lockAmount: true,
            );
          } catch (e, s) {
            ToastService.show('Failed to fetch the bolt12 invoice!');
            logE(e, stackTrace: s);
          }
        } else {
          ToastService.show('Bolt12 is not supported!');
        }
      }

      if (data.addressType == AddressType.bolt12Invoice) {
        if (Config.isBolt12SendEnabled) {
          final bolt12Invoice = decodeBolt12Invoice(invoice: data.address);
          if (bolt12Invoice.network != Config.network) {
            ToastService.show('Invoice is from different network!');
            return null;
          }
          if (bolt12Invoice.isExpired) {
            ToastService.show('Invoice expired!');
            return null;
          }
          if (bolt12Invoice.msats.toInt() <= 0) {
            ToastService.show('Invoice with no amount is not supported!');
            return null;
          }

          final submarinePair = BoltzFees.getSubmarineFeesAndLimits();
          final minimum = submarinePair.lbtcLimits.minimalBatched ?? submarinePair.lbtcLimits.minimal;
          final maximum = submarinePair.lbtcLimits.maximal;
          if (data.amount < minimum || data.amount > maximum) {
            ToastService.show(
              'Amount must be between ${getSatInBitcoinStyle(minimum)} and ${getSatInBitcoinStyle(maximum)}.',
            );
            return null;
          }

          final bolt12Swap = await BoltzService.createLbtcToLightningSwap(account, data.address, note: data.memo);
          final lockupAddress = bolt12Swap?.submarine?.swapCreateRes.address;
          if (lockupAddress == null || lockupAddress.isEmpty) return null;

          return returnData.copyWith(
            liquidLockupAddress: lockupAddress,
            swap: Nullable(bolt12Swap),
            sendAll: sendAll,
            calculation: await calculateFeeAndAmounts(
              wallet: account.currentWallet,
              address: data.address,
              amount: data.amount,
              type: TraType.lbtcToLN,
            ),
          );
        } else {
          ToastService.show('Bolt12 is not supported!');
        }
      }

      if (data.addressType == AddressType.bolt11Invoice) {
        final invoice = await decodeBolt11InvoiceBip21(invoice: data.address, boltzUrl: Config.current.boltzUrl);
        if (invoice.network != Config.network) {
          ToastService.show('Invoice is from different network!');
          return null;
        }
        if (invoice.isExpired) {
          ToastService.show('Invoice expired!');
          return null;
        }
        if (invoice.msats.toInt() <= 0) {
          ToastService.show('Invoice with no amount is not supported!');
          return null;
        }

        // MRH in bolt11 invoice
        if (invoice.bip21 != null) {
          return returnData.copyWith(
            liquidLockupAddress: invoice.bip21!.$1,
            calculation: await calculateFeeAndAmounts(
              wallet: account.currentWallet,
              address: invoice.bip21!.$1,
              amount: invoice.bip21!.$2.i,
              type: TraType.lbtcToLbtcSend,
              isSendAll: sendAll,
            ),
          );
        } else {
          data = data.copyWith(
            amount: (invoice.msats.i / 1000.0).toInt(),
            memo: Nullable(invoice.description),
            lockAmount: true,
          );

          final submarinePair = BoltzFees.getSubmarineFeesAndLimits();
          final minimum = submarinePair.lbtcLimits.minimalBatched ?? submarinePair.lbtcLimits.minimal;
          final maximum = submarinePair.lbtcLimits.maximal;
          if (data.amount < minimum || data.amount > maximum) {
            ToastService.show(
              'Amount must be between ${getSatInBitcoinStyle(minimum)} and ${getSatInBitcoinStyle(maximum)}.',
            );
            return null;
          }

          final bolt11Swap = await BoltzService.createLbtcToLightningSwap(account, data.address, note: data.memo);
          final lockupAddress = bolt11Swap?.submarine?.swapCreateRes.address;
          if (lockupAddress == null || lockupAddress.isEmpty) return null;
          return returnData.copyWith(
            liquidLockupAddress: lockupAddress,
            swap: Nullable(bolt11Swap),
            sendAll: sendAll,
            calculation: await calculateFeeAndAmounts(
              wallet: account.currentWallet,
              address: data.address,
              amount: data.amount,
              type: TraType.lbtcToLN,
            ),
          );
        }
      }

      if (data.addressType == AddressType.liquid) {
        return returnData.copyWith(
          liquidLockupAddress: data.address,
          calculation: await calculateFeeAndAmounts(
            wallet: account.currentWallet,
            address: data.address,
            amount: data.amount,
            type: TraType.lbtcToLbtcSend,
            isSendAll: sendAll,
          ),
        );
      }
    } catch (e, s) {
      logE(e, stackTrace: s);
    }
    return null;
  }

  /// throws [AddressParsingException]
  static Future<AddressData> processAddress({
    required String rawAddress,
    Network? network,
    bool validateOnly = false,
  }) async {
    final net = network ?? Config.network;
    final uri = Uri.tryParse(rawAddress.trim().replaceAll(r'\n', '').replaceAll(r'\r', ''));
    if (uri == null) {
      throw AddressParsingException('Failed to parse address!');
    }

    final addr = parseString(
      uri.pathSegments.firstOrNull ??
          uri.getQueryParam('lno') ??
          uri.getQueryParam('lni') ??
          uri.getQueryParam('lightning') ??
          uri.getQueryParam('sp') ??
          uri.getQueryParam('bc') ??
          uri.getQueryParam('tb'),
    );

    String? fallbackAddr =
        (uri.getQueryParam('lightning') ??
                uri.getQueryParam('lni') ??
                uri.getQueryParam('lno') ??
                uri.getQueryParam('sp'))
            ?.trim();
    if (fallbackAddr?.isEmpty ?? true) fallbackAddr = null;

    try {
      final res = await handleLNURL(
        rawAddress: {'lnurlp', 'lnurlw', 'keyauth'}.contains(uri.scheme.toLowerCase()) ? rawAddress : addr,
        network: net,
        validateOnly: validateOnly,
      );
      if (res != null) {
        return res;
      }
    } catch (e) {
      if (fallbackAddr != null) {
        try {
          final res = await handleLNURL(rawAddress: fallbackAddr, network: net, validateOnly: validateOnly);
          if (res != null) return res;
        } catch (_) {}
      } else if (e is AddressParsingException) {
        ToastService.show(e.message);
      }
    }

    AddressData? fallback;
    if (fallbackAddr != null) {
      try {
        fallback = await processAddress(rawAddress: fallbackAddr, validateOnly: validateOnly);
      } catch (_) {}
    }

    // bolt11 invoice
    try {
      final invoice = await decodeBolt11InvoiceBip21(invoice: addr, boltzUrl: Config.of(net).boltzUrl);
      if (invoice.network != net) throw AddressParsingException('Invalid network : ${invoice.network.name}');
      if (invoice.isExpired) throw AddressParsingException('Invoice expired!');

      // lbtc magic routing hint
      if (invoice.bip21 != null) {
        return AddressData(
          addressType: AddressType.liquid,
          address: invoice.bip21!.$1,
          amount: invoice.bip21!.$2.toInt(),
          memo: invoice.description,
          fallback: fallback,
        );
      }
      if (invoice.msats.toInt() <= 0) throw AddressParsingException('Invoice with no amount is not supported!');

      return AddressData(
        addressType: AddressType.bolt11Invoice,
        address: addr,
        amount: (invoice.msats.toInt() / 1000.0).toInt(),
        lockAmount: true,
        memo: invoice.description,
        fallback: fallback,
      );
    } on AddressParsingException catch (_) {
      rethrow;
    } catch (_) {}

    if (Config.isBolt12SendEnabled) {
      // bolt12 Invoice
      try {
        final invoice = decodeBolt12Invoice(invoice: addr);
        if (invoice.network != net) throw AddressParsingException('Invalid network : ${invoice.network.name}');
        if (invoice.isExpired) throw AddressParsingException('Invoice expired!');

        if (invoice.msats.toInt() <= 0) throw AddressParsingException('Invoice with no amount is not supported!');

        return AddressData(
          addressType: AddressType.bolt12Invoice,
          address: addr,
          amount: (invoice.msats.toInt() / 1000.0).toInt(),
          lockAmount: true,
          memo: invoice.description,
          fallback: fallback,
        );
      } on AddressParsingException catch (_) {
        rethrow;
      } catch (_) {}

      // bolt12 offer
      try {
        final offer = await decodeBolt12Offer(offer: addr);
        if (!offer.networks.contains(net)) {
          throw AddressParsingException('Invalid network : ${offer.networks.map((e) => e.name).join(', ')}');
        }
        if (offer.isExpired) throw AddressParsingException('Offer expired!');

        return AddressData(address: offer.parsedOffer, addressType: AddressType.bolt12Offer, fallback: fallback);
      } on AddressParsingException catch (_) {
        rethrow;
      } catch (_) {}
    }

    // liquid
    try {
      final network = await Address.validate(addressString: addr);
      if (network != net) throw AddressParsingException('Invalid network : ${network.name}');

      return AddressData(
        address: addr,
        addressType: AddressType.liquid,
        amount: (parseDoubleN(uri.getQueryParam('amount')) ?? 0).toSat,
        memo: parseString(uri.getQueryParam('label') ?? uri.getQueryParam('note') ?? uri.getQueryParam('message')),
        fallback: fallback,
      );
    } on AddressParsingException catch (_) {
      rethrow;
    } catch (_) {}

    // btc address
    try {
      if (await validateBtcAddress(address: addr, network: net)) {
        return AddressData(
          address: addr,
          addressType: AddressType.bitcoin,
          amount: (parseDoubleN(uri.getQueryParam('amount')) ?? 0).toSat,
          memo: parseString(uri.getQueryParam('label') ?? uri.getQueryParam('note') ?? uri.getQueryParam('message')),
          fallback: fallback,
        );
      }
    } catch (_) {}

    return AddressData(addressType: AddressType.unknown, address: addr, fallback: fallback);
  }

  static Future<(String?, Map<String, dynamic>? successAction)> generateInvoiceFromLNURL({
    required String lightningAddress,
    required int amount,
    String? memo,
  }) async {
    try {
      final match = Regexes.internetAddress.firstMatch(lightningAddress);
      final username = match?.group(1);
      final domain = match?.group(2);
      if (username != null && domain != null) {
        final lnurlData = await callLNURL(Uri.parse('https://$domain/.well-known/lnurlp/$username'));
        final callback = Uri.tryParse(parseString(lnurlData['callback']));
        if (callback == null) return (null, null);

        final queryMap = {'amount': amount.toString()};
        if (parseInt(lnurlData['commentAllowed']) > 0 && memo != null) {
          queryMap['comment'] = memo.substring(0, math.min(memo.length, parseInt(lnurlData['commentAllowed'])));
        }

        final invoiceRes = await globalDio.getUri(callback.replace(queryParameters: queryMap));
        if (invoiceRes.isSuccess && invoiceRes.data is Map) {
          final successActionRaw = invoiceRes.data['successAction'];
          Map<String, dynamic>? successAction;
          if (successActionRaw is Map) {
            successAction = successActionRaw.cast<String, dynamic>();

            // mismatching server
            if (successActionRaw['tag'] == 'url' &&
                Uri.tryParse(parseString(successActionRaw['url']))?.host != callback.host) {
              successAction = null;
            }
          }
          return (parseString(invoiceRes.data['pr']), successAction);
        }
      }
    } catch (e, s) {
      if (e is! AddressParsingException) {
        logE(e, stackTrace: s);
      }
    }
    return (null, null);
  }

  static Future<void> exportTransactions({required List<Transaction> transactions}) async {
    if (!(await BiometricService.authenticateBiometricsIfExists(message: 'Verify to export transactions'))) return;
    transactions.sort(
      (a, b) => a.confirmationTimestamp == b.confirmationTimestamp
          ? b.timestamp.compareTo(a.timestamp)
          : b.txTimestamp.compareTo(a.txTimestamp),
    );
    if (transactions.isEmpty) {
      return ToastService.show('No transactions to export');
    }

    try {
      final List<List<String>> csvData = [
        [
          'Transaction Id',
          'Date',
          'Incoming/Outgoing',
          'Amount (₿)',
          'Amount (${AppState.selectedCurrency.currencyCode})',
          'Memo',
          'Note',
          'Category',
          'Wallet',
          'Swap Id',
          'Manna Fee',
          'Network Fees',
          'Block Height',
          'Vsize',
          'Tax',
          'Tip',
        ],
      ];

      for (final t in transactions) {
        final swap = t.linkedSwap;
        final note = swap?.note ?? t.memo;
        String? tip, tax;
        final taxIndex = note.indexOf('Tax : ');
        if (taxIndex != -1) {
          final endIndex = note.indexOf('\n', taxIndex);
          tax = note.substring(taxIndex + 6, endIndex != -1 ? endIndex : note.length);
        }
        final noteIndex = note.indexOf('Tip : ');
        if (noteIndex != -1) {
          final endIndex = note.indexOf('\n', noteIndex);
          tip = note.substring(noteIndex + 6, endIndex != -1 ? endIndex : note.length);
        }
        csvData.add([
          t.txId,
          DateFormat('dd/MM/yyyy HH:mm:ss').format(t.txTimestamp),
          t.isIncoming ? 'Incoming' : 'Outgoing',
          t.amount.toStringAsFixed(0),
          t.amount.satsToFiat(at: t.txTimestamp).toStringAsFixed(2),
          t.memo,
          t.note,
          t.categories.join(','),
          DB.allWallets.where((w) => w.uuid == t.walletId).firstOrNull?.account.name ?? '',
          swap?.id ?? '',
          t.mannaFees().toString(),
          t.liquidTx?.fee.toString() ?? '',
          t.liquidTx?.height.toString() ?? '',
          t.liquidTx?.vsize.toString() ?? '',
          tax?.toString() ?? '',
          tip?.toString() ?? '',
        ]);
      }

      final csvContent = const ListToCsvConverter(eol: '\n').convert(csvData);
      await FileSaver.instance.saveAs(
        name: 'transactions_${DateFormat('yyyy_MM_dd_hh_mm').format(DateTime.now())}',
        bytes: utf8.encode(csvContent),
        fileExtension: 'csv',
        mimeType: MimeType.csv,
      );
    } catch (e, s) {
      logE(e, stackTrace: s, title: 'Transaction exporting failed!');
    }
  }

  static Uri generateExplorerUrl(
    int explorer, // 0:BlockStream, 1:Mempool, 2:BullBitcoin or manna regtest
    String txString, {
    Network? network,
    bool isBTC = false,
    bool blinded = false,
  }) {
    network ??= Config.network;
    Uri url = Uri(
      scheme: 'https',
      host: switch (network) {
        Network.mainnet || Network.testnet => switch (explorer) {
          1 => isBTC ? 'mempool.space' : 'liquid.network',
          2 => isBTC ? 'mempool.bullbitcoin.com' : 'liquid.bullbitcoin.com',
          _ => isBTC ? 'blockstream.info' : 'blockstream.info',
        },
        Network.regtest => Config.current.serverUrl,
      },
      path: switch (network) {
        Network.mainnet => switch (explorer) {
          0 => isBTC ? '' : 'liquid',
          _ => '',
        },
        Network.testnet => switch (explorer) {
          0 => isBTC ? 'testnet' : 'liquidtestnet',
          _ => 'testnet',
        },
        Network.regtest => isBTC ? 'bitcoin' : 'liquid',
      },
    );
    url = Uri.parse('$url/$txString');

    if (blinded) {
      return url.removeFragment();
    }
    return url;
  }
}

class AddressParsingException {
  AddressParsingException(this.message);

  final String message;
}
