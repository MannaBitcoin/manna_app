import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:file_saver/file_saver.dart';
import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:manna/app_state.dart';
import 'package:manna/config.dart';
import 'package:manna/globals.dart';
import 'package:manna/models/boltz_fees.dart';
import 'package:manna/models/enums.dart';
import 'package:manna/models/swap.dart';
import 'package:manna/router.dart';
import 'package:manna/services/boltz_service.dart';
import 'package:manna/services/clipboard_service.dart';
import 'package:manna/services/db.dart';
import 'package:manna/services/db_service.dart';
import 'package:manna/services/log_service.dart';
import 'package:manna/services/transaction_service.dart';
import 'package:manna/utils/date_extension.dart';
import 'package:manna/utils/extensions.dart';
import 'package:manna/utils/parser.dart';
import 'package:manna/utils/sats_extension.dart';
import 'package:manna/utils/state_extension.dart';
import 'package:manna/utils/toast_service.dart';
import 'package:manna/widgets/amount_text.dart';
import 'package:manna_core/manna_core.dart';
import 'package:url_launcher/url_launcher.dart';

class SwapDetailScreen extends StatefulWidget {
  const SwapDetailScreen({required this.swapId, super.key});

  final String swapId;

  @override
  State<SwapDetailScreen> createState() => _SwapDetailScreenState();
}

class _SwapDetailScreenState extends State<SwapDetailScreen> {
  Swap get swap => DB.swaps[widget.swapId]!;
  int? offerAmount;
  String? errorText, resolutionText;
  final swapDataExpansionController = ExpansibleController();
  StreamSubscription? swapSubscription;

  late String lastKnownStatus = swap.swapStatus;
  late int lastKnownTxCount = 0;

  @override
  void initState() {
    if (DB.swaps[widget.swapId] == null) {
      AppRouter.pop();
    } else {
      Future(() async {
        await BoltzService.updateSwapStatus(swap.id);
        await linkTxs();
        prepareSwapResolution();

        swapSubscription = DB.swaps.box
            .watch(key: widget.swapId)
            .asyncMap((e) async {
              update();
              if (!e.deleted) {
                if (lastKnownStatus != swap.swapStatus ||
                    (lastKnownTxCount != swap.transactions.length && swap.isMissingTransaction)) {
                  lastKnownStatus = swap.swapStatus;
                  await linkTxs();
                }
              }
            })
            .listen((e) {});
      });
    }

    super.initState();
  }

  @override
  void dispose() {
    swapSubscription?.cancel();
    super.dispose();
  }

  Future<void> linkTxs() async {
    try {
      final s = await fetchAndLinkSwapTransactions(swap: swap, apiConfig: Config.apiConfig);
      await s.save();
      prepareSwapResolution();
      lastKnownTxCount = s.transactions.length;
    } catch (e, s) {
      logE(e, stackTrace: s);
    }
  }

  void prepareSwapResolution() async {
    errorText = null;
    resolutionText = null;
    if (swap.failureReason != null && swap.failureReason!.isNotEmpty) {
      if (swap.isChainQuoteAvailable) {
        final chainSwapFailureReason = RegExp(r'locked\s+(\d+).*?expected\s+(\d+)');
        final match = chainSwapFailureReason.firstMatch(swap.failureReason ?? '');
        if (match != null) {
          final locked = parseInt(match.group(1));
          final expected = parseInt(match.group(2));

          try {
            final quoteAmount = (await BoltzService.boltzManager.getChainSwapQuote(swap: swap)).toInt();
            if (quoteAmount > 0) {
              offerAmount = quoteAmount;
              final culprit = swap.chain!.direction == ChainSwapDirection.lbtcToBtc ? 'Manna' : 'sender';

              errorText =
                  'The swap is not completed automatically because the $culprit paid ${locked > expected ? 'more' : 'less'}'
                  ' than expected amount.\n'
                  'The expected amount was ${getSatInBitcoinStyle(expected)} but the $culprit sent ${getSatInBitcoinStyle(locked)}.';

              final claimableValue = quoteAmount - (swap.claimFee?.i ?? 0);
              final claimableValueString =
                  '${getSatInBitcoinStyle(claimableValue)} (${claimableValue.satsToFiat().formatFiat()})';
              resolutionText = swap.isChainRefundable
                  ? 'You have 2 options :\n'
                        '(preferred) 1. Settle the swap by accepting the amount boltz offers : $claimableValueString\n'
                        '2. Reclaim coins to the address you want'
                  : 'You can settle the swap by accepting the amount boltz offers : $claimableValueString';
              update();
              return;
            }
          } catch (e, s) {
            logE(e, stackTrace: s);
          }
        }
      }
      if (swap.isChainRefundable) {
        errorText = 'Your swap did not complete due to following reason: ${swap.failureReason}';
        resolutionText = 'You can reclaim coins to the address you want';
        update();
        return;
      }
    }
  }

  @override
  Widget build(BuildContext context) {
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
    if (errorText?.isNotEmpty ?? false) {
      postFrameCallBack(() => swapDataExpansionController.collapse());
    }

    return Scaffold(
      appBar: AppBar(
        title: const Text('Swap details'),
        actions: [
          IconButton(
            onPressed: () async {
              final res = await showDialog(
                context: AppRouter.navigatorContext,
                builder: (context) => AlertDialog(
                  title: const Text('Do you want to save details of this swap for developers?'),
                  content: Text(
                    'The export contains all data for this swap, Export only if you have a problem with this swap.',
                    style: TextStyle(color: Colors.red.shade300),
                  ),
                  actions: [
                    TextButton(onPressed: () => AppRouter.pop(false), child: const Text('Cancel')),
                    TextButton(onPressed: () => AppRouter.pop(true), child: const Text('Yes')),
                  ],
                ),
              );
              if (res is bool && res) {
                final savedPath = await FileSaver.instance.saveAs(
                  name:
                      'swap_data_${swap.id}_${swap.walletId}_${DateFormat('yyyy_MM_dd_hh_mm').format(DateTime.now())}',
                  bytes: utf8.encode(jsonEncode(swap.toJson())),
                  fileExtension: 'txt',
                  mimeType: MimeType.text,
                );
                if (savedPath?.isNotEmpty == true) return ToastService.show('Swap data saved successfully.');
              }
            },
            icon: const Icon(Icons.share_outlined),
          ),
        ],
      ),
      body: RefreshIndicator(
        onRefresh: () async {
          await BoltzService.updateSwapStatus(swap.id);
          await Future.wait([BoltzService.processSwap(swap.id), Future.delayed(const Duration(seconds: 5))]);
          await linkTxs();
        },
        child: SingleChildScrollView(
          physics: const AlwaysScrollableScrollPhysics(),
          padding: const EdgeInsets.symmetric(vertical: 16),
          child: Column(
            crossAxisAlignment: .start,
            children: [
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 16),
                child: Column(
                  crossAxisAlignment: .start,
                  spacing: 4,
                  children: [
                    Row(
                      children: [
                        Expanded(
                          child: Text(
                            'Id : ${swap.id} ($statusText)',
                            style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 16),
                          ),
                        ),
                        IconButton(
                          onPressed: () => ClipboardService.setClipBoard(swap.id),
                          icon: const Icon(Icons.copy),
                          visualDensity: VisualDensity.compact,
                        ),
                      ],
                    ),
                    if (swap.note != null && swap.note!.isNotEmpty)
                      Text(swap.note!, style: const TextStyle(fontSize: 16)),
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
                            color: isFinalState && !swap.isIncoming
                                ? (swap.isClosed ? Colors.green : Colors.red)
                                : null,
                          ),
                        ),
                        const Text('->'),
                        AmountText(
                          amountSat: swap.receiveAmount.i,
                          btcStyle: TextStyle(
                            fontSize: 16,
                            color: isFinalState && !swap.isIncoming
                                ? (swap.isClosed ? Colors.green : Colors.red)
                                : null,
                          ),
                        ),
                      ],
                    ),
                    if (swap.getDuration() != null) Text('Completed in ${swap.getDuration()}'),
                  ],
                ),
              ),
              const Divider(),
              Builder(
                builder: (context) {
                  final refundTx = swap.transactions
                      .where((tx) => tx.isUser && tx.txType == SwapTransactionType.refund)
                      .firstOrNull;

                  final List<({SwapTransaction? tx, String text, bool isCompleted})> steps = [];

                  switch (swap.swapType) {
                    case SwapType.submarine:
                      // manna lockup
                      final tx = swap.transactions
                          .where((tx) => tx.isUser && tx.txType == SwapTransactionType.lockup)
                          .firstOrNull;
                      steps.add((
                        tx: tx,
                        text: tx != null ? 'Locked up\n(Manna)' : 'Pending\nlock up\n(Manna)',
                        isCompleted: tx != null,
                      ));

                      // refund
                      if (refundTx != null) {
                        steps.add((
                          tx: refundTx,
                          text: refundTx.isUser ? 'Reclaimed\n(Manna)' : 'Reclaimed\n(Boltz)',
                          isCompleted: true,
                        ));
                      } else {
                        // invoice paid
                        bool isCompleted = false;
                        try {
                          final invoice = decodeBolt11Invoice(invoice: swap.submarine!.invoice);
                          isCompleted = swap.preimage.value.isNotEmpty && invoice.preimageHash == swap.preimage.sha256;
                        } catch (_) {}

                        try {
                          final invoice = decodeBolt12Invoice(invoice: swap.submarine!.invoice);
                          isCompleted = swap.preimage.value.isNotEmpty && invoice.preimageHash == swap.preimage.sha256;
                        } catch (_) {}

                        steps.add((
                          tx: null,
                          text: isCompleted ? 'Invoice paid\n(Boltz)' : 'Pending\ninvoice\npayment\n(Boltz)',
                          isCompleted: isCompleted,
                        ));

                        // boltz claim
                        final claimTx = swap.transactions
                            .where((tx) => !tx.isUser && tx.txType == SwapTransactionType.claim)
                            .firstOrNull;
                        steps.add((
                          tx: claimTx,
                          text: claimTx != null ? 'Claimed\n(Boltz)' : 'Pending\nclaim\n(Boltz)',
                          isCompleted: claimTx != null,
                        ));
                      }

                    case SwapType.reverse:
                      // Invoice paid
                      bool isCompleted = false;
                      final invoiceStr = swap.reverse!.swapCreateRes.invoice;
                      if (invoiceStr != null) {
                        try {
                          final invoice = decodeBolt11Invoice(invoice: invoiceStr);
                          isCompleted = swap.preimage.value.isNotEmpty && invoice.preimageHash == swap.preimage.sha256;
                        } catch (_) {}

                        if (!isCompleted) {
                          try {
                            final invoice = decodeBolt12Invoice(invoice: invoiceStr);
                            isCompleted =
                                swap.preimage.value.isNotEmpty &&
                                invoice.preimageHash == swap.preimage.sha256 &&
                                status != 'swap.created';
                          } catch (e) {
                            logE(e);
                          }
                        }
                      }

                      steps.add((
                        tx: null,
                        text: isCompleted ? 'Invoice\npaid' : 'Pending\ninvoice\npayment',
                        isCompleted: isCompleted,
                      ));

                      // Boltz lockup
                      final lockupTx = swap.transactions
                          .where((tx) => !tx.isUser && tx.txType == SwapTransactionType.lockup)
                          .firstOrNull;
                      steps.add((
                        tx: lockupTx,
                        text: lockupTx != null ? 'Locked up\n(Boltz)' : 'Pending\nlock up\n(Boltz)',
                        isCompleted: lockupTx != null,
                      ));

                      // refund
                      if (refundTx != null) {
                        steps.add((
                          tx: refundTx,
                          text: refundTx.isUser ? 'Reclaimed\n(Manna)' : 'Reclaimed\n(Boltz)',
                          isCompleted: true,
                        ));
                      } else {
                        // Manna claim
                        final claimTx = swap.transactions
                            .where((tx) => tx.isUser && tx.txType == SwapTransactionType.claim)
                            .firstOrNull;
                        steps.add((
                          tx: claimTx,
                          text: claimTx != null ? 'Claimed\n(Manna)' : 'Pending\nclaim\n(Manna)',
                          isCompleted: claimTx != null,
                        ));
                      }

                    case SwapType.chain:
                      // user lockup
                      final userLock = swap.transactions
                          .where((tx) => tx.isUser && tx.txType == SwapTransactionType.lockup)
                          .firstOrNull;
                      steps.add((
                        tx: userLock,
                        text: swap.chain!.direction == ChainSwapDirection.btcToLbtc
                            ? userLock != null
                                  ? 'Sender\npaid'
                                  : 'Waiting\nfor sender\nto pay'
                            : userLock != null
                            ? 'Locked up\n(Manna)'
                            : 'Pending\nlock up\n(Manna)',
                        isCompleted: userLock != null,
                      ));

                      // user refund
                      final userRefund = swap.transactions
                          .where((tx) => tx.isUser && tx.txType == SwapTransactionType.refund)
                          .firstOrNull;
                      if (userRefund != null) {
                        steps.add((tx: userRefund, text: 'Reclaimed\n(Manna)', isCompleted: true));
                      } else {
                        // boltz lockup
                        final boltzLock = swap.transactions
                            .where((tx) => !tx.isUser && tx.txType == SwapTransactionType.lockup)
                            .firstOrNull;
                        if (!isFinalState || boltzLock != null) {
                          steps.add((
                            tx: boltzLock,
                            text: boltzLock != null ? 'Locked up\n(Boltz)' : 'Pending\nlock up\n(Boltz)',
                            isCompleted: boltzLock != null,
                          ));
                        }

                        // boltz refund
                        final boltzRefund = swap.transactions
                            .where((tx) => !tx.isUser && tx.txType == SwapTransactionType.refund)
                            .firstOrNull;
                        if (boltzRefund != null) {
                          steps.add((tx: boltzRefund, text: 'Reclaimed\n(Boltz)', isCompleted: true));
                        } else {
                          // user claim
                          final userClaim = swap.transactions
                              .where((tx) => tx.isUser && tx.txType == SwapTransactionType.claim)
                              .firstOrNull;
                          steps.add((
                            tx: userClaim,
                            text: swap.chain!.direction == ChainSwapDirection.btcToLbtc
                                ? userClaim != null
                                      ? 'Claimed\n(Manna)'
                                      : 'Pending\nclaim\n(Manna)'
                                : userClaim != null
                                ? 'Received\n(Receiver)'
                                : 'Pending\nclaim\n(Receiver)',
                            isCompleted: userClaim != null,
                          ));

                          // boltz claim
                          final boltzClaim = swap.transactions
                              .where((tx) => !tx.isUser && tx.txType == SwapTransactionType.claim)
                              .firstOrNull;
                          steps.add((
                            tx: boltzClaim,
                            text: boltzClaim != null ? 'Claimed\n(Boltz)' : 'Pending\nclaim\n(Boltz)',
                            isCompleted: boltzClaim != null,
                          ));
                        }
                      }
                  }

                  if (swap.failureReason?.isNotEmpty ?? false) {
                    steps.removeWhere((e) => !e.isCompleted);
                  }

                  if (steps.isNotEmpty) {
                    return Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 4),
                      child: Card(
                        child: Padding(
                          padding: const EdgeInsets.all(8.0),
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            spacing: 8,
                            children: [
                              const Text('Swap Progress', style: TextStyle(fontWeight: FontWeight.w500, fontSize: 16)),
                              LayoutBuilder(
                                builder: (context, constraint) {
                                  return SingleChildScrollView(
                                    scrollDirection: Axis.horizontal,
                                    child: ConstrainedBox(
                                      constraints: BoxConstraints(minWidth: constraint.maxWidth),
                                      child: Row(
                                        mainAxisAlignment: MainAxisAlignment.spaceBetween,
                                        crossAxisAlignment: CrossAxisAlignment.start,
                                        children: [
                                          for (final step in steps)
                                            GestureDetector(
                                              onTap: step.tx != null || step.text.toLowerCase().contains('invoice')
                                                  ? () {
                                                      // Lightning payment
                                                      final invoice =
                                                          swap.submarine?.invoice ??
                                                          swap.reverse?.swapCreateRes.invoice;
                                                      if (step.text.toLowerCase().contains('invoice') &&
                                                          invoice != null &&
                                                          swap.preimage.value.isNotEmpty) {
                                                        launchUrl(
                                                          Uri(
                                                            scheme: 'https',
                                                            host: 'validate-payment.com',
                                                            queryParameters: {
                                                              'invoice': invoice,
                                                              'preimage': swap.preimage.value,
                                                            },
                                                          ),
                                                        );
                                                      } else if (step.tx != null) {
                                                        launchUrl(
                                                          TransactionService.generateExplorerUrl(
                                                            AppState.blockExplorer,
                                                            DB.transactions.values
                                                                    .where((t) => step.tx!.txId == t.txId)
                                                                    .firstOrNull
                                                                    ?.liquidTx
                                                                    ?.unblindedUrl ??
                                                                'tx/${step.tx!.txId}',
                                                            network: swap.network,
                                                            isBTC: step.tx!.chain == Chain.bitcoin,
                                                          ),
                                                        );
                                                      }
                                                    }
                                                  : null,
                                              onLongPress: step.tx == null
                                                  ? null
                                                  : () => ClipboardService.setClipBoard(
                                                      TransactionService.generateExplorerUrl(
                                                        AppState.blockExplorer,
                                                        DB.transactions.values
                                                                .where((t) => step.tx!.txId == t.txId)
                                                                .firstOrNull
                                                                ?.liquidTx
                                                                ?.unblindedUrl ??
                                                            'tx/${step.tx!.txId}',
                                                        network: swap.network,
                                                        isBTC: step.tx!.chain == Chain.bitcoin,
                                                      ).toString(),
                                                    ),
                                              child: Card(
                                                child: Padding(
                                                  padding: const EdgeInsets.all(8.0),
                                                  child: Column(
                                                    spacing: 4,
                                                    children: [
                                                      SizedBox.square(
                                                        dimension: 24,
                                                        child: step.isCompleted
                                                            ? const Icon(
                                                                Icons.check_circle_outline,
                                                                color: Colors.green,
                                                              )
                                                            : const Icon(
                                                                Icons.access_time_outlined,
                                                                color: Colors.amber,
                                                              ),
                                                      ),
                                                      Text(step.text, textAlign: TextAlign.center),
                                                    ],
                                                  ),
                                                ),
                                              ),
                                            ),
                                        ],
                                      ),
                                    ),
                                  );
                                },
                              ),
                            ],
                          ),
                        ),
                      ),
                    );
                  }
                  return const SizedBox.shrink();
                },
              ),
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 16),
                child: Column(
                  crossAxisAlignment: .stretch,
                  spacing: 8,
                  children: [
                    if (errorText != null) Text(errorText!, style: const TextStyle(color: Colors.red, fontSize: 16)),
                    if (resolutionText != null) Text(resolutionText!, style: const TextStyle(fontSize: 16)),
                    if (offerAmount != null)
                      ElevatedButton(
                        onPressed: () async {
                          final res = await showDialog(
                            context: context,
                            builder: (context) => AlertDialog(
                              title: const Text('Do you want to settle the swap?'),
                              content: Text(
                                '${swap.chain!.direction == ChainSwapDirection.lbtcToBtc ? 'The receiver' : 'You'} will receive ${getSatInBitcoinStyle(offerAmount! - (swap.claimFee?.i ?? 0))}. do you want to settle the swap?',
                              ),
                              actions: [
                                TextButton(child: const Text('No'), onPressed: () => AppRouter.pop(false)),
                                TextButton(
                                  child: const Text('Yes'),
                                  onPressed: () async {
                                    try {
                                      final swapWallet = swap.wallet;
                                      if (swapWallet == null) {
                                        return ToastService.show('Missing wallet');
                                      }
                                      final amount = offerAmount!;
                                      startLoader();
                                      final res = await BoltzService.boltzManager.acceptChainSwapQuote(
                                        swap: swap,
                                        quoteAmount: amount.bigInt,
                                      );
                                      if (res) {
                                        final traType = swap.chain?.direction == ChainSwapDirection.btcToLbtc
                                            ? TraType.btcToLbtc
                                            : TraType.lbtcToBtc;
                                        final estimate = await calculateFeeAndAmounts(
                                          wallet: swapWallet,
                                          amount: amount,
                                          type: traType,
                                          dateTime: swap.creationTimeUTC.toLocal(),
                                        );
                                        swap.sendAmount = (estimate.sendAmount - (swap.claimFee?.i ?? 0)).bigInt;
                                        swap.receiveAmount = amount.bigInt;
                                        swap.boltzFee = estimate.boltzFee.bigInt;
                                        await swap.save();

                                        update();
                                        AppRouter.pop(true);
                                      }
                                    } catch (e, s) {
                                      logE(e, stackTrace: s);
                                    } finally {
                                      stopLoader();
                                    }
                                  },
                                ),
                              ],
                            ),
                          );
                          if (res is bool && res) {
                            AppRouter.pop();
                          }
                        },
                        style: ElevatedButton.styleFrom(visualDensity: VisualDensity.standard),
                        child: const Text('Settle'),
                      ),
                    // this will appear only in case of btcToLbtc swap
                    if (swap.isChainRefundable && swap.failureReason != null)
                      ElevatedButton(
                        onPressed: () async {
                          final res = await showDialog(
                            context: context,
                            builder: (context) => RefundDialog(swapId: swap.id),
                          );

                          if (res is bool && res) {
                            prepareSwapResolution();
                            await linkTxs();
                          }
                        },
                        style: ElevatedButton.styleFrom(visualDensity: VisualDensity.standard),
                        child: const Text('Refund'),
                      ),
                  ],
                ),
              ),
              ExpansionTile(
                childrenPadding: const EdgeInsets.symmetric(horizontal: 16),
                shape: InputBorder.none,
                title: const Text('Swap data', style: TextStyle(fontWeight: FontWeight.w500)),
                children: [
                  Column(
                    crossAxisAlignment: .start,
                    spacing: 6,
                    children: [
                      _SwapDataTile(title: 'Swap type', value: swap.swapType.name.capitalize),
                      _SwapDataTile(title: 'Created at', value: swap.creationTimeUTC.toLocal().format()),
                      if (swap.completionTimeUTC != null)
                        _SwapDataTile(title: 'Completed at', value: swap.completionTimeUTC!.toLocal().format()),
                      Builder(
                        builder: (context) {
                          final mannaFee =
                              swap.sendAmount.i -
                              swap.receiveAmount.i -
                              (swap.lockupFee?.i ?? 0) -
                              (swap.claimFee?.i ?? 0) -
                              (swap.boltzFee?.i ?? 0);
                          return _SwapDataTile(
                            title: 'Manna fee',
                            value: AmountText(amountSat: mannaFee),
                          );
                        },
                      ),
                      if ((swap.boltzFee?.i ?? 0) > 0)
                        _SwapDataTile(
                          title: 'Boltz fee',
                          value: AmountText(amountSat: swap.boltzFee!.i),
                        ),
                      if ((swap.lockupFee?.i ?? 0) > 0)
                        _SwapDataTile(
                          title: 'Lockup tx fee',
                          value: AmountText(amountSat: swap.lockupFee!.i),
                        ),
                      if ((swap.claimFee?.i ?? 0) > 0)
                        _SwapDataTile(
                          title: 'Claim tx fee',
                          value: AmountText(amountSat: swap.claimFee!.i),
                        ),
                      if ((swap.refundFee?.i ?? 0) > 0)
                        _SwapDataTile(
                          title: 'Refund tx fee',
                          value: AmountText(amountSat: swap.refundFee!.i),
                        ),
                      if (swap.failureReason != null)
                        Column(
                          crossAxisAlignment: .start,
                          children: [
                            const Text(
                              'Failure reason',
                              style: TextStyle(fontSize: 11, color: Colors.grey, fontWeight: FontWeight.w300),
                            ),
                            Text('${swap.failureReason}', style: const TextStyle(color: Colors.red)),
                          ],
                        ),
                      if (swap.refundedAddress != null)
                        _SwapDataTile(title: 'Reclaimed to', value: swap.refundedAddress, isCopyable: true),
                      _SwapDataTile(title: 'Preimage', value: swap.preimage.value, isCopyable: true, isSecure: true),
                      _SwapDataTile(title: 'Preimage Hash', value: swap.preimage.sha256, isCopyable: true),

                      if (swap.swapType == SwapType.submarine && swap.submarine != null) ...[
                        _SwapDataTile(title: 'Lightning invoice', value: swap.submarine!.invoice, isCopyable: true),
                        _SwapDataTile(
                          title: 'Lockup address',
                          value: swap.submarine!.swapCreateRes.address,
                          isCopyable: true,
                        ),
                        _SwapDataTile(
                          title: 'Swap private key',
                          value: swap.submarine!.keys.secretKey,
                          isCopyable: true,
                          isSecure: true,
                        ),
                        _SwapDataTile(
                          title: 'Swap public key',
                          value: swap.submarine!.keys.publicKey,
                          isCopyable: true,
                        ),
                        _SwapDataTile(
                          title: 'Claim public key',
                          value: swap.submarine!.swapCreateRes.claimPublicKey,
                          isCopyable: true,
                        ),
                        _SwapDataTile(
                          title: 'Timeout at block height',
                          value: swap.submarine!.swapCreateRes.timeoutBlockHeight.toString(),
                        ),
                      ],

                      if (swap.swapType == SwapType.reverse && swap.reverse != null) ...[
                        if (swap.reverse!.swapCreateRes.invoice != null)
                          _SwapDataTile(
                            title: 'Lightning invoice',
                            value: swap.reverse!.swapCreateRes.invoice!,
                            isCopyable: true,
                          ),
                        _SwapDataTile(
                          title: 'Lockup address',
                          value: swap.reverse!.swapCreateRes.lockupAddress,
                          isCopyable: true,
                        ),
                        _SwapDataTile(
                          title: 'Swap private key',
                          value: swap.reverse!.keys.secretKey,
                          isCopyable: true,
                          isSecure: true,
                        ),
                        _SwapDataTile(title: 'Swap public key', value: swap.reverse!.keys.publicKey, isCopyable: true),
                        _SwapDataTile(
                          title: 'Refund public key',
                          value: swap.reverse!.swapCreateRes.refundPublicKey,
                          isCopyable: true,
                        ),
                        _SwapDataTile(
                          title: 'Timeout at block height',
                          value: swap.reverse!.swapCreateRes.timeoutBlockHeight.toString(),
                        ),
                      ],

                      if (swap.swapType == SwapType.chain && swap.chain != null) ...[
                        ExpansionTile(
                          childrenPadding: const EdgeInsets.symmetric(horizontal: 16),
                          shape: InputBorder.none,
                          title: const Text('Lockup data', style: TextStyle(fontWeight: FontWeight.w500)),
                          children: [
                            _SwapDataTile(
                              title: 'Private key',
                              value: swap.chain!.refundKeys.secretKey,
                              isCopyable: true,
                              isSecure: true,
                            ),
                            _SwapDataTile(
                              title: 'Public key',
                              value: swap.chain!.refundKeys.publicKey,
                              isCopyable: true,
                            ),
                            _SwapDataTile(
                              title: 'Lockup address',
                              value: swap.chain!.lockupDetails.lockupAddress,
                              isCopyable: true,
                            ),
                            if (swap.chain!.lockupDetails.claimAddress != null)
                              _SwapDataTile(
                                title: 'Claim address',
                                value: swap.chain!.lockupDetails.claimAddress,
                                isCopyable: true,
                              ),
                            if (swap.chain!.lockupDetails.refundAddress != null)
                              _SwapDataTile(
                                title: 'Refund address',
                                value: swap.chain!.lockupDetails.refundAddress,
                                isCopyable: true,
                              ),
                            _SwapDataTile(
                              title: 'Server public key',
                              value: swap.chain!.lockupDetails.serverPublicKey,
                              isCopyable: true,
                            ),
                            _SwapDataTile(
                              title: 'Timeout at block height',
                              value: swap.chain!.lockupDetails.timeoutBlockHeight.toString(),
                            ),
                          ],
                        ),
                        ExpansionTile(
                          childrenPadding: const EdgeInsets.symmetric(horizontal: 16),
                          shape: InputBorder.none,
                          title: const Text('claim data', style: TextStyle(fontWeight: FontWeight.w500)),
                          children: [
                            _SwapDataTile(
                              title: 'Private key',
                              value: swap.chain!.claimKeys.secretKey,
                              isCopyable: true,
                              isSecure: true,
                            ),
                            _SwapDataTile(
                              title: 'Public key',
                              value: swap.chain!.claimKeys.publicKey,
                              isCopyable: true,
                            ),
                            _SwapDataTile(
                              title: 'Lockup address',
                              value: swap.chain!.claimDetails.lockupAddress,
                              isCopyable: true,
                            ),
                            if (swap.chain!.claimDetails.claimAddress != null)
                              _SwapDataTile(
                                title: 'Claim address',
                                value: swap.chain!.claimDetails.claimAddress,
                                isCopyable: true,
                              ),
                            if (swap.chain!.claimDetails.refundAddress != null)
                              _SwapDataTile(
                                title: 'Refund address',
                                value: swap.chain!.claimDetails.refundAddress,
                                isCopyable: true,
                              ),
                            _SwapDataTile(
                              title: 'Server public key',
                              value: swap.chain!.claimDetails.serverPublicKey,
                              isCopyable: true,
                            ),
                            _SwapDataTile(
                              title: 'Timeout at block height',
                              value: swap.chain!.claimDetails.timeoutBlockHeight.toString(),
                            ),
                          ],
                        ),
                      ],
                    ],
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

class RefundDialog extends StatefulWidget {
  const RefundDialog({required this.swapId, super.key});

  final String swapId;

  @override
  State<RefundDialog> createState() => _RefundDialogState();
}

class _RefundDialogState extends State<RefundDialog> {
  String? btcAddress;

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('Do you want to reclaim the swap?'),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        spacing: 16,
        children: [
          const Text('Enter the on-chain BTC address to reclaim the funds to.', style: TextStyle(fontSize: 16)),
          const Text('You can use address from other bitcoin wallet app if needed.', style: TextStyle(fontSize: 16)),
          TextFormField(
            autofocus: true,
            textAlign: TextAlign.center,
            keyboardType: TextInputType.number,
            decoration: const InputDecoration(contentPadding: EdgeInsets.all(8), labelText: 'Enter btc address'),
            onChanged: (value) async {
              final swap = DB.swaps[widget.swapId];
              if (swap == null) return;

              btcAddress = null;

              try {
                final addressData = await TransactionService.processAddress(rawAddress: value, network: swap.network);
                if (addressData.addressType == AddressType.bitcoin) {
                  btcAddress = addressData.address;
                  update();
                } else {
                  return ToastService.show('Invalid bitcoin address');
                }
              } on AddressParsingException catch (e) {
                return ToastService.show(e.message);
              } catch (e, s) {
                logE(e, stackTrace: s);
              }
            },
          ),
          Text(
            '* On-chain fees will apply! (${getSatInBitcoinStyle(BoltzFees.getChainFeesAndLimits(network: DB.swaps[widget.swapId]?.network).btcFees.userClaim)})',
            style: const TextStyle(fontSize: 12),
          ),
        ],
      ),
      actions: [
        TextButton(onPressed: () => AppRouter.pop(false), child: const Text('No')),
        TextButton(
          onPressed: btcAddress == null
              ? null
              : () async {
                  final swap = DB.swaps[widget.swapId];
                  if (swap == null) return;
                  startLoader();
                  final refundAddress = btcAddress!;
                  final refundFee = BoltzFees.getChainFeesAndLimits(network: swap.network).btcFees.userClaim.bigInt;
                  Future<String?> createRefundTx() async {
                    try {
                      return BoltzService.boltzManager.refundChain(
                        swap: swap,
                        refundAddress: refundAddress,
                        minerFee: TxFee(absolute: refundFee),
                        tryCooperate: true,
                      );
                    } catch (e, s) {
                      logE(e, stackTrace: s);
                      return BoltzService.boltzManager.refundChain(
                        swap: swap,
                        refundAddress: refundAddress,
                        minerFee: TxFee(absolute: refundFee),
                        tryCooperate: false,
                      );
                    }
                  }

                  try {
                    final txHex = await createRefundTx();
                    if (txHex != null) {
                      final txId = await BoltzService.boltzManager.broadcastSwapTx(
                        network: swap.network,
                        chain: Chain.bitcoin,
                        txHex: txHex,
                      );
                      if (txId.isNotEmpty) {
                        swap.transactions.add(
                          SwapTransaction(
                            txId: txId,
                            chain: Chain.bitcoin,
                            txType: SwapTransactionType.refund,
                            isUser: true,
                          ),
                        );
                        swap.refundedAddress = refundAddress;
                        swap.refundFee = refundFee;
                        await swap.save();
                        await DbService.useSupabase((sup) => sup.from('swap_webhook').delete().eq('swap_id', swap.id));
                        ToastService.show('Swap Reclaimed');
                        AppRouter.pop(true);
                      }
                    } else {
                      ToastService.show('Failed to create refund transaction');
                    }
                  } catch (e, s) {
                    logE(e, stackTrace: s);
                  } finally {
                    stopLoader();
                  }
                },
          child: const Text('Yes'),
        ),
      ],
    );
  }
}

class _SwapDataTile extends StatefulWidget {
  const _SwapDataTile({required this.title, required this.value, this.isCopyable = false, this.isSecure = false});

  final String title;
  final dynamic value;
  final bool isCopyable;
  final bool isSecure;

  @override
  State<_SwapDataTile> createState() => _SwapDataTileState();
}

class _SwapDataTileState extends State<_SwapDataTile> {
  late bool isVisible = !widget.isSecure;

  @override
  Widget build(BuildContext context) {
    final value = widget.value is Uint8List ? (widget.value as Uint8List).toHexString : widget.value;
    return Column(
      crossAxisAlignment: .start,
      children: [
        Text(
          widget.title,
          style: const TextStyle(fontSize: 11, color: Colors.grey, fontWeight: FontWeight.w300),
        ),
        if (value is Widget)
          value
        else if (value is String)
          value.isEmpty
              ? const Text('-')
              : GestureDetector(
                  onTap: () {
                    if (widget.isSecure) {
                      update(() => isVisible = !isVisible);
                    }
                  },
                  child: Row(
                    crossAxisAlignment: .start,
                    spacing: 8,
                    children: [
                      Expanded(
                        child: Text(
                          isVisible ? value : '*' * 25,
                          style: const TextStyle(fontSize: 16),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                      if (widget.isCopyable)
                        IconButton(
                          onPressed: () => ClipboardService.setClipBoard(value),
                          visualDensity: VisualDensity.compact,
                          padding: EdgeInsets.zero,
                          constraints: const BoxConstraints(maxHeight: 24, maxWidth: 24),
                          icon: const Icon(Icons.copy_rounded),
                        ),
                    ],
                  ),
                ),
      ],
    );
  }
}
