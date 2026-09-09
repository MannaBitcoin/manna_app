import 'package:flutter/material.dart';
import 'package:manna/app_state.dart';
import 'package:manna/config.dart';
import 'package:manna/globals.dart';
import 'package:manna/models/swap.dart';
import 'package:manna/services/db.dart';
import 'package:manna/theme.dart';
import 'package:manna/utils/extensions.dart';
import 'package:manna/utils/parser.dart';
import 'package:manna/utils/state_extension.dart';
import 'package:manna/widgets/shimmer.dart';
import 'package:manna_core/manna_core.dart';
import '../amount_text.dart';

class ReceivingTx {
  ReceivingTx({this.swapId, this.walletId, this.amount, this.txId})
    : assert(
        swapId != null || (amount != null && (walletId != null || txId != null)),
        'You must provide either a swapId, or (amount AND walletId), or (amount AND txId).',
      );

  factory ReceivingTx.fromMap(Map map) => ReceivingTx(
    swapId: parseStringN(map['swapId']),
    walletId: parseStringN(map['walletId']),
    amount: parseIntN(map['amount']),
    txId: parseStringN(map['txId']),
  );

  final String? swapId;
  final String? walletId;
  final int? amount;
  final String? txId;

  Map<String, dynamic> toMap() => {'swapId': swapId, 'walletId': walletId, 'amount': amount, 'txId': txId};

  String get id {
    if (swapId != null) return swapId!;
    if (txId != null && amount != null) return '$txId-$amount';
    if (walletId != null && amount != null) return '$walletId-$amount';

    return 'unknown_tx';
  }
}

class ReceivingTxService {
  // this is to wait for liquid wallet to sync
  static bool shouldShowBottomSheet = false;

  static Future<void> addReceivingTxs(List<ReceivingTx> newTxs, {bool forNotificationClick = false}) async {
    final existing = getReceivingTxs();
    final txMap = {for (final tx in existing) tx.id: tx};
    for (final newTx in newTxs) {
      txMap[newTx.id] = newTx;
    }
    if (forNotificationClick && txMap.isNotEmpty) {
      await AppState.prefs.setBool('isReceivingBottomSheetForNotification', true);
    }
    await _setReceivingTxs(txMap.values.toList());
  }

  static Future<void> removeReceivingTx(String id) async {
    final existing = getReceivingTxs();
    existing.removeWhere((e) => e.id == id);
    await _setReceivingTxs(existing.toList());
  }

  static List<ReceivingTx> getReceivingTxs() {
    final List rawList = DB.generalBox.get('receivingTxs') ?? [];
    return rawList.map((e) => ReceivingTx.fromMap(e as Map)).toList();
  }

  static Future<void> _setReceivingTxs(List<ReceivingTx> txs) async {
    await DB.generalBox.put('receivingTxs', txs.map((e) => e.toMap()).toList());
    if (txs.isEmpty) {
      await AppState.prefs.setBool('isReceivingBottomSheetForNotification', false);
    }
    // This is to force update root
    GlobalListener.update(stream: .receivingTx);
  }

  static Future<void> cleanUp() async {
    final receivingTxs = getReceivingTxs();
    if (receivingTxs.isEmpty) return;
    final oldLength = receivingTxs.length;

    final existingTxIds = DB.transactions.values.map((t) => '${t.txId}-${t.amount}').toSet();
    final existingTxWalletAmountPair = DB.transactions.values.map((t) => '${t.walletId}-${t.amount}').toSet();

    receivingTxs.removeWhere((e) {
      if (e.swapId != null && DB.swaps.contains(e.swapId!)) {
        final swap = DB.swaps[e.swapId!]!;
        return swap.isClosed || swap.transactions.any((st) => st.txId == e.txId);
      }
      return existingTxIds.contains(e.id) || existingTxWalletAmountPair.contains(e.id);
    });

    if (oldLength != receivingTxs.length) {
      await _setReceivingTxs(receivingTxs);
    }
  }
}

Widget? receivingTxBottomSheet(BuildContext context) {
  if (!ReceivingTxService.shouldShowBottomSheet) return null;
  ReceivingTxService.cleanUp();

  final txs = ReceivingTxService.getReceivingTxs();
  if (txs.isEmpty) return null;

  return ConstrainedBox(
    constraints: const BoxConstraints(maxHeight: 400, minHeight: 250),
    child: Material(
      elevation: 16,
      borderRadius: const BorderRadiusGeometry.vertical(top: Radius.circular(24)),
      child: SingleChildScrollView(
        padding: const EdgeInsets.only(left: 16.0, right: 16.0, bottom: 16),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: .start,
          spacing: 6,
          children: [
            const SizedBox(height: 20),
            Row(
              spacing: 16,
              children: [
                const SizedBox.square(dimension: 20, child: CircularProgressIndicator()),
                Expanded(
                  child: Text(
                    (AppState.prefs.getBool('isReceivingBottomSheetForNotification') ?? false)
                        ? 'Syncing received payment...'
                        : 'Receiving payment...',
                    style: const TextStyle(fontSize: 22, fontWeight: FontWeight.bold),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 4),
            ...txs.map((payment) {
              final swap = payment.swapId != null ? DB.swaps[payment.swapId!] : null;
              final wallet = DB.allWallets
                  .where((w) => w.uuid == (payment.walletId ?? swap?.walletId ?? ''))
                  .firstOrNull;
              final account = wallet?.account;
              final network = swap?.network ?? wallet?.network;
              final networkText = network != null && network != Config.network
                  ? ' (${switch (network) {
                      Network.mainnet => 'MainNet',
                      Network.testnet => 'TestNet',
                      Network.regtest => 'MannaNet',
                    }})'
                  : '';

              return Card(
                child: Padding(
                  padding: const EdgeInsets.all(12),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    spacing: 8,
                    children: [
                      const SizedBox(width: double.infinity),
                      Row(
                        spacing: 16,
                        children: [
                          Expanded(
                            child: ShimmerWidget.fromColors(
                              baseColor: context.themedColor(bright: Colors.black, dark: Colors.white),
                              highlightColor: context.themedColor(bright: Colors.black26, dark: Colors.white24),
                              period: const Duration(seconds: 3),
                              child: Column(
                                mainAxisSize: MainAxisSize.min,
                                crossAxisAlignment: CrossAxisAlignment.start,
                                spacing: 8,
                                children: [
                                  if (account != null)
                                    Text('Wallet : ${account.name}$networkText', style: const TextStyle(fontSize: 20)),
                                  if (payment.txId != null)
                                    Text(
                                      'Tx ID: ${payment.txId!.shortenAddress()}',
                                      textAlign: TextAlign.center,
                                      maxLines: 1,
                                      overflow: TextOverflow.ellipsis,
                                      style: const TextStyle(fontSize: 18),
                                    ),
                                ],
                              ),
                            ),
                          ),
                          IconButton(
                            onPressed: () => ReceivingTxService.removeReceivingTx(payment.id),
                            icon: const Icon(Icons.close),
                          ),
                        ],
                      ),
                      AmountText(
                        amountSat: payment.amount ?? swap?.receiveAmount.i ?? 0,
                        btcStyle: const TextStyle(
                          fontSize: 22,
                          fontWeight: FontWeight.w700,
                          color: AppColors.primaryColor,
                        ),
                        showFiat: true,
                        isLongTapDisable: true,
                      ),
                    ],
                  ),
                ),
              );
            }),
          ],
        ),
      ),
    ),
  );
}
