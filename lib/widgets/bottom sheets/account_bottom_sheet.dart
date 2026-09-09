import 'dart:async';

import 'package:flutter/material.dart';
import 'package:manna/globals.dart';
import 'package:manna/models/account.dart';
import 'package:manna/router.dart';
import 'package:manna/screens/account_detail_screen.dart';
import 'package:manna/services/db.dart';
import 'package:manna/services/wallet_service.dart';
import 'package:manna/utils/state_extension.dart';
import 'package:manna/utils/toast_service.dart';

class AccountBottomSheet extends StatefulWidget {
  const AccountBottomSheet({super.key, this.account});

  final Account? account;

  @override
  AccountBottomSheetState createState() => AccountBottomSheetState();
}

class AccountBottomSheetState extends State<AccountBottomSheet> {
  final nameController = TextEditingController();

  @override
  void initState() {
    if (widget.account != null) {
      nameController.text = widget.account!.name;
    }
    if (nameController.text.trim().isEmpty) {
      nameController.text = 'Wallet ${DB.accounts.length + 1}';
    }
    super.initState();
  }

  @override
  void dispose() {
    nameController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return SingleChildScrollView(
      padding: const EdgeInsets.all(16) + context.keyboardPadding,
      child: Column(
        mainAxisAlignment: .center,
        mainAxisSize: MainAxisSize.min,
        spacing: 16,
        children: [
          TextFormField(
            controller: nameController,
            keyboardType: TextInputType.text,
            maxLength: 40,
            buildCounter: (context, {required currentLength, required isFocused, required maxLength}) => null,
            decoration: const InputDecoration(labelText: 'Wallet name'),
          ),
          SizedBox(
            width: double.infinity,
            child: ElevatedButton(
              onPressed: () async {
                final accountName = nameController.text.trim();
                if (DB.accounts.values.any((e) => e.name == accountName && e.id != widget.account?.id)) {
                  return ToastService.show('Wallet account name already exists!');
                }

                if (widget.account != null) {
                  await widget.account!.update(name: accountName);
                  AppRouter.pop(true);
                } else {
                  if (await WalletService.createAccount(accountName: accountName)) {
                    AppRouter.pop(true);

                    Future.delayed(const Duration(seconds: 1), () {
                      if (AppRouter.navigatorContext.mounted) {
                        final account = DB.accounts.values.where((acc) => acc.name == accountName).firstOrNull;
                        final userName = account?.currentWallet.metaData?.userName;

                        if (userName != null) {
                          showDialog(
                            context: AppRouter.navigatorContext,
                            builder: (context) => AlertDialog(
                              title: const Text('Choose username'),
                              content: Column(
                                mainAxisSize: MainAxisSize.min,
                                crossAxisAlignment: CrossAxisAlignment.start,
                                spacing: 12,
                                children: [
                                  Text.rich(
                                    TextSpan(
                                      text: 'Your current username is ',
                                      children: [
                                        TextSpan(
                                          text: userName,
                                          style: TextStyle(color: Colors.blue.shade600, fontSize: 16),
                                        ),
                                      ],
                                    ),
                                  ),
                                  const Text(
                                    'You can change it to your own custom Lightning Address. This is where other people can send you bitcoin payments.\n'
                                    'You can always change your username later in your wallet settings.',
                                  ),
                                ],
                              ),
                              actions: [
                                TextButton(onPressed: () => AppRouter.pop(), child: const Text('dismiss')),
                                TextButton(
                                  onPressed: () {
                                    AppRouter.pop();
                                    AppRouter.push(AccountDetailScreen(accountId: account!.id));
                                  },
                                  child: const Text('change now'),
                                ),
                              ],
                            ),
                          );
                        }
                      }
                    });
                  }
                }
                GlobalListener.update(stream: .account);
              },
              style: ElevatedButton.styleFrom(visualDensity: VisualDensity.standard),
              child: Text(widget.account == null ? 'Create' : 'Update'),
            ),
          ),
        ],
      ),
    );
  }
}
