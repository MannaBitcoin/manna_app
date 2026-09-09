import 'dart:convert';

import 'package:manna/models/wallet.dart';
import 'package:manna/services/db.dart';
import 'package:manna/services/nostr_service.dart';
import 'package:manna/services/secure_storage.dart';
import 'package:manna/utils/parser.dart';
import 'package:manna/utils/toast_service.dart';
import 'package:manna_core/manna_core.dart' as c;

import 'misc.dart';

String? _selectedAccountId;
String get selectedAccountId => _selectedAccountId!;
Account get selectedAccount {
  final acc = DB.activeAccounts.where((a) => a.id == _selectedAccountId).firstOrNull ?? selectAccount();
  if (acc != null) return acc;

  throw Exception('No Accounts, but called selectAccount');
}

Account? selectAccount([String? id]) {
  final acc =
      DB.activeAccounts.where((a) => id != null ? id == a.id : a.isMainAccount).firstOrNull ??
      DB.activeAccounts.where((a) => !a.isDisabled).firstOrNull;

  _selectedAccountId = acc?.id;
  return acc;
}

Wallet get selectedWallet {
  final currentWallets = DB.currentWallets;

  Wallet? wallet;
  wallet = currentWallets.where((w) => w.accountId == _selectedAccountId).firstOrNull;
  if (wallet == null) {
    selectAccount();
    wallet = currentWallets.where((w) => w.accountId == _selectedAccountId).firstOrNull;
  }
  if (wallet != null) return wallet;

  throw Exception('No Accounts, but called selectWallet');
}

class Account {
  Account({
    required this.id,
    required this.name,
    required this.createdAtUTC,
    required this.isMainAccount,
    required this.isDisabled,
    required this.isBackedUp,
    required this.isSendAnonymously,
    required this.isSendNotification,
    required this.sortOrder,
    String? mnemonicSentence,
    this.chatKeyPair,
    this.nsec,
  }) {
    if (mnemonicSentence != null) {
      SecureStorage.store('acc-$id', utf8.encode(mnemonicSentence), useSecureEnclave: true);
    }
  }

  static Future<Account> fromMap(Map<String, dynamic> map) async {
    final mnemonicSentence = parseStringN(map['mnemonicSentence']);
    c.Mnemonics? mnemonics;
    if (mnemonicSentence != null) {
      mnemonics = await c.Mnemonics.newInstance(mnemonic: mnemonicSentence);
    }
    return Account(
      id: parseString(map['id']),
      name: parseString(map['name']),
      createdAtUTC: parseDateTime(map['createdAt']),
      isMainAccount: parseBool(map['isMainAccount']),
      isDisabled: parseBool(map['isDisabled']),
      isBackedUp: parseBool(map['isBackedUp']),
      isSendAnonymously: parseBool(map['isSendAnonymously']),
      isSendNotification: parseBool(map['isSendNotification']),
      sortOrder: parseInt(map['sortOrder']),
      mnemonicSentence: mnemonics?.sentence,
      chatKeyPair: mnemonics == null ? null : await Account.generateChatKeyPair(mnemonics),
      nsec: mnemonics == null ? null : await NostrService.generateNsecFromSeed(mnemonics.seedBytes),
    );
  }

  final String id;
  String name;
  final DateTime createdAtUTC;
  bool isMainAccount;
  bool isDisabled;
  bool isBackedUp;
  bool isSendAnonymously;
  bool isSendNotification;
  int sortOrder;

  // only for accounts with mnemonic, not for watch only wallets
  c.KeyPair? chatKeyPair;
  String? nsec;

  Future<bool> get hasMnemonic => SecureStorage.exists('acc-$id', useSecureEnclave: true);

  Wallet get currentWallet {
    final w = DB.currentWallets.where((e) => e.accountId == id).firstOrNull;
    if (w == null) {
      ToastService.show('Missing wallet');
      throw 'Missing wallet';
    }
    return w;
  }

  Future<String?> getMnemonicSentence() async {
    final utf8Bytes = await SecureStorage.fetch('acc-$id', useSecureEnclave: true);
    if (utf8Bytes == null) return null;
    return utf8.decode(utf8Bytes);
  }

  Future<void> update({
    String? name,
    bool? isMainAccount,
    bool? isDisabled,
    bool? isBackedUp,
    bool? isSendAnonymously,
    bool? isSendNotification,
    int? sortOrder,
  }) {
    this.name = name ?? this.name;
    this.isMainAccount = isMainAccount ?? this.isMainAccount;
    this.isDisabled = isDisabled ?? this.isDisabled;
    this.isBackedUp = isBackedUp ?? this.isBackedUp;
    this.isSendAnonymously = isSendAnonymously ?? this.isSendAnonymously;
    this.isSendNotification = isSendNotification ?? this.isSendNotification;
    this.sortOrder = sortOrder ?? this.sortOrder;
    return save();
  }

  Future<void> save() => DB.accounts.box.put(id, this);

  Future<void> delete() async {
    await SecureStorage.delete('acc-$id', useSecureEnclave: true);
    await DB.walletBox.deleteAll(DB.fullWallets.values.where((w) => w.accountId == id).map((e) => e.uuid));
    await DB.woWalletBox.deleteAll(DB.woWallets.values.where((w) => w.accountId == id).map((e) => e.uuid));
    await DB.accounts.box.delete(id);
  }

  Map<String, dynamic> toMap() => {
    'id': id,
    'name': name,
    'createdAt': createdAtUTC,
    'isMainAccount': isMainAccount,
    'isDisabled': isDisabled,
    'isBackedUp': isBackedUp,
    'isSendAnonymously': isSendAnonymously,
    'isSendNotification': isSendNotification,
    'sortOrder': sortOrder,
  };

  @override
  String toString() => jsonEncode(toMap().toEncodeReady());

  static Future<c.KeyPair> generateChatKeyPair(c.Mnemonics mnemonics) async {
    final derivedSeed = await c.Crypto.deriveHkdf(seed: mnemonics.seedBytes, info: 'wallet-chat-v2');
    return c.Crypto.generateX25519KeyPair(privateKeyBytes: derivedSeed);
  }
}
