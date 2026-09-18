import 'dart:async';

import 'package:breez_sdk_spark_flutter/breez_sdk_spark.dart' show RefundState_BroadcastPending;
import 'package:flutter/material.dart';
import 'package:manna/globals.dart';
import 'package:manna/models/account.dart';
import 'package:manna/router.dart';
import 'package:manna/services/deposit_claim_service.dart';
import 'package:manna/theme.dart';
import 'package:manna/utils/extensions.dart';
import 'package:manna/utils/state_extension.dart';
import 'package:manna/widgets/amount_text.dart';
import 'package:manna/widgets/bottom%20sheets/deposit_claim_bottom_sheet.dart';

void promptUnclaimedDeposits(List<TrackedDeposit> deposits) {
  if (deposits.isEmpty || !globalState.value.isAppForeground) return;
  final context = AppRouter.navigatorKey.currentContext;
  if (context == null || !context.mounted) return;
  if (isDepositClaimUiOpen) return;

  final page = AppRouter.navigatorObserver.pageStack.lastOrNull?.settings.name;
  if ({'SplashScreen', 'SetupWalletScreen', 'RestoreWalletScreen', 'SeedPhraseScreen'}.contains(page)) {
    return;
  }

  DepositClaimService.markPrompted(deposits);
  if (deposits.length == 1) {
    final deposit = deposits.first;
    unawaited(
      showDepositClaimSheet(
        context: context,
        xpub: deposit.xpub,
        txid: deposit.deposit.txid,
        vout: deposit.deposit.vout,
      ),
    );
  } else {
    AppRouter.pushIfNotExists(UnclaimedDepositsScreen(xpub: deposits.first.xpub));
  }
}

class UnclaimedDepositsScreen extends StatefulWidget {
  const UnclaimedDepositsScreen({this.xpub, super.key});

  final String? xpub;

  @override
  State<UnclaimedDepositsScreen> createState() => _UnclaimedDepositsScreenState();
}

class _UnclaimedDepositsScreenState extends State<UnclaimedDepositsScreen> {
  late String xpub = widget.xpub ?? selectedWallet.xpub;

  @override
  void initState() {
    DepositClaimService.changes.addListener(_onChanged);
    unawaited(DepositClaimService.refresh(xpub: xpub));
    super.initState();
  }

  @override
  void dispose() {
    DepositClaimService.changes.removeListener(_onChanged);
    super.dispose();
  }

  void _onChanged() => update();

  @override
  Widget build(BuildContext context) {
    final deposits = DepositClaimService.depositsFor(xpub: xpub);
    return Scaffold(
      appBar: AppBar(title: const Text('On-chain deposits')),
      body: Align(
        alignment: Alignment.topCenter,
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 600),
          child: deposits.isEmpty
              ? const Center(child: Text('No pending on-chain deposits.'))
              : ListView.separated(
                  padding: const EdgeInsets.all(16),
                  itemCount: deposits.length,
                  separatorBuilder: (context, index) => const SizedBox(height: 8),
                  itemBuilder: (context, index) => _DepositCard(deposit: deposits[index]),
                ),
        ),
      ),
    );
  }
}

class _DepositCard extends StatelessWidget {
  const _DepositCard({required this.deposit});

  final TrackedDeposit deposit;

  @override
  Widget build(BuildContext context) {
    return Card(
      child: ListTile(
        contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
        title: AmountText(amountSat: deposit.deposit.amountSats.i, showFiat: true),
        subtitle: Column(
          crossAxisAlignment: .start,
          children: [
            const SizedBox(height: 4),
            Text(_subtitle(deposit)),
            Text(
              '${deposit.deposit.txid.shortenAddress()}:${deposit.deposit.vout}',
              style: const TextStyle(color: AppColors.accentColor, fontSize: 12),
            ),
          ],
        ),
        trailing: Row(
          mainAxisSize: .min,
          children: [
            if (deposit.needsUserAction)
              const Icon(Icons.error_outline, color: Colors.orange)
            else
              const Icon(Icons.hourglass_top_outlined, color: AppColors.accentColor),
            const Icon(Icons.chevron_right),
          ],
        ),
        onTap: () => unawaited(
          showDepositClaimSheet(
            context: context,
            xpub: deposit.xpub,
            txid: deposit.deposit.txid,
            vout: deposit.deposit.vout,
          ),
        ),
      ),
    );
  }

  String _subtitle(TrackedDeposit deposit) {
    return switch (deposit.uiState) {
      DepositUiState.instantSubmitted => 'Early claim submitted',
      DepositUiState.refundPending =>
        deposit.deposit.refundState is RefundState_BroadcastPending &&
                (deposit.deposit.refundState as RefundState_BroadcastPending).lastError != null
            ? 'Refund needs a higher fee'
            : 'Refund waiting to broadcast',
      DepositUiState.refundBroadcast => 'Refund broadcasting',
      DepositUiState.claimFailed => 'Claim failed',
      DepositUiState.approveFee => 'Approve claim fee',
      DepositUiState.chooseEarlyOrMature => 'Choose early or wait',
      DepositUiState.earlyLater => () {
        final instant = deposit.quote?.instant;
        if (instant == null) return 'Waiting for confirmations';
        final wait = deposit.blocksUntil(instant.confirmationsRequired);
        return 'Early claim in $wait block${wait == 1 ? '' : 's'}';
      }(),
      DepositUiState.waitForMaturity => deposit.deposit.isMature ? 'Ready to claim' : 'Waiting to mature',
      DepositUiState.autoClaiming => 'Claiming automatically',
    };
  }
}

class UnclaimedDepositsBanner extends StatelessWidget {
  const UnclaimedDepositsBanner({required this.xpub, this.lightOnDark = false, super.key});

  final String xpub;
  final bool lightOnDark;

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder(
      valueListenable: DepositClaimService.changes,
      builder: (context, _, _) {
        final deposits = DepositClaimService.depositsFor(xpub: xpub);
        if (deposits.isEmpty) return const SizedBox.shrink();
        final needsAction = deposits.where((d) => d.needsUserAction).length;
        final label = needsAction > 0
            ? (needsAction == 1
                  ? 'Action needed to claim an on-chain deposit'
                  : 'Action needed to claim $needsAction on-chain deposits')
            : (deposits.length == 1
                  ? 'On-chain deposit pending'
                  : '${deposits.length} on-chain deposits pending');

        final foreground = lightOnDark ? Colors.white : null;
        return Padding(
          padding: EdgeInsets.fromLTRB(8, lightOnDark ? 12 : 0, 8, 0),
          child: Material(
            color: lightOnDark
                ? Colors.white.withValues(alpha: 0.12)
                : AppColors.primaryColor.withValues(alpha: 0.1),
            borderRadius: BorderRadius.circular(12),
            child: InkWell(
              borderRadius: BorderRadius.circular(12),
              onTap: () {
                if (deposits.length == 1) {
                  final deposit = deposits.first;
                  unawaited(
                    showDepositClaimSheet(
                      context: context,
                      xpub: deposit.xpub,
                      txid: deposit.deposit.txid,
                      vout: deposit.deposit.vout,
                    ),
                  );
                } else {
                  AppRouter.push(UnclaimedDepositsScreen(xpub: xpub));
                }
              },
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
                child: Row(
                  children: [
                    Icon(
                      needsAction > 0 ? Icons.error_outline : Icons.hourglass_top_outlined,
                      color: needsAction > 0 ? Colors.orange : foreground ?? AppColors.primaryColor,
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        label,
                        style: TextStyle(color: foreground, fontWeight: FontWeight.w500),
                      ),
                    ),
                    Icon(Icons.chevron_right, color: foreground),
                  ],
                ),
              ),
            ),
          ),
        );
      },
    );
  }
}
