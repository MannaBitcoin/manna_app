import 'dart:async';
import 'dart:convert';
import 'package:manna/models/account.dart';
import 'package:manna/services/secure_storage.dart';
import 'package:manna/services/wallet_service.dart';
import 'package:manna/utils/parser.dart';
import 'package:manna_core/manna_core.dart';
import 'package:manna/services/db.dart';
import 'package:manna_core/manna_core.dart' as core;
import 'package:uuid/v5.dart';

export 'enums.dart';
import 'misc.dart';

// Data from supabase database
class WalletMetaData {
  WalletMetaData({
    required this.uuid,
    required this.swapIndex,
    required this.useTrustedLNURL,
    required this.userName,
    required this.bolt11ShortDesc,
    required this.about,
    required this.picture,
    required this.banner,
  });

  factory WalletMetaData.fromMap(Map<String, dynamic> map) => WalletMetaData(
    uuid: parseString(map['uuid']),
    swapIndex: parseIntN(map['swap_index']) ?? 0,
    useTrustedLNURL: parseBool(map['use_trusted_lnurl']),
    userName: parseString(map['user_name']),
    bolt11ShortDesc: parseString(map['bolt11_short_desc']),
    about: parseStringN(map['about']),
    picture: parseStringN(map['picture']),
    banner: parseStringN(map['banner']),
  );

  factory WalletMetaData.fromMapWO(Map<String, dynamic> map) => WalletMetaData(
    uuid: parseString(map['uuid']),
    swapIndex: parseList(map['wo_swap_index'], (e) => parseInt(e['swap_index'])).firstOrNull ?? 0,
    useTrustedLNURL: parseBool(map['use_trusted_lnurl']),
    userName: parseString(map['user_name']),
    bolt11ShortDesc: parseString(map['bolt11_short_desc']),
    about: parseStringN(map['about']),
    picture: parseStringN(map['picture']),
    banner: parseStringN(map['banner']),
  );

  final String uuid;
  final int swapIndex;
  final bool useTrustedLNURL;
  final String userName;
  final String bolt11ShortDesc;
  final String? about;
  final String? picture;
  final String? banner;

  Map<String, dynamic> toMap() => {
    'uuid': uuid,
    'swapIndex': swapIndex,
    'useTrustedLNURL': useTrustedLNURL,
    'userName': userName,
    'bolt11ShortDesc': bolt11ShortDesc,
    'about': about,
    'picture': picture,
    'banner': banner,
  };
}

/// String(UUID_walletType): [WalletMetaData]
final Map<String, WalletMetaData> walletDataMap = {};

class Wallet {
  Wallet({
    required this.accountId,
    required this.descriptor,
    required this.xpub,
    required this.network,
    required this.type,
    this.balance = 0,
    this.isCorrupted = false,
  }) : uuid = Wallet.generateUuid(xpub: xpub);

  factory Wallet.fromMap(Map<String, dynamic> map) {
    return Wallet(
      accountId: parseString(map['accountId']),
      descriptor: parseString(map['descriptor']),
      xpub: parseString(map['xpub']),
      network: Network.values[parseInt(map['network'])],
      type: WalletType.values[parseInt(map['walletType'])],
      balance: parseIntN(map['balance']) ?? 0,
      isCorrupted: parseBool(map['isCorrupted']),
    );
  }

  /// [swapMnemonic] deterministic in case of full wallet, random otherwise, used to generate swap keys and preimage deterministically
  Future<void> initSwapMnemonic(String? swapMnemonic) async {
    if (!await SecureStorage.exists('swapMnemonic_${uuid}_${type.index}', useSecureEnclave: true)) {
      final mnemonicToSave =
          swapMnemonic ??
          // (BIP85 different mnemonic derived from wallet mnemonic used for boltz swap)
          (await MasterSwapKey.fromWalletMnemonic(
            walletMnemonic: (await core.Mnemonics.generate()).sentence,
            network: network,
          )).toMnemonicString();
      await SecureStorage.store(
        'swapMnemonic_${uuid}_${type.index}',
        utf8.encode(mnemonicToSave),
        useSecureEnclave: true,
      );
    }
  }

  final String accountId;
  final String uuid;
  final String descriptor;
  final String xpub;
  final Network network;
  final WalletType type;
  int balance;
  bool isCorrupted;

  Future<String> getSwapMnemonic() async {
    final cache = _swapMnemonicCache['${uuid}_${type.index}'];
    if (cache != null) return cache;

    final utf8Bytes = await SecureStorage.fetch('swapMnemonic_${uuid}_${type.index}', useSecureEnclave: true);
    if (utf8Bytes == null || utf8Bytes.isEmpty) {
      throw Exception('Failed to fetch swap mnemonics!');
    }
    final mnemonic = utf8.decode(utf8Bytes);
    _swapMnemonicCache['${uuid}_${type.index}'] = mnemonic;
    return mnemonic;
  }

  Future<LiquidWallet> getLiquidWallet() async =>
      LiquidWallet(uuid: uuid, walletType: type, descriptor: descriptor, swapMnemonic: await getSwapMnemonic());

  Account get account {
    final account = DB.accounts[accountId];
    if (account != null) return account;

    throw Exception('How did we get here?');
  }

  WalletMetaData? get metaData => walletDataMap['${uuid}_${type.name}'];

  core.Wallet? get liquidWollet => WalletService.liquidNodes[xpub];

  Future<String?> getConfidentialAddress({int? index}) async {
    if (liquidWollet == null) return null;
    if (index != null) {
      return (await liquidWollet!.address(index: index)).confidential;
    }
    return (await liquidWollet!.addressLastUnused()).confidential;
  }

  Future<void> update({bool? isCorrupted, int? balance}) {
    this.balance = balance ?? this.balance;
    this.isCorrupted = isCorrupted ?? this.isCorrupted;
    return save();
  }

  Future<void> save() async {
    if (type == WalletType.full) {
      await DB.walletBox.put(uuid, this);
    } else {
      await DB.woWalletBox.put(uuid, this);
    }
    DB.loadWallets();
  }

  Future<void> delete() async {
    if (type == WalletType.full) {
      await DB.walletBox.delete(uuid);
    } else {
      await DB.woWalletBox.delete(uuid);
    }
    DB.loadWallets();
  }

  String get contactWalletId => Wallet.generateContactWalletId(xpub: xpub, type: type);

  Map<String, dynamic> toMap() => {
    'accountId': accountId,
    'uuid': uuid,
    'descriptor': descriptor,
    'xpub': xpub,
    'network': network.index,
    'walletType': type.index,
    'balance': balance,
    'isCorrupted': isCorrupted,
  }.toEncodeReady();

  @override
  String toString() => jsonEncode(toMap());

  static String generateUuid({required String xpub}) =>
      const UuidV5().generate('d8a36b29-21dc-4caa-a004-163606cdfe70', xpub);

  static String generateContactWalletId({required String xpub, required WalletType type}) =>
      const UuidV5().generate('d8a36b29-21dc-4caa-a004-163606cdfe70', '${xpub}_$type');

  @override
  bool operator ==(Object other) => other is Wallet && other.uuid == uuid && other.type == type;

  @override
  int get hashCode => Object.hash(uuid, type);
}

// walletId_walletTypeIndex : swap mnemonic
final Map<String, String> _swapMnemonicCache = {};
