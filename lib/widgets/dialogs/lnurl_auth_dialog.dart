import 'package:flutter/material.dart';
import 'package:manna/models/account.dart';
import 'package:manna/router.dart';
import 'package:manna/services/db.dart';
import 'package:manna/services/lnurl_service.dart';
import 'package:manna/theme.dart';
import 'package:manna/utils/state_extension.dart';

enum LNURLAuthAction {
  register('wants to create new account with your lightningKey.'),
  login('wants to login to an existing account with your lightningKey.'),
  link('wants to link your lightningKey to an existing account.'),
  auth('wants to authenticate you with your lightningKey.');

  const LNURLAuthAction(this.message);
  final String message;
}

class LNURLAuthDialog extends StatefulWidget {
  const LNURLAuthDialog({required this.uri, required this.service, required this.k1, this.action, super.key});

  final Uri uri;
  final String service;
  final String k1;
  final String? action;

  @override
  State<LNURLAuthDialog> createState() => _LNURLAuthDialogState();
}

class _LNURLAuthDialogState extends State<LNURLAuthDialog> {
  Account? selectedAcc = selectedAccount;
  List<Account> accounts = [];

  @override
  void initState() {
    Future(() async {
      for (final acc in DB.activeAccounts) {
        if (await acc.hasMnemonic) {
          accounts.add(acc);
        }
      }
      update();
    });
    super.initState();
  }

  @override
  Widget build(BuildContext context) {
    final action =
        LNURLAuthAction.values.where((e) => e.name == widget.action?.toLowerCase()).firstOrNull ??
        LNURLAuthAction.login;

    return AlertDialog(
      title: const Text('LNURL-Auth'),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text.rich(
            TextSpan(
              children: [
                TextSpan(
                  text: widget.service,
                  style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 18, color: AppColors.primaryColor),
                ),
                TextSpan(text: ' ${action.message}'),
              ],
            ),
          ),
          Row(
            spacing: 12,
            children: [
              const Text('Select wallet :', style: TextStyle(fontSize: 16, fontWeight: FontWeight.w600)),
              Expanded(
                child: DropdownButtonHideUnderline(
                  child: DropdownButton<Account>(
                    value: selectedAcc,
                    onChanged: (value) => update(() => selectedAcc = value),
                    items:
                        [
                              ...accounts.where((w) => w.isMainAccount),
                              ...accounts.where((w) => !w.isDisabled && !w.isMainAccount),
                            ]
                            .map(
                              (acc) => DropdownMenuItem(
                                value: acc,
                                child: Text(acc.name, maxLines: 2, overflow: TextOverflow.ellipsis),
                              ),
                            )
                            .toList(),
                    style: const TextStyle(
                      color: AppColors.primaryColor,
                      fontSize: 18,
                      letterSpacing: 1.1,
                      fontWeight: FontWeight.w500,
                    ),
                    borderRadius: BorderRadius.circular(16),
                    alignment: Alignment.center,
                  ),
                ),
              ),
            ],
          ),
        ],
      ),
      actions: [
        TextButton(onPressed: () => AppRouter.pop(false), child: const Text('Cancel')),
        TextButton(
          onPressed: selectedAcc == null
              ? null
              : () => LnurlAuthService.onLNURLAuth(
                  account: selectedAcc!,
                  service: widget.service,
                  k1Hex: widget.k1,
                  uri: widget.uri,
                ),
          child: Text(switch (action) {
            LNURLAuthAction.register => 'Register',
            LNURLAuthAction.auth || LNURLAuthAction.login => 'Login',
            LNURLAuthAction.link => 'Link',
          }),
        ),
      ],
    );
  }
}
