import 'dart:async';
import 'dart:io';

import 'package:emoji_picker_flutter/emoji_picker_flutter.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:intl/intl.dart' hide TextDirection;
import 'package:keyboard_detection/keyboard_detection.dart';
import 'package:manna/globals.dart';
import 'package:manna/models/account.dart';
import 'package:manna/models/chat_message.dart';
import 'package:manna/models/contact.dart';
import 'package:manna/models/misc.dart';
import 'package:manna/router.dart';
import 'package:manna/screens/contact_detail_screen.dart';
import 'package:manna/screens/image_preview_screen.dart';
import 'package:manna/screens/message_info_screen.dart';
import 'package:manna/screens/send_screen.dart';
import 'package:manna/screens/transaction_detail_screen.dart';
import 'package:manna/services/chat_service.dart';
import 'package:manna/services/clipboard_service.dart';
import 'package:manna/services/db.dart';
import 'package:manna/services/notification_service.dart';
import 'package:manna/theme.dart';
import 'package:manna/utils/de_bouncer.dart';
import 'package:manna/utils/extensions.dart';
import 'package:manna/utils/state_extension.dart';
import 'package:manna/utils/toast_service.dart';
import 'package:manna/utils/util.dart';
import 'package:manna/widgets/amount_text.dart';
import 'package:manna/widgets/bottom sheets/request_bottom_sheet.dart';
import 'package:uuid/v4.dart';

class ChatController {
  ChatController(Contact contact, this.updateCallback) : _contact = contact;
  final Contact _contact;
  final Function updateCallback;
  // safe cause this controller is used only on chat screen
  BuildContext? context;

  String get myId => selectedWallet.uuid;

  Contact get contact =>
      DB.contacts[IdWithWalletAndType(
        id: _contact.uuid,
        walletId: selectedWallet.uuid,
        walletType: selectedWallet.type,
      )] ??
      _contact;

  ChatConversation? get conversation => DB.conversationsBox.get('${myId}_${_contact.uuid}');

  StreamSubscription? chatHiveSubscription;

  final GlobalKey<FormFieldState> messageTextFieldKey = GlobalKey();
  final messageController = TextEditingController();
  late final messageTextFieldFocusNode = FocusNode(
    onKeyEvent: (FocusNode node, KeyEvent e) {
      if (!(HardwareKeyboard.instance.isShiftPressed || HardwareKeyboard.instance.isAltPressed) &&
          e.logicalKey == LogicalKeyboardKey.enter) {
        if (e is KeyDownEvent) {
          sendMessage();
        }
        return KeyEventResult.handled;
      } else {
        return KeyEventResult.ignored;
      }
    },
  );

  List<Message> messages = [];
  String? replyId;

  bool isInSelectionMode = false;
  final Set<ChatMessage> selectedMessages = {};

  Set<String> repliedIds = {};
  final emojiPickerKey = GlobalKey<EmojiPickerState>();

  void init({required BuildContext context, MessageData? initialMessage}) {
    // cancel relevant notifications
    if (Platform.isAndroid) {
      NotificationService.cancelNotification(notificationId: contact.uuid);
    } else {
      NotificationService.getActiveNotifications().then((notifications) {
        for (final not in notifications) {
          if (not.groupId == contact.uuid) {
            NotificationService.cancelNotification(notificationId: not.id);
          }
        }
      });
    }

    if (initialMessage != null) {
      switch (initialMessage) {
        case TextMessageData(message: final message):
          messageController.text = message.trim();
        case PayReqMessageData():
          postFrameCallBack(() => sendPayRequest(context: context));
      }
    }
    messages = [
      ...DB.chatBox.values
          .where((e) => e.senderId == contact.uuid || e.receiverId == contact.uuid)
          .where((e) => e.senderId == myId || e.receiverId == myId),
    ];

    final transactions = DB.transactions.values
        .where(
          (t) =>
              contact.walletId == t.walletId &&
              (t.senderUUID == contact.uuid ||
                  t.receiverUserNameOrUUID == contact.uuid ||
                  t.receiverUserNameOrUUID == contact.lnurl()),
        )
        .toList();
    messages.addAll(transactions.map((tx) => TxMessage(tx)).toList());
    messages.sort((a, b) => b.timestampUTC.compareTo(a.timestampUTC));

    repliedIds = messages.whereType<ChatMessage>().where((e) => e.replyOfId != null).map((e) => e.replyOfId!).toSet();
    if (messages.isNotEmpty) {
      postFrameCallBack(() {
        final c = messages
            .whereType<ChatMessage>()
            .where((e) => e.receiverId == myId && e.seenAtUTC == null && e.receivedAtUTC != null)
            .lastOrNull
            ?.globalKey
            .currentContext;
        if (c != null) {
          Scrollable.ensureVisible(c, alignmentPolicy: ScrollPositionAlignmentPolicy.keepVisibleAtStart);
        }
      });
    }

    chatHiveSubscription = DB.chatBox.watch().listen((t) {
      try {
        if (t.deleted) {
          // delete
          messages.removeWhere((e) => e is ChatMessage && e.uuid == t.key);
          updateCallback();
          return;
        }

        final message = t.value as ChatMessage;
        if ((message.senderId == contact.uuid && message.receiverId == myId) ||
            (message.senderId == myId && message.receiverId == contact.uuid)) {
          // status update
          for (final m in messages.whereType<ChatMessage>()) {
            if (t.key == m.uuid) {
              m.isPending = message.isPending;
              m.receivedAtUTC = message.receivedAtUTC;
              m.seenAtUTC = message.seenAtUTC;
              m.reaction = message.reaction;
              updateCallback();
              return;
            }
          }
          messages.add(message);
          messages.sort((a, b) => b.timestampUTC.compareTo(a.timestampUTC));
          if (message.replyOfId != null) {
            repliedIds.add(message.replyOfId!);
          }
          updateCallback();
          markAsRead();
        }
      } catch (_) {}
    });
  }

  final markAsReadDeBouncer = DeBouncer(const Duration(seconds: 2));

  void markAsRead() {
    Future(() async {
      final visibleMessagesNonSeenMessages = messages
          .whereType<ChatMessage>()
          .where((m) => myId == m.receiverId && m.seenAtUTC == null)
          .map((e) => e.globalKey.currentContext != null ? e : null)
          .nonNulls
          .toList();

      if (visibleMessagesNonSeenMessages.isNotEmpty) {
        visibleMessagesNonSeenMessages.sort((a, b) => a.timestampUTC.compareTo(b.timestampUTC));
        await ChatService.bulkReceiptTillMessage(message: visibleMessagesNonSeenMessages.last, isSeen: true);
      }
    });
  }

  Future<void> addReaction(ChatMessage message, String emoji) async {
    await ChatService.setReaction(message: message, reaction: emoji);
    isInSelectionMode = false;
    selectedMessages.clear();
    updateCallback();
  }

  Future<void> sendMessage() async {
    final messageText = messageController.text.trim();
    if (messageText.isEmpty) return;
    // This is to make sure receiver can actually receive message
    final data = await MessageLog.encryptMessage(receiverUUID: contact.uuid, wallet: selectedWallet, data: '');
    if (data == null) return;

    final message = ChatMessage(
      uuid: const UuidV4().generate(),
      senderId: myId,
      receiverId: contact.uuid,
      messageData: TextMessageData(message: messageText),
      replyOfId: replyId,
      timestampUTC: DateTime.timestamp(),
      isPending: true,
    );
    await message.save();
    messageController.clear();

    // this is the only way to hide the selection handlers.
    EditableTextState? targetChildState;
    messageTextFieldKey.currentContext?.visitChildElements((e) {
      void search(Element el) {
        if (el.widget is EditableText && el is StatefulElement) {
          targetChildState = el.state as EditableTextState;
          return;
        }
        el.visitChildren(search);
      }

      search(e);
    });
    targetChildState?.hideToolbar();

    replyId = null;
    updateCallback();
    messageTextFieldFocusNode.requestFocus();
    await (await MessageLog.forNewMessage(message))?.save();

    await updateConversation();
    if (context?.mounted ?? false) {
      PrimaryScrollController.of(context!).jumpTo(0);
    }
    await ChatService.sendPendingLogs();
  }

  Future<void> sendPayRequest({required BuildContext context, PayReqMessageData? data}) async {
    final res = await showModalBottomSheet(
      context: context,
      showDragHandle: true,
      isScrollControlled: true,
      useSafeArea: true,
      isDismissible: false,
      shape: const RoundedRectangleBorder(borderRadius: BorderRadius.vertical(top: Radius.circular(24))),
      routeSettings: const RouteSettings(name: 'RequestBottomSheet'),
      builder: (context) => RequestBottomSheet(initialData: data),
    );
    if (res is PayReqMessageData && context.mounted) {
      // check if recipient is reachable
      final data = await MessageLog.encryptMessage(receiverUUID: contact.uuid, wallet: selectedWallet, data: '');
      if (data == null) return;

      final message = ChatMessage(
        uuid: const UuidV4().generate(),
        senderId: myId,
        receiverId: contact.uuid,
        messageData: res,
        timestampUTC: DateTime.timestamp(),
        isPending: true,
      );
      await message.save();
      updateCallback();
      await (await MessageLog.forNewMessage(message))?.save();

      await updateConversation();
      if (context.mounted) {
        PrimaryScrollController.of(context).jumpTo(0);
      }
      await ChatService.sendPendingLogs();
    }
  }

  void dispose() {
    messageController.dispose();
    messageTextFieldFocusNode.dispose();
    chatHiveSubscription?.cancel();
  }
}

class ChatScreen extends StatefulWidget {
  const ChatScreen({required this.contact, this.messageToDeliver, super.key});

  final Contact contact;
  final MessageData? messageToDeliver;

  @override
  State<ChatScreen> createState() => _ChatScreenState();
}

class _ChatScreenState extends State<ChatScreen> {
  late final controller = ChatController(widget.contact, update);
  final showScrollToBottom = ValueNotifier(false);
  ScrollController? scrollController;
  AppLifecycleListener? lifecycleListener;
  bool isKeyboardVisible = false;

  @override
  void initState() {
    Future(() async {
      await NotificationService.setChatActiveUUID(widget.contact.uuid);
      await ChatService.sync(walletId: selectedWallet.uuid);
      await ChatService.sendPendingLogs();
      controller.markAsRead();
      update();
    });
    lifecycleListener = AppLifecycleListener(
      onShow: () => scheduleMicrotask(() async {
        await ChatService.sendPendingLogs();
        await ChatService.sync(walletId: controller.myId);
        await NotificationService.setChatActiveUUID(widget.contact.uuid);
      }),
      onHide: () => NotificationService.setChatActiveUUID(null),
    );
    controller.init(initialMessage: widget.messageToDeliver, context: context);
    super.initState();
  }

  @override
  void dispose() {
    NotificationService.setChatActiveUUID(null);
    lifecycleListener?.dispose();
    scrollController?.removeListener(scrollListener);
    controller.dispose();
    super.dispose();
  }

  void scrollListener() {
    if (scrollController != null) {
      showScrollToBottom.value = scrollController!.offset > context.screenHeight;
    }
  }

  @override
  void didChangeDependencies() {
    scrollController = PrimaryScrollController.of(context);
    PrimaryScrollController.of(context).addListener(scrollListener);
    super.didChangeDependencies();
  }

  @override
  Widget build(BuildContext context) {
    return KeyboardDetection(
      controller: KeyboardDetectionController(
        onChanged: (value) => update(() => isKeyboardVisible = value == KeyboardState.visible),
      ),
      child: Scaffold(
        appBar: AppBar(
          titleSpacing: 0,
          title: GestureDetector(
            onTap: () => AppRouter.push(ContactDetailScreen(contact: widget.contact)).then((_) => update()),
            child: ColoredBox(
              color: Colors.transparent,
              child: Row(
                spacing: 8,
                children: [
                  if (controller.isInSelectionMode) ...[
                    Text(controller.selectedMessages.length.toString()),
                  ] else ...[
                    Container(
                      height: 45,
                      width: 45,
                      clipBehavior: Clip.antiAlias,
                      decoration: BoxDecoration(
                        shape: BoxShape.circle,
                        color: AppColors.primaryColor.withValues(alpha: 0.5),
                      ),
                      child: Builder(
                        builder: (context) {
                          final provider = getImageProvider(controller.contact.picture());
                          final fallback = Center(
                            child: Text(
                              controller.contact.name().shortName,
                              style: const TextStyle(color: Colors.white, fontSize: 24),
                            ),
                          );
                          if (provider != null) {
                            return Image(
                              image: provider,
                              fit: BoxFit.cover,
                              errorBuilder: (context, error, stackTrace) => fallback,
                              loadingBuilder: imageLoadingBuilder,
                            );
                          }
                          return fallback;
                        },
                      ),
                    ),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: .start,
                        children: [
                          Text(
                            controller.contact.name(),
                            style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w500),
                          ),
                          Text(
                            controller.contact.about() ?? controller.contact.lnurl(),
                            style: const TextStyle(fontSize: 14),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                          ),
                        ],
                      ),
                    ),
                  ],
                ],
              ),
            ),
          ),
          actions: [
            if (controller.isInSelectionMode) ...[
              if (controller.selectedMessages.length == 1 &&
                  controller.selectedMessages.first.messageData is TextMessageData)
                IconButton(
                  onPressed: () {
                    ClipboardService.setClipBoard(
                      (controller.selectedMessages.first.messageData as TextMessageData).message,
                    );
                    controller.selectedMessages.clear();
                    update(() => controller.isInSelectionMode = false);
                  },
                  icon: const Icon(Icons.copy),
                ),
              IconButton(
                onPressed: () {
                  showDialog(
                    context: context,
                    builder: (context) => AlertDialog(
                      title: const Text('Do you want to delete selected messages?', style: TextStyle(fontSize: 16)),
                      actions: [
                        TextButton(onPressed: () => AppRouter.pop(), child: const Text('No')),
                        TextButton(
                          onPressed: () async {
                            try {
                              startLoader();
                              final res = await ChatService.deleteMessages(
                                controller.selectedMessages.toList(),
                                controller.myId,
                              );

                              if (res) {
                                ToastService.show(
                                  'Message${controller.selectedMessages.length == 1 ? '' : 's'} deleted!',
                                );
                                controller.selectedMessages.clear();
                                controller.isInSelectionMode = false;
                                update();
                                AppRouter.pop();
                              }
                            } finally {
                              stopLoader();
                            }
                          },
                          child: const Text('Yes'),
                        ),
                      ],
                    ),
                  );
                },
                icon: const Icon(Icons.delete_outline, color: Colors.red),
              ),
            ] else
              PopupMenuButton<String>(
                icon: const Icon(Icons.more_vert),
                itemBuilder: (BuildContext context) => [
                  PopupMenuItem(
                    child: const Text('Delete conversation', style: TextStyle(color: Colors.red)),
                    onTap: () async {
                      final res = await showDialog(
                        context: context,
                        builder: (context) => AlertDialog(
                          title: const Text('Do you want to delete all the messages?', style: TextStyle(fontSize: 16)),
                          actions: [
                            TextButton(onPressed: () => AppRouter.pop(false), child: const Text('No')),
                            TextButton(
                              onPressed: () async {
                                try {
                                  startLoader();
                                  final res = await ChatService.deleteMessages(
                                    controller.messages.whereType<ChatMessage>().toList(),
                                    controller.myId,
                                  );
                                  if (res) {
                                    ToastService.show('Conversation deleted!');
                                    update();
                                    await DB.conversationsBox
                                        .get('${selectedWallet.uuid}_${widget.contact.uuid}')
                                        ?.update(deletedAt: Nullable(DateTime.timestamp()));
                                    AppRouter.pop(true);
                                  }
                                } finally {
                                  stopLoader();
                                }
                              },
                              child: const Text('Yes'),
                            ),
                          ],
                        ),
                      );
                      if (res is bool && res) {
                        AppRouter.pop();
                      }
                    },
                  ),
                ],
              ),
          ],
        ),
        body: Column(
          children: [
            Expanded(
              child: Stack(
                children: [
                  NotificationListener<ScrollNotification>(
                    onNotification: (notification) {
                      if (notification is ScrollEndNotification) {
                        controller.markAsReadDeBouncer.call(() => controller.markAsRead());
                      }
                      return false;
                    },
                    child: ListView.builder(
                      reverse: true,
                      itemCount: controller.messages.length,
                      scrollCacheExtent: const ScrollCacheExtent.viewport(5),
                      primary: true,
                      padding: const EdgeInsets.only(top: 12, bottom: 12),
                      itemBuilder: (context, index) => MessageBubble(controller: controller, index: index),
                    ),
                  ),
                  Positioned(
                    bottom: 16,
                    right: 16,
                    child: ValueListenableBuilder(
                      valueListenable: showScrollToBottom,
                      builder: (context, value, child) {
                        if (value) {
                          final scrollController = PrimaryScrollController.of(context);
                          return FloatingActionButton.small(
                            onPressed: () => scrollController.animateTo(
                              0,
                              duration: Duration(milliseconds: scrollController.offset.floor().clamp(0, 1000)),
                              curve: Curves.easeInOut,
                            ),
                            shape: const CircleBorder(),
                            tooltip: 'Scroll to bottom',
                            child: const Icon(Icons.keyboard_arrow_down),
                          );
                        }
                        return const SizedBox.shrink();
                      },
                    ),
                  ),
                ],
              ),
            ),
            Padding(
              padding: const EdgeInsets.only(left: 16, right: 16, bottom: 16),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.end,
                children: [
                  AnimatedSize(
                    duration: const Duration(milliseconds: 300),
                    alignment: Alignment.centerLeft,
                    curve: Curves.fastOutSlowIn,
                    child: SizedBox(
                      width: isKeyboardVisible || (isDesktop && controller.messageController.text.isNotEmpty)
                          ? 0
                          : null,
                      child: Row(
                        spacing: 8,
                        children: [
                          ElevatedButton(
                            style: ElevatedButton.styleFrom(
                              shape: RoundedRectangleBorder(borderRadius: BorderRadiusGeometry.circular(12)),
                              visualDensity: VisualDensity.comfortable,
                            ),
                            onPressed: () => controller.sendPayRequest(context: context),
                            child: const Text('Request'),
                          ),
                          ElevatedButton(
                            style: ElevatedButton.styleFrom(
                              shape: RoundedRectangleBorder(borderRadius: BorderRadiusGeometry.circular(12)),
                              visualDensity: VisualDensity.comfortable,
                            ),
                            onPressed: () => AppRouter.push(SendScreen(address: controller.contact.lnurl())),
                            child: const Text('Pay'),
                          ),
                          const SizedBox.shrink(),
                        ],
                      ),
                    ),
                  ),
                  Expanded(
                    child: Column(
                      children: [
                        if (controller.replyId != null)
                          Container(
                            padding: const EdgeInsets.all(8),
                            decoration: BoxDecoration(
                              color: Colors.grey.shade200.withValues(alpha: 0.7),
                              borderRadius: BorderRadius.circular(12),
                            ),
                            child: Row(
                              children: [
                                Expanded(
                                  child: GestureDetector(
                                    onTap: () {
                                      for (final m in controller.messages.whereType<ChatMessage>()) {
                                        if (m.globalKey.currentContext != null) {
                                          Scrollable.ensureVisible(
                                            m.globalKey.currentContext!,
                                            duration: const Duration(milliseconds: 500),
                                          );
                                          break;
                                        }
                                      }
                                    },
                                    child: IntrinsicHeight(
                                      child: Row(
                                        spacing: 8,
                                        children: [
                                          Container(
                                            decoration: const BoxDecoration(color: AppColors.primaryColor),
                                            width: 4,
                                          ),
                                          Expanded(
                                            child: Builder(
                                              builder: (context) {
                                                final m = DB.chatBox.get(controller.replyId!);
                                                return Column(
                                                  mainAxisSize: MainAxisSize.min,
                                                  crossAxisAlignment: CrossAxisAlignment.start,
                                                  children: [
                                                    if (m == null)
                                                      const Text(
                                                        '*Message deleted*',
                                                        maxLines: 2,
                                                        overflow: TextOverflow.ellipsis,
                                                        style: TextStyle(color: Colors.black),
                                                      )
                                                    else ...[
                                                      Text(
                                                        m.senderId == controller.myId
                                                            ? 'You'
                                                            : controller.contact.name(),
                                                        style: const TextStyle(color: Colors.black),
                                                      ),
                                                      m.createPreview(forReply: true),
                                                    ],
                                                  ],
                                                );
                                              },
                                            ),
                                          ),
                                        ],
                                      ),
                                    ),
                                  ),
                                ),
                                IconButton(
                                  onPressed: () {
                                    controller.messageTextFieldFocusNode.unfocus();
                                    update(() => controller.replyId = null);
                                  },
                                  icon: const Icon(Icons.close),
                                  constraints: const BoxConstraints(maxWidth: 24, maxHeight: 24),
                                  visualDensity: VisualDensity.compact,
                                ),
                              ],
                            ),
                          ),
                        TextFormField(
                          key: controller.messageTextFieldKey,
                          controller: controller.messageController,
                          focusNode: controller.messageTextFieldFocusNode,
                          decoration: const InputDecoration(
                            hintText: 'Enter message',
                            isDense: true,
                            contentPadding: EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                          ),
                          maxLines: 5,
                          minLines: 1,
                          cursorColor: AppColors.primaryColor,
                          textCapitalization: TextCapitalization.sentences,
                          keyboardType: TextInputType.multiline,
                          textInputAction: TextInputAction.newline,
                          onChanged: (value) => update(),
                          maxLength: 5000,
                          buildCounter: (context, {required currentLength, required isFocused, required maxLength}) =>
                              null,
                        ),
                      ],
                    ),
                  ),
                  if (controller.messageController.text.trim().isNotEmpty)
                    Padding(
                      padding: const EdgeInsets.only(left: 8),
                      child: IconButton(
                        style: IconButton.styleFrom(
                          backgroundColor: AppColors.primaryColor.withValues(alpha: 0.1),
                          padding: const EdgeInsets.all(12),
                        ),
                        icon: Transform.rotate(
                          angle: -0.8,
                          child: const Icon(Icons.send_rounded, color: AppColors.primaryColor),
                        ),
                        onPressed: () => controller.sendMessage(),
                      ),
                    ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

final now = DateTime.now();
final today = DateTime(now.year, now.month, now.day);
final yesterday = today.subtract(const Duration(days: 1));

class MessageBubble extends StatefulWidget {
  const MessageBubble({this.message, this.controller, this.index, super.key})
    : assert((controller != null && index != null) || message != null, 'Either pass message or controller and index');

  final ChatMessage? message;
  final ChatController? controller;
  final int? index;

  @override
  State<MessageBubble> createState() => _MessageBubbleState();
}

class _MessageBubbleState extends State<MessageBubble> with AutomaticKeepAliveClientMixin {
  double dismissProgress = 0;
  OverlayEntry? emojiOverlay;

  void addEmojiOverlay(ChatMessage message, Offset offset) {
    if (widget.controller == null) return;
    emojiOverlay = OverlayEntry(
      builder: (context) => EmojiReactionOverlay(
        dy: offset.dy,
        alignment: message.senderId == selectedWallet.uuid ? Alignment.centerRight : Alignment.centerLeft,
        onEmojiSelected: (emoji) {
          removeEmojiOverlay();
          if (emoji == '➕') {
            final color = context.themedColor(bright: Colors.white, dark: AppColors.darkCardColor);
            final invertedColor = context.themedColor(bright: AppColors.darkCardColor, dark: Colors.white);
            showModalBottomSheet(
              context: context,
              isScrollControlled: true,
              backgroundColor: color,
              useSafeArea: true,
              isDismissible: false,
              builder: (context) => Padding(
                padding: context.keyboardPadding + const EdgeInsets.all(12),
                child: EmojiPicker(
                  key: widget.controller!.emojiPickerKey,
                  config: Config(
                    bottomActionBarConfig: BottomActionBarConfig(
                      showBackspaceButton: false,
                      buttonIconColor: AppColors.primaryColor,
                      backgroundColor: color,
                      buttonColor: color,
                    ),
                    emojiViewConfig: EmojiViewConfig(backgroundColor: color),
                    searchViewConfig: SearchViewConfig(backgroundColor: color, buttonIconColor: invertedColor),
                    categoryViewConfig: CategoryViewConfig(backgroundColor: color, dividerColor: Colors.transparent),
                    viewOrderConfig: const ViewOrderConfig(
                      top: EmojiPickerItem.searchBar,
                      bottom: EmojiPickerItem.categoryBar,
                    ),
                  ),
                  onEmojiSelected: (category, emoji) async {
                    AppRouter.pop();
                    await widget.controller!.addReaction(message, emoji.emoji);
                  },
                ),
              ),
            );
          } else {
            widget.controller!.addReaction(message, emoji);
          }
        },
        onDismiss: removeEmojiOverlay,
      ),
    );

    Overlay.of(context).insert(emojiOverlay!);
  }

  void removeEmojiOverlay() {
    emojiOverlay?.remove();
    emojiOverlay = null;
  }

  @override
  Widget build(BuildContext context) {
    super.build(context);
    Widget messageWidget = const SizedBox.shrink();
    final message = widget.message ?? widget.controller!.messages[widget.index!];

    if (message is TxMessage) {
      final isSent = !message.tx.isIncoming;
      final tx = message.tx;
      messageWidget = Align(
        alignment: isSent ? Alignment.centerRight : Alignment.centerLeft,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
          child: SizedBox(
            width: (context.screenWidth * 0.4).clamp(0, 600),
            child: GestureDetector(
              onTap: () => AppRouter.push(
                TransactionDetailScreen(
                  id: IdWithWallet(walletId: tx.walletId, id: tx.txId),
                ),
              ),
              child: Card(
                shape: RoundedRectangleBorder(borderRadius: BorderRadiusGeometry.circular(12)),
                child: Padding(
                  padding: const EdgeInsets.all(8),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      AmountText(
                        amountSat: tx.amount.abs(),
                        showFiat: true,
                        atTime: tx.txTimestamp,
                        btcStyle: const TextStyle(fontSize: 24, fontWeight: FontWeight.bold),
                        fiatStyle: TextStyle(
                          fontSize: 14,
                          color: context.themedColor(bright: Colors.black54, dark: Colors.white54),
                          fontWeight: FontWeight.w500,
                        ),
                      ),
                      const SizedBox(height: 8),
                      Text(
                        '${!tx.isCompleted
                            ? 'Pending'
                            : isSent
                            ? 'Sent'
                            : 'Received'}${tx.note.trim().isNotEmpty ? ' : ${tx.note.trim()}' : ''}',
                        style: TextStyle(
                          fontSize: 12,
                          color: context.themedColor(bright: Colors.black54, dark: Colors.white54),
                        ),
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                      ),
                      if (tx.memo.isNotEmpty || tx.note.isNotEmpty)
                        Text(tx.memo.isNotEmpty ? tx.memo : tx.note, maxLines: 1, overflow: TextOverflow.ellipsis),
                      const SizedBox(height: 8),
                      Row(
                        spacing: 6,
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Icon(Icons.check_circle, color: tx.isCompleted ? Colors.green : Colors.grey, size: 16),
                          Expanded(
                            child: Text(
                              DateFormat('h:mm a').format(message.timestamp),
                              style: const TextStyle(color: Colors.grey, fontSize: 12),
                            ),
                          ),
                          const Icon(Icons.chevron_right),
                        ],
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
        ),
      );
    } else if (message is ChatMessage) {
      final isSent = message.senderId == selectedWallet.uuid;

      final reactionWidget = message.reaction != null
          ? Container(
              decoration: BoxDecoration(color: AppColors.primaryColor.withValues(alpha: 0.2), shape: BoxShape.circle),
              padding: const EdgeInsets.all(6),
              child: Text(message.reaction!),
            )
          : null;

      messageWidget = Stack(
        children: [
          const Positioned.fill(child: ColoredBox(color: Colors.transparent)),
          Align(
            alignment: isSent ? Alignment.centerRight : Alignment.centerLeft,
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  if (isSent && reactionWidget != null) ...[reactionWidget, const SizedBox(width: 8)],
                  Container(
                    decoration: BoxDecoration(
                      color: isSent ? AppColors.primaryColor : Theme.of(context).colorScheme.surfaceContainerLow,
                      borderRadius: BorderRadius.circular(12),
                    ),
                    padding: const EdgeInsets.only(left: 12, top: 8, bottom: 8, right: 8),
                    constraints: BoxConstraints(maxWidth: (context.screenWidth * 0.8).clamp(0, 600)),
                    child: Padding(
                      padding: const EdgeInsets.only(right: 4),
                      child: IntrinsicWidth(
                        child: Column(
                          crossAxisAlignment: .stretch,
                          spacing: 2,
                          children: [
                            if (message.replyOfId != null)
                              Container(
                                decoration: BoxDecoration(
                                  color: Colors.grey.shade200.withValues(alpha: 0.7),
                                  borderRadius: BorderRadius.circular(8),
                                ),
                                clipBehavior: Clip.hardEdge,
                                child: GestureDetector(
                                  onTap: widget.controller == null
                                      ? null
                                      : () {
                                          for (final m in widget.controller!.messages.whereType<ChatMessage>()) {
                                            if (m.uuid == message.replyOfId && m.globalKey.currentContext != null) {
                                              Scrollable.ensureVisible(
                                                m.globalKey.currentContext!,
                                                duration: const Duration(milliseconds: 500),
                                              );
                                              break;
                                            }
                                          }
                                        },
                                  child: IntrinsicHeight(
                                    child: Row(
                                      mainAxisSize: MainAxisSize.min,
                                      spacing: 8,
                                      children: [
                                        Container(
                                          decoration: BoxDecoration(
                                            color: isSent
                                                ? Theme.of(context).colorScheme.surfaceContainerLow
                                                : AppColors.primaryColor,
                                          ),
                                          width: 4,
                                        ),
                                        Expanded(
                                          child: Builder(
                                            builder: (context) {
                                              final m = DB.chatBox.get(message.replyOfId!);
                                              return Column(
                                                mainAxisSize: MainAxisSize.min,
                                                crossAxisAlignment: CrossAxisAlignment.start,
                                                children: [
                                                  if (m == null)
                                                    const Text(
                                                      '*Message deleted*',
                                                      maxLines: 2,
                                                      overflow: TextOverflow.ellipsis,
                                                      style: TextStyle(color: Colors.black),
                                                    )
                                                  else ...[
                                                    if (widget.controller != null)
                                                      Text(
                                                        m.senderId == widget.controller!.myId
                                                            ? 'You'
                                                            : widget.controller!.contact.name(),
                                                        style: const TextStyle(color: Colors.black),
                                                      ),
                                                    m.createPreview(forReply: true),
                                                  ],
                                                ],
                                              );
                                            },
                                          ),
                                        ),
                                      ],
                                    ),
                                  ),
                                ),
                              ),
                            message.createPreview(),
                          ],
                        ),
                      ),
                    ),
                  ),
                  if (!isSent && reactionWidget != null) ...[
                    const SizedBox(width: 8),
                    InkWell(
                      onTap: () {
                        if (message.reaction == null) return;
                        ChatService.setReaction(message: message, reaction: message.reaction!, remove: true);
                      },
                      child: reactionWidget,
                    ),
                  ],
                ],
              ),
            ),
          ),

          if (widget.controller != null && widget.controller!.selectedMessages.contains(message))
            Positioned.fill(child: Container(color: Colors.grey.withValues(alpha: 0.4))),
        ],
      );

      if (widget.controller != null) {
        final controller = widget.controller!;
        messageWidget = Dismissible(
          key: message.globalKey,
          dismissThresholds: const {DismissDirection.startToEnd: 0.4, DismissDirection.endToStart: 0.4},
          background: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            child: Row(
              children: [
                Transform.scale(scale: dismissProgress * 2, child: const Icon(Icons.reply_outlined)),
                const Expanded(child: SizedBox.shrink()),
                Transform.scale(scale: dismissProgress * 2, child: const Icon(Icons.info_outline)),
              ],
            ),
          ),
          confirmDismiss: (direction) {
            if (direction == DismissDirection.startToEnd) {
              controller.replyId = message.uuid;
              controller.updateCallback();
            } else if (direction == DismissDirection.endToStart) {
              AppRouter.push(MessageInfoScreen(message: message));
            }
            return Future.value(false);
          },
          onUpdate: (details) {
            update(() => dismissProgress = details.progress);
          },
          child: AnimatedContainer(
            duration: const Duration(milliseconds: 1500),
            color: message.receiverId == controller.myId && message.seenAtUTC == null
                ? AppColors.primaryColor.withValues(alpha: 0.5)
                : Colors.transparent,
            child: GestureDetector(
              onLongPress: () {
                if (!controller.isInSelectionMode) {
                  controller.isInSelectionMode = true;
                }
                if (controller.selectedMessages.contains(message)) {
                  controller.selectedMessages.remove(message);
                } else {
                  controller.selectedMessages.add(message);
                }
                if (controller.selectedMessages.isEmpty) {
                  controller.isInSelectionMode = false;
                }
                controller.updateCallback();
              },
              onTap: () {
                if (controller.isInSelectionMode) {
                  if (controller.selectedMessages.contains(message)) {
                    controller.selectedMessages.remove(message);
                  } else {
                    controller.selectedMessages.add(message);
                  }
                  if (controller.selectedMessages.isEmpty) {
                    controller.isInSelectionMode = false;
                  }
                  controller.updateCallback();
                  return;
                }

                if (isSent) return;
                final renderBox = message.globalKey.currentContext?.findRenderObject() as RenderBox?;
                if (renderBox == null) return;
                final offset = renderBox.localToGlobal(Offset.zero);

                addEmojiOverlay(message, offset);
              },
              child: messageWidget,
            ),
          ),
        );
      }
    }

    if (widget.controller != null) {
      DateTime lastDate = widget.controller!.messages.elementAtOrNull(widget.index! + 1)?.timestamp ?? DateTime(1970);
      lastDate = DateTime(lastDate.year, lastDate.month, lastDate.day);
      final currentDate = DateTime(message.timestamp.year, message.timestamp.month, message.timestamp.day);

      if (lastDate != currentDate) {
        return Column(
          children: [
            Center(
              child: Card(
                margin: const EdgeInsets.symmetric(vertical: 4),
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8.0)),
                child: Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
                  child: Text(message.timeString()),
                ),
              ),
            ),
            messageWidget,
          ],
        );
      }
    }

    return messageWidget;
  }

  @override
  bool get wantKeepAlive => widget.message != null
      ? false
      : widget.controller!.messages[widget.index!] is ChatMessage &&
            widget.controller!.repliedIds.contains((widget.controller!.messages[widget.index!] as ChatMessage).uuid);
}

class EmojiReactionOverlay extends StatefulWidget {
  const EmojiReactionOverlay({
    required this.dy,
    required this.alignment,
    required this.onEmojiSelected,
    required this.onDismiss,
    super.key,
  });

  final double dy;
  final Alignment alignment;
  final Function(String) onEmojiSelected;
  final VoidCallback onDismiss;

  @override
  EmojiReactionOverlayState createState() => EmojiReactionOverlayState();
}

class EmojiReactionOverlayState extends State<EmojiReactionOverlay> with SingleTickerProviderStateMixin {
  late final AnimationController animationController = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 200),
  );
  late final Animation<double> scaleAnimation;
  final List<String> emojis = [];

  @override
  void initState() {
    EmojiPickerUtils().getRecentEmojis().then((recents) async {
      final Map<String, RecentEmoji> recentEmojis = {};
      final fixEmojis = {
        RecentEmoji(const Emoji('👍', '', hasSkinTone: true), 6),
        RecentEmoji(const Emoji('❤️', ''), 5),
        RecentEmoji(const Emoji('😂', ''), 4),
        RecentEmoji(const Emoji('😮', ''), 3),
        RecentEmoji(const Emoji('😢', ''), 2),
        RecentEmoji(const Emoji('😠', ''), 1),
      };
      recentEmojis.addAll(Map.fromEntries(recents.map((e) => MapEntry(e.emoji.emoji, e))));
      recentEmojis.addAll(Map.fromEntries(fixEmojis.map((e) => MapEntry(e.emoji.emoji, e))));
      final emojis = recentEmojis.values.toList();
      emojis.sort((a, b) => b.counter.compareTo(a.counter));
      this.emojis.addAll(emojis.take(10).map((e) => e.emoji.emoji));
      this.emojis.add('➕');
      update();
    });

    scaleAnimation = Tween<double>(begin: 0.0, end: 1.0).animate(
      CurvedAnimation(parent: animationController, curve: Curves.easeOutBack, reverseCurve: Curves.easeOutBack),
    );
    animationController.forward();
    super.initState();
  }

  @override
  void dispose() {
    animationController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Stack(
      children: [
        Positioned.fill(
          child: GestureDetector(
            onPanStart: (_) {
              animationController.reverse();
              Future.delayed(const Duration(milliseconds: 200), () => widget.onDismiss());
            }, // Dismiss the overlay on outside click
            child: Container(color: Colors.transparent),
          ),
        ),
        Positioned(
          top: widget.dy - 48,
          left: 8,
          right: 8,
          child: Align(
            alignment: widget.alignment,
            child: ScaleTransition(
              scale: scaleAnimation,
              child: Card(
                elevation: 5,
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(30)),
                child: SingleChildScrollView(
                  scrollDirection: Axis.horizontal,
                  padding: const EdgeInsets.symmetric(horizontal: 12),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      for (final emoji in emojis)
                        IconButton(
                          onPressed: () {
                            animationController.reverse();
                            Future.delayed(const Duration(milliseconds: 200), () => widget.onEmojiSelected(emoji));
                          },
                          padding: EdgeInsets.zero,
                          visualDensity: VisualDensity.compact,
                          icon: Text(emoji, style: const TextStyle(fontSize: 24)),
                        ),
                    ],
                  ),
                ),
              ),
            ),
          ),
        ),
      ],
    );
  }
}
