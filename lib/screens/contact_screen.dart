import 'dart:async';
import 'dart:io';

import 'package:croppy/croppy.dart';
import 'package:flutter/material.dart';
import 'package:flutter_svg/flutter_svg.dart';
import 'package:manna/app_state.dart';
import 'package:manna/globals.dart';
import 'package:manna/models/account.dart';
import 'package:manna/models/chat_message.dart';
import 'package:manna/models/contact.dart';
import 'package:manna/router.dart';
import 'package:manna/screens/chat_screen.dart';
import 'package:manna/screens/contact_detail_screen.dart';
import 'package:manna/screens/image_preview_screen.dart';
import 'package:manna/services/chat_service.dart';
import 'package:manna/services/clipboard_service.dart';
import 'package:manna/services/db.dart';
import 'package:manna/services/db_service.dart';
import 'package:manna/services/media_service.dart';
import 'package:manna/services/nostr_service.dart';
import 'package:manna/theme.dart';
import 'package:manna/utils/constants.dart';
import 'package:manna/utils/de_bouncer.dart';
import 'package:manna/utils/extensions.dart';
import 'package:manna/utils/state_extension.dart';
import 'package:manna/utils/toast_service.dart';
import 'package:manna/utils/util.dart';
import 'package:manna/widgets/bottom sheets/contact_bottom_sheet.dart';
import 'package:manna/widgets/bottom sheets/nostr_import_bottom_sheet.dart';
import 'package:manna_core/manna_core.dart';
import 'package:text_search/text_search.dart';

class ContactScreen extends StatefulWidget {
  const ContactScreen({this.messageToDeliver, this.showMessagePage = false, super.key});

  final MessageData? messageToDeliver;
  final bool showMessagePage;

  @override
  State<ContactScreen> createState() => _ContactScreenState();
}

class _ContactScreenState extends State<ContactScreen> with SingleTickerProviderStateMixin {
  final searchController = TextEditingController();
  final DeBouncer searchDeBouncer = DeBouncer(const Duration(milliseconds: 500));
  List<Contact> mannaContacts = [];
  List<Contact> filteredContacts = [];

  List<Contact> selectedContacts = [];
  bool isInSelectionMode = false;

  int pageIndex = 0;
  final pageController = PageController();
  late final tabController = TabController(length: 3, vsync: this);
  StreamSubscription? conversationSubscription;
  final Map<String, DateTime> contactSortOrder = {};

  final currentWalletId = selectedWallet.uuid;

  @override
  void initState() {
    if (widget.showMessagePage) {
      postFrameCallBack(
        () => pageController.animateToPage(1, duration: const Duration(milliseconds: 300), curve: Curves.easeInOut),
      );
    }

    updateConversation();
    conversationSubscription = DB.conversationsBox.watch().listen((_) => update());

    final lastSyncedNpub = AppState.prefs.getString('lastSyncedNpub');
    if (lastSyncedNpub?.isNotEmpty ?? false) {
      NostrService.syncNostrContacts(lastSyncedNpub!);
    }

    final Map<String, String> contactIdMap = {};
    final currentWalletType = selectedWallet.type;
    for (final c in DB.contacts.values.where(
      (c) => c.uuid != currentWalletId && c.walletId == currentWalletId && c.walletType == currentWalletType,
    )) {
      contactIdMap[c.uuid] = c.uuid;
      contactIdMap[c.lnurl()] = c.uuid;
    }
    for (final tx in DB.transactions.values) {
      if (tx.walletId != currentWalletId) continue;
      final txTime = tx.timestamp;

      // holy heck, don't touch these condition
      final senderId = contactIdMap[tx.senderUUID];
      if (senderId != null && (contactSortOrder[senderId]?.isBefore(txTime) ?? true)) {
        contactSortOrder[senderId] = txTime;
      }
      final receiverId = contactIdMap[tx.receiverUserNameOrUUID];
      if (receiverId != null && (contactSortOrder[receiverId]?.isBefore(txTime) ?? true)) {
        contactSortOrder[receiverId] = txTime;
      }
    }

    refreshData();

    ChatService.sync(walletId: currentWalletId);
    super.initState();
  }

  @override
  void dispose() {
    conversationSubscription?.cancel();
    searchController.dispose();
    pageController.dispose();
    tabController.dispose();
    super.dispose();
  }

  void refreshData() {
    final search = searchController.text.trim();

    final Map<String, Contact> contacts = {};
    for (final c in mannaContacts) {
      contacts[c.uuid] = c;
    }

    final currentWalletType = selectedWallet.type;
    final savedContacts = DB.contacts.values.where(
      (c) => c.walletId == currentWalletId && c.walletType == currentWalletType,
    );
    if (search.isNotEmpty) {
      final searchRes = TextSearch(
        savedContacts.map((e) => TextSearchItem.fromTerms(e, [e.name(), e.lnurl()].nonNulls)).toList(),
      ).fastSearch(search);
      for (final c in searchRes) {
        contacts[c.uuid] = c;
      }
    } else {
      for (final c in savedContacts) {
        contacts[c.uuid] = c;
      }
    }

    contacts.remove(currentWalletId);
    filteredContacts = contacts.values.toList();

    filteredContacts.sort((a, b) {
      // favorites first
      if (b.isFavorite && !a.isFavorite) return 1;
      if (a.isFavorite && !b.isFavorite) return -1;

      final aTxTime = contactSortOrder[a.uuid];
      final bTxTime = contactSortOrder[b.uuid];

      // sort by descending last tx time
      if (aTxTime != null && bTxTime != null) return bTxTime.compareTo(aTxTime);
      // Push contacts without transactions to the end: If only `a` has a transaction time, `a` comes before `b`
      if (aTxTime != null) return -1;
      // If only `b` has a transaction time, `b` comes before `a`
      if (bTxTime != null) return 1;

      // Sort contacts with no transactions: puts `isMannaUser` at the top of this group
      if (b.isMannaUser && !a.isMannaUser) return 1;
      if (a.isMannaUser && !b.isMannaUser) return -1;

      return a.name().compareTo(b.name());
    });
    update();
  }

  @override
  Widget build(BuildContext context) {
    final currentAccount = selectedAccount;
    final conversationCount = DB.conversationsBox.values
        .map((e) => e.myUUID == currentAccount.currentWallet.uuid ? e.unreadCount : 0)
        .fold(0, (p, e) => p + e);

    return Scaffold(
      floatingActionButton: pageIndex == 0
          ? FloatingActionButton(
              onPressed: () {},
              child: SizedBox.expand(
                child: PopupMenuButton(
                  itemBuilder: (context) => [
                    const PopupMenuItem(
                      value: 1,
                      child: ListTile(leading: Icon(Icons.add, size: 32), title: Text('Create new contact')),
                    ),
                    PopupMenuItem(
                      value: 2,
                      child: ListTile(
                        leading: Image.asset(
                          AppImages.nostr,
                          width: 32,
                          color: context.isDarkMode ? Colors.white : null,
                        ),
                        title: const Text('Import from Nostr'),
                      ),
                    ),
                  ],
                  onSelected: (value) async {
                    FocusManager.instance.primaryFocus?.unfocus();
                    if (value == 1) {
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
                        builder: (context) => const ContactBottomSheet(),
                      );
                      if (res is bool && res) update();
                    } else {
                      final res = await showModalBottomSheet(
                        context: context,
                        showDragHandle: true,
                        isScrollControlled: true,
                        useSafeArea: true,
                        shape: const RoundedRectangleBorder(
                          borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
                        ),
                        routeSettings: const RouteSettings(name: 'NostrImportBottomSheet'),
                        builder: (context) => const NostrImportBottomSheet(),
                      );
                      if (res is bool && res) {
                        update();
                      }
                    }
                  },
                  child: const Icon(Icons.add, color: Colors.white),
                ),
              ),
            )
          : null,
      appBar: AppBar(
        titleSpacing: 0,
        title: TabBar(
          controller: tabController,
          labelStyle: const TextStyle(fontSize: 24),
          unselectedLabelStyle: const TextStyle(fontSize: 14, color: Colors.grey),
          labelPadding: const EdgeInsets.symmetric(horizontal: 8),
          isScrollable: true,
          tabAlignment: TabAlignment.start,
          indicator: const BoxDecoration(),
          indicatorWeight: 0,
          dividerHeight: 0,
          automaticIndicatorColorAdjustment: false,
          overlayColor: WidgetStateColor.resolveWith((states) => Colors.transparent),
          tabs: [
            const Tab(child: Text('Contacts')),
            if (selectedWallet.type == WalletType.full)
              Tab(
                child: Row(
                  crossAxisAlignment: .start,
                  spacing: 4,
                  children: [
                    const Text('Messages'),
                    if (conversationCount > 0)
                      Container(
                        width: 8,
                        height: 8,
                        decoration: BoxDecoration(
                          color: AppColors.primaryColor.withValues(alpha: context.isDarkMode ? 1 : 0.5),
                          shape: BoxShape.circle,
                        ),
                      ),
                  ],
                ),
              ),
            const Tab(child: Text('Profile')),
          ],
          onTap: (value) =>
              pageController.animateToPage(value, duration: const Duration(milliseconds: 300), curve: Curves.easeInOut),
        ),
        actions: [
          if (isInSelectionMode && pageIndex == 0) ...[
            Text(selectedContacts.length.toString()),
            IconButton(
              onPressed: () {
                showDialog(
                  context: context,
                  builder: (context) => AlertDialog(
                    title: const Text('Do you want to delete selected contact?', style: TextStyle(fontSize: 16)),
                    actions: [
                      TextButton(onPressed: () => AppRouter.pop(), child: const Text('No')),
                      TextButton(
                        onPressed: () async {
                          await Future.wait(selectedContacts.map((e) => e.delete()));
                          ToastService.show(
                            '${selectedContacts.length} Contact${selectedContacts.length == 1 ? '' : 's'} deleted!',
                          );
                          selectedContacts.clear();
                          isInSelectionMode = false;
                          update();
                          AppRouter.pop();
                        },
                        child: const Text('Yes'),
                      ),
                    ],
                  ),
                );
              },
              icon: const Icon(Icons.delete_outline, color: Colors.red),
            ),
          ],
        ],
      ),
      body: Column(
        children: [
          if (pageIndex != 2)
            Padding(
              padding: const EdgeInsets.all(16) - const EdgeInsets.only(bottom: 16),
              child: TextFormField(
                autofocus: isDesktop,
                controller: searchController,
                onChanged: (value) {
                  if (pageIndex == 0) {
                    searchDeBouncer.call(() async {
                      mannaContacts.clear();
                      if (value.trim().isNotEmpty) {
                        await DbService.useSupabase((supabase) async {
                          final searchResults = await supabase
                              .from('wallets')
                              .select('uuid, user_name, picture, about, banner, npub, wallet_chat_keys(pubkey)')
                              .ilike('user_name', '%${value.trim().toLowerCase()}%')
                              .limit(10);
                          mannaContacts = searchResults.map((e) => Contact.fromSupabaseMap(e, selectedWallet)).toList();
                        });
                      }
                      refreshData();
                    });
                  } else if (selectedWallet.type == WalletType.full && pageIndex == 1) {
                    searchDeBouncer.call(() => update());
                  }
                },
                decoration: const InputDecoration(
                  contentPadding: EdgeInsets.all(10.0),
                  prefixIcon: Icon(Icons.search),
                  hintText: 'Search...',
                ),
              ),
            ),
          Expanded(
            child: PageView(
              controller: pageController,
              onPageChanged: (value) {
                tabController.animateTo(value);
                update(() => pageIndex = value);
              },
              children: [
                contactsList(filteredContacts),
                if (selectedWallet.type == WalletType.full) conversationList(searchController.text.trim()),
                const ProfilePage(),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget contactsList(List<Contact> contacts) {
    return contacts.isEmpty
        ? const Center(child: Text('No contacts yet!'))
        : ListView.builder(
            padding: const EdgeInsets.all(16),
            itemCount: contacts.length,
            itemBuilder: (context, index) {
              final contact = contacts[index];
              return GestureDetector(
                onLongPress: () {
                  if (!isInSelectionMode) {
                    isInSelectionMode = true;
                  }
                  if (selectedContacts.contains(contact)) {
                    selectedContacts.remove(contact);
                  } else {
                    selectedContacts.add(contact);
                  }
                  if (selectedContacts.isEmpty) {
                    isInSelectionMode = false;
                  }
                  update();
                },
                onTap: () {
                  if (isInSelectionMode) {
                    if (selectedContacts.contains(contact)) {
                      selectedContacts.remove(contact);
                    } else {
                      selectedContacts.add(contact);
                    }
                    if (selectedContacts.isEmpty) {
                      isInSelectionMode = false;
                    }
                    update();
                    return;
                  }
                },
                child: Stack(
                  children: [
                    ContactCard(
                      contact: contact,
                      updateCallback: refreshData,
                      messageToDeliver: widget.messageToDeliver,
                      disableTap: isInSelectionMode,
                    ),
                    if (selectedContacts.contains(contact))
                      Positioned.fill(child: Container(color: Colors.grey.withValues(alpha: 0.4))),
                  ],
                ),
              );
            },
          );
  }

  Widget conversationList(String search) {
    final conversations = DB.conversationsBox.values
        .where((e) => e.myUUID == currentWalletId && e.contact != null && e.lastMessage != null)
        .toList();

    // Search
    if (search.isNotEmpty) {
      final matchingContactUUIDs = TextSearch(
        conversations.map((e) => TextSearchItem.fromTerms(e, [e.contact!.name(), e.contact!.lnurl()])).toList(),
      ).fastSearch(search).map((e) => e.id);
      conversations.removeWhere((e) => !matchingContactUUIDs.contains(e.id));
    }
    conversations.sort((a, b) => b.lastMessage!.timestampUTC.compareTo(a.lastMessage!.timestampUTC));

    if (conversations.isEmpty) {
      return const Center(child: Text('No conversations yet!'));
    }
    return ListView.builder(
      padding: const EdgeInsets.all(16),
      itemCount: conversations.length,
      itemBuilder: (context, index) {
        final conv = conversations[index];

        return ListTile(
          onTap: () async {
            await AppRouter.push(ChatScreen(contact: conv.contact!, messageToDeliver: widget.messageToDeliver));
            await updateConversation();
            refreshData();
          },
          contentPadding: const EdgeInsets.symmetric(horizontal: 8),
          leading: Container(
            height: 45,
            width: 45,
            clipBehavior: Clip.antiAlias,
            decoration: BoxDecoration(shape: BoxShape.circle, color: AppColors.primaryColor.withValues(alpha: 0.5)),
            child: Builder(
              builder: (context) {
                final provider = getImageProvider(conv.contact!.picture());
                final fallback = Center(
                  child: Text(
                    conv.contact!.name().shortName,
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
          title: Row(
            spacing: 8,
            children: [
              Expanded(
                child: Text(conv.contact!.name(), style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w500)),
              ),
              Text(
                conv.lastMessage!.timeString(showDaysOnly: false),
                style: const TextStyle(color: Colors.grey, fontSize: 12),
              ),
            ],
          ),
          subtitle: Row(
            spacing: 4,
            children: [
              // if sent
              if (conv.lastMessage!.senderId == currentWalletId)
                Icon(
                  (conv.lastMessage!.seenAtUTC ?? conv.lastMessage!.receivedAtUTC) != null
                      ? Icons.done_all
                      : !conv.lastMessage!.isPending
                      ? Icons.check
                      : Icons.access_time,
                  size: 14,
                  color: conv.lastMessage!.seenAtUTC != null ? AppColors.primaryColor : Colors.grey,
                ),
              Expanded(child: conv.lastMessage!.createPreview(forConversation: true)),
              Badge(
                isLabelVisible: conv.unreadCount > 0,
                backgroundColor: AppColors.primaryColor.withValues(alpha: 0.5),
                padding: const EdgeInsets.all(4),
                label: Text(conv.unreadCount.toString(), style: const TextStyle(color: Colors.white, fontSize: 12)),
              ),
            ],
          ),
        );
      },
    );
  }
}

class ContactCard extends StatelessWidget {
  const ContactCard({
    required this.contact,
    this.updateCallback,
    this.messageToDeliver,
    this.disableTap = false,
    super.key,
  });

  final Contact contact;
  final Function? updateCallback;
  final MessageData? messageToDeliver;
  final bool disableTap;

  @override
  Widget build(BuildContext context) {
    return ListTile(
      onTap: disableTap
          ? null
          : () {
              if (messageToDeliver != null) {
                AppRouter.push(ChatScreen(contact: contact, messageToDeliver: messageToDeliver));
              } else {
                AppRouter.push(
                  ContactDetailScreen(contact: contact.customizedContact ?? contact),
                ).then((value) => updateCallback?.call());
              }
            },
      contentPadding: const EdgeInsets.symmetric(horizontal: 8),
      leading: Container(
        height: 45,
        width: 45,
        clipBehavior: Clip.antiAlias,
        decoration: BoxDecoration(shape: BoxShape.circle, color: AppColors.primaryColor.withValues(alpha: 0.5)),
        child: Builder(
          builder: (context) {
            final provider = getImageProvider(contact.picture());
            final fallback = Center(
              child: Text(contact.name().shortName, style: const TextStyle(color: Colors.white, fontSize: 24)),
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
      title: Row(
        spacing: 8,
        children: [
          Flexible(
            child: Text(contact.name(), style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w500)),
          ),
          if (contact.isMannaUser)
            CircleAvatar(
              backgroundColor: AppColors.primaryColor,
              radius: 8,
              child: SvgPicture.asset(AppImages.logoWhiteAssetSVG),
            ),
          if (contact.isFavorite) const Icon(Icons.star, color: AppColors.primaryColor, size: 16),
        ],
      ),
      subtitle: (contact.about() ?? contact.lnurl()).isEmpty
          ? null
          : Text(contact.about() ?? contact.lnurl(), maxLines: 1, overflow: TextOverflow.ellipsis),
    );
  }
}

class ProfilePage extends StatefulWidget {
  const ProfilePage({super.key});

  @override
  State<ProfilePage> createState() => _ProfilePageState();
}

class _ProfilePageState extends State<ProfilePage> {
  final aboutController = TextEditingController();

  final GlobalKey<FormState> formKey = GlobalKey<FormState>();
  File? pictureFile;
  String? pictureURL;
  File? bannerFile;
  String? bannerURL;
  bool isPickingPicture = false;
  bool isPickingBanner = false;

  @override
  void initState() {
    final walletData = selectedWallet.metaData;
    if (walletData != null) {
      aboutController.text = walletData.about ?? '';
      pictureURL = walletData.picture;
      bannerURL = walletData.banner;
    }
    super.initState();
  }

  @override
  void dispose() {
    aboutController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final currentAccount = selectedAccount;
    final walletData = selectedWallet.metaData;
    if (walletData == null) return const Center(child: CircularProgressIndicator());
    return Center(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 600),
        child: Column(
          children: [
            Expanded(
              child: Center(
                child: SingleChildScrollView(
                  padding: const EdgeInsets.all(16),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      GestureDetector(
                        onTap: () async {
                          FocusManager.instance.primaryFocus?.unfocus();
                          update(() => isPickingPicture = true);
                          final res = await MediaService.pickMedia(context: context, crop: true);
                          update(() => isPickingPicture = false);
                          if (res != null) {
                            pictureFile = res;
                          }
                          update();
                        },
                        onLongPress: (pictureFile ?? pictureURL) == null
                            ? null
                            : () => AppRouter.push(
                                ImagePreviewScreen(appBarTitle: currentAccount.name, image: pictureFile ?? pictureURL),
                              ),
                        child: Stack(
                          clipBehavior: Clip.none,
                          alignment: Alignment.center,
                          children: [
                            Container(
                              height: 128,
                              width: 128,
                              clipBehavior: Clip.antiAlias,
                              decoration: BoxDecoration(
                                shape: BoxShape.circle,
                                color: AppColors.accentColor.withValues(alpha: 0.2),
                              ),
                              child: Builder(
                                builder: (context) {
                                  final provider = getImageProvider(pictureFile ?? pictureURL);
                                  const fallback = Center(child: Icon(Icons.camera_alt_outlined, size: 32));
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
                            if (isPickingPicture) const CircularProgressIndicator(),
                            Positioned(
                              right: 0,
                              bottom: 0,
                              child: GestureDetector(
                                onTap: pictureFile != null || (pictureURL?.isNotEmpty ?? false)
                                    ? () => update(() => pictureFile = pictureURL = null)
                                    : null,
                                child: Container(
                                  height: 32,
                                  width: 32,
                                  decoration: BoxDecoration(
                                    shape: BoxShape.circle,
                                    color: Colors.white,
                                    border: Border.all(color: AppColors.accentColor, width: 1.5),
                                  ),
                                  child: Icon(
                                    pictureFile != null || (pictureURL?.isNotEmpty ?? false)
                                        ? Icons.delete_forever_outlined
                                        : Icons.edit,
                                    color: AppColors.accentColor,
                                    size: 12,
                                  ),
                                ),
                              ),
                            ),
                          ],
                        ),
                      ),
                      const SizedBox(height: 12),
                      Text(
                        selectedWallet.metaData!.userName,
                        style: const TextStyle(fontSize: 16, fontWeight: FontWeight.bold),
                      ),
                      const SizedBox(height: 32),
                      GestureDetector(
                        onTap: () async {
                          FocusManager.instance.primaryFocus?.unfocus();
                          update(() => isPickingBanner = true);
                          final res = await MediaService.pickMedia(
                            context: context,
                            crop: true,
                            aspectRatio: const CropAspectRatio(width: 1000, height: 333),
                          );
                          update(() => isPickingBanner = false);
                          if (res != null) {
                            bannerFile = res;
                          }
                          update();
                        },
                        onLongPress: (bannerFile ?? bannerURL) == null
                            ? null
                            : () => AppRouter.push(
                                ImagePreviewScreen(appBarTitle: currentAccount.name, image: bannerFile ?? bannerURL),
                              ),
                        child: AspectRatio(
                          aspectRatio: 3,
                          child: Stack(
                            clipBehavior: Clip.none,
                            alignment: Alignment.center,
                            children: [
                              Positioned.fill(
                                child: DecoratedBox(
                                  decoration: BoxDecoration(
                                    borderRadius: BorderRadius.circular(16),
                                    color: AppColors.accentColor.withValues(alpha: 0.2),
                                  ),
                                  child: ClipRRect(
                                    borderRadius: BorderRadius.circular(16),
                                    child: Builder(
                                      builder: (context) {
                                        final provider = getImageProvider(bannerFile ?? bannerURL);
                                        const fallback = Center(child: Icon(Icons.camera_alt_outlined, size: 32));
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
                                ),
                              ),
                              if (isPickingBanner) const CircularProgressIndicator(),
                              Positioned(
                                right: -4,
                                bottom: -4,
                                child: GestureDetector(
                                  onTap: bannerFile != null || bannerURL != null
                                      ? () => update(() => bannerFile = bannerURL = null)
                                      : null,
                                  child: Container(
                                    height: 32,
                                    width: 32,
                                    decoration: BoxDecoration(
                                      color: Colors.white,
                                      shape: BoxShape.circle,
                                      border: Border.all(color: AppColors.accentColor, width: 1.5),
                                    ),
                                    child: Icon(
                                      bannerFile != null || bannerURL != null
                                          ? Icons.delete_forever_outlined
                                          : Icons.edit,
                                      color: AppColors.accentColor,
                                      size: 12,
                                    ),
                                  ),
                                ),
                              ),
                            ],
                          ),
                        ),
                      ),
                      const SizedBox(height: 32),
                      Form(
                        key: formKey,
                        autovalidateMode: AutovalidateMode.onUserInteraction,
                        child: Column(
                          spacing: 12,
                          children: [
                            TextFormField(
                              controller: aboutController,
                              decoration: const InputDecoration(
                                labelText: 'About',
                                hintText: 'Enter something about yourself...',
                              ),
                              textCapitalization: TextCapitalization.sentences,
                              maxLines: 2,
                              maxLength: 140,
                              buildCounter:
                                  (context, {required currentLength, required isFocused, required maxLength}) => null,
                              onChanged: (value) => update(),
                            ),
                            if (currentAccount.nsec != null)
                              Row(
                                children: [
                                  Expanded(
                                    child: TextFormField(
                                      enabled: false,
                                      initialValue: currentAccount.nsec,
                                      decoration: const InputDecoration(labelText: 'Nsec', hintText: 'Enter Nsec'),
                                    ),
                                  ),
                                  IconButton(
                                    onPressed: () => ClipboardService.setClipBoard(currentAccount.nsec!),
                                    icon: const Icon(Icons.copy),
                                  ),
                                ],
                              ),
                          ],
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
            SizedBox(
              width: double.infinity,
              child: Padding(
                padding: const EdgeInsets.all(16),
                child: ElevatedButton(
                  style: ElevatedButton.styleFrom(visualDensity: VisualDensity.standard),
                  onPressed:
                      !(aboutController.text.trim() != (walletData.about ?? '') ||
                          pictureFile != null ||
                          bannerFile != null ||
                          pictureURL != walletData.picture ||
                          bannerURL != walletData.banner)
                      ? null
                      : () async {
                          startLoader();
                          try {
                            if (formKey.currentState?.validate() ?? false) {
                              final about = aboutController.text.trim().isNotEmpty ? aboutController.text.trim() : null;
                              if (pictureFile != null) {
                                pictureURL = await DbService.uploadImage(pictureFile!, 'user-images', path: 'avatars');
                              }
                              if (bannerFile != null) {
                                bannerURL = await DbService.uploadImage(bannerFile!, 'user-images', path: 'banners');
                              }

                              final wallets = DB.allWallets.where((w) => w.accountId == selectedAccountId);
                              await DbService.upsertWallets(
                                Map.fromEntries(
                                  wallets.map(
                                    (e) => MapEntry(e, {'about': about, 'picture': pictureURL, 'banner': bannerURL}),
                                  ),
                                ),
                              );
                              await NostrService.sendProfileUpdate(account: currentAccount);

                              if (pictureFile != null) pictureFile = null;
                              if (bannerFile != null) bannerFile = null;

                              ToastService.show('Profile updated successfully!');
                              update();
                            }
                          } finally {
                            stopLoader();
                          }
                        },
                  child: const Text('Save Profile', textAlign: TextAlign.center),
                ),
              ),
            ),
            const SizedBox(height: 8),
          ],
        ),
      ),
    );
  }
}
