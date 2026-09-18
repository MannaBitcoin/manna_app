import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:manna/config.dart';
import 'package:manna/globals.dart';
import 'package:manna/models/account.dart';
import 'package:manna/models/wallet.dart';
import 'package:manna/router.dart';
import 'package:manna/screens/image_preview_screen.dart';
import 'package:manna/screens/liquid_wallet_screen.dart';
import 'package:manna/screens/seed_phrase_screen.dart';
import 'package:manna/services/db.dart';
import 'package:manna/services/db_service.dart';
import 'package:manna/services/log_service.dart';
import 'package:manna/services/wallet_service.dart';
import 'package:manna/theme.dart';
import 'package:manna/utils/constants.dart';
import 'package:manna/utils/extensions.dart';
import 'package:manna/utils/state_extension.dart';
import 'package:manna/utils/toast_service.dart';
import 'package:manna/widgets/amount_text.dart';
import 'package:manna/widgets/bottom sheets/edit_profile_bottom_sheet.dart';
import 'package:manna/widgets/bottom%20sheets/account_bottom_sheet.dart';
import 'package:manna_core/manna_core.dart' show WalletType;

class AccountDetailScreen extends StatefulWidget {
  const AccountDetailScreen({required this.accountId, super.key});

  final String accountId;

  @override
  State<AccountDetailScreen> createState() => _AccountDetailScreenState();
}

class _AccountDetailScreenState extends State<AccountDetailScreen> {
  Account get account => DB.accounts[widget.accountId]!;
  late List<Wallet> wallets = DB.allWallets.where((w) => w.accountId == widget.accountId).toList();
  late Wallet wallet = wallets.where((w) => w.network == Config.network).first;

  late final userNameController = TextEditingController(text: wallet.metaData?.userName);
  late final bolt11DescController = StyleableTextFieldController(text: wallet.metaData?.bolt11ShortDesc);
  bool isFetchingRandomUserName = false, isSavingUserName = false, isSavingBolt11Desc = false;

  @override
  void initState() {
    if (DB.accounts[widget.accountId] == null) {
      AppRouter.pop();
    }
    GlobalListener.addListener(
      stream: .account,
      listenerName: runtimeType.toString(),
      callback: (data) {
        if (data is String && data == widget.accountId) {
          update();
          return true;
        }
        return false;
      },
    );
    super.initState();
  }

  @override
  void dispose() {
    GlobalListener.removeListener(stream: .account, listenerName: runtimeType.toString());
    userNameController.dispose();
    bolt11DescController.dispose();
    super.dispose();
  }

  void updateData() {
    wallets = DB.allWallets.where((w) => w.accountId == widget.accountId).toList();
    wallet = wallets.where((w) => w.network == Config.network).first;
    update();
  }

  Future<void> cycleUserName() async {
    if (isFetchingRandomUserName) return;
    update(() => isFetchingRandomUserName = true);
    userNameController.text = await DbService.generateRandomUserName() ?? '';
    update(() => isFetchingRandomUserName = false);
  }

  @override
  Widget build(BuildContext context) {
    final shouldSaveUserName = userNameController.text.trim().toLowerCase() != wallet.metaData?.userName;
    final shouldSaveBolt11Desc = bolt11DescController.text.trim() != wallet.metaData?.bolt11ShortDesc;

    return Scaffold(
      appBar: AppBar(
        title: const Text('Wallet Details'),
        actions: [
          Padding(
            padding: const EdgeInsets.only(right: 16),
            child: GestureDetector(
              onTap: () async {
                final res = await showModalBottomSheet(
                  context: context,
                  showDragHandle: true,
                  isScrollControlled: true,
                  useSafeArea: true,
                  isDismissible: false,
                  shape: const RoundedRectangleBorder(borderRadius: BorderRadius.vertical(top: Radius.circular(24))),
                  routeSettings: const RouteSettings(name: 'EditProfileBottomSheet'),
                  builder: (context) => EditProfileBottomSheet(account: account),
                );
                if (res is bool && res) {
                  updateData();
                }
              },
              child: Container(
                height: 52,
                width: 52,
                clipBehavior: Clip.antiAlias,
                decoration: BoxDecoration(shape: BoxShape.circle, color: AppColors.primaryColor.withValues(alpha: 0.5)),
                child: Builder(
                  builder: (context) {
                    final provider = getImageProvider(wallet.metaData?.picture);
                    final fallback = Center(
                      child: Text(
                        wallet.metaData?.userName.shortName ?? 'M',
                        style: const TextStyle(color: Colors.white, fontSize: 24),
                      ),
                    );
                    if (provider != null) {
                      return Image(
                        image: provider,
                        fit: BoxFit.cover,
                        errorBuilder: (context, error, stackTrace) => fallback,
                        loadingBuilder: imageLoadingBuilder,
                      );
                    }
                    return fallback;
                  },
                ),
              ),
            ),
          ),
        ],
      ),
      body: SingleChildScrollView(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: .start,
          spacing: 16,
          children: [
            Card(
              child: Container(
                padding: const EdgeInsets.all(16),
                child: Column(
                  crossAxisAlignment: .start,
                  spacing: 4,
                  children: [
                    Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Row(
                          spacing: 8,
                          children: [
                            Expanded(
                              child: Text(
                                account.name,
                                style: const TextStyle(fontSize: 20, fontWeight: FontWeight.w700),
                              ),
                            ),
                            IconButton(
                              onPressed: () async {
                                await showModalBottomSheet(
                                  context: context,
                                  showDragHandle: true,
                                  isScrollControlled: true,
                                  useSafeArea: true,
                                  shape: const RoundedRectangleBorder(
                                    borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
                                  ),
                                  routeSettings: const RouteSettings(name: 'AccountBottomSheet'),
                                  builder: (context) => AccountBottomSheet(account: account),
                                );
                                update();
                              },
                              icon: const Icon(Icons.edit),
                            ),
                          ],
                        ),
                      ],
                    ),
                    Align(
                      alignment: Alignment.centerRight,
                      child: AmountText(
                        amountSat: wallet.balance.toDouble(),
                        btcStyle: const TextStyle(fontSize: 36, fontWeight: FontWeight.bold),
                      ),
                    ),
                    Row(
                      children: [
                        const Expanded(child: Text('Total Transactions: ')),
                        Text(
                          DB.transactions.values.where((t) => t.walletId == wallet.uuid).length.toString(),
                          style: const TextStyle(fontSize: 18),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
            ),
            TextFormField(
              controller: userNameController,
              decoration: InputDecoration(
                labelText: 'Username',
                suffix: Padding(
                  padding: const EdgeInsets.only(right: 8),
                  child: GestureDetector(
                    onTap: () => cycleUserName(),
                    child: SizedBox.square(
                      dimension: 24,
                      child: isFetchingRandomUserName
                          ? const Center(child: CircularProgressIndicator())
                          : const Icon(Icons.shuffle, color: AppColors.primaryColor),
                    ),
                  ),
                ),
                suffixIcon: Padding(
                  padding: const EdgeInsets.only(right: 8),
                  child: GestureDetector(
                    onTap: shouldSaveUserName && !isSavingUserName
                        ? () async {
                            update(() => isSavingUserName = true);
                            final res = await DbService.updateUserName(
                              wallet: wallet,
                              userName: userNameController.text.trim().toLowerCase(),
                            );
                            if (res) {
                              ToastService.show('Username updated!');
                            }
                            isSavingUserName = false;
                            updateData();
                          }
                        : null,
                    child: DecoratedBox(
                      decoration: BoxDecoration(
                        color: shouldSaveUserName && !isSavingUserName ? AppColors.primaryColor : Colors.grey,
                        borderRadius: BorderRadius.circular(12),
                      ),
                      child: SizedBox.square(
                        dimension: 48,
                        child: isSavingUserName
                            ? const Center(
                                child: SizedBox.square(
                                  dimension: 24,
                                  child: CircularProgressIndicator(color: Colors.white),
                                ),
                              )
                            : const Icon(Icons.done, color: Colors.white),
                      ),
                    ),
                  ),
                ),
              ),
              inputFormatters: [FilteringTextInputFormatter.allow(Regexes.username)],
              maxLength: 25,
              buildCounter: (context, {required currentLength, required isFocused, required maxLength}) => null,
              onChanged: (value) => update(),
            ),

            Card(
              margin: EdgeInsets.zero,
              child: ListTile(
                title: const Text('Old liquid wallet'),
                leading: const Icon(Icons.wallet),
                trailing: const Icon(Icons.chevron_right),
                onTap: () => AppRouter.push(LiquidWalletScreen(wallet: wallet)),
              ),
            ),

            // seed phrase
            if (wallet.type == WalletType.full)
              Card(
                margin: EdgeInsets.zero,
                child: ListTile(
                  title: const Text('Seed Phrase'),
                  leading: const Icon(Icons.security),
                  trailing: const Icon(Icons.chevron_right),
                  onTap: () => AppRouter.push(SeedPhraseScreen(account: account, fromBackup: !account.isBackedUp)),
                ),
              ),
            // enable-disable
            if (!account.isMainAccount)
              Builder(
                builder: (context) {
                  final acc = account;
                  final isDisabled = acc.isDisabled;

                  return Card(
                    margin: EdgeInsets.zero,
                    child: ListTile(
                      title: Text(isDisabled ? 'Enable' : 'Disable'),
                      leading: Icon(isDisabled ? Icons.lock_open : Icons.lock_outline),
                      onTap: () async {
                        try {
                          startLoader();
                          if (isDisabled) {
                            await acc.update(isDisabled: false);
                            unawaited(DbService.syncEverything());
                            await WalletService.initSpark(xpub: wallet.xpub, waitForSync: true);
                            await DbService.setNotificationsStatus(account: acc, status: true);
                          } else {
                            await DbService.setNotificationsStatus(account: acc, status: false);
                            await acc.update(isDisabled: true);
                            WalletService.disposeNonActiveWallets();
                          }
                          selectAccount();
                          GlobalListener.update(stream: GlobalStream.account);
                          update();
                        } catch (e, s) {
                          logE(e, stackTrace: s);
                        } finally {
                          stopLoader();
                        }
                      },
                    ),
                  );
                },
              ),
            Card(
              margin: EdgeInsets.zero,
              child: ExpansionTile(
                shape: const Border(),
                title: const Text('Advanced options'),
                childrenPadding: const EdgeInsets.all(8),
                children: [
                  Column(
                    crossAxisAlignment: .start,
                    children: [
                      const SizedBox(height: 8),
                      TextFormField(
                        controller: bolt11DescController,
                        decoration: InputDecoration(
                          labelText: 'Lightning address comment',
                          helper: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            spacing: 4,
                            children: [
                              const Text('Supported variables : ', style: TextStyle(color: Colors.grey, fontSize: 12)),
                              Wrap(
                                spacing: 12,
                                runSpacing: 12,
                                children: [
                                  ActionChip(
                                    materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
                                    label: const Text('UserName'),
                                    onPressed: () => injectVar(r'$UserName'),
                                  ),
                                  ActionChip(
                                    materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
                                    label: const Text('Timestamp'),
                                    onPressed: () => injectVar(r'$Timestamp'),
                                  ),
                                ],
                              ),
                            ],
                          ),
                          suffixIcon: Padding(
                            padding: const EdgeInsets.only(right: 8),
                            child: GestureDetector(
                              onTap: shouldSaveBolt11Desc && !isSavingBolt11Desc
                                  ? () async {
                                      update(() => isSavingBolt11Desc = true);
                                      await DbService.upsertWallets({
                                        wallet: {'bolt11_short_desc': bolt11DescController.text.trim()},
                                      });
                                      ToastService.show('Bolt11 invoice description updated successfully');
                                      isSavingBolt11Desc = false;
                                      updateData();
                                    }
                                  : null,
                              child: DecoratedBox(
                                decoration: BoxDecoration(
                                  color: shouldSaveBolt11Desc && !isSavingBolt11Desc
                                      ? AppColors.primaryColor
                                      : Colors.grey,
                                  borderRadius: BorderRadius.circular(12),
                                ),
                                child: SizedBox.square(
                                  dimension: 48,
                                  child: isSavingBolt11Desc
                                      ? const Center(
                                          child: SizedBox.square(
                                            dimension: 24,
                                            child: CircularProgressIndicator(color: Colors.white),
                                          ),
                                        )
                                      : const Icon(Icons.done, color: Colors.white),
                                ),
                              ),
                            ),
                          ),
                        ),
                        maxLength: 300,
                        buildCounter: (context, {required currentLength, required isFocused, required maxLength}) =>
                            null,
                        maxLines: 3,
                        minLines: 1,
                        onChanged: (value) => update(),
                      ),
                      const SizedBox(height: 8),
                      SwitchListTile(
                        title: const Text('Anonymous transactions'),
                        subtitle: const Text(
                          "Receiver will not get notification, notes won't be stored in Manna's database",
                        ),
                        contentPadding: const EdgeInsets.only(left: 8),
                        value: account.isSendAnonymously,
                        onChanged: (value) async {
                          await account.update(isSendAnonymously: value);
                          update();
                        },
                      ),
                    ],
                  ),
                ],
              ),
            ),
            // delete
            Card(
              margin: EdgeInsets.zero,
              child: ListTile(
                title: const Text('Delete'),
                leading: const Icon(Icons.delete_outline),
                iconColor: Colors.red,
                textColor: Colors.red,
                onTap: () async {
                  final res = await showDialog(
                    context: context,
                    builder: (context) => AlertDialog(
                      title: const Text('Delete Wallet'),
                      content: const Text('Are you sure you want to delete this wallet?'),
                      actions: [
                        TextButton(onPressed: () => AppRouter.pop(false), child: const Text('Cancel')),
                        TextButton(
                          onPressed: () async {
                            await WalletService.deleteAccount(widget.accountId);
                            AppRouter.pop(true);
                          },
                          child: const Text('Delete'),
                        ),
                      ],
                    ),
                  );
                  if (res is bool && res) AppRouter.pop();
                },
              ),
            ),
          ],
        ),
      ),
    );
  }

  void injectVar(String varName) {
    final currentPos = bolt11DescController.selection.baseOffset;
    final existingText = bolt11DescController.text.codeUnits.toList();
    existingText.insertAll(currentPos, varName.codeUnits);
    bolt11DescController.text = String.fromCharCodes(existingText);
    bolt11DescController.selection = TextSelection.fromPosition(TextPosition(offset: currentPos + varName.length));
    update();
  }
}

class StyleableTextFieldController extends TextEditingController {
  StyleableTextFieldController({super.text});

  @override
  TextSpan buildTextSpan({required BuildContext context, required bool withComposing, TextStyle? style}) {
    final List<InlineSpan> textSpanChildren = <InlineSpan>[];

    text.splitMapJoin(
      RegExp(r'(\$UserName|\$Timestamp)'),
      onMatch: (Match match) {
        final String? textPart = match.group(0);
        if (textPart == null) return '';

        textSpanChildren.add(
          TextSpan(
            text: textPart,
            style: style?.merge(const TextStyle(color: AppColors.primaryColor, fontWeight: FontWeight.bold)),
          ),
        );
        return '';
      },
      onNonMatch: (String text) {
        textSpanChildren.add(TextSpan(text: text, style: style));
        return '';
      },
    );
    return TextSpan(style: style, children: textSpanChildren);
  }
}
