import 'dart:async';
import 'dart:convert';
import 'dart:math' as math;

import 'package:csv/csv.dart';
import 'package:file_saver/file_saver.dart';
import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:manna/app_state.dart';
import 'package:manna/config.dart';
import 'package:manna/models/account.dart';
import 'package:manna/models/contact.dart';
import 'package:manna/models/misc.dart';
import 'package:manna/models/transaction.dart';
import 'package:manna/models/wallet.dart';
import 'package:manna/router.dart';
import 'package:manna/services/biometric_services.dart';
import 'package:manna/services/db.dart';
import 'package:manna/services/lnurl_service.dart';
import 'package:manna/services/log_service.dart';
import 'package:manna/utils/constants.dart';
import 'package:manna/utils/extensions.dart';

import 'package:manna/utils/parser.dart';
import 'package:manna/utils/sats_extension.dart';
import 'package:manna/utils/state_extension.dart';
import 'package:manna/utils/toast_service.dart';
import 'package:breez_sdk_spark_flutter/breez_sdk_spark.dart' as breez;
import 'package:manna/widgets/dialogs/lnurl_auth_dialog.dart';
import 'package:manna/widgets/dialogs/lnurl_withdraw_dialog.dart';
import 'package:manna_core/manna_core.dart' hide Wallet;
import 'package:manna/utils/util.dart';

// Transaction type
enum TraType { btcToSpark, lnToSpark, sparkToBTC, sparkToLN, sparkToSpark }

class TransactionService {
  static Future<String?> generateQrData({
    required Account account,
    required int amount,
    required TraType type,
    bool asBIP21 = true,
    String? memo,
  }) async {
    final sdk = account.currentWallet.spark;
    if (sdk == null) return null;

    try {
      String? invoice;

      if (type == TraType.btcToSpark) {
        final res = await sdk.receivePayment(
          request: const breez.ReceivePaymentRequest(paymentMethod: breez.ReceivePaymentMethod.bitcoinAddress()),
        );
        invoice = res.paymentRequest;
      } else if (type == TraType.lnToSpark) {
        final res = await sdk.receivePayment(
          request: breez.ReceivePaymentRequest(
            paymentMethod: breez.ReceivePaymentMethod.bolt11Invoice(description: memo ?? '', amountSats: amount.bigInt),
          ),
        );
        invoice = res.paymentRequest;
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
    if (type == TraType.btcToSpark) {
      // return address;
      return Uri(scheme: 'bitcoin', path: path, queryParameters: queryParams.isEmpty ? null : queryParams).toString();
    } else if (type == TraType.lnToSpark) {
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
    String? comment,
    String? note,
    Set<String>? categories,
    BrantaData? brantaData,
  }) async {
    final sdk = account.currentWallet.spark;
    if (sdk == null) {
      ToastService.show('Something went wrong!');
      return null;
    }
    if (addressData.addressType == AddressType.unknown) {
      ToastService.show('Invalid address');
      return null;
    }

    AddressData data = addressData.copyWith(comment: Nullable(comment));
    // prioritize lightning even if its fallback.
    if (data.fallback != null && data.fallback!.addressType == AddressType.bolt11Invoice) {
      data = data.copyWith(address: data.fallback!.address, addressType: AddressType.bolt11Invoice, lockAmount: true);
    }

    final returnData = PayOutData(
      account: account,
      userEnteredAddress: data.address,
      addressData: data,
      calculation: calculation,
      note: note,
      category: categories,
      receiverDetail: receiverContact,
      brantaData: brantaData,
    );

    try {
      if (data.addressType == AddressType.bitcoin &&
          calculation.preparedPayment?.paymentMethod is breez.SendPaymentMethod_BitcoinAddress) {
        return returnData;
      }

      if (data.data case breez.InputType_LightningAddress(:final field0)) {
        try {
          if (field0.address.isMannaUserName) {
            return returnData;
          }

          final lnurlRes = await sdk.prepareLnurlPay(
            request: breez.PrepareLnurlPayRequest(
              amount: calculation.receiveAmount.bigInt,
              payRequest: field0.payRequest,
              feePolicy: sendAll ? breez.FeePolicy.feesIncluded : breez.FeePolicy.feesExcluded,
              comment: comment,
              validateSuccessActionUrl: true,
            ),
          );

          data = data.copyWith(
            addressType: AddressType.bolt11Invoice,
            data: breez.InputType.bolt11Invoice(lnurlRes.invoiceDetails),
            address: lnurlRes.invoiceDetails.invoice.bolt11,
            amount: lnurlRes.amountSats.i,
            lockAmount: true,
          );
        } catch (e, s) {
          logE(e, stackTrace: s, showToast: true);
        }
      }

      if (data.data case breez.InputType_Bolt12Offer() when data.addressType == AddressType.bolt12Offer) {
        if (Config.isBolt12SendEnabled) {
          try {
            // TODO implement bolt12 invoice fetching
            // data = data.copyWith(
            //   address: res.$1,
            //   addressType: AddressType.bolt12Invoice,
            //   amount: (bolt12Invoice.msats.i / 1000).toInt(),
            //   lockAmount: true,
            // );
          } catch (e, s) {
            ToastService.show('Failed to fetch the bolt12 invoice!');
            logE(e, stackTrace: s);
          }
        } else {
          ToastService.show('Bolt12 is not supported!');
        }
      }

      if (data.data case breez.InputType_Bolt12Invoice(
        :final field0,
      ) when data.addressType == AddressType.bolt12Invoice) {
        if (Config.isBolt12SendEnabled) {
          if (field0.amountMsat.toInt() <= 0) {
            ToastService.show('Invoice with no amount is not supported!');
            return null;
          }

          return returnData;
        } else {
          ToastService.show('Bolt12 is not supported!');
        }
      }

      if (data.data case breez.InputType_Bolt11Invoice(
        :final field0,
      ) when data.addressType == AddressType.bolt11Invoice) {
        if (field0.network != Config.network.toBTC) {
          ToastService.show('Invoice is from different network!');
          return null;
        }
        if ((field0.timestamp.i + field0.expiry.i) * 1000 <= DateTime.now().millisecondsSinceEpoch) {
          ToastService.show('Invoice expired!');
          return null;
        }

        return returnData.copyWith(addressData: data.copyWith(amount: calculation.receiveAmount));
      }

      if (data.data case breez.InputType_SparkAddress(:final field0) when data.addressType == AddressType.spark) {
        if (field0.network != Config.network.toBTC) {
          ToastService.show('Invoice is from different network!');
          return null;
        }

        return returnData;
      }
    } catch (e, s) {
      logE(e, stackTrace: s);
    }
    return null;
  }

  static Future<AddressData> processAddress({
    required String rawAddress,
    Network? network,
    bool validateOnly = false,
  }) async {
    if (rawAddress.trim().isEmpty) {
      return AddressData(addressType: AddressType.unknown, data: null, address: rawAddress);
    }

    final net = network ?? Config.network;

    Future<AddressData?> processInputType(breez.InputType data, {int? amountSats, String? comment}) async {
      try {
        switch (data) {
          case breez.InputType_BitcoinAddress(:final field0):
            if (field0.network != net.toBTC) throw AddressParsingException('Invalid network : ${field0.network.name}');

            return AddressData(
              addressType: AddressType.bitcoin,
              data: data,
              address: field0.address,
              amount: amountSats ?? 0,
              comment: comment,
            );

          case breez.InputType_SilentPaymentAddress(:final field0):
            if (field0.network != net.toBTC) throw AddressParsingException('Invalid network : ${field0.network.name}');

            return AddressData(
              addressType: AddressType.silentPayment,
              data: data,
              address: field0.address,
              amount: amountSats ?? 0,
              comment: comment,
            );

          case breez.InputType_Bolt11Invoice(:final field0):
            if (field0.network != net.toBTC) throw AddressParsingException('Invalid network : ${field0.network.name}');
            if ((field0.timestamp.i + field0.expiry.i) * 1000 <= DateTime.now().millisecondsSinceEpoch) {
              throw AddressParsingException('Invoice expired!');
            }

            return AddressData(
              addressType: AddressType.bolt11Invoice,
              data: data,
              address: field0.invoice.bolt11,
              amount: field0.amountMsat == null ? 0 : (field0.amountMsat!.toInt() / 1000.0).toInt(),
              lockAmount: field0.amountMsat != null,
              comment: field0.description,
            );

          case breez.InputType_SparkAddress(:final field0):
            if (field0.network != net.toBTC) throw AddressParsingException('Invalid network : ${field0.network.name}');
            return AddressData(
              addressType: AddressType.spark,
              data: data,
              address: field0.address,
              amount: amountSats ?? 0,
              comment: comment,
            );

          case breez.InputType_SparkInvoice(:final field0):
            if (field0.network != net.toBTC) throw AddressParsingException('Invalid network : ${field0.network.name}');
            if (field0.expiryTime != null && field0.expiryTime!.i * 1000 <= DateTime.now().millisecondsSinceEpoch) {
              throw AddressParsingException('Invoice expired!');
            }
            if (field0.tokenIdentifier != null) {
              throw AddressParsingException('Invalid token : ${field0.tokenIdentifier}');
            }

            return AddressData(
              addressType: AddressType.sparkInvoice,
              data: data,
              address: field0.invoice,
              amount: field0.amount == null ? 0 : field0.amount!.i,
              lockAmount: field0.amount != null,
              comment: field0.description,
            );

          case breez.InputType_LnurlAuth(:final field0):
            final uri = Uri.tryParse(field0.url);
            if (uri != null && AppRouter.navigatorContext.mounted) {
              postFrameCallBack(
                () => showDialog(
                  context: AppRouter.navigatorContext,
                  builder: (context) =>
                      LNURLAuthDialog(uri: uri, service: field0.domain, k1: field0.k1, action: field0.action),
                ),
              );
            }

          case breez.InputType_LnurlWithdraw(:final field0):
            unawaited(
              Future(() async {
                if (AppRouter.navigatorContext.mounted) {
                  final res = await showDialog(
                    context: AppRouter.navigatorContext,
                    builder: (context) => LNURLWithdrawDialog(
                      callback: field0.callback,
                      k1: field0.k1,
                      minWithdrawable: field0.minWithdrawable.i,
                      maxWithdrawable: field0.maxWithdrawable.i,
                      desc: field0.defaultDescription,
                    ),
                  );
                  // pop again to jump to wallet screen instead of send screen
                  if (res is bool) {
                    AppRouter.popIfExists('SendScreen');
                  }
                }
              }),
            );
            return AddressData(addressType: AddressType.lnurl, data: data, address: field0.url);

          case breez.InputType_LnurlPay(:final field0):
            if (field0.address != null) {
              return AddressData(addressType: AddressType.lnurl, data: data, address: field0.address!);
            }

          case breez.InputType_LightningAddress(:final field0):
            if (field0.payRequest.address != null) {
              return AddressData(addressType: AddressType.lnurl, data: data, address: field0.payRequest.address!);
            }

          case breez.InputType_Bolt12Offer(:final field0):
            if (Config.isBolt12SendEnabled) {
              try {
                final networks = field0.chains.map(
                  (e) => switch (field0.chains.firstOrNull) {
                    '6fe28c0ab6f1b372c1a6a246ae63f74f931e8365e15a089c68d6190000000000' => Network.mainnet,
                    '43f08bdab050e35b567c864b91f47f50ae725ae2de53bcfbbaf284da00000000' => Network.testnet,
                    '06226e46111a0b59caaf126043eb5bbf28c34f3a5e332a1fc7b2b73cf188910f' => Network.regtest,
                    _ => null,
                  },
                );
                if (!networks.contains(net)) {
                  throw AddressParsingException('Invalid network');
                }
                if ((field0.absoluteExpiry?.i ?? double.infinity) < DateTime.now().millisecondsSinceEpoch) {
                  throw AddressParsingException('Offer expired!');
                }

                return AddressData(addressType: AddressType.bolt12Offer, data: data, address: field0.offer.offer);
              } on AddressParsingException catch (_) {
                rethrow;
              } catch (_) {}
            }
          case breez.InputType_Bolt12Invoice(:final field0):
            if (Config.isBolt12SendEnabled) {
              try {
                final invoice = Crypto.decodeBolt12Invoice(invoice: field0.invoice.invoice);
                if (invoice.network != net) throw AddressParsingException('Invalid network : ${invoice.network.name}');
                if (invoice.isExpired) throw AddressParsingException('Invoice expired!');

                if (invoice.msats.toInt() <= 0) {
                  throw AddressParsingException('Invoice with no amount is not supported!');
                }

                return AddressData(
                  addressType: AddressType.bolt12Invoice,
                  data: data,
                  address: field0.invoice.invoice,
                  amount: (invoice.msats.toInt() / 1000.0).toInt(),
                  lockAmount: true,
                  comment: invoice.description,
                );
              } on AddressParsingException catch (_) {
                rethrow;
              } catch (_) {}
            }

          case breez.InputType_Url():
            break;

          case breez.InputType_Bip21():
            break;

          case breez.InputType_Bolt12InvoiceRequest():
            break;

          case breez.InputType_CrossChainAddress():
            break;
        }
      } catch (_) {}
      return null;
    }

    try {
      final res = await selectedWallet.spark?.parse(input: rawAddress);
      if (res != null) {
        if (res case breez.InputType_Bip21(:final field0)) {
          AddressData? fallback;
          if (field0.paymentMethods.isNotEmpty) {
            final primaryAddressData = await processInputType(
              field0.paymentMethods.first,
              amountSats: field0.amountSat?.i,
              comment: field0.message ?? field0.label,
            );
            if (field0.paymentMethods.length > 1) {
              fallback = await processInputType(field0.paymentMethods[1]);
            }

            if (primaryAddressData != null) {
              return primaryAddressData.copyWith(fallback: Nullable(fallback));
            }
          }
        } else {
          final addressData = await processInputType(res);
          if (addressData != null) return addressData;
        }
      }
    } on AddressParsingException catch (e) {
      ToastService.show(e.message);
    } catch (_) {
      rethrow;
    }

    return AddressData(addressType: AddressType.unknown, data: null, address: rawAddress);
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
    transactions.sort((a, b) => b.timestamp.compareTo(a.timestamp));
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
          'Tax',
          'Tip',
        ],
      ];

      for (final t in transactions) {
        final note = t.memo;
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

        final timestamp = t.timestamp;
        final amount = t.inner.amount.i;
        csvData.add([
          t.txId,
          DateFormat('dd/MM/yyyy HH:mm:ss').format(timestamp),
          t.inner.paymentType == breez.PaymentType.receive ? 'Incoming' : 'Outgoing',
          amount.toStringAsFixed(0),
          amount.satsToFiat(at: timestamp).toStringAsFixed(2),
          t.memo,
          t.note,
          t.categories.join(','),
          DB.allWallets.where((w) => w.uuid == t.walletId).firstOrNull?.account.name ?? '',
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
