import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:manna/models/account.dart';
import 'package:manna/router.dart';
import 'package:manna/services/biometric_services.dart';
import 'package:manna/theme.dart';
import 'package:manna/utils/state_extension.dart';
import 'package:manna/utils/toast_service.dart';
import 'package:manna/utils/util.dart';

class SeedPhraseScreen extends StatefulWidget {
  const SeedPhraseScreen({required this.account, this.fromBackup = false, super.key});

  final Account account;
  final bool fromBackup;

  @override
  State<SeedPhraseScreen> createState() => _SeedPhraseScreenState();
}

class _SeedPhraseScreenState extends State<SeedPhraseScreen> {
  late bool isVisible = false;
  late bool isVerifying = false;
  final List<String> mnemonicsDictionary = [];
  int pageIndex = 0;
  final List<String> decoys = [];
  List<String>? seedWords;

  @override
  void initState() {
    makeScreenRecordable(false);
    loadMnemonics();
    super.initState();
  }

  @override
  void dispose() {
    makeScreenRecordable(true);
    super.dispose();
  }

  Future<void> loadMnemonics() async {
    if (!await widget.account.hasMnemonic) {
      ToastService.show('The wallet is watch-only!');
      return AppRouter.pop();
    }
    final mnemonic = await widget.account.getMnemonicSentence();
    if (mnemonic != null) {
      seedWords = mnemonic.split(' ');
      update();

      final file = await rootBundle.loadString('assets/data/mnemonics_dictionary.txt');
      mnemonicsDictionary.addAll(file.split('\n'));
      decoys.addAll(
        mnemonicsDictionary.where((w) => !seedWords!.contains(w)).toList()
          ..shuffle(math.Random())
          ..take(9),
      );
      update();
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: Text('${widget.fromBackup ? 'Backup' : ''} Seed Phrase')),
      body: Align(
        alignment: Alignment.topCenter,
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 600),
          child: Builder(
            builder: (context) {
              if (seedWords == null) return const Center(child: CircularProgressIndicator());

              return SingleChildScrollView(
                padding: const EdgeInsets.symmetric(horizontal: 16),
                child: Column(
                  children: [
                    // progress bar
                    if (isVerifying)
                      Padding(
                        padding: const EdgeInsets.all(16.0),
                        child: Stack(
                          children: [
                            Container(
                              height: 14,
                              decoration: BoxDecoration(
                                color: Colors.grey.shade300,
                                borderRadius: BorderRadius.circular(10),
                              ),
                            ),
                            LayoutBuilder(
                              builder: (context, constraints) {
                                return AnimatedContainer(
                                  duration: const Duration(milliseconds: 400),
                                  curve: Curves.easeInOut,
                                  width: constraints.maxWidth * pageIndex / 5,
                                  height: 14,
                                  decoration: BoxDecoration(
                                    color: AppColors.primaryColor,
                                    borderRadius: BorderRadius.circular(10),
                                  ),
                                );
                              },
                            ),
                          ],
                        ),
                      )
                    else
                      Text.rich(
                        const TextSpan(
                          children: [
                            TextSpan(
                              text:
                                  '\u2022 Write down your seed phrase in order on paper and keep it private.\n'
                                  '\u2022 Reveal it only in a safe, private place.\n',
                            ),
                            TextSpan(
                              text:
                                  '\u2022 Losing this phrase means losing your bitcoin. Use it to restore your wallet.',
                              style: TextStyle(color: Colors.red),
                            ),
                            // TextSpan(
                            //   text:
                            //       '\u2022 Write down your seed phrase in the correct order. Back up your seed phrase on paper. Do not let anyone else see your seed phrase.\n'
                            //       '\u2022 If you are in a safe, private area away from cameras, tap to reveal your seed phrase below.\n',
                            // ),
                            // TextSpan(
                            //   text:
                            //       '\u2022 You will lose your bitcoin if you lose this key. You can use this seed phrase to restore your funds on Manna or other compatible wallets.',
                            //   style: TextStyle(color: Colors.red),
                            // ),
                          ],
                        ),
                        textAlign: TextAlign.start,
                        style: TextStyle(
                          fontSize: 16,
                          fontWeight: widget.fromBackup ? FontWeight.bold : FontWeight.w600,
                          color: AppColors.primaryColor,
                        ),
                      ),
                    const SizedBox(height: 16),
                    Column(
                      spacing: 16,
                      children: [
                        !widget.fromBackup
                            ? seedPhraseView(widget.account, isVisible)
                            : AnimatedSwitcher(
                                duration: const Duration(milliseconds: 200),
                                child: pageIndex == 0
                                    ? seedPhraseView(widget.account, isVisible)
                                    : SeedCheckView(
                                        key: ValueKey(pageIndex),
                                        pageIndex: pageIndex - 1,
                                        mnemonicWords: seedWords!,
                                        decoys: decoys,
                                        onCorrectCallback: () async {
                                          if (pageIndex == 4) {
                                            await widget.account.update(isBackedUp: true);
                                            ToastService.show('Seed phrase verified successfully!');
                                            AppRouter.pop();
                                          } else {
                                            pageIndex++;
                                          }
                                          update();
                                        },
                                        onIncorrectCallback: () {
                                          pageIndex = 0;
                                          isVerifying = false;
                                          ToastService.show('Incorrect seed phrase');
                                          update();
                                        },
                                      ),
                                transitionBuilder: (child, animation) => AnimatedBuilder(
                                  animation: animation,
                                  builder: (context, child) {
                                    return FractionalTranslation(
                                      translation: Offset(1 - animation.value, 0),
                                      child: child,
                                    );
                                  },
                                  child: child,
                                ),
                              ),
                        if ((widget.fromBackup || !isVisible) && !isVerifying)
                          SizedBox(
                            width: double.infinity,
                            child: ElevatedButton(
                              style: ElevatedButton.styleFrom(visualDensity: VisualDensity.standard),
                              onPressed: () async {
                                if (isVisible) {
                                  isVerifying = true;
                                  pageIndex++;
                                } else {
                                  toggleMnemonicVisibility();
                                }
                                update();
                              },
                              child: Text(isVisible ? 'Verify' : 'Reveal'),
                            ),
                          ),
                        const SizedBox(height: 8),
                      ],
                    ),
                  ],
                ),
              );
            },
          ),
        ),
      ),
    );
  }

  void toggleMnemonicVisibility() async {
    if (!isVisible) {
      isVisible = await BiometricService.authenticateBiometricsIfExists(
        message: 'Please authenticate to get seed phrase!',
      );
    } else {
      isVisible = false;
    }
    update();
  }

  Widget seedPhraseView(Account account, bool isVisible) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Text('Wallet : ${account.name}', style: const TextStyle(fontSize: 24, fontWeight: FontWeight.bold)),
        const SizedBox(height: 18),
        GestureDetector(
          onTap: () => toggleMnemonicVisibility(),
          child: Wrap(
            runSpacing: 12,
            spacing: 12,
            children: [
              for (int i = 0; i < seedWords!.length; i++)
                Chip(
                  materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
                  label: Text(
                    isVisible ? '${i + 1}. ${seedWords![i]}' : '*' * 5,
                    style: const TextStyle(fontSize: 16, fontWeight: FontWeight.bold),
                  ),
                  shape: StadiumBorder(side: BorderSide(color: Theme.of(context).focusColor)),
                ),
            ],
          ),
        ),
      ],
    );
  }
}

class SeedCheckView extends StatelessWidget {
  SeedCheckView({
    required this.pageIndex,
    required this.mnemonicWords,
    required this.decoys,
    this.onCorrectCallback,
    this.onIncorrectCallback,
    super.key,
  });

  final List<String> mnemonicWords;
  final List<String> decoys;
  final int pageIndex;
  final void Function()? onCorrectCallback;
  final void Function()? onIncorrectCallback;
  final random = math.Random(DateTime.timestamp().microsecondsSinceEpoch);

  @override
  Widget build(BuildContext context) {
    final start = pageIndex * 3;
    final hideIndex = random.nextInt(3);
    final correctWord = mnemonicWords.sublist(start, start + 3)[hideIndex];
    final options = [...decoys.skip(start).take(3), correctWord]..shuffle(random);
    final seedPart = mnemonicWords.sublist(start, start + 3);

    return Column(
      spacing: 24,
      mainAxisSize: MainAxisSize.min,
      children: [
        const Text(
          'Verify Seed Phrase',
          textAlign: TextAlign.center,
          style: TextStyle(fontSize: 24, fontWeight: FontWeight.bold, color: AppColors.primaryColor),
        ),
        Row(
          spacing: 12,
          children: [
            for (int i = 0; i < seedPart.length; i++)
              Expanded(
                child: Container(
                  padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                  decoration: BoxDecoration(color: Colors.grey.shade200, borderRadius: BorderRadius.circular(8)),
                  child: Row(
                    children: [
                      Text('${start + i + 1}. ', style: const TextStyle(color: AppColors.primaryColor)),
                      Expanded(
                        child: FittedBox(
                          fit: BoxFit.scaleDown,
                          child: Text(
                            i == hideIndex ? '______' : seedPart[i],
                            style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w500, color: Colors.black),
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
          ],
        ),
        Column(
          spacing: 12,
          children: [
            for (final option in options)
              GestureDetector(
                onTap: () => option == correctWord ? onCorrectCallback?.call() : onIncorrectCallback?.call(),
                child: Container(
                  alignment: Alignment.center,
                  padding: const EdgeInsets.symmetric(vertical: 12),
                  decoration: BoxDecoration(
                    borderRadius: BorderRadius.circular(12),
                    border: Border.all(color: Colors.grey),
                  ),
                  child: Text(option, style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w500)),
                ),
              ),
          ],
        ),
      ],
    );
  }
}
