import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';
import 'package:convert/convert.dart';
import 'package:manna/models/wallet.dart';
import 'package:manna/services/db.dart';
import 'package:manna/services/db_service.dart';
import 'package:manna/services/log_service.dart';
import 'package:manna/services/transaction_service.dart';
import 'package:manna/utils/extensions.dart';
import 'package:manna/utils/parser.dart';
import 'package:manna/utils/util.dart';
import 'package:manna_core/manna_core.dart' hide Wallet;

import 'misc.dart';

extension SwapExtension on Swap {
  Wallet? get wallet => DB.allWallets.where((w) => w.uuid == walletId && w.type == walletType).firstOrNull;

  static Future<Swap?> fromSupabaseRow(Map<String, dynamic> row, Network network) async {
    try {
      final walletId = parseString(row['wallet_id']);
      final wallet = DB.fullWallets[walletId] ?? DB.woWallets[walletId];
      if (wallet == null) return null;

      final masterKey = (await Crypto.getSwapEncryptionKey(swapMnemonic: await wallet.getSwapMnemonic()))?.secretKey;
      if (masterKey == null) return null;

      final index = parseInt(row['index']);

      final swapData = parseString(row['swap_data']).byteaToUint8List;
      if (swapData == null) return null;

      final aesKey = wallet.type == WalletType.watchOnly
          ? parseString(row['wrapped_k_wo']).byteaToUint8List
          : parseString(row['wrapped_k_main']).byteaToUint8List;

      // mark as sync, the swap is created by main wallet, no need to cache it on watch only wallet
      final swapId = parseString(row['id']);
      if (swapId.isNotEmpty && wallet.type == WalletType.watchOnly && row['wrapped_k_wo'] == null) {
        await DB.setSyncedSwapIds({...DB.getSyncedSwapIds(), swapId}.toList());
      }

      if (aesKey == null) return null;

      final decryptionKey = await Crypto.decryptEcies(privKey: U8Array32(masterKey), payload: aesKey);

      final rawSwapData = utf8.decode(
        await Crypto.aesDecrypt(key: U8Array32(decryptionKey), payload: swapData, aad: 'swap_v1-$index'),
      );
      return fromMap(jsonDecode(rawSwapData));
    } catch (e, s) {
      logE(e, stackTrace: s);
    }
    return null;
  }

  static Future<Swap> fromMap(Map map) async {
    final wallets = DB.allWallets.where((w) => w.uuid == parseString(map['walletId']));
    final wallet =
        wallets.where((w) => w.type == WalletType.watchOnly).firstOrNull ??
        wallets.where((w) => w.type == WalletType.full).firstOrNull;

    if (wallet == null) {
      throw Exception('Invalid swap data');
    }
    return Swap(
      id: parseString(map['id']),
      index: parseInt(map['index']),
      walletId: wallet.uuid,
      walletType: wallet.type,
      network: Network.values.where((e) => e.name == parseString(map['network'])).firstOrNull ?? Network.mainnet,
      sendAmount: parseBigInt(map['sendAmount']),
      receiveAmount: parseBigInt(map['receiveAmount']),
      preimage: PreimageExtension.fromMap(map['preimage']),
      creationTime: parseBigInt(map['creationTime']),
      completionTime: parseBigIntN(map['completionTime']),
      submarine: map['submarine'] is Map ? SubmarineExtension.fromMap(map['submarine']) : null,
      reverse: map['reverse'] is Map ? ReverseExtension.fromMap(map['reverse']) : null,
      chain: map['chain'] is Map ? ChainExtension.fromMap(map['chain']) : null,
      swapStatus: parseString(map['swapStatus']),
      failureReason: parseStringN(map['failureReason']),
      note: parseStringN(map['note']),
      boltzFee: parseBigIntN(map['boltzFee']),
      lockupFee: parseBigIntN(map['lockUpFee']),
      claimFee: parseBigIntN(map['claimFee']),
      refundedAddress: parseStringN(map['refundedAddress']),
      refundFee: parseBigIntN(map['refundFee']),
      transactions: parseList(jsonDecode(map['transactions']), (e) => SwapTransactionExtension.fromMap(e)),
      isExchangeSwap: parseBool(map['isExchangeSwap']),
    );
  }

  static Future<Swap> fromSerdeJson(String json) async {
    final swap = Swap.fromJson(json: json);
    final wallets = DB.allWallets.where((w) => w.uuid == swap.walletId);
    final wallet =
        wallets.where((w) => w.type == WalletType.watchOnly).firstOrNull ??
        wallets.where((w) => w.type == WalletType.full).firstOrNull;

    if (wallet == null) {
      throw Exception('Invalid swap data');
    }
    return swap.copyWith(wallet: wallet);
  }

  Swap copyWith({Wallet? wallet}) => Swap(
    id: id,
    index: index,
    walletId: wallet?.uuid ?? walletId,
    walletType: wallet?.type ?? walletType,
    network: network,
    preimage: preimage,
    sendAmount: sendAmount,
    receiveAmount: receiveAmount,
    creationTime: creationTime,
    swapStatus: swapStatus,
    transactions: transactions,
    submarine: submarine,
    reverse: reverse,
    chain: chain,
    note: note,
    failureReason: failureReason,
    completionTime: completionTime,
    lockupFee: lockupFee,
    boltzFee: boltzFee,
    claimFee: claimFee,
    refundFee: refundFee,
    refundedAddress: refundedAddress,
    isExchangeSwap: isExchangeSwap,
  );

  Map<String, dynamic> toMap() => {
    'id': id,
    'index': index,
    'walletId': walletId,
    'walletType': walletType.index,
    'network': network.name,
    'sendAmount': sendAmount,
    'receiveAmount': receiveAmount,
    'preimage': preimage.toMap(),
    'creationTime': creationTime,
    'completionTime': completionTime,
    if (submarine != null) 'submarine': submarine!.toMap(),
    if (reverse != null) 'reverse': reverse!.toMap(),
    if (chain != null) 'chain': chain!.toMap(),
    'swapStatus': swapStatus,
    'failureReason': failureReason,
    'note': note,
    'boltzFee': boltzFee,
    'lockUpFee': lockupFee,
    'claimFee': claimFee,
    'refundedAddress': refundedAddress,
    'refundFee': refundFee,
    'transactions': jsonEncode(transactions.map((e) => e.toMap()).toList()),
    'isExchangeSwap': isExchangeSwap,
  }.toEncodeReady();

  SwapType get swapType => submarine != null
      ? SwapType.submarine
      : chain != null
      ? SwapType.chain
      : SwapType.reverse;

  DateTime get creationTimeUTC => DateTime.fromMillisecondsSinceEpoch(creationTime.i);
  DateTime? get completionTimeUTC =>
      completionTime != null ? DateTime.fromMillisecondsSinceEpoch(completionTime!.i) : null;

  String? getDuration() {
    if (completionTimeUTC == null) return null;
    final diff = completionTimeUTC!.difference(creationTimeUTC).abs();
    final minutes = diff.inMinutes;
    if (minutes == 0) {
      final seconds = diff.inSeconds;
      return '$seconds seconds';
    } else if (minutes > 60) {
      final hours = diff.inHours;
      return '$hours hours';
    } else {
      return '$minutes minutes';
    }
  }

  int get expectedNoTransaction => swapType == SwapType.chain ? 4 : 2;
  // if there is lockup there has to be either claim or refund
  bool get isMissingTransaction =>
      transactions.where((e) => e.txType == SwapTransactionType.lockup).length !=
      transactions.where((e) => e.txType != SwapTransactionType.lockup).length;

  TraType get getTransactionType => switch (swapType) {
    SwapType.submarine => TraType.lbtcToLN,
    SwapType.reverse => TraType.lnToLbtc,
    SwapType.chain => chain?.direction == ChainSwapDirection.btcToLbtc ? TraType.btcToLbtc : TraType.lbtcToBtc,
  };

  int get boltzNetworkFee => switch (swapType) {
    SwapType.submarine => claimFee?.i ?? 0,
    SwapType.reverse => lockupFee?.i ?? 0,
    SwapType.chain =>
      chain?.direction == ChainSwapDirection.btcToLbtc ? (lockupFee?.i ?? 0) : (claimFee?.i ?? 0) + (lockupFee?.i ?? 0),
  };

  bool get isIncoming => reverse != null || chain?.direction == ChainSwapDirection.btcToLbtc;
  bool get isClosed => completionTime != null;

  bool get isLockedUp => transactions.any((tx) => tx.txType == SwapTransactionType.lockup);
  bool get isClaimed => transactions.any((tx) => tx.txType == SwapTransactionType.claim);
  bool get isRefunded => transactions.any((tx) => tx.txType == SwapTransactionType.refund);
  bool get isMannaLockedUp => transactions.any((tx) => tx.isUser && tx.txType == SwapTransactionType.lockup);
  bool get isMannaClaimed => transactions.any((tx) => tx.isUser && tx.txType == SwapTransactionType.claim);

  bool get isChainQuoteAvailable =>
      chain != null &&
      swapStatus.toChainStatus != ChainSwapStatus.swapRefunded &&
      swapStatus.toChainStatus == ChainSwapStatus.transactionLockupFailed &&
      failureReason != null &&
      failureReason!.contains('locked') &&
      failureReason!.contains('expected') &&
      isLockedUp &&
      !isClaimed;

  bool get isChainRefundable => chain != null && isLockedUp && !(isClaimed || isRefunded);

  Future<void> save() => DB.swaps.box.put(id, this);

  Future<void> delete() async {
    await DB.swaps.box.delete(id);
    final existingIds = DB.getSyncedSwapIds();
    existingIds.remove(id);
    await DB.setSyncedSwapIds(existingIds);
  }

  Future<Map<String, dynamic>?> encryptForSupabase() async {
    try {
      final wallet = DB.woWallets[walletId] ?? DB.fullWallets[walletId];
      if (wallet == null) return null;

      final swapMnemonic = await wallet.getSwapMnemonic();
      final swapEncKeyPair = await Crypto.getSwapEncryptionKey(swapMnemonic: swapMnemonic);
      if (swapEncKeyPair == null) return null;

      final symKey = randomByteSlice(32);
      final cipher = await Crypto.aesEncrypt(
        key: U8Array32(symKey),
        plaintext: utf8.encode(jsonEncode(toMap())),
        aad: 'swap_v1-$index',
      );

      Uint8List? encryptedMainKey, encryptedWoKey;

      if (wallet.type == WalletType.watchOnly) {
        encryptedWoKey = await Crypto.encryptEcies(pubKey: swapEncKeyPair.publicKey, payload: symKey);
        final mainWalletKey = await DbService.getWalletSwapEncryptionKey(walletId);
        if (mainWalletKey != null) {
          encryptedMainKey = await Crypto.encryptEcies(pubKey: hex.decode(mainWalletKey), payload: symKey);
        }
      } else {
        encryptedMainKey = await Crypto.encryptEcies(pubKey: swapEncKeyPair.publicKey, payload: symKey);
      }

      return {
        'id': id,
        'index': index,
        'wallet_id': walletId,
        'swap_data': cipher.toBytea,
        if (encryptedMainKey != null) 'wrapped_k_main': encryptedMainKey.toBytea,
        if (encryptedWoKey != null) 'wrapped_k_wo': encryptedWoKey.toBytea,
        'created_at': DateTime.fromMillisecondsSinceEpoch(creationTime.i),
      }.toEncodeReady();
    } catch (e, s) {
      logE(e, stackTrace: s);
    }
    return null;
  }
}

extension LNURLPoolEntryExtension on LnurlPoolEntry {
  Map<String, dynamic>? toUploadMap() => address == null
      ? null
      : {
          'i': index,
          'addr': {'i': address!.index, 'a': address!.address, 's': address!.signature},
          'pih': preimage.sha256,
          'cpk': base64Encode(claimKey.publicKey),
        }.toEncodeReady();
}

extension SwapTransactionExtension on SwapTransaction {
  Map<String, dynamic> toMap() => {'txId': txId, 'chain': chain.name, 'type': txType.name, 'isUser': isUser};

  static SwapTransaction fromMap(Map<String, dynamic> map) => SwapTransaction(
    txId: parseString(map['txId']),
    chain: parseEnum(Map.fromEntries(Chain.values.map((e) => MapEntry(e, e.name))), parseString(map['chain'])),
    txType: parseEnum(
      Map.fromEntries(SwapTransactionType.values.map((e) => MapEntry(e, e.name))),
      parseString(map['type']),
    ),
    isUser: parseBool(map['isUser']),
  );
}

extension ExtraSwapFeeExtension on ExtraSwapFee {
  Map<String, dynamic> toMap() => {'id': id, 'percentage': percentage};

  static ExtraSwapFee fromMap(Map<String, dynamic> map) =>
      ExtraSwapFee(id: parseString(map['id']), percentage: parseDouble(map['percentage']));
}

extension PreimageExtension on PreImage {
  Map<String, dynamic> toMap() => {'value': value, 'sha256': sha256, 'hash160': hash160};

  static PreImage fromMap(Map<String, dynamic> map) => PreImage(
    value: parseString(map['value']),
    sha256: parseString(map['sha256']),
    hash160: parseString(map['hash160']),
  );
}

extension KeyPairExtension on KeyPair {
  Map<String, dynamic> toMap() => {'publicKey': publicKey.toHexString, 'secretKey': secretKey.toHexString};

  static KeyPair fromMap(Map<String, dynamic> map) {
    return KeyPair(
      publicKey: parseString(map['publicKey']).hexStringToBytes,
      secretKey: parseString(map['secretKey']).hexStringToBytes,
    );
  }
}

extension SwapTreeExtension on SwapTreeData {
  Map<String, dynamic> toMap() => {'claimLeaf': claimLeaf.toMap(), 'refundLeaf': refundLeaf.toMap()};

  static SwapTreeData fromMap(Map<String, dynamic> map) => SwapTreeData(
    claimLeaf: LeafExtension.fromMap(map['claimLeaf'] ?? {}),
    refundLeaf: LeafExtension.fromMap(map['refundLeaf'] ?? {}),
  );
}

extension LeafExtension on LeafData {
  Map<String, dynamic> toMap() => {'output': output, 'version': version};

  static LeafData fromMap(Map<String, dynamic> map) =>
      LeafData(output: parseString(map['output']), version: parseInt(map['version']));
}

extension SubmarineExtension on SubmarineSwap {
  Map<String, dynamic> toMap() => {
    'from': from.name,
    'keys': keys.toMap(),
    'invoice': invoice,
    'swapCreateRes': swapCreateRes.toMap(),
  };

  static SubmarineSwap fromMap(Map<dynamic, dynamic> map) => SubmarineSwap(
    from: parseEnum(Map.fromEntries(Chain.values.map((e) => MapEntry(e, e.name))), parseString(map['from'])),
    keys: KeyPairExtension.fromMap(map['keys'] ?? {}),
    invoice: parseString(map['invoice']),
    swapCreateRes: SubmarineResponseExtension.fromMap(map['swapCreateRes']),
  );
}

extension SubmarineResponseExtension on SubmarineResponse {
  Map<String, dynamic> toMap() => {
    'acceptZeroConf': acceptZeroConf,
    'address': address,
    'bip21': bip21,
    'claimPublicKey': claimPublicKey,
    'expectedAmount': expectedAmount,
    'swapTree': swapTree.toMap(),
    'timeoutBlockHeight': timeoutBlockHeight,
    'blindingKey': blindingKey,
  };

  static SubmarineResponse fromMap(Map<String, dynamic> map) => SubmarineResponse(
    acceptZeroConf: parseBool(map['acceptZeroConf']),
    address: parseString(map['address']),
    bip21: parseString(map['bip21']),
    claimPublicKey: parseString(map['claimPublicKey']),
    expectedAmount: parseBigInt(map['expectedAmount']),
    swapTree: SwapTreeExtension.fromMap(map['swapTree'] ?? {}),
    timeoutBlockHeight: parseBigInt(map['timeoutBlockHeight']),
    blindingKey: parseStringN(map['blindingKey']),
  );
}

extension ReverseExtension on ReverseSwap {
  Map<String, dynamic> toMap() => {'to': to.name, 'keys': keys.toMap(), 'swapCreateRes': swapCreateRes.toMap()};

  static ReverseSwap fromMap(Map<dynamic, dynamic> map) => ReverseSwap(
    to: parseEnum(Map.fromEntries(Chain.values.map((e) => MapEntry(e, e.name))), parseString(map['to'])),
    keys: KeyPairExtension.fromMap(map['keys'] ?? {}),
    swapCreateRes: ReverseResponseExtension.fromMap(map['swapCreateRes']),
  );
}

extension ReverseResponseExtension on ReverseResponse {
  Map<String, dynamic> toMap() => {
    'invoice': invoice,
    'lockupAddress': lockupAddress,
    'refundPublicKey': refundPublicKey,
    'onchainAmount': onchainAmount,
    'swapTree': swapTree.toMap(),
    'timeoutBlockHeight': timeoutBlockHeight,
    'blindingKey': blindingKey,
  };

  static ReverseResponse fromMap(Map<String, dynamic> map) => ReverseResponse(
    invoice: parseStringN(map['invoice']),
    lockupAddress: parseString(map['lockupAddress']),
    refundPublicKey: parseString(map['refundPublicKey']),
    onchainAmount: parseBigInt(map['onchainAmount']),
    swapTree: SwapTreeExtension.fromMap(map['swapTree'] ?? {}),
    timeoutBlockHeight: parseInt(map['timeoutBlockHeight']),
    blindingKey: parseStringN(map['blindingKey']),
  );
}

extension ChainExtension on ChainSwap {
  Map<String, dynamic> toMap() => {
    'direction': direction.name,
    'refundKeys': refundKeys.toMap(),
    'claimKeys': claimKeys.toMap(),
    'lockupDetails': lockupDetails.toMap(),
    'claimDetails': claimDetails.toMap(),
  };

  static ChainSwap fromMap(Map<dynamic, dynamic> map) => ChainSwap(
    direction: parseEnum(
      Map.fromEntries(ChainSwapDirection.values.map((e) => MapEntry(e, e.name))),
      parseString(map['direction']),
    ),
    refundKeys: KeyPairExtension.fromMap(map['refundKeys'] ?? {}),
    claimKeys: KeyPairExtension.fromMap(map['claimKeys'] ?? {}),
    lockupDetails: ChainSwapDataExtension.fromMap(map['lockupDetails'] ?? {}),
    claimDetails: ChainSwapDataExtension.fromMap(map['claimDetails'] ?? {}),
  );
}

extension ChainSwapDataExtension on ChainSwapData {
  Map<String, dynamic> toMap() => {
    'swapTree': swapTree.toMap(),
    'lockupAddress': lockupAddress,
    'serverPublicKey': serverPublicKey,
    'timeoutBlockHeight': timeoutBlockHeight,
    'amount': amount,
    'blindingKey': blindingKey,
    'refundAddress': refundAddress,
    'claimAddress': claimAddress,
    'bip21': bip21,
  };

  static ChainSwapData fromMap(Map<String, dynamic> map) => ChainSwapData(
    swapTree: SwapTreeExtension.fromMap(map['swapTree'] ?? {}),
    lockupAddress: parseString(map['lockupAddress']),
    serverPublicKey: parseString(map['serverPublicKey']),
    timeoutBlockHeight: parseInt(map['timeoutBlockHeight']),
    amount: parseBigInt(map['amount']),
    blindingKey: parseStringN(map['blindingKey']),
    refundAddress: parseStringN(map['refundAddress']),
    claimAddress: parseStringN(map['claimAddress']),
    bip21: parseStringN(map['bip21']),
  );
}
