import 'package:file_saver/file_saver.dart';
import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:manna/router.dart';
import 'package:manna/screens/seed_phrase_screen.dart';
import 'package:manna/screens/shop_screen.dart';
import 'package:manna/screens/splash_screen.dart';
import 'package:manna/services/db.dart';
import 'package:manna/services/log_service.dart';
import 'package:manna/services/shop_service.dart';
import 'package:manna/utils/toast_service.dart';

class DataRecoveryScreen extends StatefulWidget {
  const DataRecoveryScreen({super.key});

  @override
  State<DataRecoveryScreen> createState() => _DataRecoveryScreenState();
}

class _DataRecoveryScreenState extends State<DataRecoveryScreen> {
  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Fail Safe Recovery')),
      body: SingleChildScrollView(
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 10),
          child: Column(
            children: [
              ExpansionTile(
                title: const Text('Wallets'),
                leading: const Icon(Icons.wallet),
                shape: const Border(),
                childrenPadding: const EdgeInsets.only(left: 16),
                children: [
                  for (final account in DB.accounts.values)
                    ExpansionTile(
                      visualDensity: VisualDensity.adaptivePlatformDensity,
                      shape: const Border(),
                      tilePadding: const EdgeInsets.symmetric(horizontal: 17),
                      title: Text(account.name),
                      children: [
                        ListTile(
                          title: const Text('Get Wallet Seed Phrase'),
                          leading: const Icon(Icons.wallet),
                          trailing: const Icon(Icons.navigate_next),
                          onTap: () => AppRouter.push(SeedPhraseScreen(account: account)),
                        ),
                      ],
                    ),
                ],
              ),
              ListTile(
                title: const Text('Download shop catalog'),
                leading: const Icon(Icons.shop),
                onTap: () async {
                  final accountId = await showAccountSelectionDialog(context);
                  if (accountId is String) {
                    final wallet = DB.accounts[accountId]?.currentWallet;
                    if (wallet != null) {
                      await ShopService.downloadShopData(wallet);
                    }
                  }
                },
              ),
              ListTile(
                title: const Text('Import app data'),
                leading: const RotatedBox(quarterTurns: 2, child: Icon(Icons.exit_to_app)),
                onTap: () async {
                  if (await DB.importAppData()) {
                    AppRouter.replaceAll(const SplashScreen());
                  }
                },
              ),
              ListTile(
                title: const Text('Export app data'),
                leading: const Icon(Icons.exit_to_app),
                onTap: () => DB.exportAppData(),
              ),
              ListTile(
                title: const Text('Export App logs'),
                leading: const Icon(Icons.receipt_long),
                onTap: () async {
                  final zipData = await LogManager.exportLogs();
                  if (zipData != null) {
                    final savedPath = await FileSaver.instance.saveAs(
                      name: 'manna_logs_${DateFormat('yyyy_MM_dd_hh_mm').format(DateTime.now())}',
                      bytes: zipData,
                      mimeType: MimeType.zip,
                      fileExtension: 'zip',
                    );
                    if (savedPath?.isNotEmpty ?? false) ToastService.show('Logs saved successfully.');
                  }
                },
              ),
            ],
          ),
        ),
      ),
    );
  }
}
