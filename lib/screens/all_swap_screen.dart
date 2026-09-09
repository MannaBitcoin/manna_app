import 'dart:async';

import 'package:flutter/material.dart';
import 'package:manna/models/swap.dart';
import 'package:manna/models/wallet.dart';
import 'package:manna/services/db.dart';
import 'package:manna/utils/state_extension.dart';
import 'package:manna/widgets/bottom%20sheets/swap_mnemonic_bottom_sheet.dart';
import 'package:manna/widgets/swap_data_card.dart';
import 'package:manna_core/manna_core.dart' show Swap;

class AllSwapScreen extends StatefulWidget {
  const AllSwapScreen({required this.wallet, super.key});

  // reason for using wallet instead of walletId is to separate watch-only and full wallets.
  final Wallet wallet;

  @override
  State<AllSwapScreen> createState() => _AllSwapScreenState();
}

class _AllSwapScreenState extends State<AllSwapScreen> {
  List<Swap> swaps = [];
  StreamSubscription? swapSubscription;

  @override
  void initState() {
    swapSubscription = DB.swaps.box.watch().listen((_) => update());
    swaps =
        (DB.swaps.values.where((s) => s.walletId == widget.wallet.uuid && s.walletType == widget.wallet.type).toList()
          ..sort((e1, e2) => e2.creationTimeUTC.compareTo(e1.creationTimeUTC)));
    super.initState();
  }

  @override
  void dispose() {
    swapSubscription?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Swaps'),
        actions: [
          PopupMenuButton(
            icon: const Icon(Icons.more_vert),
            itemBuilder: (context) {
              return [
                PopupMenuItem(
                  child: const Text('swap seed phrase'),
                  onTap: () {
                    showModalBottomSheet(
                      context: context,
                      showDragHandle: true,
                      isScrollControlled: true,
                      useSafeArea: true,
                      isDismissible: false,
                      shape: const RoundedRectangleBorder(
                        borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
                      ),
                      routeSettings: const RouteSettings(name: 'SwapMnemonicBottomSheet'),
                      builder: (context) => SwapMnemonicBottomSheet(wallet: widget.wallet),
                    );
                  },
                ),
              ];
            },
          ),
        ],
      ),
      body: swaps.isNotEmpty
          ? ListView.builder(
              padding: const EdgeInsets.all(16),
              itemCount: swaps.length,
              itemBuilder: (context, index) => SwapDataCard(swaps[index].id),
            )
          : const Center(child: Text('No swaps found!')),
    );
  }
}
