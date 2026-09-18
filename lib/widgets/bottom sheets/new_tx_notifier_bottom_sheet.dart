import 'dart:async';

import 'package:breez_sdk_spark_flutter/breez_sdk_spark.dart' show PaymentType;
import 'package:flutter/material.dart';
import 'package:manna/config.dart';
import 'package:manna/globals.dart';
import 'package:manna/models/contact.dart';
import 'package:manna/router.dart';
import 'package:manna/screens/contact_detail_screen.dart';
import 'package:manna/screens/transaction_detail_screen.dart';
import 'package:manna/services/db.dart';
import 'package:manna/services/db_service.dart';
import 'package:manna/services/nostr_service.dart';
import 'package:manna/services/wallet_service.dart';
import 'package:manna/theme.dart';
import 'package:manna/utils/extensions.dart';
import 'package:manna/utils/state_extension.dart';
import 'package:manna/widgets/amount_text.dart';
import 'package:manna_core/manna_core.dart';
import 'package:uuid/uuid.dart';

class NewReceivedTxBottomSheet extends StatefulWidget {
  const NewReceivedTxBottomSheet({required this.txIds, super.key});

  final List<IdWithWallet> txIds;

  @override
  State<NewReceivedTxBottomSheet> createState() => _NewReceivedTxBottomSheetState();
}

class _NewReceivedTxBottomSheetState extends State<NewReceivedTxBottomSheet> {
  late final txs = widget.txIds.map((e) => DB.allTransactions[e]).nonNulls.toList()
    ..sort((a, b) => b.timestamp.compareTo(a.timestamp));
  late List<Contact?> contacts = List.generate(txs.length, (index) => null);
  final carouselController = CarouselController();
  StreamSubscription? transactionSubscription;

  @override
  void initState() {
    if (txs.isEmpty) AppRouter.pop();
    transactionSubscription = DB.transactionBox.watch().listen((_) => update());

    carouselController.addListener(update);

    scheduleMicrotask(() async {
      for (final (i, tx) in txs.indexed) {
        final wallets = DB.allWallets.where((w) => w.uuid == tx.walletId);
        for (final wallet in wallets) {
          if (contacts[i] == null && (tx.senderUUID != null || tx.receiverUserNameOrUUID != null)) {
            if (tx.inner.paymentType == PaymentType.receive) {
              if (tx.senderUUID != null) {
                contacts[i] =
                    DB.contacts[IdWithWalletAndType.wallet(id: tx.senderUUID!, wallet: wallet)] ??
                    await DbService.getContact(uuid: tx.senderUUID, wallet: wallet);
              }
            } else {
              if (tx.receiverUserNameOrUUID != null) {
                if (tx.receiverUserNameOrUUID!.isUUID) {
                  contacts[i] =
                      DB.contacts[IdWithWalletAndType.wallet(id: tx.receiverUserNameOrUUID!, wallet: wallet)] ??
                      await DbService.getContact(uuid: tx.receiverUserNameOrUUID, wallet: wallet);
                } else {
                  contacts[i] = DB.contacts.values.where((e) => e.lnurl() == tx.receiverUserNameOrUUID).firstOrNull;
                  contacts[i] ??= await DbService.getContact(
                    userName: tx.receiverUserNameOrUUID?.getUserName,
                    wallet: wallet,
                  );
                  contacts[i] ??= await NostrService.fetchUserData(tx.receiverUserNameOrUUID!, wallet);

                  contacts[i] ??= Contact(
                    uuid: const Uuid().v5(Namespace.url.value, tx.receiverUserNameOrUUID),
                    walletId: wallet.uuid,
                    walletType: wallet.type,
                    name: tx.receiverUserNameOrUUID!.getUserName ?? '',
                    lnurl: tx.receiverUserNameOrUUID!,
                  );
                }
              }
            }
            await contacts[i]?.save();
            update();
          }
        }
      }
    });
    super.initState();
  }

  @override
  void dispose() {
    transactionSubscription?.cancel();

    carouselController.removeListener(update);
    carouselController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return SafeArea(
      child: Material(
        elevation: 16,
        borderRadius: const BorderRadiusGeometry.vertical(top: Radius.circular(24)),
        child: SingleChildScrollView(
          padding: const EdgeInsets.only(left: 16.0, right: 16.0, bottom: 16) + context.keyboardPadding,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: .start,
            spacing: 12,
            children: [
              const SizedBox(height: 8),
              const Text(
                'Payment Received!',
                style: TextStyle(fontSize: 22, fontWeight: FontWeight.bold),
                textAlign: TextAlign.center,
              ),
              SizedBox(
                height: 300,
                width: 600,
                child: CarouselView(
                  itemExtent: 5000,
                  shrinkExtent: 200,
                  itemSnapping: true,
                  controller: carouselController,
                  enableSplash: false,
                  children: [
                    for (final (i, tx) in txs.indexed)
                      Padding(
                        padding: const EdgeInsets.all(8.0),
                        child: Builder(
                          builder: (context) {
                            final wallet = DB.allWallets
                                .where((w) => w.uuid == tx.walletId && w.network == tx.network)
                                .firstOrNull;
                            final account = wallet?.account;
                            final networkText = tx.network != Config.network
                                ? ' (${switch (tx.network) {
                                    Network.mainnet => 'MainNet',
                                    Network.testnet => 'TestNet',
                                    Network.regtest => 'MannaNet',
                                  }})'
                                : '';

                            return GestureDetector(
                              onTap: () async {
                                if (wallet != null) {
                                  await NewReceivedTxService.clear();
                                  unawaited(
                                    AppRouter.push(
                                      TransactionDetailScreen(
                                        id: IdWithWallet(walletId: wallet.uuid, id: tx.txId),
                                      ),
                                    ),
                                  );
                                }
                              },
                              child: Column(
                                mainAxisSize: MainAxisSize.min,
                                spacing: 6,
                                children: [
                                  Column(
                                    children: [
                                      Text(
                                        'Wallet : ${account != null ? account.name : ''}$networkText',
                                        style: const TextStyle(fontSize: 20),
                                      ),
                                      if (contacts[i] != null)
                                        Wrap(
                                          alignment: WrapAlignment.center,
                                          crossAxisAlignment: WrapCrossAlignment.center,
                                          children: [
                                            const Text('From ', style: TextStyle(fontSize: 16)),
                                            GestureDetector(
                                              onTap: () => AppRouter.push(ContactDetailScreen(contact: contacts[i]!)),
                                              child: Text(
                                                contacts[i]!.isMannaUser
                                                    ? contacts[i]!.name()
                                                    : contacts[i]!.lnurl(wrap: true),
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
                                  ),
                                  AmountText(
                                    amountSat: tx.inner.amount.i,
                                    btcStyle: const TextStyle(
                                      fontSize: 36,
                                      fontWeight: FontWeight.w700,
                                      color: AppColors.primaryColor,
                                    ),
                                    showFiat: true,
                                    atTime: tx.timestamp,
                                  ),
                                  const SizedBox(height: 4),
                                  Text(
                                    tx.txId.shortenAddress(charCount: 14),
                                    textAlign: TextAlign.center,
                                    maxLines: 2,
                                    overflow: TextOverflow.ellipsis,
                                    style: const TextStyle(color: Colors.grey),
                                  ),
                                  const SizedBox(height: 4),
                                  if (tx.memo.isNotEmpty)
                                    Container(
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
                                          maxLines: 2,
                                          overflow: TextOverflow.ellipsis,
                                          style: TextStyle(
                                            fontSize: 16,
                                            color: context.themedColor(bright: Colors.black54, dark: Colors.white54),
                                          ),
                                        ),
                                      ),
                                    ),
                                ],
                              ),
                            );
                          },
                        ),
                      ),
                  ],
                ),
              ),
              if (txs.length > 1 && carouselController.hasClients)
                Row(
                  mainAxisAlignment: .center,
                  spacing: 6,
                  children: [
                    for (int i = 0; i < txs.length; i++)
                      Container(
                        width: 8,
                        height: 8,
                        decoration: BoxDecoration(
                          shape: BoxShape.circle,
                          color:
                              ((carouselController.offset / carouselController.position.viewportDimension).round() == i
                              ? AppColors.primaryColor
                              : Colors.grey),
                        ),
                      ),
                  ],
                ),
              SizedBox(
                width: double.infinity,
                child: ElevatedButton(
                  onPressed: () async {
                    final walletMap = Map.fromEntries(
                      txs
                          .map((tx) => DB.allWallets.where((w) => w.uuid == tx.walletId).firstOrNull)
                          .nonNulls
                          .map((e) => MapEntry(e.uuid, e)),
                    );
                    for (final w in walletMap.values) {
                      unawaited(
                        WalletService.partialSync(
                          xpub: w.xpub,
                        ).then((value) => GlobalListener.update(stream: .account, data: w.accountId)),
                      );
                    }
                    await NewReceivedTxService.clear();
                    if (AppRouter.navigatorObserver.pageStack.lastOrNull?.settings.name == 'ReceiveScreen') {
                      AppRouter.pop();
                    }
                  },
                  style: ElevatedButton.styleFrom(visualDensity: VisualDensity.standard),
                  child: const Text('Ok'),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class NewReceivedTxService {
  // this is to wait for liquid wallet to sync
  static bool shouldShowBottomSheet = false;

  static List<IdWithWallet> getNewReceivedTxs() {
    final List rawList = DB.generalBox.get('receivedTxs') ?? [];
    return rawList.map((e) => IdWithWallet.fromString(e)).toList();
  }

  static Future<void> add(List<IdWithWallet> newTxIds) async {
    final existing = getNewReceivedTxs();
    await _setReceivedTxs({...existing, ...newTxIds}.toList());
  }

  static Future<void> remove(String id) async {
    final existing = getNewReceivedTxs();
    existing.removeWhere((e) => e.id == id);
    await _setReceivedTxs(existing.toList());
  }

  static Future<void> clear() => _setReceivedTxs([]);

  static Future<void> _setReceivedTxs(List<IdWithWallet> txIds) async {
    await DB.generalBox.put('receivedTxs', txIds.map((e) => e.toString()).toList());
    // This is to force update root
    GlobalListener.update(stream: .receivedTx);
    GlobalListener.update(stream: .account);
  }
}

Widget? newReceivedTxBottomSheet(BuildContext context) {
  if (!NewReceivedTxService.shouldShowBottomSheet) return null;

  final txIds = NewReceivedTxService.getNewReceivedTxs();
  if (txIds.isEmpty) return null;

  return NewReceivedTxBottomSheet(txIds: txIds);
}
