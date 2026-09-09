import 'package:flutter/material.dart';
import 'package:manna/config.dart';
import 'package:manna/models/wallet.dart';
import 'package:manna/router.dart';
import 'package:manna/services/biometric_services.dart';
import 'package:manna/services/clipboard_service.dart';
import 'package:manna/utils/state_extension.dart';
import 'package:manna/utils/toast_service.dart';
import 'package:manna_core/manna_core.dart' show MasterSwapKey;

class SwapMnemonicBottomSheet extends StatefulWidget {
  const SwapMnemonicBottomSheet({required this.wallet, super.key});

  final Wallet wallet;

  @override
  State<SwapMnemonicBottomSheet> createState() => _SwapMnemonicBottomSheetState();
}

class _SwapMnemonicBottomSheetState extends State<SwapMnemonicBottomSheet> {
  bool isVisible = false;
  List<String> seedWords = [];

  @override
  void initState() {
    init();
    super.initState();
  }

  void init() async {
    final swapMnemonic = await widget.wallet.getSwapMnemonic();

    if (swapMnemonic.isEmpty) {
      ToastService.show('unable to get swap mnemonics');
      AppRouter.pop();
      return;
    }
    seedWords = swapMnemonic.split(' ');
    update();
  }

  @override
  Widget build(BuildContext context) {
    return SingleChildScrollView(
      padding: const EdgeInsets.all(16) - const EdgeInsets.only(top: 16) + context.keyboardPadding,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(
            'The swap seed phrase is used for everything related to boltz swaps, and it might allow others to claim any pending swaps.\nKeep it safe!',
            style: TextStyle(color: Colors.red.shade300,fontSize: 16),
            textAlign: TextAlign.center,
          ),
          const SizedBox(height: 16),
          GestureDetector(
            onTap: () => toggleMnemonicVisibility(),
            child: Wrap(
              runSpacing: 12,
              spacing: 12,
              children: [
                for (int i = 0; i < seedWords.length; i++)
                  Chip(
                    materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
                    label: Text(
                      isVisible ? '${i + 1}. ${seedWords[i]}' : '*' * 5,
                      style: const TextStyle(fontSize: 16, fontWeight: FontWeight.bold),
                    ),
                    shape: StadiumBorder(side: BorderSide(color: Theme.of(context).focusColor)),
                  ),
              ],
            ),
          ),
          const SizedBox(height: 16),
          if (isVisible) ...[
            SizedBox(
              width: double.infinity,
              child: ElevatedButton.icon(
                style: ElevatedButton.styleFrom(visualDensity: VisualDensity.standard),
                onPressed: () => ClipboardService.setClipBoard(seedWords.join(' '), 'swap seed phrase copied'),
                label: const Text('Copy'),
                icon: const Icon(Icons.copy),
              ),
            ),
            SizedBox(
              width: double.infinity,
              child: ElevatedButton.icon(
                style: ElevatedButton.styleFrom(visualDensity: VisualDensity.standard),
                onPressed: () async => ClipboardService.setClipBoard(
                  await (await MasterSwapKey.fromMnemonic(
                    mnemonic: seedWords.join(' '),
                    network: Config.network,
                  )).getSwapXpub(),
                  'swap xpub copied',
                ),
                label: const Text('Copy swap xpub', textAlign: TextAlign.center),
                icon: const Icon(Icons.copy),
              ),
            ),
          ],
        ],
      ),
    );
  }

  void toggleMnemonicVisibility() async {
    if (!isVisible) {
      isVisible = await BiometricService.authenticateBiometricsIfExists(
        message: 'Please authenticate to get swap seed phrase!',
      );
    } else {
      isVisible = false;
    }
    update();
  }
}
