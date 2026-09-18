import 'package:breez_sdk_spark_flutter/breez_sdk_spark.dart'
    show
        PrepareSendPaymentRequest,
        PaymentRequest,
        FeePolicy,
        SendPaymentMethod_Bolt11Invoice,
        SendPaymentMethod_SparkInvoice,
        SendPaymentMethod_BitcoinAddress,
        OnchainConfirmationSpeed,
        PrepareSendPaymentResponse,
        SendPaymentMethod_SparkAddress,
        SendPaymentMethod_CrossChainAddress,
        SendOnchainFeeQuote,
        InputType_LightningAddress,
        PrepareLnurlPayRequest,
        PrepareLnurlPayResponse,
        LnurlPayRequestDetails;
import 'package:intl/intl.dart';
import 'package:manna/app_state.dart';
import 'package:manna/models/misc.dart';
import 'package:manna/models/wallet.dart' show Wallet;
import 'package:manna/services/db.dart';
import 'package:manna/services/db_service.dart';
import 'package:manna/services/log_service.dart';
import 'package:manna/utils/extensions.dart';
import 'package:manna/utils/toast_service.dart';

extension AmountExtension on num {
  double satsToFiat({DateTime? at, String? targetCurrencyCode}) {
    final targetCode = (targetCurrencyCode ?? AppState.selectedCurrency.currencyCode).toLowerCase();
    final btcUsdPrice = getBTCPriceAt(at: at);

    if (btcUsdPrice < 0 || this == 0) return 0;

    final usd = this / 100000000 * btcUsdPrice;
    return usd * (DbService.currencyRates[targetCode] ?? 1);
  }

  int fiatToSats({DateTime? at, String? sourceCurrencyCode}) {
    final targetCode = (sourceCurrencyCode ?? AppState.selectedCurrency.currencyCode).toLowerCase();
    final btcUsdPrice = getBTCPriceAt(at: at);

    if (btcUsdPrice < 0 || this == 0) return 0;

    final fiatPrice = btcUsdPrice * (DbService.currencyRates[targetCode] ?? 1);
    return (this * 100000000 / fiatPrice).ceil();
  }

  String formatFiat({String? targetCurrencyCode}) {
    final code = (targetCurrencyCode ?? AppState.selectedCurrency.currencyCode).toLowerCase();

    final formattedAmount = this % 1 == 0
        ? NumberFormat('###,###,###').format(this)
        : NumberFormat('###,###,##0.00').format(this);

    return '${AppState.currencySymbols[code] ?? code}$formattedAmount';
  }

  String get formatSats => NumberFormat('###,###,###').format(this);

  String get formatBTC => NumberFormat('###,###,##0.########').format(this);

  double get toBtc => this / 100000000;

  int get toSat => (this * 100000000).toInt();

  double convertCurrency({String sourceFiatCode = 'usd', String? targetCurrencyCode}) {
    final sourceCode = sourceFiatCode.toLowerCase();
    final targetCode = (targetCurrencyCode ?? AppState.selectedCurrency.currencyCode).toLowerCase();

    final sourceRate = DbService.currencyRates[sourceCode];
    final targetRate = DbService.currencyRates[targetCode];
    return (sourceCode != 'usd' ? this / (sourceRate ?? 1) : this) * (targetRate ?? 1);
  }
}

// seconds: value
final Map<int, double> _btcPriceCache = {};
double getBTCPriceAt({DateTime? at}) {
  double getClosestValue(int key) {
    int? closest;
    int minDistance = 200;
    for (final k in DB.btcPriceHistoryBox.keys) {
      final distance = (key - (k as int)).abs();
      if (distance < 30) {
        final val = DB.btcPriceHistoryBox.get(k);
        if (val != null) return 1 / val;
      }
      if (distance < minDistance || closest == null) {
        minDistance = distance;
        closest = k;
      }
    }

    final val = DB.btcPriceHistoryBox.get(closest);
    return val != null ? 1 / val : 0;
  }

  if (at != null) {
    final key = at.toUtc().millisecondsSinceEpoch ~/ 1000;
    return _btcPriceCache[key] ??= getClosestValue(key);
  }
  if (AppState.btcPrice != 0) return 1 / AppState.btcPrice;
  return getClosestValue(DateTime.timestamp().millisecondsSinceEpoch ~/ 1000);
}

class FeesAndAmounts {
  FeesAndAmounts({
    required this.sendAmount,
    required this.receiveAmount,
    required this.sparkFee,
    required this.lightningFee,
    required this.networkFee,
    this.preparedPayment,
    this.preparedLnurlPay,
    this.onchainFeeQuote,
    this.btcFeeRate = OnchainConfirmationSpeed.medium,
  });

  final int sendAmount;
  final int receiveAmount;
  final int sparkFee;
  final int lightningFee;
  final int networkFee;

  final PrepareSendPaymentResponse? preparedPayment;
  final PrepareLnurlPayResponse? preparedLnurlPay;
  final SendOnchainFeeQuote? onchainFeeQuote;
  final OnchainConfirmationSpeed btcFeeRate;

  FeesAndAmounts copyWith({int? sendAmount, int? sparkFee, int? networkFee, OnchainConfirmationSpeed? btcFeeRate}) {
    return FeesAndAmounts(
      sendAmount: sendAmount ?? this.sendAmount,
      receiveAmount: receiveAmount,
      sparkFee: sparkFee ?? this.sparkFee,
      lightningFee: lightningFee,
      networkFee: networkFee ?? this.networkFee,
      preparedPayment: preparedPayment,
      onchainFeeQuote: onchainFeeQuote,
      btcFeeRate: btcFeeRate ?? this.btcFeeRate,
    );
  }
}

(int, LnurlPayRequestDetails, FeePolicy, String?, PrepareLnurlPayResponse)? lnurlCache;
Future<FeesAndAmounts?> calculateFeeAndAmounts({
  required Wallet wallet,
  required AddressData addressData,
  required int amount,
  bool amountExcludesFee = true,
  OnchainConfirmationSpeed? alreadySelectedSpeed,
}) async {
  if (wallet.balance < amount) {
    ToastService.show('Insufficient balance!');
    return null;
  }
  if (amount <= 0) return null;

  try {
    if (wallet.spark != null) {
      if (addressData.data case InputType_LightningAddress(:final field0)) {
        final feePolicy = amountExcludesFee ? FeePolicy.feesExcluded : FeePolicy.feesIncluded;

        PrepareLnurlPayResponse? lnurlRes;
        if (lnurlCache != null &&
            lnurlCache!.$1 == amount &&
            lnurlCache!.$2 == field0.payRequest &&
            lnurlCache!.$3 == feePolicy &&
            lnurlCache!.$4 == addressData.comment) {
          lnurlRes = lnurlCache!.$5;
        } else {
          lnurlRes = await wallet.spark!.prepareLnurlPay(
            request: PrepareLnurlPayRequest(
              amount: amount.bigInt,
              payRequest: field0.payRequest,
              feePolicy: feePolicy,
              comment: addressData.comment,
              validateSuccessActionUrl: true,
            ),
          );
          lnurlCache = (amount, field0.payRequest, feePolicy, addressData.comment, lnurlRes);
        }

        final lightningFee = lnurlRes.feeSats.i;
        final sendAmount = amountExcludesFee ? lnurlRes.amountSats.i + lightningFee : lnurlRes.amountSats.i;
        return FeesAndAmounts(
          sendAmount: sendAmount,
          receiveAmount: sendAmount - lightningFee,
          sparkFee: 0,
          lightningFee: lightningFee,
          networkFee: 0,
          preparedLnurlPay: lnurlRes,
        );
      }

      final res = await wallet.spark!.prepareSendPayment(
        request: PrepareSendPaymentRequest(
          paymentRequest: PaymentRequest.input(input: addressData.address),
          amount: amount.bigInt,
          feePolicy: amountExcludesFee ? FeePolicy.feesExcluded : FeePolicy.feesIncluded,
        ),
      );
      switch (res.paymentMethod) {
        case SendPaymentMethod_Bolt11Invoice(:final sparkTransferFeeSats, :final lightningFeeSats):
          final sparkFee = sparkTransferFeeSats?.i ?? 0;
          final lightningFee = lightningFeeSats.i;
          final totalFee = sparkFee + lightningFee;
          final sendAmount = amountExcludesFee ? res.amount.i + totalFee : res.amount.i;

          return FeesAndAmounts(
            sendAmount: sendAmount,
            receiveAmount: sendAmount - totalFee,
            sparkFee: sparkFee,
            lightningFee: lightningFeeSats.i,
            networkFee: 0,
            preparedPayment: res,
          );

        case SendPaymentMethod_SparkInvoice(:final fee, :final tokenIdentifier):
        case SendPaymentMethod_SparkAddress(:final fee, :final tokenIdentifier):
          if (tokenIdentifier == null) {
            final sendAmount = amountExcludesFee ? res.amount.i + fee.i : res.amount.i;
            return FeesAndAmounts(
              sendAmount: sendAmount,
              receiveAmount: sendAmount - fee.i,
              sparkFee: fee.i,
              lightningFee: 0,
              networkFee: 0,
              preparedPayment: res,
            );
          }

        case SendPaymentMethod_BitcoinAddress(:final feeQuote):
          final btcFeeRate = alreadySelectedSpeed ?? OnchainConfirmationSpeed.medium;
          final (sparkFee, networkFee) = switch (btcFeeRate) {
            OnchainConfirmationSpeed.fast => (feeQuote.speedFast.userFeeSat.i, feeQuote.speedFast.l1BroadcastFeeSat.i),
            OnchainConfirmationSpeed.medium => (
              feeQuote.speedMedium.userFeeSat.i,
              feeQuote.speedMedium.l1BroadcastFeeSat.i,
            ),
            OnchainConfirmationSpeed.slow => (feeQuote.speedSlow.userFeeSat.i, feeQuote.speedSlow.l1BroadcastFeeSat.i),
          };
          final sendAmount = amountExcludesFee ? res.amount.i + sparkFee + networkFee : res.amount.i;
          return FeesAndAmounts(
            sendAmount: sendAmount,
            receiveAmount: sendAmount - sparkFee - networkFee,
            sparkFee: sparkFee,
            lightningFee: 0,
            networkFee: networkFee,
            preparedPayment: res,
            onchainFeeQuote: feeQuote,
            btcFeeRate: btcFeeRate,
          );

        case SendPaymentMethod_CrossChainAddress():
      }
    }
  } catch (e, s) {
    logE(e, stackTrace: s);
  }

  return null;
}
