import 'package:flutter/material.dart';
import 'package:flutter_svg/flutter_svg.dart';
import 'package:manna/config.dart';
import 'package:manna/models/wallet.dart';
import 'package:manna/services/wallet_service.dart';
import 'package:manna/theme.dart';
import 'package:manna/utils/constants.dart';
import 'package:manna/utils/date_extension.dart';
import 'package:manna/utils/state_extension.dart';
import 'package:manna/utils/toast_service.dart';
import 'package:manna/widgets/amount_text.dart';
import 'package:manna/widgets/shimmer.dart';
import 'package:manna_core/manna_core.dart' as core;
import 'package:relative_time/relative_time.dart';

class LiquidWalletScreen extends StatefulWidget {
  const LiquidWalletScreen({required this.wallet, super.key});

  final Wallet wallet;

  @override
  State<LiquidWalletScreen> createState() => _LiquidWalletScreenState();
}

class _LiquidWalletScreenState extends State<LiquidWalletScreen> {
  core.Wallet? wollet;
  int balance = 0;
  List<core.Tx> txs = [];
  bool isSyncing = false;

  Future<void> initWollet() async {
    final mnemonic = await widget.wallet.account.getMnemonicSentence();
    if (mnemonic?.isEmpty ?? true) {
      return ToastService.show('Something went wrong!');
    }
    final descriptor = await core.Descriptor.newConfidential(network: widget.wallet.network, mnemonic: mnemonic!);
    wollet = await core.Wallet.init(
      descriptorStr: descriptor,
      network: widget.wallet.network,
      dbpath: await WalletService.getLWKPath(),
    );
    await refresh();
    await sync();
  }

  Future<void> sync() async {
    if (wollet == null) return;
    update(() => isSyncing = true);
    final network = wollet!.network();
    final electrumUrl = Config.of(network).liquid.electrum;
    if (electrumUrl.isNotEmpty) {
      await wollet!.sync_(electrumUrl: electrumUrl);
    }
    await refresh();
    update(() => isSyncing = false);
  }

  Future<void> refresh() async {
    final balances = await wollet!.balances();
    balance = balances.where((e) => e.assetId == Config.lBtcId(network: wollet!.network())).firstOrNull?.value ?? 0;

    txs = await wollet!.txs();
    update();
  }

  @override
  void initState() {
    initWollet();
    super.initState();
  }

  @override
  void dispose() {
    wollet?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: Text('Liquid wallet : ${widget.wallet.account.name}')),
      body: wollet == null
          ? const Center(child: Text('Failed to load the wallet'))
          : Center(
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 600),
                child: Column(
                  spacing: 16,
                  children: [
                    const SizedBox(height: 16),
                    const Text('Balance', style: TextStyle(fontSize: 20)),
                    AmountText(
                      amountSat: balance,
                      showFiat: true,
                      btcStyle: TextStyle(
                        fontSize: 48,
                        color: context.themedColor(bright: Colors.white, dark: AppColors.primaryColor),
                        fontWeight: FontWeight.bold,
                      ),
                      fiatStyle: const TextStyle(fontSize: 18, color: Colors.white70, fontWeight: FontWeight.w500),
                    ),
                    Row(
                      children: [
                        Expanded(
                          child: ShimmerWidget.fromColors(
                            baseColor: context.themedColor(bright: AppColors.primaryColor, dark: Colors.white),
                            highlightColor: context.themedColor(
                              bright: Colors.grey.shade100,
                              dark: AppColors.primaryColor,
                            ),
                            shimmerState: isSyncing ? ShimmerState.running : ShimmerState.stopped,
                            child: const Text(
                              'Transactions',
                              style: TextStyle(fontSize: 16, fontWeight: FontWeight.w500),
                            ),
                          ),
                        ),
                        ElevatedButton(onPressed: () => sync(), child: const Text('Rescan')),
                      ],
                    ),

                    Expanded(
                      child: ListView.builder(
                        itemCount: txs.length,
                        itemBuilder: (context, index) {
                          final tx = txs[index];
                          final isIncoming = tx.kind == 'incoming';
                          final isCompleted = tx.height != null;
                          final timestamp = tx.timestamp != null
                              ? DateTime.fromMillisecondsSinceEpoch(tx.timestamp! * 1000)
                              : DateTime(2026);

                          return Card(
                            child: Padding(
                              padding: const EdgeInsets.all(8.0),
                              child: Row(
                                spacing: 12,
                                children: [
                                  Container(
                                    width: 48,
                                    height: 48,
                                    clipBehavior: Clip.antiAlias,
                                    decoration: const BoxDecoration(
                                      color: Color.fromARGB(255, 120, 120, 120),
                                      shape: BoxShape.circle,
                                    ),
                                    child: Builder(
                                      builder: (context) {
                                        return Padding(
                                          padding: const EdgeInsets.symmetric(horizontal: 8),
                                          child: SvgPicture.asset(AppImages.logoWhiteAssetSVG),
                                        );
                                      },
                                    ),
                                  ),
                                  Expanded(
                                    child: Column(
                                      crossAxisAlignment: CrossAxisAlignment.start,
                                      mainAxisSize: MainAxisSize.min,
                                      children: [
                                        Row(
                                          spacing: 4,
                                          children: [
                                            ShimmerWidget.fromColors(
                                              key: Key(isCompleted.toString()),
                                              baseColor: isIncoming ? Colors.green : Colors.red,
                                              highlightColor: Colors.white,
                                              shimmerState: !isCompleted ? ShimmerState.running : ShimmerState.stopped,
                                              direction: isIncoming ? ShimmerDirection.ttb : ShimmerDirection.btt,
                                              child: Transform.rotate(
                                                angle: isIncoming ? -0.785398 : 2.35619,
                                                child: const Icon(
                                                  Icons.arrow_back,
                                                  size: 20,
                                                  fontWeight: FontWeight.w600,
                                                ),
                                              ),
                                            ),
                                            Expanded(
                                              child: Text(
                                                'payment ${isIncoming ? 'received' : 'sent'}',
                                                maxLines: 1,
                                                overflow: TextOverflow.ellipsis,
                                                style: const TextStyle(fontWeight: FontWeight.w600, fontSize: 15),
                                              ),
                                            ),
                                          ],
                                        ),

                                        Text(
                                          timestamp.isBefore(DateTime.now().subtract(const Duration(hours: 24)))
                                              ? timestamp.format()
                                              : timestamp.relativeTime(context),
                                          style: TextStyle(fontSize: 12, color: Colors.grey.shade600),
                                          textAlign: TextAlign.right,
                                        ),
                                      ],
                                    ),
                                  ),
                                  AmountText(
                                    amountSat:
                                        tx.balances
                                            .where((e) => e.assetId == Config.lBtcId(network: wollet!.network()))
                                            .firstOrNull
                                            ?.value ??
                                        0,
                                    btcStyle: const TextStyle(fontSize: 20),
                                    showFiat: true,
                                    isIncoming: isIncoming,
                                    scale: 0.8,
                                    atTime: timestamp,
                                  ),
                                ],
                              ),
                            ),
                          );
                        },
                      ),
                    ),
                  ],
                ),
              ),
            ),
    );
  }
}
