import 'dart:convert';

import 'package:intl/intl.dart';
import 'package:manna/app_state.dart';
import 'package:manna/config.dart';
import 'package:manna/models/boltz_fees.dart';
import 'package:manna/models/wallet.dart';
import 'package:manna/services/db.dart';
import 'package:manna/services/db_service.dart';
import 'package:manna/services/transaction_service.dart';
import 'package:manna/services/wallet_service.dart';
import 'package:manna/utils/parser.dart';
import 'package:manna_core/manna_core.dart' hide Wallet;

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

int getSwapNetworkFees(TraType type) => switch (type) {
  TraType.lbtcToLbtcReceive || TraType.lbtcToLbtcSend => 0,
  TraType.lbtcToLN => BoltzFees.getSubmarineFeesAndLimits().lbtcFees.minerFees,
  TraType.lnToLbtc => () {
    final fee = BoltzFees.getReverseFeesAndLimits();
    return fee.lbtcFees.minerFees.claim + fee.lbtcFees.minerFees.lockup;
  }(),
  TraType.btcToLbtc => () {
    final fee = BoltzFees.getChainFeesAndLimits();
    return fee.lbtcFees.userClaim + fee.lbtcFees.server;
  }(),
  TraType.lbtcToBtc => () {
    final fee = BoltzFees.getChainFeesAndLimits();
    return fee.btcFees.userClaim + fee.btcFees.server;
  }(),
};

double getBoltzPercentFee(TraType type) => switch (type) {
  TraType.lbtcToLbtcSend || TraType.lbtcToLbtcReceive => 0,
  TraType.lbtcToLN => BoltzFees.getSubmarineFeesAndLimits().btcFees.percentage,
  TraType.lnToLbtc => BoltzFees.getReverseFeesAndLimits().lbtcFees.percentage,
  TraType.btcToLbtc => BoltzFees.getChainFeesAndLimits().lbtcFees.percentage,
  TraType.lbtcToBtc => BoltzFees.getChainFeesAndLimits().btcFees.percentage,
};

double? getMannaPercentFeeForSwap(TraType type, [DateTime? dt]) => switch (type) {
  TraType.lbtcToLbtcSend || TraType.lbtcToLbtcReceive => 0,
  TraType.lbtcToLN =>
    dt != null ? parseDoubleN(DB.getSettingAtTime('app_lbtc_ln_swap_fee', dt)?.value) : DbService.lbtcLnSwapFee,
  TraType.lnToLbtc =>
    dt != null ? parseDoubleN(DB.getSettingAtTime('app_ln_lbtc_swap_fee', dt)?.value) : DbService.lnLbtcSwapFee,
  TraType.btcToLbtc =>
    dt != null ? parseDoubleN(DB.getSettingAtTime('app_btc_lbtc_swap_fee', dt)?.value) : DbService.btcLbtcSwapFee,
  TraType.lbtcToBtc =>
    dt != null ? parseDoubleN(DB.getSettingAtTime('app_lbtc_btc_swap_fee', dt)?.value) : DbService.lbtcBtcSwapFee,
};

// TODO remove in future
int getTemporaryMannaFee(int amount, TraType type, [DateTime? dt]) {
  final percent = dt != null
      ? parseDoubleN(DB.getSettingAtTime('temp_swap_fee_percent', dt)?.value) ?? 0
      : DbService.tempSwapFeePercent;
  final threshold = dt != null
      ? parseDoubleN(DB.getSettingAtTime('temp_swap_fee_threshold', dt)?.value) ?? 0
      : DbService.tempSwapFeeThreshold;

  final fee = amount >= threshold ? (amount * percent / 100) : 0.0;
  if ({TraType.lbtcToBtc, TraType.lbtcToLN}.contains(type)) {
    return fee.round();
  }
  return 0;
}

class FeesAndAmounts {
  FeesAndAmounts({
    required this.liquidNetworkFee,
    required this.boltzNetworkFee,
    required this.boltzFee,
    required this.mannaFee,
    required this.sendAmount,
    required this.receiveAmount,
    required this.totalSpend,
  });

  final int liquidNetworkFee;
  final int boltzNetworkFee;
  final int boltzFee;
  final int mannaFee;
  final int sendAmount;
  final int receiveAmount;
  final int totalSpend;

  FeesAndAmounts copyWith({int? liquidNetworkFee}) => FeesAndAmounts(
    liquidNetworkFee: liquidNetworkFee ?? this.liquidNetworkFee,
    boltzNetworkFee: boltzNetworkFee,
    boltzFee: boltzFee,
    mannaFee: mannaFee,
    sendAmount: sendAmount,
    receiveAmount: receiveAmount,
    totalSpend: totalSpend,
  );

  Map<String, int> toMap() => {
    'liquidNetworkFee': liquidNetworkFee,
    'boltzNetworkFee': boltzNetworkFee,
    'boltzFee': boltzFee,
    'mannaFee': mannaFee,
    'sendAmount': sendAmount,
    'receiveAmount': receiveAmount,
    'totalSpend': totalSpend,
  };

  @override
  String toString() => jsonEncode(toMap());
}

int _getSwapSendAmount(int receiveAmount, TraType type, [DateTime? dt]) {
  final fee = ((getMannaPercentFeeForSwap(type, dt) ?? 0) + getBoltzPercentFee(type)) / 100;
  final networkFee = getSwapNetworkFees(type);
  return type != TraType.lbtcToLN
      ? ((receiveAmount + networkFee) / (1 - fee)).ceil()
      : receiveAmount + (receiveAmount * fee).ceil() + networkFee;
}

// amount in sats
int _getSwapReceiveAmount(int sendAmount, TraType type, [DateTime? dt]) {
  final fee = ((getMannaPercentFeeForSwap(type, dt) ?? 0) + getBoltzPercentFee(type)) / 100;
  final networkFee = getSwapNetworkFees(type);
  return type != TraType.lbtcToLN
      ? (sendAmount - (sendAmount * fee).ceil() - networkFee)
      : ((sendAmount - networkFee) / (1 + fee)).floor();
}

Future<FeesAndAmounts> calculateFeeAndAmounts({
  required Wallet wallet,
  required int amount,
  required TraType type,
  bool isSendAll = false,
  bool isAmountTarget = true,
  DateTime? dateTime,
  String? address,
}) async {
  if (amount <= 0) {
    return FeesAndAmounts(
      liquidNetworkFee: 0,
      boltzNetworkFee: 0,
      boltzFee: 0,
      mannaFee: 0,
      receiveAmount: 0,
      sendAmount: 0,
      totalSpend: 0,
    );
  }
  if (type == TraType.lbtcToLbtcReceive) {
    return FeesAndAmounts(
      liquidNetworkFee: 0,
      boltzNetworkFee: 0,
      boltzFee: 0,
      mannaFee: 0,
      receiveAmount: amount,
      sendAmount: amount,
      totalSpend: amount,
    );
  } else if (type == TraType.lbtcToLbtcSend) {
    final mannaPercentFee =
        parseDoubleN(DB.getSettingAtTime('liquid_fee_percent', dateTime ?? DateTime.now())?.value) ??
        DbService.liquidFeePercent;
    final mannaFeeThreshold =
        parseIntN(DB.getSettingAtTime('liquid_fee_threshold', dateTime ?? DateTime.now())?.value) ??
        DbService.liquidFeeThreshold;

    final mannaFee = !isSendAll && amount >= mannaFeeThreshold ? (amount * mannaPercentFee / 100).round() : 0;

    final networkFee = await getLiquidNetworkFeeEstimate(
      walletId: wallet.uuid,
      amount: amount,
      isSendAll: isSendAll,
      isSwapLockUp: false,
      address: address,
    );
    if (networkFee == null) {
      return FeesAndAmounts(
        liquidNetworkFee: 0,
        boltzNetworkFee: 0,
        boltzFee: 0,
        mannaFee: 0,
        sendAmount: 0,
        receiveAmount: 0,
        totalSpend: 0,
      );
    }

    return FeesAndAmounts(
      liquidNetworkFee: networkFee,
      boltzNetworkFee: 0,
      boltzFee: 0,
      mannaFee: mannaFee,
      sendAmount: isSendAll ? wallet.balance - networkFee : amount,
      receiveAmount: isSendAll ? wallet.balance - networkFee : amount,
      totalSpend: isSendAll ? wallet.balance : amount + mannaFee + networkFee,
    );
  }

  // sending
  if ({TraType.lbtcToBtc, TraType.lbtcToLN}.contains(type)) {
    final networkFee = await getLiquidNetworkFeeEstimate(
      walletId: wallet.uuid,
      amount: amount,
      isSendAll: isSendAll,
      isSwapLockUp: true,
      address: address,
    );
    if (networkFee == null) {
      return FeesAndAmounts(
        liquidNetworkFee: 0,
        boltzNetworkFee: 0,
        boltzFee: 0,
        mannaFee: 0,
        sendAmount: 0,
        receiveAmount: 0,
        totalSpend: 0,
      );
    }
    final mannaPercent = getMannaPercentFeeForSwap(type, dateTime ?? DateTime.now()) ?? 0;
    final boltzPercent = getBoltzPercentFee(type);
    final boltzNetworkFee = getSwapNetworkFees(type);

    final swapSendAmount = isSendAll
        ? wallet.balance - networkFee
        : isAmountTarget
        ? _getSwapSendAmount(amount, type, dateTime)
        : amount;

    final swapReceiveAmount = _getSwapReceiveAmount(swapSendAmount, type, dateTime);
    final totalFees = swapSendAmount - swapReceiveAmount - boltzNetworkFee;
    final x = totalFees / (boltzPercent + mannaPercent);
    final boltzFee = (x * boltzPercent).round();
    final mannaFee = totalFees - boltzFee;

    // TODO remove in future
    final tempMannaFee = getTemporaryMannaFee(swapSendAmount, type);

    return FeesAndAmounts(
      liquidNetworkFee: networkFee,
      boltzNetworkFee: boltzNetworkFee,
      boltzFee: boltzFee,
      mannaFee: mannaFee < tempMannaFee ? tempMannaFee : mannaFee,
      sendAmount: swapSendAmount,
      receiveAmount: swapReceiveAmount,
      totalSpend: swapSendAmount + networkFee + (mannaFee < tempMannaFee ? tempMannaFee : 0),
    );
  } else {
    final mannaPercent = getMannaPercentFeeForSwap(type, dateTime ?? DateTime.now()) ?? 0;
    final boltzPercent = getBoltzPercentFee(type);
    final boltzNetworkFee = getSwapNetworkFees(type);

    final swapReceiveAmount = isAmountTarget ? amount : _getSwapReceiveAmount(amount, type, dateTime);
    final swapSendAmount = _getSwapSendAmount(swapReceiveAmount, type, dateTime);
    final totalFees = swapSendAmount - swapReceiveAmount - boltzNetworkFee;
    final x = totalFees / (boltzPercent + mannaPercent);
    final boltzFee = (x * boltzPercent).round();

    return FeesAndAmounts(
      liquidNetworkFee: 0,
      boltzNetworkFee: boltzNetworkFee,
      boltzFee: boltzFee,
      mannaFee: totalFees - boltzFee,
      sendAmount: swapSendAmount,
      receiveAmount: swapReceiveAmount,
      totalSpend: swapSendAmount,
    );
  }
}

int getMannaFees({
  required int receiveAmount,
  required TraType type,
  required bool isSendAll,
  int? sendAmount,
  DateTime? dateTime,
}) {
  if (receiveAmount <= 0) return 0;
  if (type == TraType.lbtcToLbtcReceive) {
    return 0;
  } else if (type == TraType.lbtcToLbtcSend) {
    final mannaPercentFee =
        parseDoubleN(DB.getSettingAtTime('liquid_fee_percent', dateTime ?? DateTime.now())?.value) ??
        DbService.liquidFeePercent;
    final mannaFeeThreshold =
        parseIntN(DB.getSettingAtTime('liquid_fee_threshold', dateTime ?? DateTime.now())?.value) ??
        DbService.liquidFeeThreshold;

    return !isSendAll && receiveAmount >= mannaFeeThreshold ? (receiveAmount * mannaPercentFee / 100).round() : 0;
  }
  final mannaPercent = getMannaPercentFeeForSwap(type, dateTime ?? DateTime.now()) ?? 0;
  final boltzPercent = getBoltzPercentFee(type);
  final boltzNetworkFee = getSwapNetworkFees(type);

  final swapReceiveAmount = receiveAmount;
  final swapSendAmount = sendAmount ?? _getSwapSendAmount(swapReceiveAmount, type, dateTime);
  final totalFees = swapSendAmount - swapReceiveAmount - boltzNetworkFee;
  final x = totalFees / (boltzPercent + mannaPercent);
  final boltzFee = (x * boltzPercent).ceil();

  return totalFees - boltzFee;
}

Future<int?> getLiquidNetworkFeeEstimate({
  required String walletId,
  required int amount,
  required bool isSendAll,
  required bool isSwapLockUp,
  String? address,
}) async {
  try {
    bool isAddressLiquid = false;
    if (address != null) {
      try {
        await Address.validate(addressString: address);
        isAddressLiquid = true;
      } catch (_) {}
    }

    final data = await WalletService.buildTx(
      walletId: walletId,
      outAddress: isAddressLiquid
          ? address!
          : switch (Config.network) {
              Network.mainnet =>
                'lq1pqw4ttv27z6fwwthfkrjk77lw5eph2092ggwp97ndrckyggre7vr2hx900ypc586yjwecnlgfnprlrcftmak02p50jtdwv0760dq5az9n4azcvmt92jr6',
              Network.testnet => '',
              Network.regtest =>
                'el1pqv80lfr7lze26cgsxxj3gvulgwtyfscptnrtqg2gm6lqrle7ddkgy45gegdz4ce3l2r55sktptc5hj38yl0e9zem3tjkmxac05dnuh0emje2m2naqlut',
            },
      outAmount: amount,
      drain: isSendAll,
      isSwapLockup: isSwapLockUp,
      showError: false,
    );
    return data.$2?.fees.first.value.toInt();
  } catch (_) {}
  return null;
}
