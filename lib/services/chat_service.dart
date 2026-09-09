import 'dart:convert';
import 'dart:math' as math;
import 'package:flutter/foundation.dart';
import 'package:manna/app_state.dart';
import 'package:manna/config.dart';
import 'package:manna/models/chat_message.dart';
import 'package:manna/models/misc.dart';
import 'package:manna/models/wallet.dart' as m;
import 'package:manna/services/db.dart';
import 'package:manna/services/db_service.dart';
import 'package:manna/services/jwt_service.dart';
import 'package:manna/services/log_service.dart';
import 'package:manna/utils/de_bouncer.dart';
import 'package:manna/utils/extensions.dart';
import 'package:manna/utils/parser.dart';
import 'package:manna/utils/toast_service.dart';
import 'package:manna/utils/util.dart';
import 'package:manna_core/manna_core.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:uuid/v5.dart';
import 'package:uuid/v7.dart';

const _uuidNamespace = '7d09e47f-b6b2-4e8c-8b8b-42769a3885b7';

enum MessageLogType {
  newMessage,
  receivedReceipt,
  seenReceipt,
  addReaction,
  removeReaction,
  deleteMessage;

  factory MessageLogType.fromInt(int i) => MessageLogType.values[i];
}

class MessageLog {
  MessageLog({
    required this.uuid,
    required this.senderId,
    required this.receiverId,
    required this.eventType,
    required this.timestamp,
    required this.data,
  });

  factory MessageLog.fromMap(Map<String, dynamic> map) => MessageLog(
    uuid: parseString(map['uuid']),
    senderId: parseString(map['sender_id']),
    receiverId: parseString(map['receiver_id']),
    eventType: MessageLogType.fromInt(parseInt(map['event_type'])),
    timestamp: parseDateTime(map['timestamp']),
    data: (map['data'] as String).byteaToUint8List,
  );

  Future<dynamic> decrypt() async {
    if (data == null) return;

    final wallet = DB.fullWallets[senderId] ?? DB.fullWallets[receiverId];
    if (wallet == null) return;
    final chatKeyPair = wallet.account.chatKeyPair;
    if (chatKeyPair == null) return;

    try {
      String? clearText;

      if (wallet.uuid == senderId) {
        clearText = await Crypto.decryptChatMessageAsSender(senderPrivKey: chatKeyPair.secretKey, payload: data!);
      } else {
        String? senderPubKey = DB.contacts[IdWithWalletAndType.wallet(id: senderId, wallet: wallet)]?.chatPubKeyBase64;
        if (senderPubKey == null) {
          final contact = await DbService.getContact(uuid: senderId, wallet: wallet);
          await contact?.save();
          senderPubKey = contact?.chatPubKeyBase64;
        }
        if (senderPubKey?.isEmpty ?? true) return;

        clearText = await Crypto.decryptChatMessageAsReceiver(
          receiverPrivKey: chatKeyPair.secretKey,
          senderPubKey: base64Decode(senderPubKey!),
          payload: data!,
        );
      }
      return clearText;
    } catch (e, s) {
      logE(e, stackTrace: s);
    }
    return null;
  }

  static Future<Uint8List?> encryptMessage({
    required m.Wallet wallet,
    required String receiverUUID,
    required String data,
  }) async {
    final chatKeyPair = wallet.account.chatKeyPair;
    if (chatKeyPair == null) return null;

    String? receiverPubKeyString =
        DB.contacts[IdWithWalletAndType.wallet(id: receiverUUID, wallet: wallet)]?.chatPubKeyBase64;
    if (receiverPubKeyString == null) {
      final receiverContact = await DbService.getContact(uuid: receiverUUID, wallet: wallet);
      await receiverContact?.save();
      receiverPubKeyString ??= receiverContact?.chatPubKeyBase64;
    }

    if (receiverPubKeyString?.isEmpty ?? true) {
      ToastService.show('Unable to reach recipient!');
      return null;
    }

    final res = await Crypto.encryptChatMessage(
      senderPrivKey: chatKeyPair.secretKey,
      receiverPubKey: base64Decode(receiverPubKeyString!),
      message: data,
    );

    return res;
  }

  static Future<MessageLog?> forNewMessage(ChatMessage message) async {
    final wallet = DB.fullWallets[message.senderId];
    if (wallet == null) return null;

    final bytes = await encryptMessage(
      wallet: wallet,
      receiverUUID: message.receiverId,
      data: jsonEncode({
        'id': message.uuid,
        if (message.replyOfId != null) 'ref': message.replyOfId,
        ...message.messageData.toMap(),
      }),
    );
    if (bytes == null) return null;

    return MessageLog(
      uuid: const UuidV5().generate(_uuidNamespace, message.uuid),
      senderId: wallet.uuid,
      receiverId: message.receiverId,
      eventType: MessageLogType.newMessage,
      timestamp: message.timestampUTC,
      data: bytes,
    );
  }

  /// if isSeen is false the received receipt will be created else read receipt will be created.
  static Future<MessageLog?> forReadReceipt({required ChatMessage message, bool isSeen = false}) async {
    final wallet = DB.fullWallets[message.receiverId];
    if (wallet == null) return null;

    final bytes = await encryptMessage(wallet: wallet, receiverUUID: message.senderId, data: message.uuid);
    if (bytes == null) return null;

    return MessageLog(
      uuid: const UuidV5().generate(_uuidNamespace, message.uuid + (isSeen ? 'read' : 'received')),
      senderId: wallet.uuid,
      receiverId: message.senderId,
      eventType: isSeen ? MessageLogType.seenReceipt : MessageLogType.receivedReceipt,
      timestamp: DateTime.now(),
      data: bytes,
    );
  }

  static Future<MessageLog?> forReaction({
    required ChatMessage message,
    required String reaction,
    bool remove = false,
  }) async {
    final wallet = DB.fullWallets[message.receiverId];
    if (wallet == null) return null;

    final bytes = await encryptMessage(
      wallet: wallet,
      receiverUUID: message.senderId,
      data: jsonEncode({'id': message.uuid, if (!remove) 'r': reaction}),
    );
    if (bytes == null) return null;

    return MessageLog(
      uuid: const UuidV7().generate(),
      senderId: wallet.uuid,
      receiverId: message.senderId,
      eventType: remove ? MessageLogType.removeReaction : MessageLogType.addReaction,
      timestamp: DateTime.now(),
      data: bytes,
    );
  }

  static Future<MessageLog?> forDelete({required List<ChatMessage> messages}) async {
    if (messages.isEmpty) return null;
    final wallet = DB.fullWallets[messages.first.senderId];
    if (wallet == null) return null;

    final bytes = await encryptMessage(
      wallet: wallet,
      receiverUUID: messages.first.receiverId,
      data: jsonEncode(messages.map((e) => e.uuid).toList()),
    );
    if (bytes == null) return null;

    return MessageLog(
      uuid: const UuidV7().generate(),
      senderId: wallet.uuid,
      receiverId: messages.first.receiverId,
      eventType: MessageLogType.deleteMessage,
      timestamp: DateTime.now(),
      data: bytes,
    );
  }

  final String uuid;
  final String senderId;
  final String receiverId;
  final MessageLogType eventType;
  final DateTime timestamp;
  final Uint8List? data;

  Future<void> save() => DB.messageLogBox.put(uuid, this);

  Future<void> delete() => DB.messageLogBox.delete(uuid);

  Map<String, dynamic>? toSupabaseRow({bool includeTimeStamp = false}) => data == null
      ? null
      : {
          'uuid': uuid,
          'sender_id': senderId,
          'receiver_id': receiverId,
          'event_type': eventType.index,
          if (includeTimeStamp) 'timestamp': timestamp,
          'data': data!.toBytea,
        }.toEncodeReady();

  @override
  String toString() => jsonEncode(toSupabaseRow() ?? {});
}

// implement message log storing and sending
class ChatService {
  static Future<void> init() async {
    if (DB.activeAccounts.map((e) => e.currentWallet).isEmpty) return;
    await sendPendingLogs();
    await sync();
    await startListener();
  }

  static Future<void> sendPendingLogs() async {
    if (DB.messageLogBox.isEmpty) return;

    final allWalletMap = Map.fromEntries(DB.allWallets.map((e) => MapEntry(e.uuid, e.network)));
    final Map<Network, List<MessageLog>> networkMessageMap = {};
    for (final e in DB.messageLogBox.values) {
      final net = allWalletMap[e.senderId] ?? Config.network;
      if (net == Network.regtest && !Config.isRegtestOn) continue;

      (networkMessageMap[net] ??= []).add(e);
    }
    for (final MapEntry(key: network, value: messagesToPush) in networkMessageMap.entries) {
      if (messagesToPush.isNotEmpty) {
        messagesToPush.sort((a, b) => a.timestamp.compareTo(b.timestamp));

        await DbService.useSupabase((supabase) async {
          for (int i = 0; i < messagesToPush.length; i += 100) {
            final batch = messagesToPush.sublist(i, math.min(i + 100, messagesToPush.length));
            final rows = await supabase
                .schema('chat')
                .from('message_log')
                .upsert(
                  batch.map((e) => e.toSupabaseRow()).nonNulls.toList(),
                  onConflict: 'uuid',
                  ignoreDuplicates: true,
                )
                .select();

            final logs = rows.map((e) => MessageLog.fromMap(e)).toList();
            // process duplicate ones manually offline
            if (batch.length != logs.length) {
              final returnedLogIds = logs.map((e) => e.uuid).toSet();
              logs.addAll(batch.where((e) => !returnedLogIds.contains(e.uuid)));
            }
            logs.sort((a, b) => a.timestamp.compareTo(b.timestamp));

            for (final log in logs) {
              if (await _applyMessageLog(log)) await DB.messageLogBox.delete(log.uuid);
            }
          }
        }, network: network);
      }
    }
  }

  static Future<bool> _applyMessageLog(MessageLog log, {bool markAsReadNewMessage = false}) async {
    final res = await Future(() async {
      final data = await log.decrypt();
      switch (log.eventType) {
        case MessageLogType.newMessage:
          final message = ChatMessage.fromDecryptedData(data, log);
          if (message == null) return false;
          await message.save();
          if (markAsReadNewMessage) {
            await bulkReceiptTillMessage(message: message);
          }
          return true;

        case MessageLogType.receivedReceipt || MessageLogType.seenReceipt:
          // message uuid
          if (data is String) {
            final message = DB.chatBox.get(data);
            if (message == null) return false;

            await applyReadReceiptLocally(
              message: message,
              timestamp: log.timestamp,
              isSeen: log.eventType == MessageLogType.seenReceipt,
            );
          }
          return true;
        case MessageLogType.addReaction || MessageLogType.removeReaction:
          try {
            final p = jsonDecode(data);
            final message = DB.chatBox.get(parseString(p['id']));
            final reaction = parseStringN(p['r']);

            if (message == null) return false;
            if (log.eventType == MessageLogType.addReaction && (reaction?.isEmpty ?? true)) return false;

            await message.update(reaction: Nullable(log.eventType == MessageLogType.removeReaction ? null : reaction));
            return true;
          } catch (e, s) {
            logE(e, stackTrace: s);
          }

        case MessageLogType.deleteMessage:
          try {
            // list of message ids to delete
            final deleteList = jsonDecode(data);
            if (deleteList is List) {
              for (final id in deleteList) {
                await DB.chatBox.delete(id);
              }
              await updateConversation();
              return true;
            }
          } catch (e, s) {
            logE(e, stackTrace: s);
          }
      }
      return false;
    });
    if (res) {
      if (!DB.syncedMessageLogIdsBox.values.contains(log.uuid)) {
        await DB.syncedMessageLogIdsBox.add(log.uuid);
      }
    }
    return res;
  }

  static Future<void> applyReadReceiptLocally({
    required ChatMessage message,
    required DateTime timestamp,
    bool isSeen = false,
  }) async {
    final messagesToUpdate = DB.chatBox.values.where(
      (e) =>
          e.senderId == message.senderId &&
          e.receiverId == message.receiverId &&
          (isSeen ? e.seenAtUTC == null : e.receivedAtUTC == null),
    );

    await Future.wait(
      messagesToUpdate.map(
        (e) => isSeen ? e.update(seenAt: Nullable(timestamp)) : e.update(receivedAt: Nullable(timestamp)),
      ),
    );

    await updateConversation();
  }

  static final MutexRun _syncMutex = MutexRun();
  static Future<void> sync({String? walletId, bool entire = false}) => _syncMutex.run(() async {
    assert(entire ? walletId != null : true, 'Pass walletId for entire sync');

    final net = DB.allWallets.where((w) => w.uuid == walletId).firstOrNull?.network ?? Config.network;
    if (net == Network.regtest && !Config.isRegtestOn) return;

    const pageSize = 1000;
    final myIds = [
      if (walletId != null) walletId else ...DB.fullWallets.values.where((w) => w.network == net).map((w) => w.uuid),
    ];
    if (myIds.isEmpty) return;

    int count = 0;
    final List<ChatMessage> newMessages = [];
    await DbService.useSupabase((supabase) async {
      while (true) {
        final payload = {
          '_my_ids': myIds,
          '_last_sync_time': entire
              ? DateTime(1970).toIso8601String()
              : AppState.prefs.getString('last_chat_sync_time') ?? DateTime(1970).toIso8601String(),
          '_limit': pageSize,
        };
        final rows = await supabase.schema('chat').rpc('sync_messages', params: payload);
        if (rows is! List || rows.isEmpty) break;

        final logs = rows.map((e) => MessageLog.fromMap(e)).toList();
        logs.sort((a, b) => a.timestamp.compareTo(b.timestamp));

        for (final (i, log) in logs.indexed) {
          if (DB.syncedMessageLogIdsBox.values.contains(log.uuid)) {
            continue;
          }

          if (await _applyMessageLog(log, markAsReadNewMessage: i == logs.length - 1)) {
            count++;
          }

          if (log.eventType == MessageLogType.newMessage && myIds.contains(log.receiverId)) {
            final message = ChatMessage.fromDecryptedData(await log.decrypt(), log);
            if (message != null) {
              newMessages.add(message);
            }
          }
        }

        await AppState.prefs.setString('last_chat_sync_time', DateTime.timestamp().toIso8601String());

        // stop if this page was smaller than limit
        if (rows.length < pageSize) break;
      }

      // mark as received : new messages
      final freshMessages = newMessages.where((e) => e.receivedAtUTC == null).toList();
      if (freshMessages.isNotEmpty) {
        freshMessages.sort((a, b) => a.timestampUTC.compareTo(b.timestampUTC));
        await bulkReceiptTillMessage(message: freshMessages.last);
      }

      if (count > 0) {
        logD('Synced $count message logs!');
        await updateConversation();
      }
    }, network: net);
  });

  static Future<void> bulkReceiptTillMessage({required ChatMessage message, bool isSeen = false}) async {
    final log = await MessageLog.forReadReceipt(message: message, isSeen: isSeen);
    if (log != null) {
      await log.save();
      await sendPendingLogs();
    }
  }

  static Future<void> setReaction({required ChatMessage message, required String reaction, bool remove = false}) async {
    final log = await MessageLog.forReaction(message: message, reaction: reaction, remove: remove);
    if (log != null) {
      await log.save();
      await sendPendingLogs();
    }
  }

  static Future<bool> deleteMessages(List<ChatMessage> messages, String myId) async {
    try {
      final t = messages.toList();
      // delete non sent messages directly
      await Future.wait(
        t.where((e) => e.isPending || e.receiverId == myId).map((e) async {
          await e.delete();
          await DB.messageLogBox.delete(const UuidV5().generate(_uuidNamespace, e.uuid));
          t.remove(e);
        }),
      );
      if (t.isEmpty) return true;

      // delete only messages sent by me
      final messageToDelete = t.where((m) => !m.isPending && m.senderId == myId).toList();
      if (messageToDelete.isEmpty) return false;

      final log = await MessageLog.forDelete(messages: messageToDelete);
      if (log != null) {
        await log.save();
        await sendPendingLogs();
        return true;
      }
    } catch (_) {}
    return false;
  }

  static RealtimeChannel? chatChannel;
  static Future<void> startListener() async {
    if (DB.activeAccounts.isEmpty) return;

    return DbService.useSupabase((supabase) async {
      final deviceId = await getDeviceId();
      await supabase.realtime.setAuth(await JWTService.getToken());
      await chatChannel?.unsubscribe();
      chatChannel = null;
      chatChannel = supabase.realtime.channel('d:$deviceId', const RealtimeChannelConfig(private: true));

      chatChannel?.onBroadcast(
        event: 'new',
        callback: (payload) async {
          final data = payload['payload'];
          if (data is Map) {
            final log = MessageLog.fromMap(data.cast<String, dynamic>());
            await _applyMessageLog(log, markAsReadNewMessage: true);

            if ({MessageLogType.newMessage, MessageLogType.deleteMessage}.contains(log.eventType)) {
              await updateConversation();
            }
          }
        },
      );

      chatChannel?.subscribe((status, error) {
        if (kDebugMode) {
          print('Chat: $status${error != null ? ' $error' : ''}');
        }
      });
    });
  }

  static Future<void> stopListener() async {
    await chatChannel?.unsubscribe();
    chatChannel = null;
  }
}
