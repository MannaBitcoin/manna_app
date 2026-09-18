import 'dart:typed_data';

import 'package:breez_sdk_spark_flutter/breez_sdk_spark.dart' show serializePaymentToJson, deserializePaymentFromJson;
import 'package:hive_ce/hive.dart';
import 'package:manna/models/account.dart';
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

  Hive.registerAdapter(OutPointAdapter(), override: true);
  Hive.registerAdapter(TxOutSecretsAdapter(), override: true);
  Hive.registerAdapter(AddressAdapter(), override: true);
  Hive.registerAdapter(TxOutAdapter(), override: true);
  Hive.registerAdapter(BalanceAdapter(), override: true);
  Hive.registerAdapter(TxAdapter(), override: true);
  Hive.registerAdapter(KeyPairAdapter(), override: true);
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
    xpub: reader.readString(),
    network: Network.values[reader.readInt()],
    type: WalletType.values[reader.readInt().clamp(0, 0)],
    balance: reader.readInt(),
  );

  @override
  void write(BinaryWriter writer, Wallet obj) {
    writer.writeString(obj.accountId);
    writer.writeString(obj.xpub);
    writer.writeInt(obj.network.index);
    writer.writeInt(obj.type.index);
    writer.writeInt(obj.balance);
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
    inner: deserializePaymentFromJson(jsonStr: reader.readString()),
    memo: reader.readString(),
    note: reader.readString(),
    isMemoSynced: reader.readBool(),
    senderUUID: reader.read() as String?,
    receiverUserNameOrUUID: reader.read() as String?,
    categories: (reader.read() as Set).cast<String>(),
    extraMetadata: reader.readMap().cast<String, dynamic>(),
  );

  @override
  void write(BinaryWriter writer, Transaction obj) {
    writer.writeString(obj.txId);
    writer.writeInt(obj.network.index);
    writer.writeString(obj.walletId);
    writer.writeString(serializePaymentToJson(payment: obj.inner));
    writer.writeString(obj.memo);
    writer.writeString(obj.note);
    writer.writeBool(obj.isMemoSynced);
    writer.write(obj.senderUUID);
    writer.write(obj.receiverUserNameOrUUID);
    writer.write(obj.categories);
    writer.writeMap(obj.extraMetadata);
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
    walletType: WalletType.values[reader.readInt().clamp(0, 0)],
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
