import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:lottie/lottie.dart';
import 'package:manna/app_state.dart';
import 'package:manna/globals.dart';
import 'package:manna/models/contact.dart';
import 'package:manna/models/misc.dart';
import 'package:manna/models/swap.dart';
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
import 'package:manna/utils/date_extension.dart';
import 'package:manna/utils/extensions.dart';
import 'package:manna/utils/parser.dart';

import 'package:manna/utils/state_extension.dart';
import 'package:manna/widgets/amount_text.dart';
import 'package:manna/widgets/bottom%20sheets/transaction_categories_bottom_sheet.dart';
import 'package:manna/widgets/swap_data_card.dart';
import 'package:manna_core/manna_core.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:url_launcher/url_launcher_string.dart';
import 'package:uuid/uuid.dart';

class TransactionDetailScreen extends StatefulWidget {
  const TransactionDetailScreen({required this.id, this.fromCompletedTx = false, this.submarineSwapId, super.key});

  final IdWithWallet id;
  final bool fromCompletedTx;
  final String? submarineSwapId;

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
  StreamSubscription? swapSubscription;
  StreamSubscription? transactionSubscription;

  bool isCompleted = true;

  late final linkedSwap = DB.transactions[widget.id]!.linkedSwap;

  @override
  void initState() {
    if (DB.transactions[widget.id] == null) {
      AppRouter.pop();
    } else {
      transactionSubscription = DB.transactionBox.watch(key: widget.id.toString()).listen((_) => update());
      if (linkedSwap != null) {
        swapSubscription = DB.swaps.box.watch(key: linkedSwap!.id).listen((_) => update());
      }
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
    swapSubscription?.cancel();
    transactionSubscription?.cancel();
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
        if (tx.isIncoming) {
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
    if (tx.memo.isEmpty && linkedSwap?.note?.isNotEmpty == true) {
      await tx.update(memo: linkedSwap!.note!, isMemoSynced: true);
    }
  });

  Future<void> playSuccessAnimation() async {
    if (widget.submarineSwapId != null && DB.swaps[widget.submarineSwapId!] != null) {
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
          if (isSwapCompleted) {
            timer.cancel();
            complete(isSuccess: true);
          } else {
            final progress = Curves.easeOutQuart.transform(timer.tick / 100);
            progressAnimationController.animateTo(progress, duration: const Duration(milliseconds: 300));
          }
        }
      });
    } else {
      // in all other case complete animation immediately.
      await AudioService.playSuccess();
      await animationController.forward();
      await Future.delayed(const Duration(milliseconds: 1800));
      if (mounted) {
        await animationController.reverse();
      }
    }
  }

  bool get isSwapCompleted => DB.swaps[widget.submarineSwapId ?? '']?.isClosed == true;

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
                                widget.submarineSwapId != null && !isSwapCompleted
                                    ? AppLottie.pending
                                    : AppLottie.success,
                                width: double.infinity,
                                repeat: widget.submarineSwapId != null && !isSwapCompleted,
                              ),
                            ),
                            AmountText(
                              amountSat: tx.amount,
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
                                  Text('${tx.isIncoming ? 'From' : 'To'} ', style: const TextStyle(fontSize: 16)),
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
                            const SizedBox(height: 8),
                            Text(
                              tx.confirmationTimestamp == null
                                  ? 'Transaction not confirmed yet!'
                                  : tx.confirmationTimestamp?.format() ?? '',
                              style: TextStyle(
                                color: context.themedColor(bright: Colors.black54, dark: Colors.white54),
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
                                  if (tx.liquidTx != null) ...[
                                    if (linkedSwap == null) ...[
                                      if (!tx.isIncoming)
                                        _detailRow(
                                          Icons.account_balance_wallet,
                                          'Actual Amount',
                                          AmountText(
                                            showFiat: true,
                                            amountSat: tx.amount.abs() - (tx.liquidTx!.fee.toInt()) - tx.mannaFees(),
                                            atTime: tx.txTimestamp,
                                          ),
                                        ),
                                      if (tx.mannaFees() > 0)
                                        _detailRow(
                                          Icons.toll,
                                          'Manna fee',
                                          AmountText(showFiat: true, amountSat: tx.mannaFees(), atTime: tx.txTimestamp),
                                        ),
                                      _detailRow(
                                        Icons.hub,
                                        'Network fees',
                                        AmountText(amountSat: tx.liquidTx?.fee.toInt() ?? 0, atTime: tx.txTimestamp),
                                      ),
                                    ] else ...[
                                      _detailRow(
                                        Icons.account_balance_wallet,
                                        'Actual Amount',
                                        AmountText(
                                          showFiat: true,
                                          amountSat: linkedSwap!.receiveAmount.toInt(),
                                          atTime: tx.txTimestamp,
                                        ),
                                      ),
                                      ExpansionTile(
                                        tilePadding: EdgeInsets.zero,
                                        shape: InputBorder.none,
                                        showTrailingIcon: false,
                                        title: _detailRow(
                                          Icons.money_off,
                                          'Total Fees',
                                          AmountText(
                                            showFiat: true,
                                            amountSat:
                                                tx.mannaFees() +
                                                (linkedSwap!.boltzFee?.i ?? 0) +
                                                (linkedSwap!.boltzNetworkFee) +
                                                (tx.liquidTx?.fee.toInt() ?? 0),
                                            atTime: tx.txTimestamp,
                                          ),
                                        ),
                                        childrenPadding: const EdgeInsets.only(left: 32),
                                        children: [
                                          _detailRow(
                                            Icons.hub,
                                            'Network fees',
                                            AmountText(
                                              showFiat: true,
                                              amountSat: tx.liquidTx?.fee.toInt() ?? 0,
                                              atTime: tx.txTimestamp,
                                            ),
                                            expand: false,
                                          ),
                                          _detailRow(
                                            Icons.offline_bolt,
                                            'Boltz fees',
                                            AmountText(
                                              showFiat: true,
                                              amountSat: (linkedSwap!.boltzFee?.i ?? 0) + (linkedSwap!.boltzNetworkFee),
                                              atTime: tx.txTimestamp,
                                            ),
                                            expand: false,
                                          ),
                                          if (tx.mannaFees() > 0)
                                            _detailRow(
                                              Icons.toll,
                                              'Manna fee',
                                              AmountText(
                                                showFiat: true,
                                                amountSat: tx.mannaFees(),
                                                atTime: tx.txTimestamp,
                                              ),
                                              expand: false,
                                            ),
                                        ],
                                      ),
                                    ],
                                    if (tx.liquidTx?.height != null)
                                      _detailRow(Icons.height, 'Height', tx.liquidTx!.height!.toString()),
                                    _detailRow(Icons.scale, 'Size', '${tx.liquidTx!.vsize} vB'),
                                  ],
                                  if (tx.extraMetadata['lnurlSuccessAction'] is Map &&
                                      (tx.extraMetadata['lnurlSuccessAction'] as Map).isNotEmpty)
                                    Builder(
                                      builder: (context) {
                                        final lnurlSuccessAction = (tx.extraMetadata['lnurlSuccessAction'] as Map)
                                            .cast<String, dynamic>();
                                        final url = parseString(lnurlSuccessAction['url']);
                                        final plainText = parseString(lnurlSuccessAction['plainText']);
                                        final desc = parseString(lnurlSuccessAction['description']);

                                        if (url.isEmpty && plainText.isEmpty && desc.isEmpty) {
                                          return const SizedBox.shrink();
                                        }

                                        return Column(
                                          spacing: 8,
                                          children: [
                                            const Text('LNURL data', style: TextStyle(fontSize: 16)),
                                            const Divider(),
                                            if (url.isNotEmpty)
                                              GestureDetector(
                                                onTap: () => launchUrlString(url),
                                                child: Text(
                                                  url,
                                                  style: TextStyle(
                                                    decoration: TextDecoration.underline,
                                                    color: Colors.blue.shade600,
                                                    decorationColor: Colors.blue.shade600,
                                                  ),
                                                ),
                                              ),
                                            if (desc.isNotEmpty) Text(desc),
                                            if (plainText.isNotEmpty)
                                              Text(plainText, style: const TextStyle(fontSize: 16)),
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

                                        if (brantaData.name.isEmpty) {
                                          return const SizedBox.shrink();
                                        }

                                        return BrantaCard(data: brantaData);
                                      },
                                    ),
                                  const SizedBox(height: 8),
                                  if (linkedSwap != null) SwapDataCard(linkedSwap!.id),
                                  const SizedBox(height: 16),
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
                                  const SizedBox(height: 8),
                                  Builder(
                                    builder: (context) {
                                      if (linkedSwap != null) {
                                        final allSwapTx =
                                            (linkedSwap!.chain != null
                                                    ? linkedSwap!.transactions.where(
                                                        (tx) => tx.chain == Chain.bitcoin && tx.isUser,
                                                      )
                                                    : linkedSwap!.transactions.where(
                                                        (tx) => tx.txType != SwapTransactionType.refund && tx.isUser,
                                                      ))
                                                .toList()
                                              ..sort((a, b) => a.txType.index.compareTo(b.txType.index));
                                        if (allSwapTx.isNotEmpty) {
                                          return SizedBox(
                                            width: double.infinity,
                                            child: Builder(
                                              builder: (context) {
                                                final swapTx = allSwapTx.last;
                                                final url = TransactionService.generateExplorerUrl(
                                                  explorer,
                                                  DB.transactions.values
                                                          .where((t) => swapTx.txId == t.txId)
                                                          .firstOrNull
                                                          ?.liquidTx
                                                          ?.unblindedUrl ??
                                                      'tx/${swapTx.txId}',
                                                  network: linkedSwap!.network,
                                                  isBTC: swapTx.chain == Chain.bitcoin,
                                                );
                                                return ElevatedButton(
                                                  onPressed: () => launchUrl(url),
                                                  onLongPress: () => ClipboardService.setClipBoard(url.toString()),
                                                  style: ElevatedButton.styleFrom(
                                                    visualDensity: VisualDensity.standard,
                                                  ),
                                                  child: const Text(
                                                    'See Tx',
                                                    style: TextStyle(fontSize: 16),
                                                    textAlign: TextAlign.center,
                                                  ),
                                                );
                                              },
                                            ),
                                          );
                                        }
                                      }

                                      return Row(
                                        children: [
                                          Expanded(
                                            child: ElevatedButton(
                                              onPressed: () => launchUrl(
                                                TransactionService.generateExplorerUrl(
                                                  explorer,
                                                  tx.liquidTx!.unblindedUrl,
                                                  blinded: true,
                                                ),
                                              ),
                                              onLongPress: () => ClipboardService.setClipBoard(
                                                TransactionService.generateExplorerUrl(
                                                  explorer,
                                                  tx.liquidTx!.unblindedUrl,
                                                  blinded: true,
                                                ).toString(),
                                              ),
                                              style: ElevatedButton.styleFrom(visualDensity: VisualDensity.standard),
                                              child: const Text(
                                                'See Tx 🙈',
                                                style: TextStyle(fontSize: 16),
                                                textAlign: TextAlign.center,
                                              ),
                                            ),
                                          ),
                                          const SizedBox(width: 16),
                                          Expanded(
                                            child: ElevatedButton(
                                              onPressed: () => launchUrl(
                                                TransactionService.generateExplorerUrl(
                                                  explorer,
                                                  tx.liquidTx!.unblindedUrl,
                                                ),
                                              ),
                                              onLongPress: () => ClipboardService.setClipBoard(
                                                TransactionService.generateExplorerUrl(
                                                  explorer,
                                                  tx.liquidTx!.unblindedUrl,
                                                ).toString(),
                                              ),
                                              style: ElevatedButton.styleFrom(visualDensity: VisualDensity.standard),
                                              child: const Text(
                                                'See Tx 👀',
                                                style: TextStyle(fontSize: 16),
                                                textAlign: TextAlign.center,
                                              ),
                                            ),
                                          ),
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
                    : widget.submarineSwapId != null
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
