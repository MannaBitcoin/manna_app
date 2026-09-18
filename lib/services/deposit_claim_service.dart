import 'dart:async';

import 'package:breez_sdk_spark_flutter/breez_sdk_spark.dart'
    show
        BreezSdk,
        ClaimDepositQuote,
        ClaimDepositRequest,
        DepositClaimError,
        DepositClaimError_Generic,
        DepositClaimError_MaxDepositClaimFeeExceeded,
        DepositClaimError_MissingUtxo,
        DepositInfo,
        Fee,
        FetchClaimDepositQuoteRequest,
        FetchClaimDepositQuoteResponse,
        InstantClaimStatus_Declined,
        InstantClaimStatus_Submitted,
        ListUnclaimedDepositsRequest,
        MaxFee,
        RecommendedFees,
        RefundDepositRequest,
        RefundState_Broadcast,
        RefundState_BroadcastPending,
        SdkError,
        SdkError_DepositClaimInProgress,
        SdkError_MaxDepositClaimFeeExceeded,
        SdkError_RefundReplacementFeeTooLow;
import 'package:flutter/foundation.dart';
import 'package:manna/globals.dart';
import 'package:manna/models/wallet.dart';
import 'package:manna/router.dart';
import 'package:manna/services/db.dart';
import 'package:manna/services/log_service.dart';
import 'package:manna/utils/de_bouncer.dart';
import 'package:manna/utils/extensions.dart';
import 'package:manna/utils/state_extension.dart';
import 'package:manna/utils/toast_service.dart';
import 'package:manna/widgets/amount_text.dart';

/// Matches the SDK default of 1 sat/vbyte. Kept low so early claims (provider
/// spread) and high on-chain fees require explicit approval instead of
/// happening silently. See https://sdk-doc-spark.breez.technology/guide/onchain_claims.html
const int kAutoClaimMaxFeeRateSatPerVbyte = 1;

enum DepositUiState {
  instantSubmitted,
  refundPending,
  refundBroadcast,
  claimFailed,
  approveFee,
  chooseEarlyOrMature,
  earlyLater,
  waitForMaturity,
  autoClaiming,
}

enum DepositClaimOption { early, mature }

class TrackedDeposit {
  TrackedDeposit({required this.xpub, required this.walletId, required this.deposit, this.quote});

  final String xpub;
  final String walletId;
  DepositInfo deposit;
  FetchClaimDepositQuoteResponse? quote;

  String get key => depositKey(deposit.txid, deposit.vout);

  DepositUiState get uiState => classifyDeposit(deposit: deposit, quote: quote);

  bool get needsUserAction => switch (uiState) {
    DepositUiState.claimFailed || DepositUiState.approveFee || DepositUiState.chooseEarlyOrMature => true,
    DepositUiState.refundPending =>
      deposit.refundState is RefundState_BroadcastPending &&
          (deposit.refundState as RefundState_BroadcastPending).lastError != null,
    _ => false,
  };

  int get confirmations => quote?.confirmations ?? 0;

  int blocksUntil(int required) {
    final current = confirmations;
    return required > current ? required - current : 0;
  }
}

String depositKey(String txid, int vout) => '$txid:$vout';

DepositUiState classifyDeposit({required DepositInfo deposit, FetchClaimDepositQuoteResponse? quote}) {
  if (deposit.instantClaimStatus is InstantClaimStatus_Submitted) {
    return DepositUiState.instantSubmitted;
  }

  switch (deposit.refundState) {
    case RefundState_BroadcastPending():
      return DepositUiState.refundPending;
    case RefundState_Broadcast():
      return DepositUiState.refundBroadcast;
    case null:
      break;
  }

  final claimError = deposit.claimError;
  if (claimError is DepositClaimError_MissingUtxo || claimError is DepositClaimError_Generic) {
    return DepositUiState.claimFailed;
  }

  final instant = quote?.instant;
  final confirmations = quote?.confirmations ?? 0;
  final instantReachable = instant != null && confirmations >= instant.confirmationsRequired;
  final instantFitsCeiling = instant != null && _quoteFitsAutoClaimCeiling(instant);
  final declined = deposit.instantClaimStatus is InstantClaimStatus_Declined;

  if (claimError is DepositClaimError_MaxDepositClaimFeeExceeded) {
    if (!deposit.isMature && instantReachable && (declined || !instantFitsCeiling)) {
      return DepositUiState.chooseEarlyOrMature;
    }
    return DepositUiState.approveFee;
  }

  if (instant == null) {
    if (deposit.isMature && claimError == null) return DepositUiState.autoClaiming;
    return DepositUiState.waitForMaturity;
  }

  if (!instantReachable) return DepositUiState.earlyLater;

  if (declined || !instantFitsCeiling) return DepositUiState.chooseEarlyOrMature;

  return DepositUiState.autoClaiming;
}

bool _quoteFitsAutoClaimCeiling(ClaimDepositQuote quote) =>
    quote.feeRateSatPerVbyte <= BigInt.from(kAutoClaimMaxFeeRateSatPerVbyte);

class DepositClaimService {
  DepositClaimService._();

  static final ValueNotifier<int> changes = ValueNotifier(0);

  // xpub -> (txid:vout -> tracked)
  static final Map<String, Map<String, TrackedDeposit>> _byXpub = {};
  static final Map<String, DeBouncer> _refreshDebouncers = {};
  static final Set<String> _promptedFingerprints = {};
  static bool _promptQueued = false;

  static List<TrackedDeposit> depositsFor({required String xpub}) {
    final deposits = _byXpub[xpub]?.values.toList() ?? [];
    deposits.sort((a, b) => b.deposit.amountSats.compareTo(a.deposit.amountSats));
    return deposits;
  }

  static TrackedDeposit? get({required String xpub, required String txid, required int vout}) =>
      _byXpub[xpub]?[depositKey(txid, vout)];

  static void clear({required String xpub}) {
    _byXpub.remove(xpub);
    _notify();
  }

  static void scheduleRefresh({required String xpub}) {
    (_refreshDebouncers[xpub] ??= DeBouncer(
      const Duration(milliseconds: 400),
    )).call(() => unawaited(refresh(xpub: xpub)));
  }

  static Future<void> onNewDeposits({required String walletId, required List<DepositInfo> deposits}) async {
    final xpub = _xpubFor(walletId);
    if (xpub == null) return;
    _merge(xpub: xpub, walletId: walletId, deposits: deposits);
    for (final deposit in deposits) {
      ToastService.show(
        'On-chain deposit of ${getSatInBitcoinStyle(deposit.amountSats.i)} detected'
        '${_accountSuffix(walletId)}',
      );
    }
    _notify();
    await _fetchQuotes(xpub: xpub, keys: deposits.map((d) => depositKey(d.txid, d.vout)));
    _queuePrompt(
      depositsFor(xpub: xpub).where((d) => deposits.any((n) => depositKey(n.txid, n.vout) == d.key)),
    );
  }

  static Future<void> onUnclaimedDeposits({
    required String walletId,
    required List<DepositInfo> deposits,
  }) async {
    final xpub = _xpubFor(walletId);
    if (xpub == null) return;
    _replace(xpub: xpub, walletId: walletId, deposits: deposits);
    _notify();
    await _fetchQuotes(xpub: xpub);
    _queuePrompt(
      depositsFor(
        xpub: xpub,
      ).where((d) => d.needsUserAction || d.uiState == DepositUiState.chooseEarlyOrMature),
    );
  }

  static Future<void> onClaimedDeposits({
    required String walletId,
    required List<DepositInfo> deposits,
  }) async {
    final xpub = _xpubFor(walletId);
    if (xpub == null) return;
    for (final deposit in deposits) {
      ToastService.show(
        'On-chain deposit of ${getSatInBitcoinStyle(deposit.amountSats.i)} claimed'
        '${_accountSuffix(walletId)}',
      );
      final existing = _byXpub[xpub]?[depositKey(deposit.txid, deposit.vout)];
      if (existing != null) {
        existing.deposit = deposit;
      }
    }
    _notify();
    scheduleRefresh(xpub: xpub);
  }

  static Future<void> refresh({required String xpub}) async {
    final sdk = _sdk(xpub);
    if (sdk == null) return;
    final walletId = DB.allWallets.where((w) => w.xpub == xpub).firstOrNull?.uuid;
    if (walletId == null) return;

    try {
      final response = await sdk.listUnclaimedDeposits(request: const ListUnclaimedDepositsRequest());
      _replace(xpub: xpub, walletId: walletId, deposits: response.deposits);
      _notify();
      await _fetchQuotes(xpub: xpub);
    } catch (e, s) {
      logE(e, stackTrace: s);
    }
  }

  static Future<FetchClaimDepositQuoteResponse?> fetchQuote({
    required String xpub,
    required String txid,
    required int vout,
  }) async {
    final sdk = _sdk(xpub);
    if (sdk == null) return null;
    try {
      final quote = await sdk.fetchClaimDepositQuote(
        request: FetchClaimDepositQuoteRequest(txid: txid, vout: vout),
      );
      final tracked = _byXpub[xpub]?[depositKey(txid, vout)];
      if (tracked != null) {
        tracked.quote = quote;
        _notify();
      }
      return quote;
    } catch (e, s) {
      logE(e, stackTrace: s);
      return null;
    }
  }

  static Future<RecommendedFees?> recommendedFees({required String xpub}) async {
    final sdk = _sdk(xpub);
    if (sdk == null) return null;
    try {
      return await sdk.recommendedFees();
    } catch (e, s) {
      logE(e, stackTrace: s);
      return null;
    }
  }

  /// Returns true if the deposit left the unclaimed list (claimed or already in progress).
  static Future<bool> claim({
    required String xpub,
    required String txid,
    required int vout,
    MaxFee? maxFee,
  }) async {
    final sdk = _sdk(xpub);
    if (sdk == null) {
      ToastService.show('Wallet is not ready');
      return false;
    }

    try {
      startLoader();
      final response = await sdk.claimDeposit(
        request: ClaimDepositRequest(txid: txid, vout: vout, maxFee: maxFee),
      );
      if (response.payment != null) {
        ToastService.show('Deposit claimed');
      } else {
        ToastService.show('Early claim submitted. Your balance will update shortly.');
      }
      await refresh(xpub: xpub);
      GlobalListener.update(stream: .account);
      return get(xpub: xpub, txid: txid, vout: vout) == null;
    } on SdkError catch (e, s) {
      return _handleClaimError(e, s, xpub: xpub, txid: txid, vout: vout);
    } catch (e, s) {
      if (e is SdkError) {
        return _handleClaimError(e, s, xpub: xpub, txid: txid, vout: vout);
      }
      logE(e, stackTrace: s, showToast: true);
      await refresh(xpub: xpub);
      return false;
    } finally {
      stopLoader();
    }
  }

  static Future<bool> _handleClaimError(
    SdkError e,
    StackTrace s, {
    required String xpub,
    required String txid,
    required int vout,
  }) async {
    switch (e) {
      case SdkError_DepositClaimInProgress():
        ToastService.show('This deposit is already being claimed. Please wait.');
        await refresh(xpub: xpub);
        return false;
      case SdkError_MaxDepositClaimFeeExceeded(:final requiredFeeSats):
        ToastService.show('A higher fee is required: ${getSatInBitcoinStyle(requiredFeeSats.i)}');
        await refresh(xpub: xpub);
        return false;
      default:
        logE(e, stackTrace: s, showToast: true);
        await refresh(xpub: xpub);
        return false;
    }
  }

  static Future<bool> refund({
    required String xpub,
    required String txid,
    required int vout,
    required String destinationAddress,
    required Fee fee,
  }) async {
    final sdk = _sdk(xpub);
    if (sdk == null) {
      ToastService.show('Wallet is not ready');
      return false;
    }

    try {
      startLoader();
      final response = await sdk.refundDeposit(
        request: RefundDepositRequest(
          txid: txid,
          vout: vout,
          destinationAddress: destinationAddress,
          fee: fee,
        ),
      );
      ToastService.show('Refund broadcast: ${response.txId.shortenAddress()}');
      await refresh(xpub: xpub);
      return true;
    } on SdkError catch (e, s) {
      return _handleRefundError(e, s, xpub: xpub);
    } catch (e, s) {
      if (e is SdkError) {
        return _handleRefundError(e, s, xpub: xpub);
      }
      logE(e, stackTrace: s, showToast: true);
      await refresh(xpub: xpub);
      return false;
    } finally {
      stopLoader();
    }
  }

  static Future<bool> _handleRefundError(SdkError e, StackTrace s, {required String xpub}) async {
    switch (e) {
      case SdkError_RefundReplacementFeeTooLow(:final requiredFeeSats):
        ToastService.show(
          'Refund fee is too low. At least ${getSatInBitcoinStyle(requiredFeeSats.i)} is required to replace it.',
        );
        await refresh(xpub: xpub);
        return false;
      default:
        logE(e, stackTrace: s, showToast: true);
        await refresh(xpub: xpub);
        return false;
    }
  }

  static BigInt? requiredFeeSats(TrackedDeposit tracked) {
    final error = tracked.deposit.claimError;
    if (error is DepositClaimError_MaxDepositClaimFeeExceeded) return error.requiredFeeSats;
    return tracked.quote?.mature.feeSats;
  }

  static BigInt? requiredFeeRate(TrackedDeposit tracked) {
    final error = tracked.deposit.claimError;
    if (error is DepositClaimError_MaxDepositClaimFeeExceeded) return error.requiredFeeRateSatPerVbyte;
    return tracked.quote?.mature.feeRateSatPerVbyte;
  }

  static String? claimErrorMessage(DepositClaimError? error) {
    if (error == null) return null;
    return switch (error) {
      DepositClaimError_MaxDepositClaimFeeExceeded(
        :final requiredFeeSats,
        :final requiredFeeRateSatPerVbyte,
      ) =>
        'Automatic claim needs a fee of ${getSatInBitcoinStyle(requiredFeeSats.i)} ($requiredFeeRateSatPerVbyte sat/vB).',
      DepositClaimError_MissingUtxo() => 'The deposit output was not found when claiming.',
      DepositClaimError_Generic(:final message) => message,
    };
  }

  static void _merge({required String xpub, required String walletId, required List<DepositInfo> deposits}) {
    final map = _byXpub[xpub] ??= {};
    for (final deposit in deposits) {
      final key = depositKey(deposit.txid, deposit.vout);
      final existing = map[key];
      if (existing != null) {
        existing.deposit = deposit;
      } else {
        map[key] = TrackedDeposit(xpub: xpub, walletId: walletId, deposit: deposit);
      }
    }
  }

  static void _replace({
    required String xpub,
    required String walletId,
    required List<DepositInfo> deposits,
  }) {
    final previous = _byXpub[xpub] ?? {};
    final next = <String, TrackedDeposit>{};
    for (final deposit in deposits) {
      final key = depositKey(deposit.txid, deposit.vout);
      final existing = previous[key];
      if (existing != null) {
        existing.deposit = deposit;
        next[key] = existing;
      } else {
        next[key] = TrackedDeposit(xpub: xpub, walletId: walletId, deposit: deposit);
      }
    }
    _byXpub[xpub] = next;
  }

  static Future<void> _fetchQuotes({required String xpub, Iterable<String>? keys}) async {
    final sdk = _sdk(xpub);
    if (sdk == null) return;
    final tracked = depositsFor(xpub: xpub).where((d) {
      if (keys != null && !keys.contains(d.key)) return false;
      return switch (d.uiState) {
        DepositUiState.instantSubmitted ||
        DepositUiState.refundPending ||
        DepositUiState.refundBroadcast ||
        DepositUiState.claimFailed => false,
        _ => true,
      };
    });

    await Future.wait(
      tracked.map((d) async {
        try {
          d.quote = await sdk.fetchClaimDepositQuote(
            request: FetchClaimDepositQuoteRequest(txid: d.deposit.txid, vout: d.deposit.vout),
          );
        } catch (e, s) {
          logE(e, stackTrace: s);
        }
      }),
    );
    _notify();
  }

  static void _queuePrompt(Iterable<TrackedDeposit> candidates) {
    final toPrompt = candidates
        .where(_shouldAutoPrompt)
        .where((d) => !_promptedFingerprints.contains(_fingerprint(d)))
        .toList();
    if (toPrompt.isEmpty) return;

    if (_promptQueued) {
      GlobalListener.update(stream: .deposits, data: toPrompt);
      return;
    }
    _promptQueued = true;
    postFrameCallBack(() {
      _promptQueued = false;
      GlobalListener.update(stream: .deposits, data: toPrompt);
    });
  }

  static void markPrompted(Iterable<TrackedDeposit> deposits) {
    for (final deposit in deposits) {
      _promptedFingerprints.add(_fingerprint(deposit));
    }
  }

  static bool _shouldAutoPrompt(TrackedDeposit deposit) {
    return switch (deposit.uiState) {
      DepositUiState.claimFailed ||
      DepositUiState.approveFee ||
      DepositUiState.chooseEarlyOrMature ||
      DepositUiState.earlyLater => true,
      DepositUiState.refundPending =>
        deposit.deposit.refundState is RefundState_BroadcastPending &&
            (deposit.deposit.refundState as RefundState_BroadcastPending).lastError != null,
      _ => false,
    };
  }

  static String _fingerprint(TrackedDeposit deposit) =>
      '${deposit.key}:${deposit.uiState.name}:${deposit.deposit.claimError.runtimeType}:'
      '${deposit.deposit.instantClaimStatus.runtimeType}:${deposit.deposit.refundState.runtimeType}';

  static String? _xpubFor(String walletId) =>
      DB.allWallets.where((w) => w.uuid == walletId).firstOrNull?.xpub;

  static String _accountSuffix(String walletId) {
    final name = DB.allWallets.where((w) => w.uuid == walletId).firstOrNull?.account.name;
    if (name == null || name.isEmpty) return '';
    return ' in $name';
  }

  static void _notify() {
    changes.value++;
    GlobalListener.update(stream: .account);
  }

  static BreezSdk? _sdk(String xpub) {
    final Wallet? wallet = DB.allWallets.where((w) => w.xpub == xpub).firstOrNull;
    return wallet?.spark;
  }
}

bool get isDepositClaimUiOpen {
  return AppRouter.navigatorObserver.popupStack.any((r) => r.settings.name == 'DepositClaimBottomSheet') ||
      AppRouter.navigatorObserver.pageStack.any((r) => r.settings.name == 'UnclaimedDepositsScreen');
}
