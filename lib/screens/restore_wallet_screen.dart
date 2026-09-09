import 'dart:ui';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:manna/globals.dart';
import 'package:manna/router.dart';
import 'package:manna/screens/qr_scanner_screen.dart';
import 'package:manna/screens/wallet_screen.dart';
import 'package:manna/services/db.dart';
import 'package:manna/services/log_service.dart';
import 'package:manna/services/wallet_service.dart';
import 'package:manna/theme.dart';
import 'package:manna/utils/state_extension.dart';
import 'package:manna/utils/toast_service.dart';
import 'package:manna/utils/util.dart';
import 'package:manna_core/manna_core.dart';

class RestoreWalletScreen extends StatefulWidget {
  const RestoreWalletScreen({super.key});

  @override
  RestoreWalletScreenState createState() => RestoreWalletScreenState();
}

class RestoreWalletScreenState extends State<RestoreWalletScreen> {
  final List<String> mnemonicWords = List.generate(12, (_) => '');
  final List<FocusNode> focusNodes = List.generate(12, (_) => FocusNode());
  final List<TextEditingController> wordControllers = List.generate(12, (_) => TextEditingController());
  final Set<String> mnemonicsDictionary = {};
  final TextEditingController nameController = TextEditingController();
  final GlobalKey<FormState> _formKey = GlobalKey<FormState>();
  bool isMain = DB.allWallets.isEmpty;

  bool isWatchOnlyMode = false;
  final descriptorController = TextEditingController();

  bool blurSeed = false;

  @override
  void initState() {
    makeScreenRecordable(false);
    if (nameController.text.trim().isEmpty) {
      nameController.text = 'Wallet ${DB.accounts.length + 1}';
    }
    loadDictionary();
    super.initState();
  }

  Future<void> loadDictionary() async {
    final file = await rootBundle.loadString('assets/data/mnemonics_dictionary.txt');
    mnemonicsDictionary.addAll(file.split('\n'));
    update();
  }

  @override
  void dispose() {
    makeScreenRecordable(true);
    wordControllers.map((e) => e.dispose());
    nameController.dispose();
    descriptorController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text('Restore Wallet${isWatchOnlyMode ? ' (Watch-only)' : ''}'),
        actions: [
          IconButton(
            onPressed: () => update(() => isWatchOnlyMode = !isWatchOnlyMode),
            tooltip: isWatchOnlyMode ? 'Import full wallet with mnemonic seed phrase' : 'Import watch-only wallet',
            icon: Icon(isWatchOnlyMode ? Icons.vpn_key_outlined : Icons.remove_red_eye_outlined),
          ),
        ],
      ),
      bottomNavigationBar: Padding(
        padding: const EdgeInsets.only(left: 16, right: 16, bottom: 16),
        child: ElevatedButton(
          style: ElevatedButton.styleFrom(visualDensity: VisualDensity.standard),
          onPressed:
              (isWatchOnlyMode
                      ? descriptorController.text.trim().isNotEmpty
                      : (mnemonicWords.length == 12 && mnemonicWords.every((e) => e.isNotEmpty))) &&
                  nameController.text.trim().isNotEmpty
              ? () async {
                  if (!_formKey.currentState!.validate()) return;
                  FocusManager.instance.primaryFocus?.unfocus();

                  try {
                    update(() => blurSeed = true);
                    if (isWatchOnlyMode) {
                      try {
                        final descriptor = await Descriptor.parseDescriptor(
                          descriptorStr: descriptorController.text.trim(),
                        );
                        if (await WalletService.importWatchOnlyWallet(
                          accountName: nameController.text.trim(),
                          walletDescriptor: descriptor,
                          makeMain: isMain,
                        )) {
                          AppRouter.replaceAll(const WalletScreen());
                        }
                      } catch (_) {
                        ToastService.show('Invalid descriptor');
                      }

                      GlobalListener.update(stream: .account);
                    } else {
                      if (await WalletService.restoreAccount(
                        mnemonicWords: mnemonicWords.map((e) => e.trim()).toList(),
                        accountName: nameController.text.trim(),
                        makeMain: isMain,
                      )) {
                        AppRouter.replaceAll(const WalletScreen());
                      }
                    }
                  } catch (e, s) {
                    logE(e, stackTrace: s);
                  } finally {
                    update(() => blurSeed = false);
                  }
                }
              : null,
          child: const Text(
            'Restore',
            style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold, color: Colors.white),
          ),
        ),
      ),
      body: Center(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(16.0),
          reverse: true,
          child: Form(
            key: _formKey,
            child: ImageFiltered(
              imageFilter: ImageFilter.blur(sigmaX: 8, sigmaY: 8),
              enabled: blurSeed,
              child: Column(
                spacing: 20,
                mainAxisSize: MainAxisSize.min,
                children: [
                  const SizedBox(height: 20),
                  Text(
                    isWatchOnlyMode
                        ? 'Watch-only wallet: displays balance, transactions, and can receive bitcoin - cannot send bitcoin.'
                        : 'Enter your 12-word seed phrase',
                    style: const TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
                    textAlign: TextAlign.center,
                  ),
                  if (isWatchOnlyMode)
                    Stack(
                      clipBehavior: Clip.none,
                      children: [
                        TextFormField(
                          controller: descriptorController,
                          maxLines: 6,
                          minLines: 2,
                          decoration: const InputDecoration(
                            labelText: 'Enter wallet descriptor',
                            alignLabelWithHint: true,
                          ),
                          style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w600),
                          keyboardType: TextInputType.multiline,
                          textInputAction: TextInputAction.done,
                          onChanged: (value) => update(),
                          validator: (value) =>
                              value == null || value.trim().isEmpty ? 'Enter wallet descriptor' : null,
                        ),
                        Positioned(
                          bottom: -4,
                          right: -1,
                          child: ElevatedButton.icon(
                            style: IconButton.styleFrom(
                              backgroundColor: AppColors.primaryColor,
                              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(99)),
                              padding: const EdgeInsets.symmetric(horizontal: 12),
                            ),
                            onPressed: () async {
                              final qrData = await AppRouter.push(
                                QRScannerScreen(
                                  validateQr: (qrData) async {
                                    try {
                                      await Descriptor.parseDescriptor(descriptorStr: qrData);
                                      return true;
                                    } catch (_) {}
                                    return false;
                                  },
                                ),
                              );
                              if (qrData is String) {
                                try {
                                  final descriptor = await Descriptor.parseDescriptor(descriptorStr: qrData);
                                  update(() => descriptorController.text = descriptor);
                                } catch (_) {}
                              }
                            },
                            label: const Text('Scan', style: TextStyle(color: Colors.white)),
                            icon: const Icon(Icons.qr_code_scanner, color: Colors.white),
                          ),
                        ),
                      ],
                    )
                  else
                    Wrap(
                      runSpacing: 12,
                      spacing: 12,
                      children: [
                        for (int i = 0; i < mnemonicWords.length; i++)
                          ConstrainedBox(
                            constraints: const BoxConstraints(maxWidth: 100),
                            child: Autocomplete<String>(
                              optionsBuilder: (TextEditingValue textEditingValue) {
                                if (textEditingValue.text.isEmpty) return [];
                                return mnemonicsDictionary.where(
                                  (word) => word.startsWith(textEditingValue.text.toLowerCase()),
                                );
                              },
                              fieldViewBuilder: (context, controller, focusNode, onFieldSubmitted) {
                                focusNodes[i] = focusNode;
                                wordControllers[i] = controller;
                                return TextFormField(
                                  controller: controller,
                                  focusNode: focusNode,
                                  decoration: InputDecoration(
                                    hintText: 'Word ${i + 1}',
                                    filled: true,
                                    fillColor: controller.text.trim().toLowerCase().isEmpty
                                        ? Colors.transparent
                                        : mnemonicsDictionary.contains(controller.text.trim().toLowerCase())
                                        ? Colors.green.shade50
                                        : Colors.red.shade50,
                                  ),
                                  style: const TextStyle(fontSize: 16, color: Colors.black),
                                  keyboardType: TextInputType.name,
                                  textInputAction: TextInputAction.next,
                                  onFieldSubmitted: (_) {
                                    if (i == 11) {
                                      focusNodes[i].unfocus();
                                    }
                                  },
                                  onChanged: (value) {
                                    final pastedMnemonic = value.trim().split(' ');
                                    if (pastedMnemonic.length == 12) {
                                      for (final (i, w) in pastedMnemonic.indexed) {
                                        mnemonicWords[i] = w.toLowerCase().trim();
                                        wordControllers[i].text = mnemonicWords[i];
                                        if (mnemonicsDictionary.contains(mnemonicWords[i])) {
                                          if (mnemonicsDictionary.where((w) => w.startsWith(mnemonicWords[i])).length ==
                                              1) {
                                            focusNodes[i].nextFocus();
                                          }
                                        }
                                      }
                                    } else {
                                      mnemonicWords[i] = value.toLowerCase().trim();
                                      if (mnemonicsDictionary.contains(mnemonicWords[i])) {
                                        if (mnemonicsDictionary.where((w) => w.startsWith(mnemonicWords[i])).length ==
                                            1) {
                                          focusNodes[i].nextFocus();
                                        }
                                      }
                                    }
                                    update();
                                  },
                                  validator: (value) {
                                    if (value == null || value.trim().isEmpty) {
                                      return 'Please enter word';
                                    }
                                    return null;
                                  },
                                );
                              },
                              onSelected: (String selection) {
                                i == 11 ? focusNodes[i].unfocus() : focusNodes[i].nextFocus();
                                mnemonicWords[i] = selection.toLowerCase();
                                update();
                              },
                            ),
                          ),
                      ],
                    ),
                  TextFormField(
                    controller: nameController,
                    keyboardType: TextInputType.text,
                    textCapitalization: TextCapitalization.words,
                    maxLength: 40,
                    buildCounter: (context, {required currentLength, required isFocused, required maxLength}) => null,
                    decoration: const InputDecoration(labelText: 'Wallet account name'),
                    validator: (value) {
                      if (value == null || value.isEmpty) {
                        return 'Please enter wallet name';
                      }
                      if (DB.accounts.values.any((e) => e.name == nameController.text.trim())) {
                        return 'Wallet account name already exists!';
                      }
                      return null;
                    },
                    onFieldSubmitted: (value) => update(),
                  ),
                  if (DB.allWallets.isNotEmpty)
                    CheckboxListTile(
                      controlAffinity: ListTileControlAffinity.leading,
                      contentPadding: EdgeInsets.zero,
                      value: isMain,
                      onChanged: (value) => update(() => isMain = value!),
                      title: const Text('Set as default wallet'),
                    ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}
