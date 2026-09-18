import 'dart:async';

import 'package:breez_sdk_spark_flutter/breez_sdk_spark.dart'
    show ClaimDepositQuote, Fee, InstantClaimStatus_Submitted, MaxFee, RecommendedFees, RefundState_BroadcastPending;
import 'package:flutter/material.dart';
import 'package:manna/app_state.dart';
import 'package:manna/config.dart';
import 'package:manna/models/enums.dart';
import 'package:manna/router.dart';
import 'package:manna/screens/qr_scanner_screen.dart';
import 'package:manna/services/clipboard_service.dart';
import 'package:manna/services/deposit_claim_service.dart';
import 'package:manna/services/log_service.dart';
import 'package:manna/services/transaction_service.dart';
import 'package:manna/theme.dart';
import 'package:manna/utils/extensions.dart';
import 'package:manna/utils/state_extension.dart';
import 'package:manna/utils/toast_service.dart';
import 'package:manna/widgets/amount_text.dart';
import 'package:manna/widgets/fees_tile.dart';
import 'package:url_launcher/url_launcher_string.dart';

Future<void> showDepositClaimSheet({
  required BuildContext context,
  required String xpub,
  required String txid,
  required int vout,
}) {
  if (AppRouter.navigatorObserver.popupStack.any((r) => r.settings.name == 'DepositClaimBottomSheet')) {
    return Future.value();
  }
  return showModalBottomSheet(
    context: context,
    showDragHandle: true,
    isScrollControlled: true,
    useSafeArea: true,
    shape: const RoundedRectangleBorder(borderRadius: BorderRadius.vertical(top: Radius.circular(24))),
    routeSettings: const RouteSettings(name: 'DepositClaimBottomSheet'),
    builder: (context) => DepositClaimBottomSheet(xpub: xpub, txid: txid, vout: vout),
  );
}

class DepositClaimBottomSheet extends StatefulWidget {
  const DepositClaimBottomSheet({required this.xpub, required this.txid, required this.vout, super.key});

  final String xpub;
  final String txid;
  final int vout;

  @override
  State<DepositClaimBottomSheet> createState() => _DepositClaimBottomSheetState();
}

class _DepositClaimBottomSheetState extends State<DepositClaimBottomSheet> {
  DepositClaimOption? selectedOption;
  bool showRefund = false;
  bool isWorking = false;
  final refundAddressController = TextEditingController();
  BigInt? selectedRefundRate;
  RecommendedFees? recommendedFees;
  String? refundAddressError;

  TrackedDeposit? get tracked => DepositClaimService.get(xpub: widget.xpub, txid: widget.txid, vout: widget.vout);

  @override
  void initState() {
    DepositClaimService.changes.addListener(_onDepositsChanged);
    unawaited(_ensureQuote());
    unawaited(_loadFees());
    super.initState();
  }

  @override
  void dispose() {
    DepositClaimService.changes.removeListener(_onDepositsChanged);
    refundAddressController.dispose();
    super.dispose();
  }

  void _onDepositsChanged() {
    if (!mounted) return;
    final current = tracked;
    if (current == null) {
      if (Navigator.of(context).canPop()) {
        AppRouter.pop();
      }
      return;
    }
    _syncDefaultOption(current);
    update();
  }

  Future<void> _ensureQuote() async {
    await DepositClaimService.fetchQuote(xpub: widget.xpub, txid: widget.txid, vout: widget.vout);
    if (!mounted) return;
    final current = tracked;
    if (current != null) _syncDefaultOption(current);
    update();
  }

  Future<void> _loadFees() async {
    recommendedFees = await DepositClaimService.recommendedFees(xpub: widget.xpub);
    if (!mounted) return;
    selectedRefundRate ??= recommendedFees?.halfHourFee;
    update();
  }

  void _syncDefaultOption(TrackedDeposit current) {
    if (selectedOption != null) return;
    final instant = current.quote?.instant;
    selectedOption = switch (current.uiState) {
      DepositUiState.chooseEarlyOrMature || DepositUiState.earlyLater => DepositClaimOption.mature,
      DepositUiState.autoClaiming when instant != null && current.blocksUntil(instant.confirmationsRequired) == 0 =>
        DepositClaimOption.early,
      _ => DepositClaimOption.mature,
    };
  }

  @override
  Widget build(BuildContext context) {
    final current = tracked;
    if (current == null) {
      return const Padding(
        padding: EdgeInsets.all(24),
        child: Center(child: Text('This deposit has been claimed.')),
      );
    }

    return SingleChildScrollView(
      padding: const EdgeInsets.only(left: 24, right: 24, bottom: 24) + context.keyboardPadding,
      child: Column(
        crossAxisAlignment: .start,
        children: [
          const Text('On-chain deposit', style: TextStyle(fontWeight: FontWeight.w500, fontSize: 20)),
          const SizedBox(height: 12),
          Center(
            child: AmountText(
              amountSat: current.deposit.amountSats.i,
              showFiat: true,
              btcStyle: const TextStyle(fontWeight: FontWeight.bold, fontSize: 30),
            ),
          ),
          const SizedBox(height: 8),
          _statusChip(current),
          const SizedBox(height: 8),
          Center(
            child: TextButton(
              onPressed: () {
                final url = TransactionService.generateExplorerUrl(
                  AppState.blockExplorer,
                  'tx/${current.deposit.txid}',
                  isBTC: true,
                ).toString();
                unawaited(launchUrlString(url));
              },
              onLongPress: () => ClipboardService.setClipBoard('${current.deposit.txid}:${current.deposit.vout}'),
              child: Text(
                '${current.deposit.txid.shortenAddress(charCount: 10)}:${current.deposit.vout}',
                style: const TextStyle(color: AppColors.accentColor),
              ),
            ),
          ),
          const Divider(height: 24),
          if (showRefund) _refundForm(current) else ..._claimBody(current),
        ],
      ),
    );
  }

  Widget _statusChip(TrackedDeposit current) {
    final (label, color) = switch (current.uiState) {
      DepositUiState.instantSubmitted => ('Early claim submitted', Colors.blue),
      DepositUiState.refundPending => ('Refund pending broadcast', Colors.orange),
      DepositUiState.refundBroadcast => ('Refund broadcasting', Colors.blue),
      DepositUiState.claimFailed => ('Claim failed', Colors.red),
      DepositUiState.approveFee => ('Fee approval needed', Colors.orange),
      DepositUiState.chooseEarlyOrMature => ('Choose how to claim', AppColors.primaryColor),
      DepositUiState.earlyLater => ('Waiting for confirmations', Colors.blueGrey),
      DepositUiState.waitForMaturity => (
        current.deposit.isMature ? 'Ready to claim' : 'Waiting to mature',
        Colors.blueGrey,
      ),
      DepositUiState.autoClaiming => ('Claiming automatically', Colors.green),
    };
    return Center(
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
        decoration: BoxDecoration(color: color.withValues(alpha: 0.12), borderRadius: BorderRadius.circular(99)),
        child: Text(
          label,
          style: TextStyle(color: color, fontWeight: FontWeight.w500),
        ),
      ),
    );
  }

  List<Widget> _claimBody(TrackedDeposit current) {
    return [
      _statusDetails(current),
      const SizedBox(height: 12),
      if (_shouldShowQuoteChoices(current)) ...[
        const Text('Claim options', style: TextStyle(fontWeight: FontWeight.w600, fontSize: 16)),
        const SizedBox(height: 8),
        if (current.quote?.instant != null)
          _quoteCard(
            option: DepositClaimOption.early,
            title: _earlyTitle(current),
            quote: current.quote!.instant!,
            confirmations: current.confirmations,
            enabled: current.blocksUntil(current.quote!.instant!.confirmationsRequired) == 0,
          ),
        _quoteCard(
          option: DepositClaimOption.mature,
          title: _matureTitle(current),
          quote: current.quote!.mature,
          confirmations: current.confirmations,
        ),
        const SizedBox(height: 16),
      ],
      if (_claimButtonLabel(current) != null)
        SizedBox(
          width: double.infinity,
          child: ElevatedButton(
            onPressed: isWorking ? null : () => unawaited(_claim(current)),
            style: ElevatedButton.styleFrom(visualDensity: VisualDensity.standard),
            child: Text(_claimButtonLabel(current)!),
          ),
        ),
      if (_canRefund(current))
        SizedBox(
          width: double.infinity,
          child: TextButton(
            onPressed: isWorking ? null : () => update(() => showRefund = true),
            child: const Text('Refund to another address'),
          ),
        ),
    ];
  }

  Widget _statusDetails(TrackedDeposit current) {
    final confirmationsText = current.quote != null
        ? '${current.confirmations} confirmation${current.confirmations == 1 ? '' : 's'}'
        : (current.deposit.isMature ? 'Mature' : 'Not yet mature');
    final errorMessage = DepositClaimService.claimErrorMessage(current.deposit.claimError);
    final refundState = current.deposit.refundState;
    final submitted = current.deposit.instantClaimStatus;

    return Container(
      width: double.infinity,
      decoration: BoxDecoration(borderRadius: BorderRadius.circular(16), color: Colors.grey.withValues(alpha: 0.05)),
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: .start,
        spacing: 8,
        children: [
          Text(confirmationsText, style: const TextStyle(color: AppColors.accentColor)),
          if (errorMessage != null) Text(errorMessage),
          if (submitted is InstantClaimStatus_Submitted)
            const Text('The provider is crediting this deposit. It will disappear once it settles.'),
          if (refundState is RefundState_BroadcastPending) ...[
            const Text('The refund is signed and will be rebroadcast until the network accepts it.'),
            if (refundState.lastError != null)
              Text('Last error: ${refundState.lastError}', style: const TextStyle(color: Colors.orange)),
          ],
          if (current.uiState == DepositUiState.autoClaiming)
            const Text('No action needed. This deposit will be claimed automatically.'),
          if (current.uiState == DepositUiState.waitForMaturity)
            const Text('It will be claimed automatically once it has enough confirmations, if network fees allow.'),
        ],
      ),
    );
  }

  bool _shouldShowQuoteChoices(TrackedDeposit current) {
    if (current.quote == null) return false;
    return switch (current.uiState) {
      DepositUiState.chooseEarlyOrMature ||
      DepositUiState.earlyLater ||
      DepositUiState.approveFee ||
      DepositUiState.waitForMaturity => true,
      _ => false,
    };
  }

  String _earlyTitle(TrackedDeposit current) {
    final instant = current.quote?.instant;
    if (instant == null) return 'Claim now';
    final wait = current.blocksUntil(instant.confirmationsRequired);
    if (wait == 0) return 'Claim now';
    return 'Claim early in $wait block${wait == 1 ? '' : 's'}';
  }

  String _matureTitle(TrackedDeposit current) {
    final mature = current.quote?.mature;
    if (mature == null) return 'Wait for maturity';
    final wait = current.blocksUntil(mature.confirmationsRequired);
    if (wait == 0) return 'Claim at current fees';
    return 'Wait $wait more block${wait == 1 ? '' : 's'}';
  }

  Widget _quoteCard({
    required DepositClaimOption option,
    required String title,
    required ClaimDepositQuote quote,
    required int confirmations,
    bool enabled = true,
  }) {
    final selected = selectedOption == option;
    final wait = quote.confirmationsRequired > confirmations ? quote.confirmationsRequired - confirmations : 0;
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: InkWell(
        onTap: enabled ? () => update(() => selectedOption = option) : null,
        borderRadius: BorderRadius.circular(16),
        child: Container(
          width: double.infinity,
          padding: const EdgeInsets.all(16),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(16),
            border: Border.all(
              color: selected ? AppColors.primaryColor : Colors.grey.withValues(alpha: 0.4),
              width: selected ? 2 : 1,
            ),
            color: selected ? AppColors.primaryColor.withValues(alpha: 0.06) : null,
          ),
          child: Column(
            crossAxisAlignment: .start,
            spacing: 6,
            children: [
              Row(
                children: [
                  Icon(
                    selected ? Icons.radio_button_checked : Icons.radio_button_off,
                    color: enabled ? AppColors.primaryColor : Colors.grey,
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      title,
                      style: TextStyle(fontWeight: FontWeight.w600, fontSize: 16, color: enabled ? null : Colors.grey),
                    ),
                  ),
                ],
              ),
              FeesTile(title: 'Fee', amountSat: quote.feeSats.i),
              FeesTile(title: 'You receive', amountSat: quote.creditAmountSats.i),
              Text(
                '${quote.feeRateSatPerVbyte} sat/vB'
                '${quote.isEstimate ? ' · estimate, final fee may differ' : ''}'
                '${wait > 0 ? ' · ${quote.confirmationsRequired} confirmations required' : ''}',
                style: const TextStyle(color: AppColors.accentColor, fontSize: 13),
              ),
            ],
          ),
        ),
      ),
    );
  }

  String? _claimButtonLabel(TrackedDeposit current) {
    return switch (current.uiState) {
      DepositUiState.approveFee => selectedOption == DepositClaimOption.early ? 'Claim now' : 'Claim with this fee',
      DepositUiState.chooseEarlyOrMature =>
        selectedOption == DepositClaimOption.early ? 'Claim now' : 'Wait for a cheaper claim',
      DepositUiState.earlyLater =>
        selectedOption == DepositClaimOption.early ? 'Claim when available' : 'Wait for maturity',
      DepositUiState.waitForMaturity when current.deposit.isMature => 'Claim',
      DepositUiState.waitForMaturity => 'Got it',
      DepositUiState.claimFailed => 'Retry claim',
      DepositUiState.autoClaiming => 'OK',
      DepositUiState.instantSubmitted || DepositUiState.refundBroadcast => 'OK',
      DepositUiState.refundPending => null,
    };
  }

  bool _canRefund(TrackedDeposit current) {
    return switch (current.uiState) {
      DepositUiState.claimFailed || DepositUiState.approveFee || DepositUiState.refundPending => true,
      DepositUiState.chooseEarlyOrMature || DepositUiState.waitForMaturity => current.deposit.isMature,
      _ => false,
    };
  }

  Future<void> _claim(TrackedDeposit current) async {
    final option = selectedOption ?? DepositClaimOption.mature;

    if (current.uiState == DepositUiState.autoClaiming ||
        current.uiState == DepositUiState.instantSubmitted ||
        current.uiState == DepositUiState.refundBroadcast) {
      AppRouter.pop();
      return;
    }

    if (option == DepositClaimOption.mature &&
        !current.deposit.isMature &&
        current.uiState != DepositUiState.approveFee) {
      ToastService.show('This deposit will be claimed automatically once it matures.');
      AppRouter.pop();
      return;
    }

    MaxFee? maxFee;
    if (option == DepositClaimOption.early) {
      final instant = current.quote?.instant;
      if (instant == null) {
        ToastService.show('Early claim is not available for this deposit.');
        return;
      }
      if (current.blocksUntil(instant.confirmationsRequired) > 0) {
        ToastService.show(
          'Early claim will be available after ${current.blocksUntil(instant.confirmationsRequired)} more confirmation(s).',
        );
        return;
      }
      maxFee = MaxFee.fixed(amount: instant.feeSats);
    } else if (current.uiState == DepositUiState.claimFailed) {
      maxFee = MaxFee.networkRecommended(leewaySatPerVbyte: BigInt.one);
    } else {
      final required = DepositClaimService.requiredFeeSats(current);
      if (required == null && !current.deposit.isMature) {
        AppRouter.pop();
        return;
      }
      if (required == null) {
        ToastService.show('Could not determine the required fee.');
        return;
      }
      maxFee = MaxFee.fixed(amount: required);
    }

    update(() => isWorking = true);
    await DepositClaimService.claim(xpub: widget.xpub, txid: widget.txid, vout: widget.vout, maxFee: maxFee);
    if (mounted) update(() => isWorking = false);
  }

  Widget _refundForm(TrackedDeposit current) {
    final pending = current.deposit.refundState;
    final rates = recommendedFees;
    return Column(
      crossAxisAlignment: .start,
      spacing: 12,
      children: [
        const Text('Refund deposit', style: TextStyle(fontWeight: FontWeight.w600, fontSize: 16)),
        const Text(
          'Sends the deposit (minus miner fees) to an external Bitcoin address. The deposit must have enough confirmations.',
          style: TextStyle(color: AppColors.accentColor),
        ),
        if (pending is RefundState_BroadcastPending && pending.lastError != null)
          Text('Previous refund was rejected: ${pending.lastError}', style: const TextStyle(color: Colors.orange)),
        TextFormField(
          controller: refundAddressController,
          decoration: InputDecoration(
            labelText: 'Bitcoin address',
            errorText: refundAddressError,
            suffixIcon: IconButton(
              tooltip: 'Scan',
              onPressed: () => unawaited(_scanRefundAddress()),
              icon: const Icon(Icons.qr_code_scanner),
            ),
          ),
          minLines: 1,
          maxLines: 3,
          onChanged: (_) => update(() => refundAddressError = null),
        ),
        Align(
          alignment: Alignment.centerRight,
          child: TextButton(
            onPressed: () async {
              final text = await ClipboardService.read('text/plain');
              if (text != null && text.trim().isNotEmpty) {
                refundAddressController.text = text.trim();
                update();
              }
            },
            child: const Text('Paste'),
          ),
        ),
        const Text('Refund fee', style: TextStyle(fontWeight: FontWeight.w500)),
        if (rates == null)
          const Center(
            child: Padding(padding: EdgeInsets.all(12), child: CircularProgressIndicator()),
          )
        else
          RadioGroup<BigInt>(
            groupValue: selectedRefundRate,
            onChanged: (value) => update(() => selectedRefundRate = value),
            child: Column(
              children: [
                for (final entry in {
                  rates.fastestFee: 'Fastest',
                  rates.halfHourFee: '30 minutes',
                  rates.hourFee: '1 hour',
                  rates.economyFee: 'Economy',
                  rates.minimumFee: 'Minimum',
                }.entries)
                  RadioListTile<BigInt>(
                    value: entry.key,
                    title: Text(entry.value),
                    subtitle: Text('${entry.key} sat/vB'),
                    contentPadding: EdgeInsets.zero,
                  ),
              ],
            ),
          ),
        SizedBox(
          width: double.infinity,
          child: ElevatedButton(
            onPressed: isWorking ? null : () => unawaited(_refund(current)),
            style: ElevatedButton.styleFrom(visualDensity: VisualDensity.standard),
            child: Text(pending is RefundState_BroadcastPending ? 'Replace refund' : 'Refund'),
          ),
        ),
        SizedBox(
          width: double.infinity,
          child: TextButton(
            onPressed: isWorking ? null : () => update(() => showRefund = false),
            child: const Text('Back'),
          ),
        ),
      ],
    );
  }

  Future<void> _scanRefundAddress() async {
    final res = await AppRouter.push(
      QRScannerScreen(
        validateQr: (qrData) async {
          try {
            final parsed = await TransactionService.processAddress(rawAddress: qrData, network: Config.network);
            return parsed.addressType == AddressType.bitcoin;
          } catch (_) {}
          return false;
        },
      ),
    );
    if (res is String) {
      final parsed = await TransactionService.processAddress(rawAddress: res, network: Config.network);
      if (parsed.addressType == AddressType.bitcoin) {
        refundAddressController.text = parsed.address;
        update(() => refundAddressError = null);
      } else {
        ToastService.show('Scan a Bitcoin address');
      }
    }
  }

  Future<void> _refund(TrackedDeposit current) async {
    final raw = refundAddressController.text.trim();
    if (raw.isEmpty) {
      update(() => refundAddressError = 'Enter a Bitcoin address');
      return;
    }

    try {
      final parsed = await TransactionService.processAddress(rawAddress: raw, network: Config.network);
      if (parsed.addressType != AddressType.bitcoin) {
        update(() => refundAddressError = 'Enter a valid Bitcoin address');
        return;
      }

      final rate = selectedRefundRate ?? recommendedFees?.halfHourFee;
      if (rate == null) {
        ToastService.show('Could not load recommended fees.');
        return;
      }

      update(() => isWorking = true);
      final done = await DepositClaimService.refund(
        xpub: widget.xpub,
        txid: widget.txid,
        vout: widget.vout,
        destinationAddress: parsed.address,
        fee: Fee.rate(satPerVbyte: rate),
      );
      if (mounted) update(() => isWorking = false);
      if (done && mounted) {
        showRefund = false;
        update();
      }
    } catch (e, s) {
      logE(e, stackTrace: s, showToast: true);
      if (mounted) update(() => isWorking = false);
    }
  }
}
