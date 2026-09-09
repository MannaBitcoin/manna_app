import 'dart:async';

import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:manna/models/chat_message.dart';
import 'package:manna/screens/chat_screen.dart';
import 'package:manna/services/db.dart';
import 'package:manna/theme.dart';
import 'package:manna/utils/state_extension.dart';

class MessageInfoScreen extends StatefulWidget {
  const MessageInfoScreen({required this.message, super.key});

  final ChatMessage message;

  @override
  State<MessageInfoScreen> createState() => _MessageInfoScreenState();
}

class _MessageInfoScreenState extends State<MessageInfoScreen> {
  late ChatMessage message = widget.message;
  StreamSubscription? chatHiveSubscription;

  @override
  void initState() {
    chatHiveSubscription = DB.chatBox.watch(key: widget.message.uuid).listen((t) {
      message = t.value as ChatMessage;
      update();
    });
    super.initState();
  }

  @override
  void dispose() {
    chatHiveSubscription?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(),
      body: SingleChildScrollView(
        padding: const EdgeInsets.only(bottom: 32) + const EdgeInsets.symmetric(horizontal: 8),
        child: Column(
          spacing: 8,
          children: [
            MessageBubble(message: message),
            if (message.messageData is PayReqMessageData) ...[
              const Divider(),
              Row(
                spacing: 4,
                children: [
                  const Text('Address', style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold)),
                  Expanded(
                    child: SelectionArea(
                      child: Text((message.messageData as PayReqMessageData).address, textAlign: TextAlign.right),
                    ),
                  ),
                ],
              ),
            ],
            const Divider(),
            Row(
              spacing: 4,
              children: [
                Text(
                  message.isPending ? 'Pending' : 'Sent',
                  style: const TextStyle(fontSize: 16, fontWeight: FontWeight.bold),
                ),
                CircleAvatar(
                  radius: 10,
                  child: Icon(message.isPending ? Icons.access_time : Icons.check, size: 12, color: Colors.grey),
                ),
                const Expanded(child: SizedBox.shrink()),
                Text(DateFormat('d MMM yyyy, h:mm a').format(message.timestamp)),
              ],
            ),
            if (message.receivedAtUTC != null)
              Row(
                spacing: 4,
                children: [
                  const Text('Received', style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold)),
                  const CircleAvatar(radius: 10, child: Icon(Icons.done_all, size: 12, color: Colors.grey)),
                  const Expanded(child: SizedBox.shrink()),
                  if (message.receivedAtUTC!.year == 19770)
                    const Text('some time ago!')
                  else
                    Text(DateFormat('d MMM yyyy, h:mm a').format(message.receivedAtUTC!.toLocal())),
                ],
              ),
            if (message.seenAtUTC != null)
              Row(
                spacing: 4,
                children: [
                  const Text('Read', style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold)),
                  const CircleAvatar(radius: 10, child: Icon(Icons.done_all, size: 12, color: AppColors.primaryColor)),
                  const Expanded(child: SizedBox.shrink()),
                  if (message.seenAtUTC!.year == 19770)
                    const Text('some time ago!')
                  else
                    Text(DateFormat('d MMM yyyy, h:mm a').format(message.seenAtUTC!.toLocal())),
                ],
              ),
          ],
        ),
      ),
    );
  }
}
