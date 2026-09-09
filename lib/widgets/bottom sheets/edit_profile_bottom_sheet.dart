import 'dart:io';

import 'package:croppy/croppy.dart';
import 'package:flutter/material.dart';
import 'package:manna/globals.dart';
import 'package:manna/models/account.dart';
import 'package:manna/router.dart';
import 'package:manna/screens/image_preview_screen.dart';
import 'package:manna/services/clipboard_service.dart';
import 'package:manna/services/db.dart';
import 'package:manna/services/db_service.dart';
import 'package:manna/services/media_service.dart';
import 'package:manna/services/nostr_service.dart';
import 'package:manna/theme.dart';
import 'package:manna/utils/state_extension.dart';
import 'package:manna/utils/toast_service.dart';

class EditProfileBottomSheet extends StatefulWidget {
  const EditProfileBottomSheet({required this.account, super.key});

  final Account account;

  @override
  State<EditProfileBottomSheet> createState() => _EditProfileBottomSheetState();
}

class _EditProfileBottomSheetState extends State<EditProfileBottomSheet> {
  final TextEditingController aboutController = TextEditingController();

  final GlobalKey<FormState> formKey = GlobalKey<FormState>();
  File? pictureFile;
  String? pictureURL;
  File? bannerFile;
  String? bannerURL;
  bool isPickingPicture = false;
  bool isPickingBanner = false;

  @override
  void initState() {
    final walletData = widget.account.currentWallet.metaData;
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
    return SingleChildScrollView(
      padding: const EdgeInsets.only(left: 16.0, right: 16.0, bottom: 16) + context.keyboardPadding,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: .start,
        children: [
          Container(
            margin: const EdgeInsets.only(bottom: 12, right: 8),
            alignment: Alignment.centerRight,
            child: GestureDetector(onTap: () => AppRouter.pop(false), child: const Icon(Icons.close)),
          ),
          Row(
            children: [
              const Expanded(
                child: Text('Edit wallet profile', style: TextStyle(fontSize: 20, fontWeight: FontWeight.bold)),
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
                        ImagePreviewScreen(appBarTitle: widget.account.name, image: pictureFile ?? pictureURL),
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
                      right: -4,
                      bottom: -4,
                      child: GestureDetector(
                        onTap: pictureFile != null || (pictureURL?.isNotEmpty ?? false)
                            ? () => update(() => pictureFile = pictureURL = null)
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
                    ImagePreviewScreen(appBarTitle: widget.account.name, image: bannerFile ?? bannerURL),
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
                  if (isPickingBanner) const Center(child: CircularProgressIndicator()),
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
                          bannerFile != null || bannerURL != null ? Icons.delete_forever_outlined : Icons.edit,
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
                  controller: aboutController,
                  decoration: const InputDecoration(labelText: 'About', hintText: 'Enter something about yourself...'),
                  maxLength: 140,
                  textCapitalization: TextCapitalization.sentences,
                  buildCounter: (context, {required currentLength, required isFocused, required maxLength}) => null,
                ),
                if (widget.account.nsec?.isNotEmpty == true)
                  Row(
                    children: [
                      Expanded(
                        child: TextFormField(
                          enabled: false,
                          initialValue: widget.account.nsec,
                          decoration: const InputDecoration(labelText: 'Nsec', hintText: 'Enter Nsec'),
                        ),
                      ),
                      IconButton(
                        onPressed: () => ClipboardService.setClipBoard(widget.account.nsec!),
                        icon: const Icon(Icons.copy),
                      ),
                    ],
                  ),
              ],
            ),
          ),
          const SizedBox(height: 16),
          SizedBox(
            width: double.infinity,
            child: ElevatedButton(
              onPressed: widget.account.currentWallet.metaData == null
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
                          await NostrService.sendProfileUpdate(account: widget.account);
                          ToastService.show('Profile updated successfully!');
                          AppRouter.pop(true);
                        }
                      } finally {
                        stopLoader();
                      }
                    },
              style: ElevatedButton.styleFrom(visualDensity: VisualDensity.standard),
              child: const Text('Save Profile', textAlign: TextAlign.center),
            ),
          ),
        ],
      ),
    );
  }
}
