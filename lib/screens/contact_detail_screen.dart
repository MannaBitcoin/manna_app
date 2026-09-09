import 'package:flutter/material.dart';
import 'package:flutter_svg/flutter_svg.dart';
import 'package:manna/app_state.dart';
import 'package:manna/models/account.dart';
import 'package:manna/models/chat_message.dart';
import 'package:manna/models/contact.dart';
import 'package:manna/models/transaction.dart';
import 'package:manna/router.dart';
import 'package:manna/screens/chat_screen.dart';
import 'package:manna/screens/image_preview_screen.dart';
import 'package:manna/screens/send_screen.dart';
import 'package:manna/services/db.dart';
import 'package:manna/services/db_service.dart';
import 'package:manna/theme.dart';
import 'package:manna/utils/constants.dart';
import 'package:manna/utils/extensions.dart';
import 'package:manna/utils/state_extension.dart';
import 'package:manna/utils/toast_service.dart';
import 'package:manna/widgets/bottom sheets/contact_bottom_sheet.dart';
import 'package:manna/widgets/shimmer.dart';
import 'package:manna/widgets/transaction_card.dart';
import 'package:manna_core/manna_core.dart';
import 'package:url_launcher/url_launcher_string.dart';

class ContactDetailScreen extends StatefulWidget {
  const ContactDetailScreen({required this.contact, this.showOriginal = false, super.key});

  final Contact contact;
  final bool showOriginal;

  @override
  State<ContactDetailScreen> createState() => _ContactDetailScreenState();
}

class _ContactDetailScreenState extends State<ContactDetailScreen> {
  final List<Transaction> transactions = [];
  @override
  void initState() {
    init();
    super.initState();
  }

  Future<void> init() async {
    transactions.addAll(
      DB.transactions.values.where(
        (t) =>
            t.walletId == contact.walletId &&
            (t.senderUUID == contact.uuid ||
                t.receiverUserNameOrUUID == contact.uuid ||
                t.receiverUserNameOrUUID == contact.lnurl()),
      ),
    );
    transactions.sort(
      (a, b) => a.confirmationTimestamp == b.confirmationTimestamp
          ? b.timestamp.compareTo(a.timestamp)
          : b.txTimestamp.compareTo(a.txTimestamp),
    );

    // update manna contacts
    if (widget.contact.lnurl().isMannaUserName && DB.contacts.containsKey(widget.contact.metaId)) {
      final wallet = DB.allWallets
          .where((w) => w.uuid == widget.contact.walletId && w.type == widget.contact.walletType)
          .firstOrNull;
      if (wallet != null) {
        final c = await DbService.getContact(uuid: widget.contact.uuid, wallet: wallet);
        c?.isFavorite = widget.contact.isFavorite;
        await c?.save();
      }
    }
    update();
  }

  Contact get contact => DB.contacts[widget.contact.metaId] ?? widget.contact;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Contact detail'),
        actions: [
          IconButton(
            onPressed: () {
              contact.isFavorite = !contact.isFavorite;
              contact.save();
              update();
            },
            icon: Icon(
              contact.isFavorite ? Icons.star : Icons.star_border,
              color: contact.isFavorite ? AppColors.primaryColor : null,
            ),
          ),
          if (!widget.showOriginal)
            PopupMenuButton<String>(
              icon: const Icon(Icons.more_vert),
              itemBuilder: (BuildContext context) => [
                const PopupMenuItem(
                  value: 'edit',
                  padding: EdgeInsets.only(left: 12),
                  child: Text('Edit', style: TextStyle(fontSize: 16)),
                ),
                const PopupMenuItem(
                  value: 'delete',
                  padding: EdgeInsets.only(left: 12),
                  child: Text('Delete', style: TextStyle(fontSize: 16, color: Colors.red)),
                ),
              ],
              onSelected: (value) async {
                switch (value) {
                  case 'edit':
                    final res = await showModalBottomSheet(
                      context: context,
                      showDragHandle: true,
                      isScrollControlled: true,
                      useSafeArea: true,
                      isDismissible: false,
                      shape: const RoundedRectangleBorder(
                        borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
                      ),
                      routeSettings: const RouteSettings(name: 'ContactBottomSheet'),
                      builder: (context) => ContactBottomSheet(contact: contact),
                    );
                    if (res is bool && res) update();
                  case 'delete':
                    final res = await showDialog<bool>(
                      context: context,
                      builder: (context) => AlertDialog(
                        title: Text(
                          'Are you sure you want to delete ${contact.name()}?',
                          style: const TextStyle(fontSize: 16),
                        ),
                        actions: [
                          TextButton(onPressed: () => AppRouter.pop(false), child: const Text('No')),
                          TextButton(
                            onPressed: () async {
                              await contact.delete();
                              ToastService.show('Contact deleted successfully!');
                              AppRouter.pop(true);
                            },
                            child: const Text('Yes'),
                          ),
                        ],
                      ),
                    );
                    if (res ?? false) AppRouter.pop(res);
                }
              },
            ),
        ],
      ),
      body: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 600),
          child: Column(
            children: [
              Expanded(
                child: SingleChildScrollView(
                  padding: const EdgeInsets.all(16),
                  child: Column(
                    spacing: 12,
                    children: [
                      Stack(
                        children: [
                          Padding(
                            padding: const EdgeInsets.only(bottom: 50),
                            child: AspectRatio(
                              aspectRatio: 3,
                              child: DecoratedBox(
                                decoration: BoxDecoration(
                                  color: AppColors.primaryColor.withValues(alpha: 0.2),
                                  borderRadius: BorderRadius.circular(16),
                                ),
                                child: Builder(
                                  builder: (context) {
                                    final fallBack = Center(
                                      child: ShimmerWidget.fromColors(
                                        baseColor: AppColors.primaryColor,
                                        highlightColor: Colors.grey.shade100,
                                        child: SvgPicture.asset(AppImages.logoWhiteAssetSVG, width: 156),
                                      ),
                                    );
                                    final provider = getImageProvider(contact.banner(original: widget.showOriginal));
                                    if (provider != null) {
                                      return GestureDetector(
                                        onTap: () => AppRouter.push(
                                          ImagePreviewScreen(
                                            appBarTitle: contact.name(original: widget.showOriginal),
                                            image: contact.banner(original: widget.showOriginal)!,
                                          ),
                                        ),
                                        child: ClipRRect(
                                          borderRadius: BorderRadius.circular(16),
                                          child: Image(
                                            image: provider,
                                            fit: BoxFit.cover,
                                            errorBuilder: (context, error, stackTrace) => fallBack,
                                          ),
                                        ),
                                      );
                                    }
                                    return fallBack;
                                  },
                                ),
                              ),
                            ),
                          ),
                          Positioned(
                            bottom: 0,
                            left: 0,
                            right: 0,
                            child: Center(
                              child: Stack(
                                children: [
                                  if (!widget.showOriginal &&
                                      contact.customizedContact != null &&
                                      contact.picture(original: true) != null &&
                                      contact.customizedContact!.picture() != contact.picture(original: true))
                                    Container(
                                      height: 100,
                                      width: 100,
                                      margin: const EdgeInsets.only(left: 36),
                                      clipBehavior: Clip.antiAlias,
                                      decoration: BoxDecoration(
                                        shape: BoxShape.circle,
                                        color: AppColors.primaryColor.withValues(alpha: 0.5),
                                      ),
                                      child: Builder(
                                        builder: (context) {
                                          final provider = getImageProvider(contact.picture(original: true));
                                          final fallBack = Center(
                                            child: Text(
                                              contact.name(original: true).shortName,
                                              style: const TextStyle(color: Colors.white, fontSize: 24),
                                            ),
                                          );
                                          if (provider != null) {
                                            return GestureDetector(
                                              onTap: () => AppRouter.push(
                                                ImagePreviewScreen(
                                                  appBarTitle: contact.name(original: true),
                                                  image: contact.picture(original: true)!,
                                                ),
                                              ),
                                              child: Image(
                                                image: provider,
                                                fit: BoxFit.cover,
                                                errorBuilder: (context, error, stackTrace) => fallBack,
                                              ),
                                            );
                                          }
                                          return fallBack;
                                        },
                                      ),
                                    ),
                                  Container(
                                    height: 100,
                                    width: 100,
                                    clipBehavior: Clip.antiAlias,
                                    decoration: BoxDecoration(
                                      shape: BoxShape.circle,
                                      color: AppColors.primaryColor.withValues(alpha: 0.5),
                                    ),
                                    child: Builder(
                                      builder: (context) {
                                        final provider = getImageProvider(
                                          contact.picture(original: widget.showOriginal),
                                        );
                                        final fallback = Center(
                                          child: Text(
                                            contact.name(original: widget.showOriginal).shortName,
                                            style: const TextStyle(color: Colors.white, fontSize: 24),
                                          ),
                                        );
                                        if (provider != null) {
                                          return GestureDetector(
                                            onTap: () => AppRouter.push(
                                              ImagePreviewScreen(
                                                appBarTitle: contact.name(original: widget.showOriginal),
                                                image: contact.picture(original: widget.showOriginal)!,
                                              ),
                                            ),
                                            child: Image(
                                              image: provider,
                                              fit: BoxFit.cover,
                                              errorBuilder: (context, error, stackTrace) => fallback,
                                            ),
                                          );
                                        }
                                        return fallback;
                                      },
                                    ),
                                  ),
                                ],
                              ),
                            ),
                          ),
                        ],
                      ),
                      Text(
                        contact.name(original: widget.showOriginal),
                        textAlign: TextAlign.center,
                        style: const TextStyle(fontSize: 20, fontWeight: FontWeight.bold),
                      ),
                      if (contact.about(original: widget.showOriginal)?.isNotEmpty ?? false)
                        Text(
                          contact.about(original: widget.showOriginal)!.trim(),
                          textAlign: TextAlign.center,
                          style: const TextStyle(color: Colors.grey),
                        ),
                      if (contact.lnurl(original: widget.showOriginal).isNotEmpty)
                        SelectableText(
                          contact.lnurl(original: widget.showOriginal, wrap: true),
                          textAlign: TextAlign.center,
                          style: const TextStyle(
                            fontSize: 18,
                            fontWeight: FontWeight.bold,
                            color: AppColors.primaryColor,
                          ),
                          onTap: () =>
                              AppRouter.push(SendScreen(address: contact.lnurl(original: widget.showOriginal))),
                        ),
                      if (contact.npub(original: widget.showOriginal)?.isNotEmpty ?? false)
                        SelectableText(
                          contact.npub(original: widget.showOriginal)!,
                          textAlign: TextAlign.center,
                          style: const TextStyle(color: AppColors.primaryColor, fontSize: 12),
                          onTap: () =>
                              launchUrlString('https://primal.net/p/${contact.npub(original: widget.showOriginal)!}'),
                        ),
                      Column(
                        spacing: 8,
                        children: [
                          if (!widget.showOriginal && selectedWallet.type == WalletType.full) ...[
                            if (contact.lnurl(original: widget.showOriginal).isMannaUserName)
                              SizedBox(
                                width: double.infinity,
                                child: ElevatedButton(
                                  style: ElevatedButton.styleFrom(visualDensity: VisualDensity.standard),
                                  onPressed: () => AppRouter.push(ChatScreen(contact: contact)),
                                  child: const Text('Message'),
                                ),
                              ),
                            Row(
                              spacing: 8,
                              children: [
                                if (contact.lnurl(original: widget.showOriginal).isMannaUserName)
                                  Expanded(
                                    child: ElevatedButton(
                                      style: ElevatedButton.styleFrom(visualDensity: VisualDensity.standard),
                                      onPressed: () => AppRouter.push(
                                        ChatScreen(
                                          contact: contact,
                                          messageToDeliver: const PayReqMessageData(
                                            address: '',
                                            amount: 0,
                                            isSat: true,
                                            memo: '',
                                          ),
                                        ),
                                      ),
                                      child: const Text('Request'),
                                    ),
                                  ),
                                if (contact.lnurl(original: widget.showOriginal).isNotEmpty)
                                  Expanded(
                                    child: ElevatedButton(
                                      style: ElevatedButton.styleFrom(visualDensity: VisualDensity.standard),
                                      onPressed: () => AppRouter.push(
                                        SendScreen(address: contact.lnurl(original: widget.showOriginal)),
                                      ),
                                      child: const Text('Pay'),
                                    ),
                                  ),
                              ],
                            ),
                          ],
                          if (contact.customizedContact != null && !contact.isEqual(contact.customizedContact!)) ...[
                            if (widget.showOriginal)
                              SizedBox(
                                width: double.infinity,
                                child: ElevatedButton(
                                  style: ElevatedButton.styleFrom(visualDensity: VisualDensity.standard),
                                  onPressed: () async {
                                    final data = await showDialog<bool>(
                                      context: context,
                                      builder: (context) => AlertDialog(
                                        title: Text.rich(
                                          TextSpan(
                                            text: 'Are you sure you want to delete local copy of saved contact ',
                                            children: [
                                              TextSpan(
                                                text: widget.contact.name(),
                                                style: const TextStyle(
                                                  color: AppColors.primaryColor,
                                                  fontWeight: FontWeight.bold,
                                                  fontSize: 18,
                                                ),
                                              ),
                                              const TextSpan(text: ' and import the original contact?'),
                                            ],
                                          ),
                                          style: const TextStyle(fontSize: 16),
                                        ),
                                        actions: [
                                          TextButton(onPressed: () => AppRouter.pop(false), child: const Text('No')),
                                          TextButton(
                                            onPressed: () async {
                                              contact.customizedContact = null;
                                              // don't replace with save
                                              final id = contact.metaId;
                                              await DB.contactsBox.put(id.toString(), contact);
                                              final c = DB.contactsBox.get(id.toString());
                                              if (c != null) {
                                                DB.contacts[id] = c;
                                              }
                                              ToastService.show('Contact overwritten!');
                                              AppRouter.pop(true);
                                            },
                                            child: const Text('Yes'),
                                          ),
                                        ],
                                      ),
                                    );
                                    if (data ?? false) AppRouter.pop(data);
                                  },
                                  child: const Text('Import'),
                                ),
                              )
                            else
                              SizedBox(
                                width: double.infinity,
                                child: ElevatedButton(
                                  style: ElevatedButton.styleFrom(visualDensity: VisualDensity.standard),
                                  onPressed: () async {
                                    final res = await AppRouter.push(
                                      ContactDetailScreen(contact: contact, showOriginal: true),
                                    );
                                    if (res is bool && res) AppRouter.pop();
                                  },
                                  child: const Text('See original contact', textAlign: TextAlign.center),
                                ),
                              ),
                          ],
                        ],
                      ),
                      const Align(
                        alignment: Alignment.centerLeft,
                        child: Text('Transactions', style: TextStyle(fontSize: 16, fontWeight: FontWeight.w500)),
                      ),
                      transactions.isNotEmpty
                          ? ListView.builder(
                              shrinkWrap: true,
                              physics: const NeverScrollableScrollPhysics(),
                              padding: const EdgeInsets.only(bottom: 16),
                              itemCount: transactions.length,
                              itemBuilder: (context, index) =>
                                  TransactionCard(tx: transactions[index], hideAmount: AppState.isPrivacyModeOn),
                            )
                          : SizedBox(
                              height: 100,
                              child: Center(
                                child: Text(
                                  "You don't have any transactions with ${contact.name()} yet!",
                                  textAlign: TextAlign.center,
                                ),
                              ),
                            ),
                    ],
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
