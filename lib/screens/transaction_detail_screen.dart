import 'dart:async';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:breez_sdk_spark_flutter/breez_sdk_spark.dart'
    show
        PaymentType,
        PaymentStatus,
        PaymentDetails_Lightning,
        SuccessActionProcessed_Message,
        SuccessActionProcessed_Url,
        SuccessActionProcessed_Aes,
        AesSuccessActionDataResult_Decrypted,
        AesSuccessActionDataResult_ErrorStatus,
        PaymentDetails_Spark,
        PaymentDetails_Token,
        PaymentDetails_Withdraw,
        PaymentDetails_Deposit;
import 'package:flutter/material.dart';
import 'package:lottie/lottie.dart';
import 'package:manna/app_state.dart';
import 'package:manna/globals.dart';
import 'package:manna/models/contact.dart';
import 'package:manna/models/misc.dart';
import 'package:manna/models/transaction.dart';
import 'package:manna/router.dart';
import 'package:manna/screens/contact_detail_screen.dart';
import 'package:manna/screens/send_screen.dart';
import 'package:manna/services/audio_service.dart';
import 'package:manna/services/clipboard_service.dart';
import 'package:manna/services/db.dart';
import 'package:manna/services/db_service.dart';
import 'package:manna/services/lnurl_service.dart';
import 'package:manna/services/nostr_service.dart';
import 'package:manna/services/transaction_service.dart';
import 'package:manna/theme.dart';
import 'package:manna/utils/constants.dart';
import 'package:manna/utils/extensions.dart';
import 'package:manna/utils/state_extension.dart';
import 'package:manna/widgets/amount_text.dart';
import 'package:manna/widgets/bottom%20sheets/transaction_categories_bottom_sheet.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:url_launcher/url_launcher_string.dart';
import 'package:uuid/uuid.dart';

class TransactionDetailScreen extends StatefulWidget {
  const TransactionDetailScreen({required this.id, this.fromCompletedTx = false, super.key});

  final IdWithWallet id;
  final bool fromCompletedTx;

  @override
  State<TransactionDetailScreen> createState() => _TransactionDetailScreenState();
}

class _TransactionDetailScreenState extends State<TransactionDetailScreen> with TickerProviderStateMixin {
  int explorer = AppState.blockExplorer;
  final noteController = TextEditingController();
  Contact? contact;
  late final animationController = AnimationController(vsync: this, duration: const Duration(milliseconds: 600));
  late final progressAnimationController = AnimationController(vsync: this);
  late final circleAnim = CurvedAnimation(parent: animationController, curve: Curves.easeOutCubic);
  Timer? swapCheckerTimer;

  bool isCompleted = true;

  @override
  void initState() {
    if (DB.transactions[widget.id] == null) {
      AppRouter.pop();
    }
    if (widget.fromCompletedTx) {
      playSuccessAnimation();
    }
    refresh();
    GlobalListener.addListener(
      stream: .account,
      listenerName: runtimeType.toString(),
      callback: (data) {
        refresh();
        return true;
      },
    );
    super.initState();
  }

  @override
  void dispose() {
    swapCheckerTimer?.cancel();
    circleAnim.dispose();
    animationController.dispose();
    progressAnimationController.dispose();
    noteController.dispose();
    GlobalListener.removeListener(stream: .account, listenerName: runtimeType.toString());
    super.dispose();
  }

  Transaction get tx => DB.transactions[widget.id]!;

  void refresh() => scheduleMicrotask(() async {
    if (contact == null && (tx.senderUUID != null || tx.receiverUserNameOrUUID != null)) {
      final wallets = DB.allWallets.where((w) => w.uuid == tx.walletId);
      for (final wallet in wallets) {
        if (tx.inner.paymentType == PaymentType.receive) {
          if (tx.senderUUID != null) {
            contact =
                DB.contacts[IdWithWalletAndType.wallet(id: tx.senderUUID!, wallet: wallet)] ??
                await DbService.getContact(uuid: tx.senderUUID, wallet: wallet);
          }
        } else {
          if (tx.receiverUserNameOrUUID != null) {
            if (tx.receiverUserNameOrUUID!.isUUID) {
              contact =
                  DB.contacts[IdWithWalletAndType.wallet(id: tx.receiverUserNameOrUUID!, wallet: wallet)] ??
                  await DbService.getContact(uuid: tx.receiverUserNameOrUUID, wallet: wallet);
            } else {
              contact = DB.contacts.values.where((e) => e.lnurl() == tx.receiverUserNameOrUUID).firstOrNull;
              contact ??= await DbService.getContact(userName: tx.receiverUserNameOrUUID?.getUserName, wallet: wallet);
              contact ??= await NostrService.fetchUserData(tx.receiverUserNameOrUUID!, wallet);
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
        await contact?.save();
        update();
      }
    }
  });

  Future<void> playSuccessAnimation() async {
    void complete({required bool isSuccess}) async {
      await progressAnimationController.animateTo(1, duration: const Duration(milliseconds: 500));
      update(() => isCompleted = true);
      if (isSuccess) {
        await AudioService.playSuccess();

        handleLNURLSuccessAction(tx);
      }
      if (mounted) {
        Future.delayed(const Duration(seconds: 1), () => animationController.reverse());
      }
    }

    isCompleted = false;
    await animationController.forward(from: 0);
    // gradually forward animation and once the swap complete reverse and play audio for lightning payment
    // we prolong the animation to 30 seconds so every tick is 300 millis * 100 ticks = 30000ms
    swapCheckerTimer = Timer.periodic(const Duration(milliseconds: 300), (timer) {
      if (timer.tick > 100) {
        timer.cancel();
        complete(isSuccess: false);
      } else if (timer.isActive) {
        if (tx.inner.status != PaymentStatus.pending) {
          timer.cancel();
          complete(isSuccess: tx.inner.status == PaymentStatus.completed);
        } else {
          final progress = Curves.easeOutQuart.transform(timer.tick / 100);
          progressAnimationController.animateTo(progress, duration: const Duration(milliseconds: 300));
        }
      }
    });

    // // in all other case complete animation immediately.
    // await AudioService.playSuccess();
    // await animationController.forward();
    // await Future.delayed(const Duration(milliseconds: 1800));
    // if (mounted) {
    //   await animationController.reverse();
    // }
  }

  @override
  Widget build(BuildContext context) {
    final maxRadius = math.sqrt(math.pow(context.screenWidth, 2) + math.pow(context.screenHeight, 2));
    final account = DB.allWallets.where((w) => w.uuid == tx.walletId).firstOrNull?.account;

    final memoWidget = tx.memo.isEmpty
        ? null
        : InkWell(
            onTap: () {
              showDialog(
                context: context,
                builder: (context) => SimpleDialog(
                  title: const Text('Memo'),
                  children: [
                    Padding(
                      padding: const EdgeInsets.all(16.0),
                      child: SelectableText(tx.memo, style: const TextStyle(fontSize: 16), textAlign: TextAlign.center),
                    ),
                  ],
                ),
              );
            },
            child: Container(
              decoration: BoxDecoration(
                color: context.themedColor(
                  bright: AppColors.accentColor.withValues(alpha: 0.1),
                  dark: AppColors.darkCardColor,
                ),
                borderRadius: BorderRadius.circular(12),
              ),
              constraints: const BoxConstraints(maxHeight: 88),
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
              child: SingleChildScrollView(
                child: Text(
                  tx.memo.trim(),
                  textAlign: TextAlign.center,
                  style: TextStyle(
                    fontSize: 16,
                    color: context.themedColor(bright: Colors.black54, dark: Colors.white54),
                  ),
                ),
              ),
            ),
          );
    final noteWidget = InkWell(
      onTap: () async {
        noteController.text = tx.note;
        await showDialog(
          context: context,
          builder: (context) => AlertDialog(
            title: const Text('Edit Note'),
            content: Column(
              spacing: 16,
              mainAxisSize: MainAxisSize.min,
              children: [
                TextFormField(
                  autofocus: true,
                  controller: noteController,
                  decoration: const InputDecoration(hintText: 'Note'),
                  textCapitalization: TextCapitalization.sentences,
                  minLines: 1,
                  maxLines: 3,
                ),
                const Text('Note : Only you can see this note', style: TextStyle(fontSize: 12)),
              ],
            ),
            actions: [
              TextButton(onPressed: () => AppRouter.pop(), child: const Text('Cancel ❌')),
              TextButton(
                onPressed: () async {
                  await tx.update(note: noteController.text.trim());
                  GlobalListener.update(stream: .account);
                  AppRouter.pop();
                },
                child: const Text('Save 💾'),
              ),
            ],
          ),
        );
        update();
      },
      child: Container(
        decoration: BoxDecoration(
          color: context.themedColor(
            bright: AppColors.accentColor.withValues(alpha: 0.06),
            dark: AppColors.darkCardColor.withValues(alpha: 0.4),
          ),
          borderRadius: BorderRadius.circular(12),
        ),
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
        child: Text(
          tx.note.isNotEmpty ? tx.note.trim() : 'Enter your note',
          textAlign: TextAlign.center,
          style: TextStyle(
            fontSize: 16,
            color: context.themedColor(bright: Colors.black54, dark: Colors.white54),
          ),
        ),
      ),
    );
    final categoriesWidget = InkWell(
      onTap: () async {
        final res = await showModalBottomSheet(
          context: context,
          showDragHandle: true,
          isScrollControlled: true,
          useSafeArea: true,
          shape: const RoundedRectangleBorder(borderRadius: BorderRadius.vertical(top: Radius.circular(24))),
          routeSettings: const RouteSettings(name: 'TransactionCategoriesBottomSheet'),
          builder: (context) => TransactionCategoriesBottomSheet(selectedCategories: tx.categories),
        );
        if (res is Set<String>) {
          await tx.update(categories: res);
          GlobalListener.update(stream: .account);
        }
        update();
      },
      child: Container(
        decoration: BoxDecoration(
          color: context.themedColor(
            bright: AppColors.accentColor.withValues(alpha: 0.06),
            dark: AppColors.darkCardColor.withValues(alpha: 0.4),
          ),
          borderRadius: BorderRadius.circular(12),
        ),
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
        child: Text(
          'Category : ${tx.categories.isEmpty ? 'None' : tx.categories.join(', ')}',
          style: TextStyle(
            color: context.themedColor(bright: Colors.black54, dark: Colors.white54),
          ),
          textAlign: TextAlign.center,
        ),
      ),
    );

    return Stack(
      children: [
        Scaffold(
          appBar: AppBar(title: account != null ? Text('Wallet : ${account.name}') : null),
          body: Center(
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 600),
              child: Stack(
                children: [
                  SingleChildScrollView(
                    padding: const EdgeInsets.all(16.0),
                    child: Column(
                      children: [
                        Column(
                          children: [
                            ConstrainedBox(
                              constraints: const BoxConstraints(maxWidth: 300),
                              child: Lottie.asset(
                                switch (tx.inner.status) {
                                  PaymentStatus.pending => AppLottie.pending,
                                  PaymentStatus.completed => AppLottie.success,
                                  PaymentStatus.failed => AppLottie.failed,
                                },
                                width: double.infinity,
                                repeat: tx.inner.status == PaymentStatus.pending,
                              ),
                            ),
                            AmountText(
                              amountSat: tx.inner.paymentType == PaymentType.receive
                                  ? tx.inner.amount.i
                                  : tx.inner.amount.i + tx.inner.fees.i,
                              btcStyle: const TextStyle(
                                fontSize: 36,
                                fontWeight: FontWeight.w700,
                                color: AppColors.primaryColor,
                              ),
                              showFiat: true,
                              atTime: tx.timestamp,
                            ),
                            if (contact != null) ...[
                              const SizedBox(height: 16),
                              Wrap(
                                alignment: WrapAlignment.center,
                                crossAxisAlignment: WrapCrossAlignment.center,
                                children: [
                                  Text(
                                    '${tx.inner.paymentType == PaymentType.receive ? 'From' : 'To'} ',
                                    style: const TextStyle(fontSize: 16),
                                  ),
                                  GestureDetector(
                                    onTap: () => AppRouter.push(ContactDetailScreen(contact: contact!)),
                                    child: Text(
                                      contact!.isMannaUser ? contact!.name() : contact!.lnurl(wrap: true),
                                      style: TextStyle(
                                        fontSize: 18,
                                        color: Colors.blue.shade600,
                                        decorationColor: Colors.blue.shade600,
                                        decoration: TextDecoration.underline,
                                      ),
                                      textAlign: TextAlign.center,
                                    ),
                                  ),
                                ],
                              ),
                            ],
                            const SizedBox(height: 16),
                            Padding(
                              padding: const EdgeInsets.symmetric(horizontal: 16),
                              child: Row(
                                mainAxisAlignment: .center,
                                spacing: 8,
                                children: [
                                  Expanded(
                                    child: Text(
                                      tx.txId.shortenAddress(charCount: 14),
                                      textAlign: TextAlign.center,
                                      maxLines: 2,
                                      overflow: TextOverflow.ellipsis,
                                      style: const TextStyle(fontSize: 12, color: Colors.grey),
                                    ),
                                  ),
                                  IconButton(
                                    onPressed: () => ClipboardService.setClipBoard(tx.txId),
                                    icon: const Icon(Icons.copy_rounded, size: 20),
                                    visualDensity: VisualDensity.compact,
                                    padding: EdgeInsets.zero,
                                  ),
                                ],
                              ),
                            ),
                            const SizedBox(height: 8),
                            Theme(
                              data: Theme.of(context).copyWith(focusColor: Colors.transparent),
                              child: ExpansionTile(
                                tilePadding: EdgeInsets.zero,
                                shape: const RoundedRectangleBorder(),
                                expandedCrossAxisAlignment: .stretch,
                                title: memoWidget ?? noteWidget,
                                children: [
                                  if (memoWidget != null) ...[noteWidget, const SizedBox(height: 8)],
                                  categoriesWidget,
                                ],
                              ),
                            ),
                          ],
                        ),
                        const SizedBox(height: 16),
                        Card(
                          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                          elevation: 2,
                          child: Builder(
                            builder: (context) {
                              return ExpansionTile(
                                shape: const RoundedRectangleBorder(),
                                childrenPadding: const EdgeInsets.only(left: 16, right: 16, bottom: 16),
                                expandedCrossAxisAlignment: .start,
                                title: const Text(
                                  'Advanced Details',
                                  style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
                                ),
                                children: [
                                  _detailRow(
                                    Icons.account_balance_wallet,
                                    'Actual Amount',
                                    AmountText(
                                      showFiat: true,
                                      amountSat: tx.inner.paymentType == PaymentType.send
                                          ? tx.inner.amount.i
                                          : tx.inner.amount.i + tx.inner.fees.i,
                                      atTime: tx.timestamp,
                                    ),
                                  ),

                                  _detailRow(
                                    Icons.toll,
                                    'Fees',
                                    AmountText(showFiat: true, amountSat: tx.inner.fees.i, atTime: tx.timestamp),
                                  ),

                                  // ExpansionTile(
                                  //   tilePadding: EdgeInsets.zero,
                                  //   shape: InputBorder.none,
                                  //   showTrailingIcon: false,
                                  //   title: _detailRow(
                                  //     Icons.money_off,
                                  //     'Total Fees',
                                  //     AmountText(showFiat: true, amountSat: tx.inner.fees.i, atTime: tx.timestamp),
                                  //   ),
                                  //   childrenPadding: const EdgeInsets.only(left: 32),
                                  //   children: [
                                  //     _detailRow(
                                  //       Icons.offline_bolt,
                                  //       'Fees',
                                  //       AmountText(showFiat: true, amountSat: tx.inner.fees.i, atTime: tx.timestamp),
                                  //       expand: false,
                                  //     ),
                                  //   ],
                                  // ),
                                  if (tx.inner.details case PaymentDetails_Lightning(:final lnurlPayInfo))
                                    if (lnurlPayInfo?.processedSuccessAction != null)
                                      Builder(
                                        builder: (context) {
                                          final widgets = switch (lnurlPayInfo!.processedSuccessAction!) {
                                            SuccessActionProcessed_Aes(:final result) => switch (result) {
                                              AesSuccessActionDataResult_Decrypted(:final data) => [
                                                if (data.description.isNotEmpty) Text(data.description),
                                                if (data.plaintext.isNotEmpty)
                                                  Text(data.plaintext, style: const TextStyle(fontSize: 16)),
                                              ],
                                              AesSuccessActionDataResult_ErrorStatus(:final reason) => [
                                                Text(reason, style: const TextStyle(color: Colors.red)),
                                              ],
                                            },
                                            SuccessActionProcessed_Message(:final data) => <Widget>[
                                              Text(data.message, style: const TextStyle(fontSize: 16)),
                                            ],
                                            SuccessActionProcessed_Url(:final data) => <Widget>[
                                              if (data.description.isNotEmpty) Text(data.description),
                                              if (data.url.isNotEmpty)
                                                GestureDetector(
                                                  onTap: () async {
                                                    if (!data.matchesCallbackDomain) {
                                                      final res = await showDialog(
                                                        context: context,
                                                        builder: (context) => AlertDialog(
                                                          title: const Text(
                                                            'The URL does not match the original LNURL, Do you still want to continue?',
                                                            style: TextStyle(fontSize: 16),
                                                          ),
                                                          actions: [
                                                            TextButton(
                                                              onPressed: () => AppRouter.pop(false),
                                                              child: const Text('No'),
                                                            ),
                                                            TextButton(
                                                              onPressed: () => AppRouter.pop(true),
                                                              child: const Text('Yes'),
                                                            ),
                                                          ],
                                                        ),
                                                      );
                                                      if (res is bool && res) {
                                                        unawaited(launchUrlString(data.url));
                                                      }
                                                    } else {
                                                      unawaited(launchUrlString(data.url));
                                                    }
                                                  },
                                                  child: Text(
                                                    data.url,
                                                    style: TextStyle(
                                                      decoration: TextDecoration.underline,
                                                      color: Colors.blue.shade600,
                                                      decorationColor: Colors.blue.shade600,
                                                    ),
                                                  ),
                                                ),
                                            ],
                                          };
                                          if (widgets.isEmpty) return const SizedBox.shrink();

                                          return Column(
                                            spacing: 8,
                                            children: [
                                              const Text('LNURL data', style: TextStyle(fontSize: 16)),
                                              const Divider(),
                                              ...widgets,
                                            ],
                                          );
                                        },
                                      ),

                                  if (tx.extraMetadata['brantaData'] is Map &&
                                      (tx.extraMetadata['brantaData'] as Map).isNotEmpty)
                                    Builder(
                                      builder: (context) {
                                        final brantaData = BrantaData.fromMap(
                                          (tx.extraMetadata['brantaData'] as Map).cast<String, dynamic>(),
                                        );
                                        if (brantaData.name.isNotEmpty) {
                                          return BrantaCard(data: brantaData);
                                        }

                                        return const SizedBox.shrink();
                                      },
                                    ),
                                  const SizedBox(height: 8),

                                  DataTile(title: 'Transaction Type', value: tx.inner.method.name.capitalize),
                                  const SizedBox(height: 8),

                                  if (tx.inner.details != null)
                                    switch (tx.inner.details!) {
                                      PaymentDetails_Spark(:final invoiceDetails) =>
                                        invoiceDetails != null
                                            ? DataTile(
                                                title: 'Invoice',
                                                value: invoiceDetails.invoice,
                                                isCopyable: true,
                                              )
                                            : const SizedBox.shrink(),
                                      PaymentDetails_Lightning(
                                        :final invoice,
                                        :final lnurlWithdrawInfo,
                                        :final htlcDetails,
                                      ) =>
                                        Column(
                                          spacing: 8,
                                          children: [
                                            DataTile(title: 'Invoice', value: invoice, isCopyable: true),
                                            if (lnurlWithdrawInfo?.withdrawUrl.isNotEmpty ?? false)
                                              DataTile(
                                                title: 'LNURL withdraw url',
                                                value: lnurlWithdrawInfo?.withdrawUrl,
                                                isCopyable: true,
                                              ),
                                            if (htlcDetails.preimage?.isNotEmpty ?? false)
                                              DataTile(
                                                title: 'Preimage',
                                                value: htlcDetails.preimage,
                                                isCopyable: true,
                                                isSecure: true,
                                              ),
                                          ],
                                        ),
                                      PaymentDetails_Withdraw() => const SizedBox.shrink(),
                                      PaymentDetails_Deposit() => const SizedBox.shrink(),
                                      PaymentDetails_Token() => const SizedBox.shrink(),
                                    },
                                  const SizedBox(height: 16),

                                  Builder(
                                    builder: (context) {
                                      final explorerUrl =
                                          'https://sparkscan.io/tx/${tx.txId}?network=${tx.network.name}';

                                      return Column(
                                        spacing: 12,
                                        crossAxisAlignment: CrossAxisAlignment.stretch,
                                        children: [
                                          ElevatedButton(
                                            onPressed: () => launchUrlString(explorerUrl),
                                            onLongPress: () => ClipboardService.setClipBoard(explorerUrl),
                                            style: ElevatedButton.styleFrom(visualDensity: VisualDensity.standard),
                                            child: const Text(
                                              'See Tx',
                                              style: TextStyle(fontSize: 16),
                                              textAlign: TextAlign.center,
                                            ),
                                          ),

                                          if (tx.inner.details case PaymentDetails_Lightning(
                                            :final invoice,
                                            :final htlcDetails,
                                          ))
                                            ElevatedButton(
                                              onPressed: () => launchUrl(
                                                Uri(
                                                  scheme: 'https',
                                                  host: 'validate-payment.com',
                                                  queryParameters: {
                                                    'invoice': invoice,
                                                    'preimage': htlcDetails.preimage,
                                                  },
                                                ),
                                              ),
                                              style: ElevatedButton.styleFrom(visualDensity: VisualDensity.standard),
                                              child: const Text(
                                                'Verify',
                                                style: TextStyle(fontSize: 16),
                                                textAlign: TextAlign.center,
                                              ),
                                            ),

                                          if (AppState.blockExplorers.isNotEmpty) ...[
                                            if (tx.inner.details is PaymentDetails_Withdraw ||
                                                tx.inner.details is PaymentDetails_Deposit) ...[
                                              DropdownButton(
                                                isExpanded: true,
                                                borderRadius: BorderRadius.circular(12),
                                                items: AppState.blockExplorers.entries
                                                    .map((e) => DropdownMenuItem(value: e.key, child: Text(e.value)))
                                                    .toList(),
                                                hint: const Text('Transaction Explorer'),
                                                underline: Container(),
                                                value: explorer,
                                                onChanged: (val) async {
                                                  if (val != null) {
                                                    explorer = val;
                                                    update();
                                                  }
                                                },
                                              ),
                                            ],
                                            if (tx.inner.details case PaymentDetails_Withdraw(:final txId))
                                              ElevatedButton(
                                                onPressed: () => launchUrl(
                                                  TransactionService.generateExplorerUrl(
                                                    explorer,
                                                    'tx/$txId',
                                                    isBTC: true,
                                                  ),
                                                ),
                                                onLongPress: () => ClipboardService.setClipBoard(
                                                  TransactionService.generateExplorerUrl(
                                                    explorer,
                                                    'tx/$txId',
                                                    isBTC: true,
                                                  ).toString(),
                                                ),
                                                style: ElevatedButton.styleFrom(visualDensity: VisualDensity.standard),
                                                child: const Text(
                                                  'See Chain Tx',
                                                  style: TextStyle(fontSize: 16),
                                                  textAlign: TextAlign.center,
                                                ),
                                              ),
                                            if (tx.inner.details case PaymentDetails_Deposit(:final txId, :final vout))
                                              ElevatedButton(
                                                onPressed: () => launchUrl(
                                                  TransactionService.generateExplorerUrl(
                                                    explorer,
                                                    'tx/$txId#vout=$vout',
                                                    isBTC: true,
                                                  ),
                                                ),
                                                onLongPress: () => ClipboardService.setClipBoard(
                                                  TransactionService.generateExplorerUrl(
                                                    explorer,
                                                    'tx/$txId#vout=$vout',
                                                    isBTC: true,
                                                  ).toString(),
                                                ),
                                                style: ElevatedButton.styleFrom(visualDensity: VisualDensity.standard),
                                                child: const Text(
                                                  'See Chain Tx',
                                                  style: TextStyle(fontSize: 16),
                                                  textAlign: TextAlign.center,
                                                ),
                                              ),
                                          ],
                                        ],
                                      );
                                    },
                                  ),
                                ],
                              );
                            },
                          ),
                        ),
                        const SizedBox(height: 16),
                      ],
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
        AnimatedBuilder(
          animation: circleAnim,
          builder: (_, child) {
            return Stack(
              children: [
                ClipPath(
                  clipper: CircleClipper(circleAnim.value * maxRadius),
                  child: Container(color: Colors.green),
                ),
                if (circleAnim.value > 0.1)
                  Material(
                    color: Colors.transparent,
                    child: Align(
                      alignment:
                          Alignment.lerp(Alignment.topCenter, Alignment.center, circleAnim.value) ?? Alignment.center,
                      child: child,
                    ),
                  ),
              ],
            );
          },
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 400),
                child: isCompleted
                    ? Lottie.asset(AppLottie.success, width: double.infinity)
                    : tx.inner.status == PaymentStatus.pending
                    ? AnimatedBuilder(
                        animation: progressAnimationController,
                        builder: (_, _) {
                          final percent = (progressAnimationController.value * 100).round();
                          return Stack(
                            alignment: Alignment.center,
                            children: [
                              CircularProgressIndicator(
                                value: progressAnimationController.value,
                                strokeCap: StrokeCap.round,
                                strokeWidth: 16,
                                strokeAlign: 13,
                                color: Color.lerp(Colors.amber, Colors.greenAccent, progressAnimationController.value),
                              ),
                              Text(
                                '$percent%${isCompleted ? '' : '\nSending${'.' * (percent % 4)}'}',
                                style: const TextStyle(fontSize: 20, fontWeight: FontWeight.bold, color: Colors.white),
                                textAlign: TextAlign.center,
                              ),
                            ],
                          );
                        },
                      )
                    : const SizedBox.shrink(),
              ),
              if (isCompleted)
                const Text(
                  'Transaction completed!',
                  style: TextStyle(color: Colors.white, fontSize: 28, fontWeight: FontWeight.bold),
                ),
            ],
          ),
        ),
      ],
    );
  }

  Widget _detailRow(IconData? icon, String title, dynamic value, {bool expand = true}) {
    final child = value is Widget
        ? value
        : Text(
            '$value',
            style: const TextStyle(fontSize: 15),
            overflow: TextOverflow.ellipsis,
            textAlign: TextAlign.right,
          );
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(
        children: [
          if (icon != null) ...[Icon(icon, color: AppColors.primaryColor), const SizedBox(width: 8)],
          Text('$title :', style: const TextStyle(color: Colors.grey)),
          const SizedBox(width: 4),
          if (expand) Expanded(child: child) else child,
        ],
      ),
    );
  }
}

class CircleClipper extends CustomClipper<Path> {
  CircleClipper(this.radius);

  final double radius;

  @override
  Path getClip(Size size) {
    final path = Path();
    path.addOval(Rect.fromCircle(center: size.topCenter(const Offset(0, 150 + 88)), radius: radius));
    return path;
  }

  @override
  bool shouldReclip(covariant CircleClipper oldClipper) => oldClipper.radius != radius;
}

class DataTile extends StatefulWidget {
  const DataTile({required this.title, required this.value, this.isCopyable = false, this.isSecure = false, super.key});

  final String title;
  final dynamic value;
  final bool isCopyable;
  final bool isSecure;

  @override
  State<DataTile> createState() => DataTileState();
}

class DataTileState extends State<DataTile> {
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
