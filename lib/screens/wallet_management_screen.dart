import 'dart:async';

import 'package:flutter/material.dart';
import 'package:manna/config.dart';
import 'package:manna/globals.dart';
import 'package:manna/models/account.dart';
import 'package:manna/router.dart';
import 'package:manna/screens/restore_wallet_screen.dart';
import 'package:manna/screens/account_detail_screen.dart';
import 'package:manna/services/db.dart';
import 'package:manna/services/db_service.dart';
import 'package:manna/services/log_service.dart';
import 'package:manna/services/wallet_service.dart';
import 'package:manna/theme.dart';
import 'package:manna/utils/state_extension.dart';
import 'package:manna/widgets/bottom sheets/account_bottom_sheet.dart';

class WalletManagementScreen extends StatefulWidget {
  const WalletManagementScreen({super.key});

  @override
  State<WalletManagementScreen> createState() => _WalletManagementScreenState();
}

class _WalletManagementScreenState extends State<WalletManagementScreen> {
  @override
  void initState() {
    GlobalListener.addListener(
      stream: .account,
      listenerName: runtimeType.toString(),
      callback: (data) {
        // don't refresh if the update is from sync and data is walletId
        if (data is! String) {
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
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final accounts = [
      ...DB.activeAccounts.where((acc) => !acc.isDisabled && acc.isMainAccount),
      ...(DB.activeAccounts.where((acc) => !acc.isDisabled && !acc.isMainAccount).toList()
        ..sort((a, b) => a.sortOrder.compareTo(b.sortOrder))),
      ...(DB.accounts.values
          .where(
            (acc) =>
                DB.fullWallets.values.where((w) => w.accountId == acc.id && w.network == Config.network).isNotEmpty &&
                acc.isDisabled,
          )
          .toList()
        ..sort((a, b) => a.sortOrder.compareTo(b.sortOrder))),
    ].toList();
    return Scaffold(
      appBar: AppBar(title: const Text('Wallet Management')),
      body: Column(
        children: [
          Expanded(
            child: ReorderableListView(
              padding: const EdgeInsets.all(8) + const EdgeInsets.only(bottom: 64),
              children: accounts.map((e) => accountListTile(e)).toList(),
              onReorderItem: (oldIndex, newIndex) async {
                final account = accounts.removeAt(oldIndex);
                accounts.insert(newIndex, account);
                final wasMainAccountDisabled = accounts.firstOrNull?.isDisabled ?? false;
                for (final (i, acc) in accounts.indexed) {
                  await acc.update(sortOrder: i, isMainAccount: i == 0, isDisabled: i == 0 ? false : acc.isDisabled);
                }
                GlobalListener.update(stream: .account);
                update();

                if (wasMainAccountDisabled) {
                  startLoader();
                  try {
                    final acc = accounts.firstOrNull;
                    if (acc != null) {
                      final wallet = acc.currentWallet;
                      unawaited(DbService.syncEverything());
                      await WalletService.initSpark(xpub: wallet.xpub, waitForSync: true);
                      await DbService.setNotificationsStatus(account: acc, status: true);
                      update();
                    }
                  } catch (e, s) {
                    logE(e, stackTrace: s);
                  } finally {
                    stopLoader();
                  }
                }
              },
            ),
          ),
          if (DB.activeAccounts.length > 20)
            Container(
              color: context
                  .themedColor(bright: AppColors.primaryColor, dark: AppColors.darkCardColor)
                  .withValues(alpha: 0.5),
              width: double.infinity,
              padding: const EdgeInsets.all(4),
              alignment: Alignment.center,
              child: const Text(
                'Creating too many wallets may degrade performance and will drain battery faster, disable non-frequent wallets!',
              ),
            ),
        ],
      ),
      floatingActionButton: FloatingActionButton(
        onPressed: () {},
        child: SizedBox.expand(
          child: PopupMenuButton(
            tooltip: 'Add Wallet Account',
            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
            constraints: const BoxConstraints(),
            icon: const Icon(Icons.add),
            itemBuilder: (context) {
              return [
                PopupMenuItem(
                  child: Tooltip(
                    message: 'Create a new wallet account',
                    child: walletOptionCard(
                      title: 'Create New Wallet',
                      description: 'Start from scratch and create a brand new wallet',
                      iconData: Icons.add,
                      gradientColors: const [Colors.purpleAccent, Colors.blueAccent],
                    ),
                  ),
                  onTap: () async {
                    await showModalBottomSheet(
                      context: context,
                      showDragHandle: true,
                      isScrollControlled: true,
                      useSafeArea: true,
                      shape: const RoundedRectangleBorder(
                        borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
                      ),
                      routeSettings: const RouteSettings(name: 'AccountBottomSheet'),
                      builder: (context) => const AccountBottomSheet(),
                    );
                    update();
                  },
                ),
                PopupMenuItem(
                  child: Tooltip(
                    message: 'Restore existing wallet account',
                    child: walletOptionCard(
                      title: 'Restore Wallet',
                      description: 'Recover an existing wallet with a recovery seed phrase or wallet descriptor',
                      iconData: Icons.lock_open,
                      gradientColors: const [Colors.greenAccent, Colors.teal],
                    ),
                  ),
                  onTap: () async {
                    await AppRouter.push(const RestoreWalletScreen());
                    update();
                  },
                ),
              ];
            },
          ),
        ),
      ),
    );
  }

  Widget walletOptionCard({
    required String title,
    required String description,
    required IconData iconData,
    required List<Color> gradientColors,
  }) {
    return Padding(
      padding: const EdgeInsets.all(8),
      child: Row(
        spacing: 16,
        children: [
          ShaderMask(
            blendMode: BlendMode.srcIn,
            shaderCallback: (Rect bounds) {
              return LinearGradient(
                colors: gradientColors,
                begin: Alignment.topLeft,
                end: Alignment.bottomRight,
              ).createShader(bounds);
            },
            child: Icon(iconData, size: 40, color: Colors.white),
          ),
          Expanded(
            child: Column(
              crossAxisAlignment: .start,
              children: [
                Text(title, style: const TextStyle(fontSize: 18, fontWeight: FontWeight.bold)),
                Text(
                  description,
                  style: TextStyle(
                    color: context.themedColor(bright: Colors.black87, dark: Colors.white70),
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget accountListTile(Account acc) {
    final wallet = acc.currentWallet;
    return Card(
      key: Key(acc.id),
      child: ListTile(
        onTap: () => AppRouter.push(AccountDetailScreen(accountId: acc.id)).then((_) => update()),
        tileColor: acc.isMainAccount ? AppColors.primaryColor.withValues(alpha: 0.1) : null,
        shape: RoundedRectangleBorder(borderRadius: BorderRadiusGeometry.circular(12)),
        titleTextStyle: TextStyle(color: acc.isDisabled ? Theme.of(context).disabledColor : null),
        title: Text.rich(
          TextSpan(
            children: <InlineSpan>[
              TextSpan(text: acc.name),
              if (wallet.metaData?.userName != null)
                TextSpan(
                  text: ' (${wallet.metaData?.userName})',
                  style: const TextStyle(color: AppColors.accentColor, fontSize: 12),
                ),
            ],
          ),
          style: const TextStyle(fontWeight: FontWeight.bold),
        ),
        leading: const Icon(Icons.vpn_key_outlined),
      ),
    );
  }
}
