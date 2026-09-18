import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;

import 'package:archive/archive.dart';
import 'package:file_picker/file_picker.dart';
import 'package:file_saver/file_saver.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:hive_ce/hive.dart';
import 'package:intl/intl.dart';
import 'package:manna/app_state.dart';
import 'package:manna/config.dart';
import 'package:manna/globals.dart';
import 'package:manna/models/account.dart';
import 'package:manna/models/chat_message.dart';
import 'package:manna/models/contact.dart';
import 'package:manna/models/country_model.dart';
import 'package:manna/models/hive_adapters/v2.dart';
import 'package:manna/models/misc.dart';
import 'package:manna/models/setting_history_cache.dart';
import 'package:manna/models/shop_item.dart';
import 'package:manna/models/tax.dart';
import 'package:manna/models/transaction.dart';
import 'package:manna/models/wallet.dart';
import 'package:manna/router.dart';
import 'package:manna/services/chat_service.dart';
import 'package:manna/services/log_service.dart';
import 'package:manna/services/secure_storage.dart';
import 'package:manna/utils/parser.dart';
import 'package:manna/utils/toast_service.dart';
import 'package:manna_core/manna_core.dart' show WalletType, Network, KeyPair;
import 'package:path/path.dart' as path;
import 'package:path_provider/path_provider.dart';

import 'biometric_services.dart';

class IdWithWallet {
  IdWithWallet({required this.walletId, required this.id});

  factory IdWithWallet.fromString(String str) {
    final parts = str.split('_');
    return IdWithWallet(walletId: parts[0], id: parts[1]);
  }

  final String walletId;
  final String id;

  @override
  int get hashCode => Object.hash(walletId, id);

  @override
  bool operator ==(Object other) => other is IdWithWallet && other.walletId == walletId && other.id == id;

  @override
  String toString() => '${walletId}_$id';
}

class IdWithWalletAndType {
  IdWithWalletAndType({required this.id, required this.walletId, required this.walletType});

  factory IdWithWalletAndType.wallet({required String id, required Wallet wallet}) =>
      IdWithWalletAndType(id: id, walletId: wallet.uuid, walletType: wallet.type);

  factory IdWithWalletAndType.fromString(String str) {
    final parts = str.split('_');
    return IdWithWalletAndType(
      id: parts[0],
      walletId: parts[1],
      walletType: WalletType.values[parseIntN(parts[2]) ?? 0],
    );
  }

  final String id;
  final String walletId;
  final WalletType walletType;

  @override
  int get hashCode => Object.hash(id, walletId, walletType);

  @override
  bool operator ==(Object other) =>
      other is IdWithWalletAndType && other.id == id && other.walletId == walletId && other.walletType == walletType;

  @override
  String toString() => '${id}_${walletId}_${walletType.index}';
}

class DB {
  static Timer? refreshTimer;

  static late BoxAccessor<String, Account> accounts;

  static List<Account> get activeAccounts => accounts.values
      .where(
        (e) =>
            !e.isDisabled &&
            fullWallets.values.where((w) => w.accountId == e.id && w.network == Config.network).isNotEmpty,
      )
      .toList();

  // all the full wallets from all network
  static Map<String, Wallet> fullWallets = {};
  static List<Wallet> get allWallets => [...fullWallets.values];
  // all the wallets for current network
  static List<Wallet> currentWallets = [];

  static Map<IdWithWallet, Transaction> allTransactions = {};
  static Map<IdWithWallet, Transaction> transactions = {};
  static late BoxAccessor<int, Tax> taxes;
  static Map<int, ShopItem> shopItems = {};
  static late BoxAccessor<String, Uint8List> categoryImages;
  static Map<IdWithWalletAndType, Contact> contacts = {};
  static late BoxAccessor<int, SettingHistoryCache> settingHistory;

  static late Box<Wallet> walletBox;
  static late Box<Transaction> transactionBox;
  static late Box<Contact> contactsBox;
  static late Box<ShopItem> shopItemBox;
  static late Box<ChatMessage> chatBox;
  static late Box<ChatConversation> conversationsBox;
  static late Box<MessageLog> messageLogBox;
  static late Box<String> syncedMessageLogIdsBox;

  static late Box<double> btcPriceHistoryBox;
  static late Box generalBox;
  static late LazyBox<Uint8List> imageCacheBox;

  static bool isInitialized = false;

  static Future<void> tinyInit() async {
    try {
      await Hive.initFlutter('manna_data/db');
      registerV2Adapters();
      generalBox = await Hive.openBox('general_data');
    } catch (e, s) {
      logE(e, stackTrace: s);
    }
  }

  static Future<void> init({bool force = false}) async {
    try {
      await tinyInit();
      if (isInitialized && !force) return;

      final dbPass = await SecureStorage.fetch('dbPass');
      Uint8List? password = dbPass;
      if (password == null || password.length != 32) {
        final random = math.Random.secure();
        final key = Uint8List.fromList(List.generate(32, (index) => random.nextInt(256)));
        await SecureStorage.store('dbPass', key);
        password = key;
      }

      accounts = BoxAccessor(await Hive.openBox<Account>('accounts', encryptionCipher: HiveAesCipher(password)));
      walletBox = await Hive.openBox<Wallet>('wallets', encryptionCipher: HiveAesCipher(password));
      contactsBox = await Hive.openBox<Contact>('contacts', encryptionCipher: HiveAesCipher(password));
      loadContacts();

      transactionBox = await Hive.openBox<Transaction>('transactions', encryptionCipher: HiveAesCipher(password));
      chatBox = await Hive.openBox<ChatMessage>('chats');
      conversationsBox = await Hive.openBox<ChatConversation>('conversations');
      messageLogBox = await Hive.openBox<MessageLog>('messageLogs');
      syncedMessageLogIdsBox = await Hive.openBox<String>('syncedMessageLogIds');
      imageCacheBox = await Hive.openLazyBox<Uint8List>('imageCaches');
      btcPriceHistoryBox = await Hive.openBox<double>('btc_price_history');
      settingHistory = BoxAccessor(
        await Hive.openBox<SettingHistoryCache>('settingHistoryCache', encryptionCipher: HiveAesCipher(password)),
      );
      shopItemBox = await Hive.openBox<ShopItem>('shopItems');
      taxes = BoxAccessor(await Hive.openBox<Tax>('taxes'));
      categoryImages = BoxAccessor(await Hive.openBox<Uint8List>('categoryImages'));

      loadAllData();
      isInitialized = true;
    } catch (e, s) {
      logE(e, stackTrace: s);
    }

    refreshTimer = Timer.periodic(const Duration(seconds: 15), (t) => loadAllData());
  }

  static String? getInitialNotificationPayload() => parseStringN(generalBox.get('initialNotificationPayload'));

  static Future<void> setInitialNotificationPayload(String? payload) => payload == null
      ? generalBox.delete('initialNotificationPayload')
      : generalBox.put('initialNotificationPayload', payload);

  static String? getInitialDeepLinkURI() => parseStringN(generalBox.get('initialDeepLinkURI'));

  static Future<void> setInitialDeepLinkURI(String? uri) =>
      uri == null ? generalBox.delete('initialDeepLinkURI') : generalBox.put('initialDeepLinkURI', uri);

  static List<String> getSyncedSwapIds() => (generalBox.get('syncedSwapIds') as List? ?? []).cast<String>();

  static Future<void> setSyncedSwapIds(List<String> swapIds) => generalBox.put('syncedSwapIds', swapIds);

  static void loadAllData() async {
    loadWallets();
    loadTransactions();
    loadShopItems();
    loadContacts();

    // This is necessary for boxes which are encrypted, cause hive just append frames for every put call.
    // Meaning updating transaction or wallet will bloat .hive file with new encrypted frames
    // which takes significant time to decrypt and compact on next boot. compacting every few seconds solves it.
    await accounts.box.compact();
    await walletBox.compact();
    await transactionBox.compact();
    await shopItemBox.compact();
    await taxes.box.compact();
    await categoryImages.box.compact();
    await contactsBox.compact();
    await settingHistory.box.compact();
    await chatBox.compact();
    await conversationsBox.compact();
    await btcPriceHistoryBox.compact();
    await generalBox.compact();
    await imageCacheBox.compact();
  }

  static void loadWallets() {
    fullWallets = {for (final w in walletBox.values) w.uuid: w};

    currentWallets = fullWallets.values.where((w) => w.network == Config.network).toList();
  }

  static void loadTransactions() {
    transactions = {
      for (final t in transactionBox.values.where((t) => t.network == Config.network))
        IdWithWallet(walletId: t.walletId, id: t.txId): t,
    };
    allTransactions = {for (final t in transactionBox.values) IdWithWallet(walletId: t.walletId, id: t.txId): t};
  }

  static void loadShopItems() => shopItems = {for (final s in shopItemBox.values) s.id: s};

  static void loadContacts() => contacts = {
    for (final c in contactsBox.values)
      IdWithWalletAndType(id: c.uuid, walletId: c.walletId, walletType: c.walletType): c,
  };

  static SettingHistoryCache? getSettingAtTime(String key, DateTime dateTime, {Network? network}) {
    final net = network ?? Config.network;
    final keySetting = settingHistory.values.where((h) => h.key == key && h.network == net).toList();
    keySetting.sort((a, b) => b.effectiveAtUTC.compareTo(a.effectiveAtUTC));

    return keySetting.where((h) => h.effectiveAt.isBefore(dateTime)).firstOrNull;
  }

  static Future<void> exportAppData() async {
    if (!(await BiometricService.authenticateBiometricsIfExists(message: 'Please authenticate to export!'))) {
      return;
    }
    await init();
    loadAllData();

    if (!AppRouter.navigatorContext.mounted) return;

    String? password;
    final res = await showDialog(
      context: AppRouter.navigatorContext,
      builder: (context) => AlertDialog(
        title: const Text('Create a password to lock the export'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          spacing: 16,
          children: [
            Text(
              'This is the encryption password required to import the exported data. Please keep it safe!',
              style: TextStyle(color: Colors.red.shade300),
            ),
            TextFormField(
              autofocus: true,
              textAlign: TextAlign.center,
              keyboardType: TextInputType.visiblePassword,
              decoration: const InputDecoration(contentPadding: EdgeInsets.all(8), labelText: 'Enter password'),
              onChanged: (value) => password = value.trim(),
            ),
          ],
        ),
        actions: [
          TextButton(onPressed: () => AppRouter.pop(false), child: const Text('Cancel')),
          TextButton(onPressed: () => AppRouter.pop(true), child: const Text('Continue')),
        ],
      ),
    );
    if (res is bool && res && password?.isNotEmpty == true) {
      try {
        final archive = Archive();

        final accountData = utf8.encode(
          jsonEncode(
            await Future.wait(
              accounts.values.map(
                (v) async => {...v.toMap().toEncodeReady(), 'mnemonicSentence': await v.getMnemonicSentence()},
              ),
            ),
          ),
        );
        final walletData = utf8.encode(
          jsonEncode(await Future.wait(fullWallets.values.map((v) async => v.toMap()).toList())),
        );
        final transactionData = utf8.encode(jsonEncode(transactionBox.values.map((v) => v.toMap()).toList()));
        final shopItemData = utf8.encode(jsonEncode(shopItemBox.values.map((v) => v.toMap()).toList()));
        final taxesData = utf8.encode(jsonEncode(taxes.values.map((v) => v.toMap()).toList()));
        final catImageData = utf8.encode(
          jsonEncode(categoryImages.toMap.map((key, value) => MapEntry(parseString(key), value))),
        );
        final contactsData = utf8.encode(jsonEncode(contactsBox.values.map((v) => v.toMap()).toList()));
        final chatData = utf8.encode(jsonEncode(chatBox.values.map((v) => v.toMap()).toList()));

        archive.add(ArchiveFile('accounts', accountData.length, accountData));
        archive.add(ArchiveFile('wallets', walletData.length, walletData));
        archive.add(ArchiveFile('transactions', transactionData.length, transactionData));
        archive.add(ArchiveFile('shopItems', shopItemData.length, shopItemData));
        archive.add(ArchiveFile('taxes', taxesData.length, taxesData));
        archive.add(ArchiveFile('categoryImages', catImageData.length, catImageData));
        archive.add(ArchiveFile('contacts', contactsData.length, contactsData));
        archive.add(ArchiveFile('chats', chatData.length, chatData));

        // app settings goes into metadata file
        final metadata = utf8.encode(
          jsonEncode({
            'isBiometricOn': AppState.prefs.getBool('isBiometricOn') ?? false,
            'isStoreTipsOn': AppState.isShopTipsOn,
            'blockExplorer': AppState.blockExplorer,
            'bitcoinDisplayStyle': AppState.bitcoinDisplayStyle,
            'theme': AppState.theme.index,
            'selectedCurrency': AppState.selectedCurrency.name,
            'isSoundEffectsOn': AppState.isSoundEffectsOn,
            'lastSyncedNpub': AppState.prefs.getString('lastSyncedNpub'),
          }),
        );
        archive.add(ArchiveFile('metadata', metadata.length, metadata));
        final zipFile = Uint8List.fromList(ZipEncoder(password: password).encode(archive));
        final savedPath = await FileSaver.instance.saveAs(
          name: 'manna_export_${DateFormat('yyyy_MM_dd_hh_mm').format(DateTime.now())}',
          bytes: zipFile,
          fileExtension: 'zip',
          mimeType: MimeType.zip,
        );

        if (savedPath?.isNotEmpty == true) return ToastService.show('App data exported successfully.');
      } catch (e, s) {
        logE(e, stackTrace: s);
        ToastService.show('Something went wrong while exporting app data.');
      }
    }
  }

  static Future<bool> importAppData() async {
    if (!(await BiometricService.authenticateBiometricsIfExists(message: 'Please authenticate to continue'))) {
      return false;
    }
    try {
      final FilePickerResult? result = await FilePicker.pickFiles(type: FileType.custom, allowedExtensions: ['zip']);
      if (!AppRouter.navigatorContext.mounted) return false;

      if (result != null) {
        final zip = File(result.files.single.path!);

        String? password;
        final res = await showDialog(
          context: AppRouter.navigatorContext,
          builder: (context) => AlertDialog(
            title: const Text('Enter the password to unlock the exported zip'),
            content: TextFormField(
              autofocus: true,
              textAlign: TextAlign.center,
              keyboardType: TextInputType.visiblePassword,
              obscureText: true,
              decoration: const InputDecoration(contentPadding: EdgeInsets.all(8), labelText: 'Enter password'),
              onChanged: (value) => password = value.trim(),
            ),
            actions: [
              TextButton(onPressed: () => AppRouter.pop(false), child: const Text('Cancel')),
              TextButton(
                onPressed: () async {
                  if (password?.isNotEmpty == true) {
                    try {
                      startLoader();
                      final archive = ZipDecoder().decodeBytes(await zip.readAsBytes(), password: password);
                      for (final file in archive) {
                        if (file.isFile) {
                          final fileData = file.readBytes();
                          if (fileData != null) {
                            final jsonData = jsonDecode(utf8.decode(fileData));
                            switch (file.name) {
                              case 'accounts':
                                await Future.wait(
                                  (await Future.wait(
                                    parseList(jsonData, (e) => Account.fromMap(e)),
                                  )).map((e) => e.save()),
                                );
                              case 'wallets':
                                await Future.wait(
                                  parseList(jsonData, (e) async {
                                    await Wallet.fromMap(e).save();
                                  }),
                                );
                              case 'woWallets':
                                await Future.wait(
                                  parseList(jsonData, (e) async {
                                    await Wallet.fromMap(e).save();
                                  }),
                                );
                              case 'transactions':
                                await Future.wait(parseList(jsonData, (e) => Transaction.fromMap(e).save()));
                              case 'shopItems':
                                await Future.wait(parseList(jsonData, (e) => ShopItem.fromMap(e).save()));
                              case 'taxes':
                                await Future.wait(parseList(jsonData, (e) => Tax.fromMap(e).save()));
                              case 'categoryImages':
                                for (final e in parseMap(
                                  jsonData,
                                  (k, v) => MapEntry(parseString(k), v as Uint8List?),
                                ).entries) {
                                  if (e.value != null) {
                                    await categoryImages.box.put(e.key, e.value!);
                                  }
                                }
                              case 'contacts':
                                await Future.wait(parseList(jsonData, (e) => Contact.fromMap(e).save()));
                              case 'chats':
                                await Future.wait(parseList(jsonData, (e) => ChatMessage.fromMap(e).save()));
                              case 'metadata':
                                await AppState.prefs.setBool('isBiometricOn', parseBool(jsonData['isBiometricOn']));
                                AppState.isShopTipsOn = parseBool(jsonData['isStoreTipsOn']);
                                AppState.blockExplorer = parseIntN(jsonData['blockExplorer']) ?? 0;
                                AppState.bitcoinDisplayStyle = parseIntN(jsonData['bitcoinDisplayStyle']) ?? 0;
                                AppState.theme = ThemeMode.values[parseIntN(jsonData['theme']) ?? 0];
                                final json = await rootBundle.loadString('assets/data/country.json');
                                final countries = (jsonDecode(json) as List)
                                    .map((e) => CountryModel.fromMap(e))
                                    .toList();
                                AppState.selectedCurrency =
                                    countries
                                        .where((c) => c.name == parseStringN(jsonData['selectedCurrency']))
                                        .firstOrNull ??
                                    AppState.selectedCurrency;
                                AppState.isSoundEffectsOn = parseBool(jsonData['isSoundEffectsOn']);
                                final lastSyncedNpub = parseStringN(jsonData['lastSyncedNpub']);
                                if (lastSyncedNpub != null) {
                                  await AppState.prefs.setString('lastSyncedNpub', lastSyncedNpub);
                                }
                            }
                          }
                        }
                      }
                      AppRouter.pop(true);
                      return ToastService.show('App data imported successfully!');
                    } catch (e, s) {
                      if ({
                        'password error',
                        "macs don't match",
                      }.contains(e.toString().replaceFirst('Exception: ', '').trim())) {
                        ToastService.show('Incorrect password!');
                      } else {
                        ToastService.show('Failed to recover the export');
                        logE(e, stackTrace: s);
                      }
                    } finally {
                      stopLoader();
                    }
                  }
                },
                child: const Text('Import'),
              ),
            ],
          ),
        );
        if (res is bool && res) {
          return true;
        }
      }
    } catch (e, s) {
      logE(e, stackTrace: s);
      ToastService.show('Something went wrong while importing app data!');
    }
    return false;
  }
}

extension HiveExtension on HiveInterface {
  Future<void> initFlutter(String subDir) async {
    WidgetsFlutterBinding.ensureInitialized();

    if (kIsWeb) {
      return;
    }

    final appDir = await getApplicationSupportDirectory();
    init(path.join(appDir.path, subDir));
  }
}

/// [E] is key type and [T] is object type
class BoxAccessor<E, T> {
  BoxAccessor(this.box);

  final Box<T> box;

  T? operator [](String key) => box.get(key);

  Iterable<E> get keys => box.keys.cast<E>();

  Iterable<T> get values => box.values;

  Map<dynamic, T> get toMap => box.toMap();

  int get length => box.length;

  bool get isEmpty => box.isEmpty;

  bool get isNotEmpty => box.isNotEmpty;

  bool contains(String key) => box.containsKey(key);
}

/// returns true if data is migrated successfully, null if no migration happend.
Future<bool?> migrateDB() async {
  WidgetsFlutterBinding.ensureInitialized();

  final migrationVersion = AppState.prefs.getInt('migration');
  if (migrationVersion == null || migrationVersion >= 4) {
    await AppState.prefs.setInt('migration', 4);
    return null;
  }

  Future<Directory?> getDbDir() async {
    if (kIsWeb) return null;
    final appDir = await getApplicationSupportDirectory();
    return Directory(path.join(appDir.path, 'manna_data/db'));
  }

  // return error message
  Future<String?> backupDBFilesZip() async {
    final dbDir = await getDbDir();
    if (dbDir == null || !dbDir.existsSync()) return 'Migration failed: Missing database path';
    try {
      final backUpFile = File(path.join(dbDir.path, 'db_backup.zip'));
      if (!backUpFile.existsSync()) await backUpFile.create(recursive: true);

      final archive = Archive();
      for (final entity in dbDir.listSync()) {
        if (entity is File && (entity.path.endsWith('.hive') || entity.path.endsWith('.lock'))) {
          final bytes = await entity.readAsBytes();
          archive.addFile(ArchiveFile(path.basename(entity.path), bytes.length, bytes));
        }
      }
      await backUpFile.writeAsBytes(ZipEncoder().encode(archive));
      return null;
    } catch (e) {
      return 'Failed to create backup: $e';
    }
  }

  Future<void> rollbackDB() async {
    try {
      final dbDir = await getDbDir();
      if (dbDir == null) return;

      final backUpFile = File(path.join(dbDir.path, 'db_backup.zip'));
      if (backUpFile.existsSync()) {
        final bytes = await backUpFile.readAsBytes();
        final archive = ZipDecoder().decodeBytes(bytes);

        for (final file in archive) {
          if (file.isFile) {
            final data = file.content as List<int>;
            File(path.join(dbDir.path, file.name))
              ..createSync(recursive: true)
              ..writeAsBytesSync(data);
          }
        }
      }
    } catch (e, s) {
      logE(e, stackTrace: s);
    }
  }

  final dbDir = await getDbDir();
  if (dbDir == null || !dbDir.existsSync()) return null;

  final dbPass = await SecureStorage.fetch('dbPass');
  if (dbPass == null || dbPass.length != 32) {
    ToastService.show('Migration failed : Missing database encryption password!');
    return null;
  }

  try {
    final err = await backupDBFilesZip();
    if (err != null) {
      ToastService.show(err);
      return null;
    }

    if (AppState.prefs.containsKey('isFirstBoot') && !(AppState.prefs.getBool('isMigratedToSpark') ?? false)) {
      await Hive.initFlutter('manna_data/db');

      // delete old tables
      for (final boxToDelete in ['wowallets', 'transactions', 'swaps', 'bolt12Offers', 'settingHistoryCache']) {
        await Hive.deleteBoxFromDisk(boxToDelete);
      }

      registerV2Adapters(force: true);
      Hive.registerAdapter(AccountV1Adapter(), override: true);
      Hive.registerAdapter(WalletV1Adapter(), override: true);

      final oldAccounts = (await Hive.openBox<Account>(
        'accounts',
        encryptionCipher: HiveAesCipher(dbPass),
      )).values.toList();
      final oldWallets = (await Hive.openBox<Wallet>(
        'wallets',
        encryptionCipher: HiveAesCipher(dbPass),
      )).values.toList();

      await Hive.close();
      await Hive.deleteBoxFromDisk('accounts');
      await Hive.deleteBoxFromDisk('wallets');

      registerV2Adapters(force: true);

      await (await Hive.openBox<Account>(
        'accounts',
        encryptionCipher: HiveAesCipher(dbPass),
      )).putAll(Map.fromEntries(oldAccounts.map((e) => MapEntry(e.id, e))));
      await (await Hive.openBox<Wallet>(
        'wallets',
        encryptionCipher: HiveAesCipher(dbPass),
      )).putAll(Map.fromEntries(oldWallets.map((e) => MapEntry(e.uuid, e))));

      await Hive.close();
      await AppState.prefs.setBool('isMigratedToSpark', true);
      await AppState.prefs.setInt('migration', 4);
    }
  } catch (e, s) {
    logE(e, stackTrace: s, showToast: true);
    await rollbackDB();
    return false;
  }
  return true;
}

class AccountV1Adapter extends TypeAdapter<Account> {
  @override
  final typeId = 1;

  @override
  Account read(BinaryReader reader) {
    final id = reader.readString();
    final name = reader.readString();
    final createdAtUTC = reader.read() as DateTime;
    final isMainAccount = reader.readBool();
    final isDisabled = reader.readBool();
    final isBackedUp = reader.readBool();
    final isSendAnonymously = reader.readBool();
    final isSendNotification = reader.readBool();
    final sortOrder = reader.readInt();
    final chatKeyPair = reader.read() as KeyPair?;
    final nsec = reader.read() as String?;
    return Account(
      id: id,
      name: name,
      createdAtUTC: createdAtUTC,
      isMainAccount: isMainAccount,
      isDisabled: isDisabled,
      isBackedUp: isBackedUp,
      isSendAnonymously: isSendAnonymously,
      sortOrder: sortOrder,
      chatKeyPair: chatKeyPair,
      nsec: nsec,
    );
  }

  @override
  void write(BinaryWriter writer, Account obj) {}
}

class WalletV1Adapter extends TypeAdapter<Wallet> {
  @override
  final typeId = 2;

  @override
  Wallet read(BinaryReader reader) {
    final accountId = reader.readString();
    final descriptor = reader.readString();
    final xpub = reader.readString();
    final network = Network.values[reader.readInt()];
    final type = WalletType.values[reader.readInt()];
    final balance = reader.readInt();
    final isCorrupted = reader.readBool();
    return Wallet(accountId: accountId, xpub: xpub, network: network, type: type, balance: balance);
  }

  @override
  void write(BinaryWriter writer, Wallet obj) {}
}
