import 'package:flutter/material.dart';
import 'package:manna/models/account.dart';
import 'package:manna/router.dart';
import 'package:manna/screens/seed_phrase_screen.dart';
import 'package:manna/theme.dart';
import 'package:manna/utils/state_extension.dart';

class BackupReminderScreen extends StatefulWidget {
  const BackupReminderScreen({required this.account, super.key});

  final Account account;

  @override
  State<BackupReminderScreen> createState() => _BackupReminderScreenState();
}

class _BackupReminderScreenState extends State<BackupReminderScreen> {
  bool showWarning = false;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        actions: [IconButton(icon: const Icon(Icons.close), onPressed: () => AppRouter.pop())],
        backgroundColor: Colors.transparent,
        elevation: 0,
        automaticallyImplyLeading: false,
      ),
      body: Center(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(24.0),
          child: Column(
            mainAxisAlignment: .center,
            crossAxisAlignment: .start,
            children: [
              if (showWarning) ...[
                const Text('Instructions', style: TextStyle(fontSize: 22, fontWeight: FontWeight.bold)),
                const SizedBox(height: 12),
                const Text(
                  '1. Write the 12 word seed phrase on paper in order.\n2. Verify accuracy.\n3. Store in a secure, private place (e.g., safe).\n4. Optionally, make a copy for another secure location.',
                  style: TextStyle(color: Colors.grey),
                ),
                const SizedBox(height: 24),
                const Text('Explanation', style: TextStyle(fontSize: 22, fontWeight: FontWeight.bold)),
                const SizedBox(height: 12),
                const Text(
                  'A seed phrase is the key to recover your Bitcoin wallet. A paper backup is offline, safe from hacks, but must be protected from physical damage or theft. Never store digitally or share.\n\nBy continuing, you understand that anyone with access to these words has full access to your wallet, and Manna cannot recover stolen coins.',
                  style: TextStyle(color: Colors.grey),
                ),
              ] else ...[
                const Center(child: Icon(Icons.warning_amber_rounded, size: 80, color: Colors.amber)),
                const SizedBox(height: 24),
                const Center(
                  child: Text('Backup Your Wallet', style: TextStyle(fontSize: 22, fontWeight: FontWeight.bold)),
                ),
                const SizedBox(height: 4),
                Center(
                  child: Text(
                    widget.account.name,
                    style: const TextStyle(fontSize: 24, fontWeight: FontWeight.bold),
                    textAlign: TextAlign.center,
                  ),
                ),
                const SizedBox(height: 16),
                const Text(
                  "Please make sure to backup your wallet seed phrase. Without it, you won't be able to recover your wallet if something goes wrong.",
                  textAlign: TextAlign.center,
                  style: TextStyle(color: Colors.grey),
                ),
              ],
              const SizedBox(height: 32),
              Row(
                spacing: 16,
                children: [
                  Expanded(
                    child: ElevatedButton(
                      style: ElevatedButton.styleFrom(
                        backgroundColor: Colors.white,
                        foregroundColor: AppColors.primaryColor,
                        shape: RoundedRectangleBorder(
                          side: const BorderSide(color: AppColors.primaryColor),
                          borderRadius: BorderRadius.circular(8),
                        ),
                        visualDensity: VisualDensity.standard,
                      ),
                      onPressed: () => AppRouter.pop(),
                      child: const FittedBox(
                        child: Text('Do this Later', style: TextStyle(fontSize: 16), textAlign: TextAlign.center),
                      ),
                    ),
                  ),
                  Expanded(
                    child: ElevatedButton(
                      style: ElevatedButton.styleFrom(visualDensity: VisualDensity.standard),
                      onPressed: () async {
                        if (!showWarning) {
                          update(() => showWarning = true);
                        } else {
                          AppRouter.replace(SeedPhraseScreen(account: widget.account, fromBackup: true));
                        }
                      },
                      child: Text(
                        showWarning ? 'I understand' : 'Backup Now',
                        style: const TextStyle(fontSize: 16),
                        textAlign: TextAlign.center,
                      ),
                    ),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}
