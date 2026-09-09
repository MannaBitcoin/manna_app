import 'package:flutter/material.dart';
import 'package:manna/models/swap.dart';
import 'package:manna/router.dart';
import 'package:manna/screens/swap_detail_screen.dart';
import 'package:manna/services/db.dart';
import 'package:manna/utils/extensions.dart';
import 'package:manna_core/manna_core.dart';

import 'amount_text.dart';

class SwapDataCard extends StatelessWidget {
  const SwapDataCard(this.swapId, {super.key});

  final String swapId;

  @override
  Widget build(BuildContext context) {
    final swap = DB.swaps[swapId];
    if (swap == null) return const SizedBox.shrink();

    final isFinalState = isFinalSwapState(swap: swap).$2;
    final status = swap.swapStatus;
    final statusText = swap.refundedAddress != null || swap.swapStatus == 'transaction.refunded'
        ? 'Reclaimed'
        : swap.isIncoming
        ? swap.isClosed
              ? 'Received'
              : 'Incoming'
        : swap.isClosed
        ? 'Sent'
        : 'Outgoing';

    return GestureDetector(
      onTap: () => AppRouter.push(SwapDetailScreen(swapId: swapId)),
      child: Card(
        margin: const EdgeInsets.symmetric(vertical: 4),
        elevation: 2,
        child: Padding(
          padding: const EdgeInsets.all(12),
          child: Column(
            crossAxisAlignment: .start,
            spacing: 4,
            children: [
              Text('Id : ${swap.id} ($statusText)', style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 16)),
              if (swap.note?.isNotEmpty ?? false) Text(swap.note!, style: const TextStyle(fontSize: 16)),
              Text(
                'Status: $status',
                style: TextStyle(
                  color: swap.isClosed
                      ? Colors.green
                      : isFinalState
                      ? Colors.red
                      : null,
                  fontWeight: FontWeight.bold,
                ),
              ),
              Row(
                spacing: 8,
                children: [
                  AmountText(
                    amountSat: swap.sendAmount.i,
                    btcStyle: TextStyle(
                      fontSize: 16,
                      color: isFinalState && !swap.isIncoming ? (swap.isClosed ? Colors.green : Colors.red) : null,
                    ),
                    atTime: swap.creationTimeUTC,
                  ),
                  const Text('->'),
                  AmountText(
                    amountSat: swap.receiveAmount.i,
                    btcStyle: TextStyle(
                      fontSize: 16,
                      color: isFinalState && !swap.isIncoming ? (swap.isClosed ? Colors.green : Colors.red) : null,
                    ),
                    atTime: swap.creationTimeUTC,
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}
