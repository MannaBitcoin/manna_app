import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:croppy/croppy.dart';
import 'package:flutter/material.dart';
import 'package:manna/models/account.dart';
import 'package:manna/models/contact.dart';
import 'package:manna/router.dart';
import 'package:manna/screens/image_preview_screen.dart';
import 'package:manna/services/db_service.dart';
import 'package:manna/services/media_service.dart';
import 'package:manna/services/nostr_service.dart';
import 'package:manna/theme.dart';
import 'package:manna/utils/extensions.dart';
import 'package:manna/utils/state_extension.dart';
import 'package:manna/utils/toast_service.dart';
import 'package:uuid/uuid.dart';

class ContactBottomSheet extends StatefulWidget {
  const ContactBottomSheet({this.contact, super.key});

  final Contact? contact;

  @override
  State<ContactBottomSheet> createState() => _ContactBottomSheetState();
}

class _ContactBottomSheetState extends State<ContactBottomSheet> {
  final nameController = TextEditingController();
  final lnurlController = TextEditingController();
  final aboutController = TextEditingController();
  final npubController = TextEditingController();

  final GlobalKey<FormState> formKey = GlobalKey<FormState>();
  File? pictureFile;
  Uint8List? pictureBytes;
  String? pictureURL;
  File? bannerFile;
  Uint8List? bannerBytes;
  String? bannerURL;
  bool isPickingPicture = false;
  bool isPickingBanner = false;

  @override
  void initState() {
    if (widget.contact != null) {
      nameController.text = widget.contact!.name();
      lnurlController.text = widget.contact!.lnurl();
      aboutController.text = widget.contact!.about() ?? '';
      npubController.text = widget.contact!.npub() ?? '';
      if (widget.contact!.picture()?.startsWith('http') ?? true) {
        pictureURL = widget.contact!.picture();
      } else {
        pictureBytes = widget.contact!.picture() == null ? null : base64Decode(widget.contact!.picture()!);
      }
      if (widget.contact!.banner()?.startsWith('http') ?? true) {
        bannerURL = widget.contact!.banner();
      } else {
        bannerBytes = widget.contact!.banner() == null ? null : base64Decode(widget.contact!.banner()!);
      }
    }
    super.initState();
  }

  @override
  void dispose() {
    nameController.dispose();
    lnurlController.dispose();
    aboutController.dispose();
    npubController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return SingleChildScrollView(
      padding: const EdgeInsets.only(left: 16.0, right: 16.0, bottom: 16) + context.keyboardPadding,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: .start,
        children: [
          widget.contact == null
              ? const SizedBox()
              : Container(
                  margin: const EdgeInsets.only(bottom: 12, right: 8),
                  alignment: Alignment.centerRight,
                  child: GestureDetector(onTap: () => AppRouter.pop(false), child: const Icon(Icons.close)),
                ),
          Row(
            children: [
              Expanded(
                child: Text(
                  widget.contact == null ? 'Add New Contact' : 'Edit Contact',
                  style: const TextStyle(fontSize: 20, fontWeight: FontWeight.bold),
                ),
              ),
              const SizedBox(width: 16),
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
                        ImagePreviewScreen(appBarTitle: nameController.text.trim(), image: pictureFile ?? pictureURL),
                      ),
                child: Stack(
                  clipBehavior: Clip.none,
                  alignment: Alignment.center,
                  children: [
                    Container(
                      height: 64,
                      width: 64,
                      clipBehavior: Clip.antiAlias,
                      decoration: BoxDecoration(
                        shape: BoxShape.circle,
                        color: AppColors.accentColor.withValues(alpha: 0.2),
                      ),
                      child: Builder(
                        builder: (context) {
                          final provider = getImageProvider(pictureFile ?? pictureBytes ?? pictureURL);
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
                      right: -4,
                      bottom: -4,
                      child: GestureDetector(
                        onTap: pictureFile != null || pictureBytes != null || pictureURL != null
                            ? () => update(() => pictureFile = pictureBytes = pictureURL = null)
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
                            pictureFile != null || pictureBytes != null || pictureURL != null
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
              const SizedBox(width: 12),
            ],
          ),
          const SizedBox(height: 16),
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
                    ImagePreviewScreen(appBarTitle: nameController.text.trim(), image: bannerFile ?? bannerURL),
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
                    ),
                  ),
                  Positioned.fill(
                    child: ClipRRect(
                      borderRadius: BorderRadius.circular(16),
                      child: Builder(
                        builder: (context) {
                          final provider = getImageProvider(bannerFile ?? bannerBytes ?? bannerURL);
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
                  if (isPickingBanner) const CircularProgressIndicator(),
                  Positioned(
                    right: -4,
                    bottom: -4,
                    child: GestureDetector(
                      onTap: bannerFile != null || bannerBytes != null || bannerURL != null
                          ? () => update(() => bannerFile = bannerBytes = bannerURL = null)
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
                          bannerFile != null || bannerBytes != null || bannerURL != null
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
          const SizedBox(height: 16),
          Form(
            key: formKey,
            autovalidateMode: AutovalidateMode.onUserInteraction,
            child: Column(
              spacing: 12,
              children: [
                TextFormField(
                  controller: nameController,
                  decoration: const InputDecoration(labelText: 'Name', hintText: 'Name (example: Adam)'),
                  maxLength: 50,
                  textCapitalization: TextCapitalization.sentences,
                  buildCounter: (context, {required currentLength, required isFocused, required maxLength}) => null,
                  validator: (value) => value == null || value.isEmpty ? 'Please enter name' : null,
                ),
                TextFormField(
                  controller: lnurlController,
                  decoration: const InputDecoration(
                    labelText: 'Lightning address',
                    hintText: 'Lightning address (example: adam@mannabitcoin.com)',
                  ),
                  buildCounter: (context, {required currentLength, required isFocused, required maxLength}) => null,
                  validator: (value) =>
                      value == null || value.isEmpty || !value.isUserName ? 'Please enter lightning address' : null,
                  enabled: widget.contact == null,
                ),
                TextFormField(
                  controller: aboutController,
                  decoration: const InputDecoration(labelText: 'About', hintText: 'Enter short description...'),
                  textCapitalization: TextCapitalization.sentences,
                  maxLength: 140,
                  buildCounter: (context, {required currentLength, required isFocused, required maxLength}) => null,
                ),
                TextFormField(
                  controller: npubController,
                  decoration: const InputDecoration(
                    labelText: 'Npub',
                    hintText: 'If the contact has Nostr account Enter their Npub',
                  ),
                  maxLength: 64,
                  buildCounter: (context, {required currentLength, required isFocused, required maxLength}) => null,
                  validator: (value) {
                    if (value == null || value.isEmpty) return null;
                    return value.npubToPubKey != null ? null : 'Please enter valid Npub!';
                  },
                  enabled: widget.contact == null,
                ),
              ],
            ),
          ),
          const SizedBox(height: 16),
          Row(
            children: [
              Expanded(
                child: ElevatedButton(
                  onPressed: () async {
                    if (widget.contact == null) {
                      AppRouter.pop(false);
                      return;
                    }
                    final data = await showDialog<bool>(
                      context: context,
                      builder: (context) => AlertDialog(
                        title: Text(
                          'Are you sure you want to import ${widget.contact?.name()}?\n'
                          'This will override existing contact',
                          style: const TextStyle(fontSize: 16),
                        ),
                        actions: [
                          TextButton(onPressed: () => AppRouter.pop(false), child: const Text('No')),
                          TextButton(
                            onPressed: () async {
                              await widget.contact!.delete();
                              ToastService.show('Contact updated successfully!');
                              AppRouter.pop(true);
                            },
                            child: const Text('Yes'),
                          ),
                        ],
                      ),
                    );
                    if (data ?? false) AppRouter.pop(data);
                  },
                  style: ElevatedButton.styleFrom(
                    backgroundColor: Colors.white,
                    foregroundColor: AppColors.primaryColor,
                    visualDensity: VisualDensity.standard,
                  ),
                  child: Text(widget.contact == null ? 'Cancel' : 'Import'),
                ),
              ),
              const SizedBox(width: 16),
              Expanded(
                child: ElevatedButton(
                  onPressed: () async {
                    if (formKey.currentState?.validate() ?? false) {
                      final about = aboutController.text.trim().isNotEmpty ? aboutController.text.trim() : null;
                      final name = nameController.text.trim();
                      final lnurl = lnurlController.text.trim();
                      final picture = pictureFile != null
                          ? base64Encode(await pictureFile!.readAsBytes())
                          : pictureBytes != null
                          ? base64Encode(pictureBytes!)
                          : pictureURL;
                      final banner = bannerFile != null
                          ? base64Encode(await bannerFile!.readAsBytes())
                          : bannerBytes != null
                          ? base64Encode(bannerBytes!)
                          : bannerURL;
                      final npub = npubController.text.trim().isNotEmpty ? npubController.text.trim() : null;

                      if (widget.contact != null) {
                        await widget.contact!.saveCustomizedCopy(
                          name: name,
                          lnurl: lnurl,
                          about: about,
                          npub: npub,
                          picture: picture,
                          banner: banner,
                        );
                      } else {
                        if (lnurl.isMannaUserName && (lnurl.getUserName?.isNotEmpty ?? false)) {
                          await (await DbService.getContact(
                            userName: lnurl.getUserName!,
                            wallet: selectedWallet,
                          ))?.saveCustomizedCopy(
                            name: name,
                            lnurl: lnurl,
                            about: about,
                            npub: npub,
                            picture: picture,
                            banner: banner,
                          );
                        } else {
                          final contact = Contact(
                            uuid: const Uuid().v4(),
                            walletId: selectedWallet.uuid,
                            walletType: selectedWallet.type,
                            name: name,
                            lnurl: lnurl,
                            about: about,
                            npub: npub,
                            picture: picture,
                            banner: banner,
                            isMannaUser: lnurl.isMannaUserName,
                          );
                          await contact.saveCustomizedCopy(
                            name: name,
                            lnurl: lnurl,
                            about: about,
                            npub: npub,
                            picture: picture,
                            banner: banner,
                          );
                          await contact.save();
                        }
                      }
                      AppRouter.pop(true);
                    }
                  },
                  style: ElevatedButton.styleFrom(visualDensity: VisualDensity.standard),
                  child: Text(widget.contact == null ? 'Add Contact' : 'Update Contact', textAlign: TextAlign.center),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}
