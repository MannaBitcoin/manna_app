import 'dart:typed_data';

import 'package:hive_ce/hive.dart';
import 'package:manna/models/account.dart';
import 'package:manna/models/bolt12_offer.dart';
import 'package:manna/models/chat_message.dart';
import 'package:manna/models/contact.dart';
import 'package:manna/models/setting_history_cache.dart';
import 'package:manna/models/shop_item.dart';
import 'package:manna/models/tax.dart';
import 'package:manna/models/transaction.dart';
import 'package:manna/models/wallet.dart';
import 'package:manna/services/chat_service.dart';
import 'package:manna/services/map_service.dart';
import 'package:manna_core/manna_core.dart' hide Wallet;

void registerV2Adapters({bool force = false}) {
  if (!force && Hive.isAdapterRegistered(AccountAdapter().typeId)) return;
  Hive.registerAdapter(AccountAdapter(), override: true);
  Hive.registerAdapter(WalletAdapter(), override: true);
  Hive.registerAdapter(TransactionAdapter(), override: true);
  Hive.registerAdapter(ShopItemAdapter(), override: true);
  Hive.registerAdapter(TaxAdapter(), override: true);
  Hive.registerAdapter(ContactAdapter(), override: true);
  Hive.registerAdapter(SettingHistoryCacheAdapter(), override: true);
  Hive.registerAdapter(ChatMessageAdapter(), override: true);
  Hive.registerAdapter(MapPlaceAdapter(), override: true);
  Hive.registerAdapter(MapCommentAdapter(), override: true);
  Hive.registerAdapter(ChatConversationAdapter(), override: true);
  Hive.registerAdapter(MessageLogAdapter(), override: true);
  Hive.registerAdapter(Bolt12OfferAdapter(), override: true);

  Hive.registerAdapter(OutPointAdapter(), override: true);
  Hive.registerAdapter(TxOutSecretsAdapter(), override: true);
  Hive.registerAdapter(AddressAdapter(), override: true);
  Hive.registerAdapter(TxOutAdapter(), override: true);
  Hive.registerAdapter(BalanceAdapter(), override: true);
  Hive.registerAdapter(TxAdapter(), override: true);
  Hive.registerAdapter(PreImageAdapter(), override: true);
  Hive.registerAdapter(KeyPairAdapter(), override: true);
  Hive.registerAdapter(SwapTreeDataAdapter(), override: true);
  Hive.registerAdapter(LeafDataAdapter(), override: true);
  Hive.registerAdapter(SubmarineSwapAdapter(), override: true);
  Hive.registerAdapter(SubmarineResponseAdapter(), override: true);
  Hive.registerAdapter(ReverseSwapAdapter(), override: true);
  Hive.registerAdapter(ReverseResponseAdapter(), override: true);
  Hive.registerAdapter(ChainSwapAdapter(), override: true);
  Hive.registerAdapter(ChainSwapDataAdapter(), override: true);
  Hive.registerAdapter(SwapAdapter(), override: true);
  Hive.registerAdapter(SwapTransactionAdapter(), override: true);

  Hive.registerAdapter(ChainAdapter(), override: true);
  Hive.registerAdapter(SwapTransactionTypeAdapter(), override: true);
  Hive.registerAdapter(ChainSwapDirectionAdapter(), override: true);
}

/// Classes
/// 1 - 12

/// 1 [Account]
class AccountAdapter extends TypeAdapter<Account> {
  @override
  final typeId = 1;

  @override
  Account read(BinaryReader reader) => Account(
    id: reader.readString(),
    name: reader.readString(),
    createdAtUTC: reader.read() as DateTime,
    isMainAccount: reader.readBool(),
    isDisabled: reader.readBool(),
    isBackedUp: reader.readBool(),
    isSendAnonymously: reader.readBool(),
    isSendNotification: reader.readBool(),
    sortOrder: reader.readInt(),
    chatKeyPair: reader.read() as KeyPair?,
    nsec: reader.read() as String?,
  );

  @override
  void write(BinaryWriter writer, Account obj) {
    writer.writeString(obj.id);
    writer.writeString(obj.name);
    writer.write(obj.createdAtUTC);
    writer.writeBool(obj.isMainAccount);
    writer.writeBool(obj.isDisabled);
    writer.writeBool(obj.isBackedUp);
    writer.writeBool(obj.isSendAnonymously);
    writer.writeBool(obj.isSendNotification);
    writer.writeInt(obj.sortOrder);
    writer.write(obj.chatKeyPair);
    writer.write(obj.nsec);
  }
}

/// 2 [Wallet]
class WalletAdapter extends TypeAdapter<Wallet> {
  @override
  final typeId = 2;

  @override
  Wallet read(BinaryReader reader) => Wallet(
    accountId: reader.readString(),
    descriptor: reader.readString(),
    xpub: reader.readString(),
    network: Network.values[reader.readInt()],
    type: WalletType.values[reader.readInt()],
    balance: reader.readInt(),
    isCorrupted: reader.readBool(),
  );

  @override
  void write(BinaryWriter writer, Wallet obj) {
    writer.writeString(obj.accountId);
    writer.writeString(obj.descriptor);
    writer.writeString(obj.xpub);
    writer.writeInt(obj.network.index);
    writer.writeInt(obj.type.index);
    writer.writeInt(obj.balance);
    writer.writeBool(obj.isCorrupted);
  }
}

/// 3 [Transaction]
class TransactionAdapter extends TypeAdapter<Transaction> {
  @override
  final typeId = 3;

  @override
  Transaction read(BinaryReader reader) => Transaction(
    txId: reader.readString(),
    network: Network.values[reader.readInt()],
    walletId: reader.readString(),
    amount: reader.readInt(),
    timestamp: reader.read() as DateTime,
    isIncoming: reader.readBool(),
    memo: reader.readString(),
    note: reader.readString(),
    liquidTx: reader.read() as Tx?,
    isMemoSynced: reader.readBool(),
    senderUUID: reader.read() as String?,
    receiverUserNameOrUUID: reader.read() as String?,
    categories: (reader.read() as Set).cast<String>(),
  );

  @override
  void write(BinaryWriter writer, Transaction obj) {
    writer.writeString(obj.txId);
    writer.writeInt(obj.network.index);
    writer.writeString(obj.walletId);
    writer.writeInt(obj.amount);
    writer.write(obj.timestamp);
    writer.writeBool(obj.isIncoming);
    writer.writeString(obj.memo);
    writer.writeString(obj.note);
    writer.write(obj.liquidTx);
    writer.writeBool(obj.isMemoSynced);
    writer.write(obj.senderUUID);
    writer.write(obj.receiverUserNameOrUUID);
    writer.write(obj.categories);
  }
}

/// 4 [ShopItem]
class ShopItemAdapter extends TypeAdapter<ShopItem> {
  @override
  final typeId = 4;

  @override
  ShopItem read(BinaryReader reader) => ShopItem(
    id: reader.readInt(),
    name: reader.readString(),
    price: reader.readDouble(),
    category: reader.readString(),
    imageBytes: reader.read() as Uint8List?,
  );

  @override
  void write(BinaryWriter writer, ShopItem obj) {
    writer.writeInt(obj.id);
    writer.writeString(obj.name);
    writer.writeDouble(obj.price);
    writer.writeString(obj.category);
    writer.write(obj.imageBytes);
  }
}

/// 5 [Tax]
class TaxAdapter extends TypeAdapter<Tax> {
  @override
  final typeId = 5;

  @override
  Tax read(BinaryReader reader) => Tax(
    id: reader.readInt(),
    name: reader.readString(),
    tax: reader.readDouble(),
    categories: (reader.read() as Set).cast<String>(),
  );

  @override
  void write(BinaryWriter writer, Tax obj) {
    writer.writeInt(obj.id);
    writer.writeString(obj.name);
    writer.writeDouble(obj.tax);
    writer.write(obj.categories);
  }
}

/// 6 [Contact]
class ContactAdapter extends TypeAdapter<Contact> {
  @override
  final typeId = 6;

  @override
  Contact read(BinaryReader reader) => Contact(
    uuid: reader.readString(),
    walletId: reader.readString(),
    walletType: WalletType.values[reader.readInt()],
    name: reader.readString(),
    lnurl: reader.readString(),
    about: reader.read() as String?,
    picture: reader.read() as String?,
    banner: reader.read() as String?,
    npub: reader.read() as String?,
    chatPubKeyBase64: reader.read() as String?,
    isMannaUser: reader.readBool(),
    isFavorite: reader.readBool(),
    customizedContact: reader.read() as Contact?,
  );

  @override
  void write(BinaryWriter writer, Contact obj) {
    writer.writeString(obj.uuid);
    writer.writeString(obj.walletId);
    writer.writeInt(obj.walletType.index);
    writer.writeString(obj.name(original: true));
    writer.writeString(obj.lnurl(original: true));
    writer.write(obj.about(original: true));
    writer.write(obj.picture(original: true));
    writer.write(obj.banner(original: true));
    writer.write(obj.npub(original: true));
    writer.write(obj.chatPubKeyBase64);
    writer.writeBool(obj.isMannaUser);
    writer.writeBool(obj.isFavorite);
    writer.write(obj.customizedContact);
  }
}

/// 7 [SettingHistoryCache]
class SettingHistoryCacheAdapter extends TypeAdapter<SettingHistoryCache> {
  @override
  final typeId = 7;

  @override
  SettingHistoryCache read(BinaryReader reader) => SettingHistoryCache(
    id: reader.readInt(),
    key: reader.readString(),
    network: Network.values[reader.readInt()],
    previousValue: reader.read() as String?,
    value: reader.readString(),
    effectiveAtUTC: reader.read() as DateTime,
  );

  @override
  void write(BinaryWriter writer, SettingHistoryCache obj) {
    writer.writeInt(obj.id);
    writer.writeString(obj.key);
    writer.writeInt(obj.network.index);
    writer.write(obj.previousValue);
    writer.writeString(obj.value);
    writer.write(obj.effectiveAtUTC);
  }
}

/// 8 [ChatMessage]
class ChatMessageAdapter extends TypeAdapter<ChatMessage> {
  @override
  final typeId = 8;

  @override
  ChatMessage read(BinaryReader reader) => ChatMessage(
    uuid: reader.readString(),
    senderId: reader.readString(),
    receiverId: reader.readString(),
    replyOfId: reader.read() as String?,
    reaction: reader.read() as String?,
    timestampUTC: reader.read() as DateTime,
    receivedAtUTC: reader.read() as DateTime?,
    seenAtUTC: reader.read() as DateTime?,
    isPending: reader.readBool(),
    messageData: MessageData.fromMap(reader.readMap()) ?? const TextMessageData(message: 'ugghhhghhh!!'),
  );

  @override
  void write(BinaryWriter writer, ChatMessage obj) {
    writer.writeString(obj.uuid);
    writer.writeString(obj.senderId);
    writer.writeString(obj.receiverId);
    writer.write(obj.replyOfId);
    writer.write(obj.reaction);
    writer.write(obj.timestampUTC);
    writer.write(obj.receivedAtUTC);
    writer.write(obj.seenAtUTC);
    writer.writeBool(obj.isPending);
    writer.writeMap(obj.messageData.toMap());
  }
}

/// 9 [MapPlace]
class MapPlaceAdapter extends TypeAdapter<MapPlace> {
  @override
  final typeId = 9;

  @override
  MapPlace read(BinaryReader reader) => MapPlace(
    id: reader.readInt(),
    lat: reader.readDouble(),
    lon: reader.readDouble(),
    icon: reader.readString(),
    name: reader.read() as String?,
    address: reader.read() as String?,
    openingHours: reader.read() as String?,
    createdAtUTC: reader.read() as DateTime,
    updatedAtUTC: reader.read() as DateTime,
    deletedAtUTC: reader.read() as DateTime?,
    verifiedAtUTC: reader.read() as DateTime?,
    boostedUntilUTC: reader.read() as DateTime?,
    osmId: reader.read() as String?,
    phone: reader.read() as String?,
    website: reader.read() as String?,
    twitter: reader.read() as String?,
    facebook: reader.read() as String?,
    instagram: reader.read() as String?,
    line: reader.read() as String?,
    email: reader.read() as String?,
    acceptOnChain: reader.read() as bool?,
    acceptLightning: reader.read() as bool?,
    acceptLightningContactLess: reader.read() as bool?,
    commentCount: reader.readInt(),
  );

  @override
  void write(BinaryWriter writer, MapPlace obj) {
    writer.writeInt(obj.id);
    writer.writeDouble(obj.lat);
    writer.writeDouble(obj.lon);
    writer.writeString(obj.icon);
    writer.write(obj.name);
    writer.write(obj.address);
    writer.write(obj.openingHours);
    writer.write(obj.createdAtUTC);
    writer.write(obj.updatedAtUTC);
    writer.write(obj.deletedAtUTC);
    writer.write(obj.verifiedAtUTC);
    writer.write(obj.boostedUntilUTC);
    writer.write(obj.osmId);
    writer.write(obj.phone);
    writer.write(obj.website);
    writer.write(obj.twitter);
    writer.write(obj.facebook);
    writer.write(obj.instagram);
    writer.write(obj.line);
    writer.write(obj.email);
    writer.write(obj.acceptOnChain);
    writer.write(obj.acceptLightning);
    writer.write(obj.acceptLightningContactLess);
    writer.writeInt(obj.commentCount);
  }
}

/// 10 [MapComment]
class MapCommentAdapter extends TypeAdapter<MapComment> {
  @override
  final typeId = 10;

  @override
  MapComment read(BinaryReader reader) => MapComment(
    id: reader.readInt(),
    placeId: reader.readInt(),
    text: reader.readString(),
    createAt: reader.read() as DateTime,
  );

  @override
  void write(BinaryWriter writer, MapComment obj) {
    writer.writeInt(obj.id);
    writer.writeInt(obj.placeId);
    writer.writeString(obj.text);
    writer.write(obj.createAt);
  }
}

/// 11 [ChatConversation]
class ChatConversationAdapter extends TypeAdapter<ChatConversation> {
  @override
  final typeId = 11;

  @override
  ChatConversation read(BinaryReader reader) => ChatConversation(
    id: reader.readString(),
    myUUID: reader.readString(),
    otherUserUUID: reader.readString(),
    lastMessageId: reader.readString(),
    unreadCount: reader.readInt(),
    deletedAt: reader.read() as DateTime?,
  );

  @override
  void write(BinaryWriter writer, ChatConversation obj) {
    writer.writeString(obj.id);
    writer.writeString(obj.myUUID);
    writer.writeString(obj.otherUserUUID);
    writer.writeString(obj.lastMessageId);
    writer.writeInt(obj.unreadCount);
    writer.write(obj.deletedAt);
  }
}

/// 12 [MessageLog]
class MessageLogAdapter extends TypeAdapter<MessageLog> {
  @override
  final typeId = 12;

  @override
  MessageLog read(BinaryReader reader) => MessageLog(
    uuid: reader.readString(),
    senderId: reader.readString(),
    receiverId: reader.readString(),
    eventType: MessageLogType.values[reader.read() as int],
    timestamp: reader.read() as DateTime,
    data: reader.read() as Uint8List?,
  );

  @override
  void write(BinaryWriter writer, MessageLog obj) {
    writer.writeString(obj.uuid);
    writer.writeString(obj.senderId);
    writer.writeString(obj.receiverId);
    writer.write(obj.eventType.index);
    writer.write(obj.timestamp);
    writer.write(obj.data);
  }
}

/// 13 [Bolt12Offer]
class Bolt12OfferAdapter extends TypeAdapter<Bolt12Offer> {
  @override
  final typeId = 13;

  @override
  Bolt12Offer read(BinaryReader reader) => Bolt12Offer(
    walletId: reader.readString(),
    walletType: WalletType.values[reader.readInt()],
    offer: reader.readString(),
    signingKey: reader.read() as KeyPair,
  );

  @override
  void write(BinaryWriter writer, Bolt12Offer obj) {
    writer.writeString(obj.walletId);
    writer.writeInt(obj.walletType.index);
    writer.writeString(obj.offer);
    writer.write(obj.signingKey);
  }
}

/// Internal classes
/// 51 - 68

/// 51 [OutPoint]
class OutPointAdapter extends TypeAdapter<OutPoint> {
  @override
  final typeId = 51;

  @override
  OutPoint read(BinaryReader reader) => OutPoint(txid: reader.readString(), vout: reader.readInt());

  @override
  void write(BinaryWriter writer, OutPoint obj) {
    writer.writeString(obj.txid);
    writer.writeInt(obj.vout);
  }
}

/// 52 [TxOutSecrets]
class TxOutSecretsAdapter extends TypeAdapter<TxOutSecrets> {
  @override
  final typeId = 52;

  @override
  TxOutSecrets read(BinaryReader reader) => TxOutSecrets(
    value: reader.read() as BigInt,
    valueBf: reader.readString(),
    asset: reader.readString(),
    assetBf: reader.readString(),
  );

  @override
  void write(BinaryWriter writer, TxOutSecrets obj) {
    writer.write(obj.value);
    writer.writeString(obj.valueBf);
    writer.writeString(obj.asset);
    writer.writeString(obj.assetBf);
  }
}

/// 53 [Address]
class AddressAdapter extends TypeAdapter<Address> {
  @override
  final typeId = 53;

  @override
  Address read(BinaryReader reader) => Address(
    standard: reader.readString(),
    confidential: reader.readString(),
    index: reader.read() as int?,
    blindingKey: reader.read() as String?,
  );

  @override
  void write(BinaryWriter writer, Address obj) {
    writer.writeString(obj.standard);
    writer.writeString(obj.confidential);
    writer.write(obj.index);
    writer.write(obj.blindingKey);
  }
}

/// 54 [TxOut]
class TxOutAdapter extends TypeAdapter<TxOut> {
  @override
  final typeId = 54;

  @override
  TxOut read(BinaryReader reader) => TxOut(
    scriptPubkey: reader.readString(),
    outpoint: reader.read() as OutPoint,
    height: reader.read() as int?,
    unblinded: reader.read() as TxOutSecrets,
    isSpent: reader.readBool(),
    address: reader.read() as Address,
  );

  @override
  void write(BinaryWriter writer, TxOut obj) {
    writer.writeString(obj.scriptPubkey);
    writer.write(obj.outpoint);
    writer.write(obj.height);
    writer.write(obj.unblinded);
    writer.writeBool(obj.isSpent);
    writer.write(obj.address);
  }
}

/// 55 [Balance]
class BalanceAdapter extends TypeAdapter<Balance> {
  @override
  final typeId = 55;

  @override
  Balance read(BinaryReader reader) => Balance(assetId: reader.readString(), value: reader.readInt());

  @override
  void write(BinaryWriter writer, Balance obj) {
    writer.writeString(obj.assetId);
    writer.writeInt(obj.value);
  }
}

/// 56 [Tx]
class TxAdapter extends TypeAdapter<Tx> {
  @override
  final typeId = 56;

  @override
  Tx read(BinaryReader reader) => Tx(
    timestamp: reader.read() as int?,
    kind: reader.readString(),
    balances: (reader.read() as List).cast<Balance>(),
    txid: reader.readString(),
    outputs: (reader.read() as List).cast<TxOut>(),
    inputs: (reader.read() as List).cast<TxOut>(),
    fee: reader.read() as BigInt,
    height: reader.read() as int?,
    unblindedUrl: reader.readString(),
    vsize: reader.read() as BigInt,
  );

  @override
  void write(BinaryWriter writer, Tx obj) {
    writer.write(obj.timestamp);
    writer.writeString(obj.kind);
    writer.write(obj.balances);
    writer.writeString(obj.txid);
    writer.write(obj.outputs);
    writer.write(obj.inputs);
    writer.write(obj.fee);
    writer.write(obj.height);
    writer.writeString(obj.unblindedUrl);
    writer.write(obj.vsize);
  }
}

/// 57 [PreImage]
class PreImageAdapter extends TypeAdapter<PreImage> {
  @override
  final typeId = 57;

  @override
  PreImage read(BinaryReader reader) =>
      PreImage(value: reader.readString(), sha256: reader.readString(), hash160: reader.readString());

  @override
  void write(BinaryWriter writer, PreImage obj) {
    writer.writeString(obj.value);
    writer.writeString(obj.sha256);
    writer.writeString(obj.hash160);
  }
}

/// 58 [KeyPair]
class KeyPairAdapter extends TypeAdapter<KeyPair> {
  @override
  final typeId = 58;

  @override
  KeyPair read(BinaryReader reader) => KeyPair(secretKey: reader.readByteList(), publicKey: reader.readByteList());

  @override
  void write(BinaryWriter writer, KeyPair obj) {
    writer.writeByteList(obj.secretKey);
    writer.writeByteList(obj.publicKey);
  }
}

/// 59 [SwapTreeData]
class SwapTreeDataAdapter extends TypeAdapter<SwapTreeData> {
  @override
  final typeId = 59;

  @override
  SwapTreeData read(BinaryReader reader) =>
      SwapTreeData(claimLeaf: reader.read() as LeafData, refundLeaf: reader.read() as LeafData);

  @override
  void write(BinaryWriter writer, SwapTreeData obj) {
    writer.write(obj.claimLeaf);
    writer.write(obj.refundLeaf);
  }
}

/// 60 [LeafData]
class LeafDataAdapter extends TypeAdapter<LeafData> {
  @override
  final typeId = 60;

  @override
  LeafData read(BinaryReader reader) => LeafData(output: reader.readString(), version: reader.readInt());

  @override
  void write(BinaryWriter writer, LeafData obj) {
    writer.writeString(obj.output);
    writer.writeInt(obj.version);
  }
}

/// 61 [SubmarineSwap]
class SubmarineSwapAdapter extends TypeAdapter<SubmarineSwap> {
  @override
  final typeId = 61;

  @override
  SubmarineSwap read(BinaryReader reader) => SubmarineSwap(
    from: reader.read() as Chain,
    keys: reader.read() as KeyPair,
    invoice: reader.readString(),
    swapCreateRes: reader.read() as SubmarineResponse,
  );

  @override
  void write(BinaryWriter writer, SubmarineSwap obj) {
    writer.write(obj.from);
    writer.write(obj.keys);
    writer.writeString(obj.invoice);
    writer.write(obj.swapCreateRes);
  }
}

/// 62 [SubmarineResponse]
class SubmarineResponseAdapter extends TypeAdapter<SubmarineResponse> {
  @override
  final typeId = 62;

  @override
  SubmarineResponse read(BinaryReader reader) => SubmarineResponse(
    acceptZeroConf: reader.readBool(),
    address: reader.readString(),
    bip21: reader.readString(),
    claimPublicKey: reader.readString(),
    expectedAmount: reader.read() as BigInt,
    swapTree: reader.read() as SwapTreeData,
    timeoutBlockHeight: reader.read() as BigInt,
    blindingKey: reader.read() as String?,
  );

  @override
  void write(BinaryWriter writer, SubmarineResponse obj) {
    writer.writeBool(obj.acceptZeroConf);
    writer.writeString(obj.address);
    writer.writeString(obj.bip21);
    writer.writeString(obj.claimPublicKey);
    writer.write(obj.expectedAmount);
    writer.write(obj.swapTree);
    writer.write(obj.timeoutBlockHeight);
    writer.write(obj.blindingKey);
  }
}

/// 63 [ReverseSwap]
class ReverseSwapAdapter extends TypeAdapter<ReverseSwap> {
  @override
  final typeId = 63;

  @override
  ReverseSwap read(BinaryReader reader) => ReverseSwap(
    to: reader.read() as Chain,
    keys: reader.read() as KeyPair,
    swapCreateRes: reader.read() as ReverseResponse,
  );

  @override
  void write(BinaryWriter writer, ReverseSwap obj) {
    writer.write(obj.to);
    writer.write(obj.keys);
    writer.write(obj.swapCreateRes);
  }
}

/// 64 [ReverseResponse]
class ReverseResponseAdapter extends TypeAdapter<ReverseResponse> {
  @override
  final typeId = 64;

  @override
  ReverseResponse read(BinaryReader reader) => ReverseResponse(
    invoice: reader.read() as String?,
    swapTree: reader.read() as SwapTreeData,
    lockupAddress: reader.readString(),
    refundPublicKey: reader.readString(),
    timeoutBlockHeight: reader.readInt(),
    onchainAmount: reader.read() as BigInt,
    blindingKey: reader.read() as String?,
  );

  @override
  void write(BinaryWriter writer, ReverseResponse obj) {
    writer.write(obj.invoice);
    writer.write(obj.swapTree);
    writer.writeString(obj.lockupAddress);
    writer.writeString(obj.refundPublicKey);
    writer.writeInt(obj.timeoutBlockHeight);
    writer.write(obj.onchainAmount);
    writer.write(obj.blindingKey);
  }
}

/// 65 [ChainSwap]
class ChainSwapAdapter extends TypeAdapter<ChainSwap> {
  @override
  final typeId = 65;

  @override
  ChainSwap read(BinaryReader reader) => ChainSwap(
    direction: reader.read() as ChainSwapDirection,
    refundKeys: reader.read() as KeyPair,
    claimKeys: reader.read() as KeyPair,
    lockupDetails: reader.read() as ChainSwapData,
    claimDetails: reader.read() as ChainSwapData,
  );

  @override
  void write(BinaryWriter writer, ChainSwap obj) {
    writer.write(obj.direction);
    writer.write(obj.refundKeys);
    writer.write(obj.claimKeys);
    writer.write(obj.lockupDetails);
    writer.write(obj.claimDetails);
  }
}

/// 66 [ChainSwapData]
class ChainSwapDataAdapter extends TypeAdapter<ChainSwapData> {
  @override
  final typeId = 66;

  @override
  ChainSwapData read(BinaryReader reader) => ChainSwapData(
    swapTree: reader.read() as SwapTreeData,
    lockupAddress: reader.readString(),
    serverPublicKey: reader.readString(),
    timeoutBlockHeight: reader.readInt(),
    amount: reader.read() as BigInt,
    blindingKey: reader.read() as String?,
    refundAddress: reader.read() as String?,
    claimAddress: reader.read() as String?,
    bip21: reader.read() as String?,
  );

  @override
  void write(BinaryWriter writer, ChainSwapData obj) {
    writer.write(obj.swapTree);
    writer.writeString(obj.lockupAddress);
    writer.writeString(obj.serverPublicKey);
    writer.writeInt(obj.timeoutBlockHeight);
    writer.write(obj.amount);
    writer.write(obj.blindingKey);
    writer.write(obj.refundAddress);
    writer.write(obj.claimAddress);
    writer.write(obj.bip21);
  }
}

/// 67 [Swap]
class SwapAdapter extends TypeAdapter<Swap> {
  @override
  final typeId = 67;

  @override
  Swap read(BinaryReader reader) => Swap(
    id: reader.readString(),
    index: (reader.read() as BigInt).toInt(),
    walletId: reader.readString(),
    walletType: WalletType.values[reader.readInt()],
    network: Network.values[reader.readInt()],
    preimage: reader.read() as PreImage,
    sendAmount: reader.read() as BigInt,
    receiveAmount: reader.read() as BigInt,
    creationTime: reader.read() as BigInt,
    completionTime: reader.read() as BigInt?,
    submarine: reader.read() as SubmarineSwap?,
    reverse: reader.read() as ReverseSwap?,
    chain: reader.read() as ChainSwap?,
    swapStatus: reader.readString(),
    failureReason: reader.read() as String?,
    note: reader.read() as String?,
    boltzFee: reader.read() as BigInt?,
    lockupFee: reader.read() as BigInt?,
    claimFee: reader.read() as BigInt?,
    refundedAddress: reader.read() as String?,
    refundFee: reader.read() as BigInt?,
    transactions: (reader.read() as List).cast<SwapTransaction>(),
    isExchangeSwap: reader.readBool(),
  );

  @override
  void write(BinaryWriter writer, Swap obj) {
    writer.writeString(obj.id);
    writer.write(BigInt.from(obj.index));
    writer.writeString(obj.walletId);
    writer.writeInt(obj.walletType.index);
    writer.writeInt(obj.network.index);
    writer.write(obj.preimage);
    writer.write(obj.sendAmount);
    writer.write(obj.receiveAmount);
    writer.write(obj.creationTime);
    writer.write(obj.completionTime);
    writer.write(obj.submarine);
    writer.write(obj.reverse);
    writer.write(obj.chain);
    writer.writeString(obj.swapStatus);
    writer.write(obj.failureReason);
    writer.write(obj.note);
    writer.write(obj.boltzFee);
    writer.write(obj.lockupFee);
    writer.write(obj.claimFee);
    writer.write(obj.refundedAddress);
    writer.write(obj.refundFee);
    writer.write(obj.transactions);
    writer.writeBool(obj.isExchangeSwap);
  }
}

/// 68 [SwapTransaction]
class SwapTransactionAdapter extends TypeAdapter<SwapTransaction> {
  @override
  final typeId = 68;

  @override
  SwapTransaction read(BinaryReader reader) => SwapTransaction(
    txId: reader.readString(),
    chain: reader.read() as Chain,
    txType: reader.read() as SwapTransactionType,
    isUser: reader.readBool(),
  );

  @override
  void write(BinaryWriter writer, SwapTransaction obj) {
    writer.writeString(obj.txId);
    writer.write(obj.chain);
    writer.write(obj.txType);
    writer.writeBool(obj.isUser);
  }
}

/// Enums
/// 100 - 106

/// 104 [Chain]
class ChainAdapter extends TypeAdapter<Chain> {
  @override
  final typeId = 104;

  @override
  Chain read(BinaryReader reader) => switch (reader.readByte()) {
    0 => Chain.bitcoin,
    1 => Chain.liquid,
    _ => Chain.bitcoin,
  };

  @override
  void write(BinaryWriter writer, Chain obj) => switch (obj) {
    Chain.bitcoin => writer.writeByte(0),
    Chain.liquid => writer.writeByte(1),
  };
}

/// 105 [SwapTransactionType]
class SwapTransactionTypeAdapter extends TypeAdapter<SwapTransactionType> {
  @override
  final typeId = 105;

  @override
  SwapTransactionType read(BinaryReader reader) => switch (reader.readByte()) {
    0 => SwapTransactionType.lockup,
    1 => SwapTransactionType.claim,
    2 => SwapTransactionType.refund,
    _ => SwapTransactionType.lockup,
  };

  @override
  void write(BinaryWriter writer, SwapTransactionType obj) => switch (obj) {
    SwapTransactionType.lockup => writer.writeByte(0),
    SwapTransactionType.claim => writer.writeByte(1),
    SwapTransactionType.refund => writer.writeByte(2),
  };
}

/// 106 [ChainSwapDirection]
class ChainSwapDirectionAdapter extends TypeAdapter<ChainSwapDirection> {
  @override
  final typeId = 106;

  @override
  ChainSwapDirection read(BinaryReader reader) => switch (reader.readByte()) {
    0 => ChainSwapDirection.btcToLbtc,
    1 => ChainSwapDirection.lbtcToBtc,
    _ => ChainSwapDirection.btcToLbtc,
  };

  @override
  void write(BinaryWriter writer, ChainSwapDirection obj) => switch (obj) {
    ChainSwapDirection.btcToLbtc => writer.writeByte(0),
    ChainSwapDirection.lbtcToBtc => writer.writeByte(1),
  };
}
