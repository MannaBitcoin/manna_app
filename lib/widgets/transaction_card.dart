import 'package:breez_sdk_spark_flutter/breez_sdk_spark.dart' show PaymentType, PaymentStatus;
import 'package:flutter/material.dart';
import 'package:flutter_svg/flutter_svg.dart';
import 'package:manna/models/contact.dart';
import 'package:manna/models/transaction.dart';
import 'package:manna/router.dart';
import 'package:manna/screens/image_preview_screen.dart';
import 'package:manna/screens/transaction_detail_screen.dart';
import 'package:manna/services/db.dart';
import 'package:manna/theme.dart';
import 'package:manna/utils/constants.dart';
import 'package:manna/utils/date_extension.dart';
import 'package:manna/utils/extensions.dart';
import 'package:manna/widgets/amount_text.dart';
import 'package:manna/widgets/shimmer.dart';
import 'package:relative_time/relative_time.dart';
import 'package:uuid/uuid.dart';

class TransactionCard extends StatelessWidget {
  const TransactionCard({
    required this.tx,
    required this.hideAmount,
    this.shouldShowCategory = false,
    // this.exchangeOrder,
    super.key,
  });

  final bool hideAmount;
  final Transaction tx;
  final bool shouldShowCategory;

  // final ExchangeOrder? exchangeOrder;

  @override
  Widget build(BuildContext context) {
    Contact? contact;
    final wallets = DB.allWallets.where(
      (w) =>
          w.uuid ==
          (
          // exchangeOrder?.swap?.walletId ??
          tx.walletId),
    );
    // if (exchangeOrder == null) {
    for (final wallet in wallets) {
      if (tx.inner.paymentType == PaymentType.receive) {
        if (tx.senderUUID != null) {
          contact ??= DB.contacts[IdWithWalletAndType.wallet(id: tx.senderUUID!, wallet: wallet)];
        }
      } else {
        if (tx.receiverUserNameOrUUID != null) {
          if (tx.receiverUserNameOrUUID!.isUUID) {
            contact ??= DB.contacts[IdWithWalletAndType.wallet(id: tx.receiverUserNameOrUUID!, wallet: wallet)];
          } else {
            contact ??= DB.contacts.values.where((c) => c.lnurl() == tx.receiverUserNameOrUUID).firstOrNull;
            contact ??= Contact(
              uuid: const Uuid().v5(Namespace.url.value, tx.receiverUserNameOrUUID),
              walletId: wallet.uuid,
              walletType: wallet.type,
              name: tx.receiverUserNameOrUUID!.getUserName ?? '',
              lnurl: tx.receiverUserNameOrUUID!,
            );
          }
        }
      }
      // }
    }

    // final isIncoming = exchangeOrder?.isBuy ?? tx.isIncoming;
    // final isCompleted = exchangeOrder != null ? exchangeOrder?.swap?.completionTime != null : tx.isCompleted;
    // final timestamp = exchangeOrder?.createdAt ?? tx.txTimestamp;

    final isIncoming = tx.inner.paymentType == PaymentType.receive;
    final isCompleted = tx.inner.status == PaymentStatus.completed;
    final timestamp = tx.timestamp;

    return GestureDetector(
      onTap: () => AppRouter.push(
        // exchangeOrder != null
        //     ? ExchangeOrderDetailScreen(order: exchangeOrder!)
        //     :
        TransactionDetailScreen(
          id: IdWithWallet(walletId: tx.walletId, id: tx.txId),
        ),
      ),
      child: Card(
        child: Padding(
          padding: const EdgeInsets.all(8.0),
          child: Row(
            spacing: 12,
            children: [
              Container(
                key: ValueKey(contact.hashCode),
                width: 48,
                height: 48,
                clipBehavior: Clip.antiAlias,
                decoration: const BoxDecoration(color: Color.fromARGB(255, 120, 120, 120), shape: BoxShape.circle),
                child: Builder(
                  builder: (context) {
                    if (contact != null) {
                      final provider = getImageProvider(contact.picture());
                      final fallback = Center(
                        child: Text(
                          contact.name().shortName,
                          style: const TextStyle(color: Colors.white, fontSize: 24),
                        ),
                      );
                      if (provider != null) {
                        return Image(
                          image: provider,
                          fit: BoxFit.cover,
                          loadingBuilder: imageLoadingBuilder,
                          errorBuilder: (context, error, stackTrace) => fallback,
                        );
                      }
                      return fallback;
                    }

                    return Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 8),
                      child: SvgPicture.asset(AppImages.logoWhiteAssetSVG),
                    );
                  },
                ),
              ),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Row(
                      spacing: 4,
                      children: [
                        ShimmerWidget.fromColors(
                          key: Key(isCompleted.toString()),
                          baseColor: isIncoming ? Colors.green : Colors.red,
                          highlightColor: Colors.white,
                          shimmerState: !isCompleted ? ShimmerState.running : ShimmerState.stopped,
                          direction: isIncoming ? ShimmerDirection.ttb : ShimmerDirection.btt,
                          child: Transform.rotate(
                            angle: isIncoming ? -0.785398 : 2.35619,
                            child: const Icon(Icons.arrow_back, size: 20, fontWeight: FontWeight.w600),
                          ),
                        ),
                        Expanded(
                          child: Text(
                            (tx.note.isNotEmpty || tx.memo.isNotEmpty) && !hideAmount
                                ? tx.note.isNotEmpty
                                      ? tx.note
                                      : tx.memo
                                : 'payment ${isIncoming ? 'received' : 'sent'}',
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(fontWeight: FontWeight.w600, fontSize: 15),
                          ),
                        ),
                      ],
                    ),
                    if (contact?.name() != null)
                      Text(
                        // exchangeOrder?.partner.name.capitalize ??
                        contact?.name() ?? 'Unknown',
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        textAlign: TextAlign.left,
                        style: const TextStyle(color: AppColors.accentColor, fontWeight: FontWeight.w600),
                      ),
                    Text(
                      timestamp.isBefore(DateTime.now().subtract(const Duration(hours: 24)))
                          ? timestamp.format()
                          : RelativeTime(context).format(timestamp),
                      style: TextStyle(fontSize: 12, color: Colors.grey.shade600),
                      textAlign: TextAlign.right,
                    ),
                    if (
                    // exchangeOrder == null &&
                    shouldShowCategory && tx.categories.isNotEmpty)
                      Text(
                        'Category: ${tx.categories.join(', ')}',
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(color: AppColors.accentColor, fontWeight: FontWeight.w600),
                      ),
                  ],
                ),
              ),
              hideAmount
                  ? const Text('***', style: TextStyle(fontSize: 20))
                  : AmountText(
                      amountSat:
                          // exchangeOrder?.cryptoAmount ??
                          tx.inner.amount.i,
                      btcStyle: const TextStyle(fontSize: 20),
                      showFiat: true,
                      isIncoming: isIncoming,
                      scale: 0.8,
                      atTime: timestamp,
                    ),
            ],
          ),
        ),
      ),
    );
  }
}
