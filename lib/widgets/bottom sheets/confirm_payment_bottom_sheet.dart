import 'package:action_slider/action_slider.dart';
import 'package:flutter/material.dart';
import 'package:manna/models/enums.dart';
import 'package:manna/models/misc.dart';
import 'package:manna/models/swap.dart';
import 'package:manna/router.dart';
import 'package:manna/screens/contact_screen.dart';
import 'package:manna/screens/send_screen.dart';
import 'package:manna/screens/transaction_detail_screen.dart';
import 'package:manna/screens/wallet_screen.dart';
import 'package:manna/services/audio_service.dart';
import 'package:manna/services/biometric_services.dart';
import 'package:manna/services/db.dart';
import 'package:manna/services/db_service.dart';
import 'package:manna/services/transaction_service.dart';
import 'package:manna/services/wallet_service.dart';
import 'package:manna/theme.dart';
import 'package:manna/utils/extensions.dart';
import 'package:manna/utils/parser.dart';
import 'package:manna/utils/sats_extension.dart';
import 'package:manna/utils/state_extension.dart';
import 'package:manna/widgets/amount_text.dart';

class ConfirmPaymentBottomSheet extends StatefulWidget {
  const ConfirmPaymentBottomSheet({required this.paymentData, super.key});

  final PayOutData paymentData;

  @override
  State<ConfirmPaymentBottomSheet> createState() => _ConfirmPaymentBottomSheetState();
}

class _ConfirmPaymentBottomSheetState extends State<ConfirmPaymentBottomSheet> {
  late PayOutData paymentData = widget.paymentData;
  double? feeRate;
  bool showFeeRateField = false;
  bool isBuildingTx = false;
  final feeRateController = TextEditingController();
  bool showFiat = false;
  late bool isPrivate = paymentData.account.isSendAnonymously;
  late bool shouldSendNotification = paymentData.account.isSendNotification;

  @override
  void initState() {
    buildTx();
    super.initState();
  }

  @override
  void dispose() {
    feeRateController.dispose();
    super.dispose();
  }

  String amountFormatter(int amount) => showFiat ? amount.satsToFiat().formatFiat() : getSatInBitcoinStyle(amount);

  @override
  Widget build(BuildContext context) {
    return SingleChildScrollView(
      padding: const EdgeInsets.symmetric(horizontal: 24) + context.keyboardPadding,
      reverse: true,
      child: Column(
        children: [
          const Align(
            alignment: Alignment.centerLeft,
            child: Text('Confirm Payment', style: TextStyle(fontWeight: FontWeight.w500, fontSize: 20)),
          ),
          const SizedBox(height: 16),
          AmountText(
            amountSat: paymentData.calculation.totalSpend,
            btcStyle: const TextStyle(fontWeight: FontWeight.bold, fontSize: 30),
            isTapDisable: false,
            onUpdate: (val) => update(() => showFiat = !val),
          ),
          const SizedBox(height: 8),
          Text(
            paymentData.userEnteredAddress,
            style: const TextStyle(
              color: AppColors.accentColor,
              fontWeight: FontWeight.w500,
              fontSize: 16,
              overflow: TextOverflow.ellipsis,
            ),
            textAlign: TextAlign.center,
            maxLines: 3,
          ),
          if (paymentData.brantaData != null) BrantaCard(data: paymentData.brantaData!),
          if (paymentData.receiverDetail != null) ContactCard(contact: paymentData.receiverDetail!),

          const Divider(height: 24),
          Stack(
            alignment: Alignment.center,
            children: [
              Container(
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(16),
                  color: Colors.grey.withValues(alpha: 0.05),
                ),
                padding: const EdgeInsets.all(16),
                child: Column(
                  crossAxisAlignment: .start,
                  children: [
                    const Text(
                      'Transaction Details',
                      style: TextStyle(color: AppColors.accentColor, fontSize: 18, fontWeight: FontWeight.bold),
                    ),
                    const SizedBox(height: 8),
                    buildInfoRow('Wallet Name', paymentData.account.name),
                    buildInfoRow('Actual Amount', amountFormatter(paymentData.calculation.receiveAmount)),

                    if (paymentData.calculation.mannaFee > 0)
                      buildInfoRow('Manna Fee', amountFormatter(paymentData.calculation.mannaFee)),
                    if (paymentData.calculation.boltzFee > 0)
                      buildInfoRow('Boltz Fee', amountFormatter(paymentData.calculation.boltzFee)),
                    if (paymentData.calculation.boltzNetworkFee > 0)
                      buildInfoRow('Boltz Network Fee', amountFormatter(paymentData.calculation.boltzNetworkFee)),

                    if (paymentData.calculation.liquidNetworkFee > 0)
                      buildInfoRow('Network Fee', amountFormatter(paymentData.calculation.liquidNetworkFee)),

                    const Divider(height: 16),
                    buildInfoRow('Total Amount', amountFormatter(paymentData.calculation.totalSpend)),
                  ],
                ),
              ),
              if (isBuildingTx) const CircularProgressIndicator(),
            ],
          ),
          const SizedBox(height: 16),
          if (showFeeRateField)
            Row(
              children: [
                Expanded(
                  child: TextFormField(
                    controller: feeRateController,
                    decoration: const InputDecoration(labelText: 'Fee Rate (sats/vB)'),
                  ),
                ),
                const SizedBox(width: 8),
                GestureDetector(
                  onTap: () async {
                    feeRate = parseDoubleN(feeRateController.text.trim());
                    if (feeRate != null) {
                      await buildTx();
                    }
                  },
                  child: Container(
                    decoration: BoxDecoration(
                      color: AppColors.primaryColor.withValues(alpha: 0.7),
                      borderRadius: BorderRadius.circular(16),
                    ),
                    padding: const EdgeInsets.all(16),
                    child: const Icon(Icons.check, color: Colors.white),
                  ),
                ),
              ],
            ),
          if (paymentData.userEnteredAddress.isMannaUserName) ...[
            CheckboxListTile(
              value: isPrivate,
              onChanged: (value) => update(() => isPrivate = value ?? false),
              title: const Text('Send Anonymously', style: TextStyle(fontWeight: FontWeight.w500)),
              contentPadding: EdgeInsets.zero,
              controlAffinity: ListTileControlAffinity.leading,
              subtitle: const Text('Receiver will not be notified. Notes will be hidden.'),
              secondary: IconButton(
                onPressed: () {
                  showDialog(
                    context: context,
                    builder: (context) => AlertDialog(
                      title: const Text('Private transaction'),
                      content: const Text(
                        'If you make this transaction private, the recipient may not know who this transaction is from. It will not be added to transaction history on contacts page.',
                      ),
                      actions: [
                        TextButton(child: const Text('Cancel'), onPressed: () => AppRouter.pop()),
                        TextButton(child: const Text('OK'), onPressed: () => AppRouter.pop()),
                      ],
                    ),
                  );
                },
                icon: const Icon(Icons.info),
              ),
            ),
            if (!isPrivate)
              CheckboxListTile(
                value: shouldSendNotification,
                onChanged: (value) => update(() => shouldSendNotification = value ?? false),
                title: const Text('Notify Receiver', style: TextStyle(fontWeight: FontWeight.w500)),
                contentPadding: EdgeInsets.zero,
                controlAffinity: ListTileControlAffinity.leading,
                subtitle: const Text('Receiver will be notified about the payment.'),
              ),
          ],
          const SizedBox(height: 24),
          ActionSlider.standard(
            backgroundColor: context.themedColor(bright: Colors.grey.shade200, dark: Colors.grey.shade800),
            toggleColor: AppColors.primaryColor,
            icon: const Icon(Icons.arrow_forward_ios, color: Colors.white),
            loadingIcon: const CircularProgressIndicator(color: Colors.white),
            successIcon: const Icon(Icons.check, color: Colors.white),
            child: const Text('Swipe to Pay', style: TextStyle(fontSize: 16)),
            action: (controller) async {
              controller.loading();
              if (await BiometricService.authenticateBiometricsIfExists(message: 'Authenticate to confirm payment!')) {
                await hapticFeedback();
                final (status, txId) = await TransactionService.payLbtc(
                  paymentData: paymentData,
                  notifyReceiver: shouldSendNotification,
                  isPrivate: isPrivate,
                  feeRate: feeRate,
                );
                if (status == 1) {
                  await hapticFeedback();
                  controller.success();
                  Future.delayed(const Duration(seconds: 1), () {
                    AppRouter.replaceAll(const WalletScreen());
                    if (txId != null) {
                      AppRouter.push(
                        TransactionDetailScreen(
                          id: IdWithWallet(walletId: paymentData.account.currentWallet.uuid, id: txId),
                          fromCompletedTx: true,
                          submarineSwapId: paymentData.swap?.swapType == SwapType.submarine
                              ? paymentData.swap?.id
                              : null,
                        ),
                      );
                    }
                  });
                } else {
                  if (status == 3) {
                    feeRate = DbService.estimatedLiquidFeesPPM * 1.2;
                    feeRateController.text = feeRate.toString();
                    await buildTx();
                  } else if (status == 4) {
                    showFeeRateField = true;
                    update();
                  }
                  controller.reset();
                }
              } else {
                controller.reset();
              }
            },
          ),
          const SizedBox(height: 32),
        ],
      ),
    );
  }

  Widget buildInfoRow(String label, String value) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 2),
      child: Row(
        crossAxisAlignment: .start,
        children: [
          Expanded(child: Text(label, style: const TextStyle(fontSize: 16))),
          Text(value, style: const TextStyle(fontSize: 16)),
        ],
      ),
    );
  }

  Future<void> buildTx() async {
    update(() => isBuildingTx = true);
    final wallet = paymentData.account.currentWallet;
    final data = await WalletService.buildTx(
      walletId: wallet.uuid,
      outAddress: paymentData.liquidLockupAddress,
      outAmount: paymentData.calculation.sendAmount,
      fees: feeRate,
      drain: paymentData.sendAll ?? false,
      isSwapLockup: paymentData.swap != null,
    );

    paymentData = paymentData.copyWith(
      calculation: paymentData.calculation.copyWith(liquidNetworkFee: data.$2?.fees.first.value.toInt() ?? 0),
    );
    update(() => isBuildingTx = false);
  }
}
