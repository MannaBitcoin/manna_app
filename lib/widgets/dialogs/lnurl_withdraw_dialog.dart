import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:manna/app_state.dart';
import 'package:manna/globals.dart';
import 'package:manna/models/account.dart';
import 'package:manna/router.dart';
import 'package:manna/services/db.dart';
import 'package:manna/services/log_service.dart';
import 'package:manna/services/transaction_service.dart';
import 'package:manna/theme.dart';
import 'package:manna/utils/constants.dart';
import 'package:manna/utils/de_bouncer.dart';
import 'package:manna/utils/extensions.dart';
import 'package:manna/utils/parser.dart';
import 'package:manna/utils/sats_extension.dart';
import 'package:manna/utils/state_extension.dart';
import 'package:manna/utils/toast_service.dart';
import 'package:manna/utils/util.dart';
import 'package:manna/widgets/amount_text.dart';
import 'package:manna/widgets/fees_tile.dart';

class LNURLWithdrawDialog extends StatefulWidget {
  const LNURLWithdrawDialog({
    required this.serviceName,
    required this.callback,
    required this.k1,
    required this.minWithdrawable,
    required this.maxWithdrawable,
    required this.desc,
    super.key,
  });

  final String serviceName;
  final String callback;
  final String k1;
  final int minWithdrawable;
  final int maxWithdrawable;
  final String? desc;

  @override
  State<LNURLWithdrawDialog> createState() => _LNURLWithdrawDialogState();
}

class _LNURLWithdrawDialogState extends State<LNURLWithdrawDialog> {
  Account? selectedAcc = selectedAccount;
  final satAmountController = TextEditingController(), memoController = TextEditingController();
  final _formKey = GlobalKey<FormState>();

  int amount = 0;
  final feeExpansionController = ExpansibleController();
  FeesAndAmounts? calculations;
  final deBouncer = DeBouncer(const Duration(milliseconds: 200));

  @override
  void initState() {
    amount = widget.maxWithdrawable;
    satAmountController.text = amount.toStringAsFixed(0);
    memoController.text = widget.desc?.trim() ?? '';
    rebuildFees();
    super.initState();
  }

  @override
  void dispose() {
    satAmountController.dispose();
    memoController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final isPaymentFeasible = (calculations?.receiveAmount ?? 0) > 0;
    if (!isPaymentFeasible) {
      postFrameCallBack(() => feeExpansionController.collapse());
    }

    return AlertDialog(
      title: const Text('LNURL-Withdraw'),
      content: Form(
        key: _formKey,
        autovalidateMode: AutovalidateMode.onUserInteraction,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            spacing: 16,
            children: [
              TextFormField(
                controller: satAmountController,
                keyboardType: TextInputType.number,
                decoration: InputDecoration(
                  hintText: '0',
                  labelText: 'Amount',
                  suffixIcon: Row(
                    mainAxisSize: .min,
                    mainAxisAlignment: .center,
                    children: [Text(getBitcoinDisplayStyle())],
                  ),
                ),
                onChanged: (value) async {
                  amount = int.tryParse(value) ?? 0;
                  deBouncer.call(() => rebuildFees());
                },
                maxLength: widget.maxWithdrawable.toStringAsFixed(0).length,
                inputFormatters: [
                  AppState.bitcoinDisplayStyle == 2
                      ? FilteringTextInputFormatter.allow(Regexes.btcInputFilter)
                      : FilteringTextInputFormatter.digitsOnly,
                ],
                buildCounter: (context, {required currentLength, required isFocused, required maxLength}) => null,
                validator: (value) {
                  if (parseInt(value) < widget.minWithdrawable) {
                    return 'You can receive minimum ${getSatInBitcoinStyle(widget.minWithdrawable)}';
                  }
                  if (parseInt(value) > widget.maxWithdrawable) {
                    return 'You can receive maximum ${getSatInBitcoinStyle(widget.minWithdrawable)}';
                  }
                  return null;
                },
              ),
              Text('${getSatInBitcoinStyle(widget.minWithdrawable)} - ${getSatInBitcoinStyle(widget.maxWithdrawable)}'),
              TextFormField(
                controller: memoController,
                textInputAction: TextInputAction.done,
                decoration: const InputDecoration(labelText: 'Memo'),
                keyboardType: TextInputType.multiline,
                textCapitalization: TextCapitalization.sentences,
                maxLines: 3,
                minLines: 1,
                maxLength: 500,
                buildCounter: (context, {required currentLength, required isFocused, required maxLength}) => null,
                onChanged: (value) => update(),
              ),
              Row(
                spacing: 8,
                children: [
                  const Text('Wallet :', style: TextStyle(fontSize: 16, fontWeight: FontWeight.w600)),
                  Expanded(
                    child: DropdownButtonHideUnderline(
                      child: DropdownButton<Account>(
                        value: selectedAcc,
                        onChanged: (value) => update(() => selectedAcc = value),
                        items: [
                          ...[
                            ...DB.activeAccounts.where((w) => w.isMainAccount),
                            ...DB.activeAccounts.where((w) => !w.isDisabled && !w.isMainAccount),
                          ].map(
                            (w) => DropdownMenuItem(
                              value: w,
                              child: Text(w.name, maxLines: 2, overflow: TextOverflow.ellipsis),
                            ),
                          ),
                        ],
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
              ListTileTheme(
                minVerticalPadding: 0,
                child: ExpansionTile(
                  controller: feeExpansionController,
                  title: feeExpansionController.isExpanded
                      ? const Text('Fee Details', style: TextStyle(fontSize: 16))
                      : FeesTile(
                          amountSat: !isPaymentFeasible ? 0 : calculations!.receiveAmount,
                          title: 'You will receive',
                        ),
                  minTileHeight: 0,
                  shape: const Border(),
                  tilePadding: EdgeInsets.only(top: 8, bottom: !feeExpansionController.isExpanded ? 8 : 0),
                  enabled: isPaymentFeasible,
                  onExpansionChanged: (value) => update(),
                  children: [
                    InkWell(
                      onTap: () => feeExpansionController.collapse(),
                      child: Column(
                        children: [
                          if (calculations != null) ...[
                            FeesTile(amountSat: calculations!.receiveAmount, title: 'Amount'),
                            if (calculations!.mannaFee > 0)
                              FeesTile(amountSat: calculations!.mannaFee, title: 'Manna fee'),
                            if (calculations!.boltzFee > 0)
                              FeesTile(amountSat: calculations!.boltzFee, title: 'Boltz fee'),
                            if (calculations!.boltzNetworkFee > 0)
                              FeesTile(amountSat: calculations!.boltzNetworkFee, title: 'Boltz network fee'),
                            if (calculations!.liquidNetworkFee > 0)
                              FeesTile(amountSat: calculations!.liquidNetworkFee, title: 'Network fee'),
                          ],
                          const Divider(),
                          FeesTile(
                            amountSat: !isPaymentFeasible ? 0 : calculations!.receiveAmount,
                            title: 'You will receive',
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
      actions: [
        TextButton(onPressed: () => AppRouter.pop(false), child: const Text('Cancel')),
        TextButton(
          onPressed: selectedAcc == null
              ? null
              : () async {
                  if (_formKey.currentState?.validate() ?? false) {
                    try {
                      startLoader();
                      final invoice = await TransactionService.generateQrData(
                        account: selectedAcc!,
                        amount: amount,
                        type: TraType.lnToLbtc,
                        memo: memoController.text.trim(),
                        asBIP21: false,
                        doesSenderPayFee: false,
                      );
                      if (invoice?.isNotEmpty ?? false) {
                        final res = await globalDio.getUri(
                          Uri.parse(widget.callback).replace(queryParameters: {'k1': widget.k1, 'pr': invoice}),
                        );
                        if (res.isSuccess && parseString(res.data['status']).toLowerCase() == 'ok') {
                          ToastService.show('Withdrawal request sent to ${widget.serviceName}!');
                          AppRouter.pop(true);
                        } else {
                          final error = parseStringN(res.data['reason']);
                          if (error != null) {
                            ToastService.show(error);
                          }
                        }
                      }
                    } catch (e, s) {
                      logE(e, stackTrace: s);
                    } finally {
                      stopLoader();
                    }
                  }
                },
          child: const Text('Withdraw'),
        ),
      ],
    );
  }

  Future<void> rebuildFees() async {
    if (selectedAcc == null) return;
    calculations = await calculateFeeAndAmounts(
      wallet: selectedAcc!.currentWallet,
      type: TraType.lnToLbtc,
      amount: amount,
      isAmountTarget: false,
    );
    update();
  }
}
