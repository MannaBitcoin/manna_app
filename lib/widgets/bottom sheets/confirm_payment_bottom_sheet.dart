import 'dart:async';

import 'package:action_slider/action_slider.dart';
import 'package:breez_sdk_spark_flutter/breez_sdk_spark.dart'
    show SendPaymentRequest, SendPaymentOptions, SendPaymentMethod_BitcoinAddress, Payment, LnurlPayRequest;
import 'package:flutter/material.dart';
import 'package:manna/config.dart';
import 'package:manna/models/misc.dart';
import 'package:manna/models/transaction.dart';
import 'package:manna/router.dart';
import 'package:manna/screens/contact_screen.dart';
import 'package:manna/screens/send_screen.dart';
import 'package:manna/screens/transaction_detail_screen.dart';
import 'package:manna/screens/wallet_screen.dart';
import 'package:manna/services/audio_service.dart';
import 'package:manna/services/biometric_services.dart';
import 'package:manna/services/db.dart';
import 'package:manna/services/db_service.dart';
import 'package:manna/theme.dart';
import 'package:manna/utils/extensions.dart';
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
  bool showFiat = false;
  late bool isPrivate = paymentData.account.isSendAnonymously;

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
            amountSat: paymentData.calculation.sendAmount,
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

                    if (paymentData.calculation.sparkFee > 0)
                      buildInfoRow('Spark Fee', amountFormatter(paymentData.calculation.sparkFee)),
                    if (paymentData.calculation.lightningFee > 0)
                      buildInfoRow('Lightning Fee', amountFormatter(paymentData.calculation.lightningFee)),
                    if (paymentData.calculation.networkFee > 0)
                      buildInfoRow('Network Fee', amountFormatter(paymentData.calculation.networkFee)),

                    const Divider(height: 16),
                    buildInfoRow('Total Amount', amountFormatter(paymentData.calculation.sendAmount)),
                  ],
                ),
              ),
            ],
          ),
          const SizedBox(height: 16),
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
              final wallet = paymentData.account.currentWallet;
              final spark = wallet.spark;
              if (spark == null) return;

              controller.loading();

              if (await BiometricService.authenticateBiometricsIfExists(message: 'Authenticate to confirm payment!')) {
                await hapticFeedback();

                Payment? payment;
                if (paymentData.calculation.preparedLnurlPay != null) {
                  payment = (await spark.lnurlPay(
                    request: LnurlPayRequest(prepareResponse: paymentData.calculation.preparedLnurlPay!),
                  )).payment;
                }

                if (paymentData.calculation.preparedPayment != null) {
                  payment = (await spark.sendPayment(
                    request: SendPaymentRequest(
                      prepareResponse: paymentData.calculation.preparedPayment!,
                      options: switch (paymentData.calculation.preparedPayment!.paymentMethod) {
                        SendPaymentMethod_BitcoinAddress() => SendPaymentOptions.bitcoinAddress(
                          confirmationSpeed: paymentData.calculation.btcFeeRate,
                        ),
                        _ => null,
                      },
                    ),
                  )).payment;
                }

                if (payment == null) {
                  controller.reset();
                  return;
                }
                await hapticFeedback();
                controller.success();

                await Transaction(
                  txId: payment.id,
                  inner: payment,
                  network: Config.network,
                  walletId: wallet.uuid,
                  memo: paymentData.addressData.comment ?? '',
                  note: paymentData.note ?? '',
                  categories: paymentData.category ?? {},
                  senderUUID: wallet.uuid,
                  receiverUserNameOrUUID: paymentData.userEnteredAddress.isUserName
                      ? paymentData.userEnteredAddress
                      : paymentData.receiverDetail?.uuid,
                  extraMetadata: {if (paymentData.brantaData != null) 'brantaData': paymentData.brantaData!.toMap()},
                ).save();
                await paymentData.receiverDetail?.save();
                unawaited(DbService.cacheContacts());

                if (!isPrivate &&
                    paymentData.receiverDetail != null &&
                    (paymentData.addressData.comment?.trim().isNotEmpty ?? false)) {
                  unawaited(
                    DbService.saveTxData(
                      senderUUID: wallet.uuid,
                      receiverLnurl: paymentData.receiverDetail!.lnurl(),
                      txId: payment.id,
                      memo: paymentData.addressData.comment!,
                    ),
                  );
                }

                Future.delayed(const Duration(seconds: 1), () {
                  AppRouter.replaceAll(const WalletScreen());
                  AppRouter.push(
                    TransactionDetailScreen(
                      id: IdWithWallet(walletId: wallet.uuid, id: payment!.id),
                      fromCompletedTx: true,
                    ),
                  );
                });
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
}
