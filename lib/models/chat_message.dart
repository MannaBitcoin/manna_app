import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:manna/models/account.dart';
import 'package:manna/models/misc.dart';
import 'package:manna/models/transaction.dart';
import 'package:manna/router.dart';
import 'package:manna/screens/send_screen.dart';
import 'package:manna/services/chat_service.dart';
import 'package:manna/services/db.dart';
import 'package:manna/services/log_service.dart';
import 'package:manna/utils/parser.dart';
import 'package:manna/utils/sats_extension.dart';
import 'package:manna/utils/state_extension.dart';
import 'package:manna/widgets/amount_text.dart';
import 'package:manna_core/manna_core.dart';

import 'contact.dart';

class ChatConversation {
  ChatConversation({
    required this.id,
    required this.myUUID,
    required this.otherUserUUID,
    required this.lastMessageId,
    required this.unreadCount,
    required this.deletedAt,
  });

  // deterministic, sender/receiver IDs
  final String id;
  final String myUUID;
  final String otherUserUUID;
  String lastMessageId;
  int unreadCount;
  DateTime? deletedAt;

  Contact? get contact =>
      DB.contacts[IdWithWalletAndType(id: otherUserUUID, walletId: myUUID, walletType: WalletType.full)];
  ChatMessage? get lastMessage => DB.chatBox.get(lastMessageId);

  Future<void> update({String? lastMessageId, int? unreadCount, Nullable<DateTime?>? deletedAt}) async {
    this.lastMessageId = lastMessageId ?? this.lastMessageId;
    this.unreadCount = unreadCount ?? this.unreadCount;
    this.deletedAt = deletedAt != null ? deletedAt.value : this.deletedAt;
    await save();
  }

  Future<void> save() async => DB.conversationsBox.put(id, this);

  Future<void> delete() async => DB.conversationsBox.delete(id);

  Map<String, dynamic> toMap() => {
    'id': id,
    'myUUID': myUUID,
    'otherUserUUID': otherUserUUID,
    'lastMessageId': lastMessageId,
    'unreadCount': unreadCount,
    'deletedAt': deletedAt,
  };

  @override
  String toString() => jsonEncode(toMap().toEncodeReady());
}

Future<void> updateConversation() async {
  final myIds = DB.fullWallets.values.map((e) => e.uuid).nonNulls.toList();

  final oldDeletedAtInfo = DB.conversationsBox.toMap().map((key, value) => MapEntry(key, value.deletedAt));
  final chatMessages = DB.chatBox.values.toList();
  chatMessages.sort((a, b) => b.timestampUTC.compareTo(a.timestampUTC));

  final Map<(String, String), ChatMessage> convLastMessages = {};
  final Map<(String, String), int> unreadCount = {};

  // await DB.conversationsBox.clear();
  for (final message in chatMessages) {
    if (myIds.contains(message.senderId)) {
      final convId = (message.senderId, message.receiverId);
      convLastMessages[convId] ??= message;
    }
    if (myIds.contains(message.receiverId)) {
      final convId = (message.receiverId, message.senderId);
      convLastMessages[convId] ??= message;
      if (message.seenAtUTC == null) {
        unreadCount[convId] = (unreadCount[convId] ?? 0) + 1;
      }
    }
  }

  for (final e in convLastMessages.entries) {
    await ChatConversation(
      id: '${e.key.$1}_${e.key.$2}',
      myUUID: e.key.$1,
      otherUserUUID: e.key.$2,
      lastMessageId: e.value.uuid,
      unreadCount: unreadCount[e.key] ?? 0,
      deletedAt: oldDeletedAtInfo[e.key],
    ).save();
  }

  // Delete conversations with no messages.
  for (final convId in DB.conversationsBox.keys) {
    if (!convLastMessages.keys.any((e) => '${e.$1}_${e.$2}' == convId)) {
      await DB.conversationsBox.delete(convId);
    }
  }
}

enum MessageDataType {
  text('text'),
  payReq('payReq');

  const MessageDataType(this.jsonName);

  final String jsonName;

  static Map<MessageDataType, String> dataValues() => Map.fromEntries(values.map((e) => MapEntry(e, e.jsonName)));
}

sealed class MessageData {
  const MessageData();

  static MessageData? fromMap(Map map) {
    final type = parseString(map['type']);
    return switch (parseEnum(MessageDataType.dataValues(), type, unknownValue: MessageDataType.text)) {
      MessageDataType.text => TextMessageData.fromMap(map),
      MessageDataType.payReq => PayReqMessageData.fromMap(map),
    };
  }

  MessageDataType get type;

  @mustCallSuper
  Map<String, dynamic> toMap() => {'type': type.jsonName};
}

class TextMessageData extends MessageData {
  const TextMessageData({required this.message});

  static TextMessageData? fromMap(Map map) => TextMessageData(message: parseString(map['content']));

  @override
  final type = MessageDataType.text;

  final String message;

  @override
  Map<String, dynamic> toMap() => {...super.toMap(), 'content': message};
}

class PayReqMessageData extends MessageData {
  const PayReqMessageData({required this.amount, required this.isSat, required this.memo});

  static PayReqMessageData? fromMap(Map map) {
    try {
      if (map['content'] is Map) {
        final data = map['content'];
        return PayReqMessageData(
          amount: parseDouble(data['amount']),
          isSat: parseBool(data['isSat']),
          memo: parseStringN(data['memo']),
        );
      }
    } catch (e, s) {
      logE(e, stackTrace: s);
    }
    return null;
  }

  @override
  final type = MessageDataType.payReq;

  final double amount;
  final bool isSat;
  final String? memo;

  @override
  Map<String, dynamic> toMap() => {
    ...super.toMap(),
    'content': {'amount': amount, 'isSat': isSat, if (memo != null) 'memo': memo},
  };
}

sealed class Message {
  Message(this.timestampUTC);

  final DateTime timestampUTC;
  DateTime get timestamp => timestampUTC.toLocal();

  String timeString({bool showDaysOnly = true}) {
    final now = DateTime.now();
    final today = DateTime(now.year, now.month, now.day);
    final yesterday = today.subtract(const Duration(days: 1));

    final currentDate = DateTime(timestamp.year, timestamp.month, timestamp.day);
    return currentDate == today
        ? showDaysOnly
              ? 'Today'
              : DateFormat('h:mm a').format(timestamp)
        : currentDate == yesterday
        ? 'Yesterday'
        : currentDate.isAfter(today.subtract(const Duration(days: 7)))
        ? DateFormat('EEEE').format(currentDate)
        : DateFormat('dd MMM yyyy').format(currentDate);
  }
}

class TxMessage extends Message {
  TxMessage(this.tx) : super(tx.timestamp);
  final Transaction tx;
}

class ChatMessage extends Message {
  ChatMessage({
    required this.uuid,
    required this.senderId,
    required this.receiverId,
    required this.messageData,
    required DateTime timestampUTC,
    this.receivedAtUTC,
    this.seenAtUTC,
    this.replyOfId,
    this.reaction,
    this.isPending = false,
  }) : super(timestampUTC);

  factory ChatMessage.fromMap(Map<String, dynamic> data) => ChatMessage(
    uuid: parseString(data['id']),
    senderId: parseString(data['senderId']),
    receiverId: parseString(data['receiverId']),
    messageData:
        MessageData.fromMap(data['messageData']) ?? const TextMessageData(message: 'Something beautiful happened!'),
    timestampUTC: parseDateTime(data['timestamp']).copyWith(isUtc: true),
    receivedAtUTC: parseDateTimeN(data['receivedAtUTC'])?.copyWith(isUtc: true),
    seenAtUTC: parseDateTimeN(data['seenAtUTC'])?.copyWith(isUtc: true),
    replyOfId: parseStringN(data['replyOfId']),
    reaction: parseStringN(data['reaction']),
    isPending: parseBool(data['isPending']),
  );

  static ChatMessage? fromDecryptedData(dynamic data, MessageLog log) {
    try {
      if (data is! String) return null;
      final messageData = jsonDecode(data);
      if (messageData is Map) {
        final messageId = parseString(messageData['id']);
        final replyOfId = parseStringN(messageData['ref']);

        final data = MessageData.fromMap(messageData.cast<String, dynamic>());
        if (data != null) {
          return ChatMessage(
            uuid: messageId,
            senderId: log.senderId,
            receiverId: log.receiverId,
            messageData: data,
            timestampUTC: log.timestamp,
            replyOfId: replyOfId,
          );
        }
      }
    } catch (e, s) {
      logE(e, stackTrace: s);
    }
    return null;
  }

  final String uuid;
  final String senderId;
  final String receiverId;
  final String? replyOfId;
  String? reaction;
  DateTime? receivedAtUTC;
  DateTime? seenAtUTC;
  bool isPending;
  final MessageData messageData;

  GlobalObjectKey get globalKey => GlobalObjectKey(uuid);

  Future<void> update({
    Nullable<DateTime?>? receivedAt,
    Nullable<DateTime?>? seenAt,
    Nullable<String?>? reaction,
    bool? isPending,
  }) {
    receivedAtUTC = receivedAt != null ? receivedAt.value : receivedAtUTC;
    if (seenAt != null) {
      seenAtUTC = seenAt.value;
      if (seenAt.value != null && receivedAtUTC == null) {
        receivedAtUTC = seenAt.value;
      }
    }
    this.reaction = reaction != null ? reaction.value : this.reaction;
    this.isPending = isPending ?? this.isPending;
    return save();
  }

  Future<void> save() async => DB.chatBox.put(uuid, this);

  Future<void> delete() async => DB.chatBox.delete(uuid);

  Map<String, dynamic> toMap() => {
    'id': uuid,
    'senderId': senderId,
    'receiverId': receiverId,
    'messageData': messageData.toMap(),
    'timestamp': timestampUTC,
    'receivedAtUTC': receivedAtUTC,
    'seenAtUTC': seenAtUTC,
    'replyOfId': replyOfId,
    'reaction': reaction,
    'isPending': isPending,
  }.toEncodeReady();

  @override
  String toString() => jsonEncode(toMap());

  Widget createPreview({bool forReply = false, bool forConversation = false}) {
    final isSent = senderId == selectedWallet.uuid;
    final color = isSent
        ? Colors.white
        : AppRouter.navigatorContext.themedColor(bright: Colors.black, dark: Colors.white);

    if (forReply) {
      switch (messageData) {
        case TextMessageData(message: final text):
          return Text(
            text,
            maxLines: 3,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(color: Colors.black),
          );
        case PayReqMessageData(amount: final amount, isSat: final isSat):
          return Text(
            'Requested ${isSat ? getSatInBitcoinStyle(amount.toInt()) : amount.formatFiat()}',
            style: const TextStyle(color: Colors.black),
          );
      }
    }

    if (forConversation) {
      switch (messageData) {
        case TextMessageData(message: final text):
          return Text(text, overflow: TextOverflow.ellipsis, maxLines: 1);
        case PayReqMessageData(amount: final amount, isSat: final isSat):
          return Text('Requested ${isSat ? getSatInBitcoinStyle(amount.toInt()) : amount.formatFiat()}');
      }
    }

    return Stack(
      children: [
        switch (messageData) {
          TextMessageData(message: final text) => SelectionArea(
            child: Text.rich(
              TextSpan(
                children: <InlineSpan>[
                  TextSpan(text: text),
                  WidgetSpan(child: SizedBox(width: isSent ? 68 : 50)),
                ],
              ),
              style: TextStyle(color: color),
            ),
          ),
          PayReqMessageData(amount: final amount, memo: final memo, isSat: final isSat) => Builder(
            builder: (context) {
              final sats = isSat ? amount.toInt() : amount.fiatToSats(at: timestamp, sourceCurrencyCode: 'usd');

              void open() {
                final contact =
                    DB.contacts[IdWithWalletAndType(
                      walletId: selectedWallet.uuid,
                      walletType: selectedWallet.type,
                      id: senderId,
                    )];
                if (contact != null) {
                  AppRouter.push(SendScreen(amount: sats, address: contact.lnurl(original: true), contact: contact));
                }
              }

              return GestureDetector(
                onTap: isSent ? null : open,
                child: Column(
                  crossAxisAlignment: isSent ? .end : .start,
                  spacing: 6,
                  children: [
                    Text(
                      'Requested ${isSat ? getSatInBitcoinStyle(amount.toInt()) : amount.formatFiat()}',
                      style: TextStyle(fontSize: 16, color: color),
                    ),
                    AmountText(
                      amountSat: sats,
                      showFiat: true,
                      btcStyle: TextStyle(fontSize: 18, color: color, fontWeight: FontWeight.bold),
                      fiatStyle: TextStyle(fontSize: 12, color: color, fontWeight: FontWeight.w500),
                    ),
                    if (memo?.isNotEmpty ?? false)
                      Text(
                        memo!,
                        style: TextStyle(color: color),
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                      ),
                    if (!isSent)
                      ElevatedButton(
                        onPressed: open,
                        style: ElevatedButton.styleFrom(visualDensity: VisualDensity.standard),
                        child: const Text('Pay'),
                      ),
                    const SizedBox(height: 12),
                  ],
                ),
              );
            },
          ),
        },

        Positioned(
          bottom: 0,
          right: 0,
          child: Row(
            crossAxisAlignment: .end,
            mainAxisSize: MainAxisSize.min,
            spacing: 2,
            children: [
              Text(
                DateFormat('h:mm a').format(timestamp),
                style: TextStyle(color: isSent ? Colors.grey.shade400 : Colors.grey, fontSize: 10),
              ),
              if (isSent)
                Icon(
                  (seenAtUTC ?? receivedAtUTC) != null
                      ? Icons.done_all
                      : !isPending
                      ? Icons.check
                      : Icons.access_time,
                  size: 14,
                  color: seenAtUTC != null ? Colors.white : Colors.grey,
                ),
            ],
          ),
        ),
      ],
    );
  }
}
