import 'dart:io';

import 'package:flutter/material.dart';
import 'package:manna/globals.dart';
import 'package:manna/router.dart';
import 'package:manna/services/db.dart';
import 'package:manna/services/db_service.dart';
import 'package:manna/services/log_service.dart';
import 'package:manna/services/media_service.dart';
import 'package:manna/utils/state_extension.dart';
import 'package:manna/utils/toast_service.dart';
import 'package:path_provider/path_provider.dart';

class BugReportBottomSheet extends StatefulWidget {
  const BugReportBottomSheet({super.key});

  @override
  State<BugReportBottomSheet> createState() => _BugReportBottomSheetState();
}

class _BugReportBottomSheetState extends State<BugReportBottomSheet> {
  final titleController = TextEditingController();
  final reportController = TextEditingController();
  final formKey = GlobalKey<FormState>();
  final List<File> images = [];
  String? selectedWalletUUID;
  bool shouldAttachLogs = true;

  @override
  Widget build(BuildContext context) {
    return SingleChildScrollView(
      padding: const EdgeInsets.only(left: 16, right: 16, bottom: 16) + context.keyboardPadding,
      child: Form(
        key: formKey,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: .start,
          spacing: 12,
          children: [
            const Text('Bug Report', style: TextStyle(fontSize: 20, fontWeight: FontWeight.bold)),
            DropdownButtonFormField(
              validator: (value) {
                if (value == null) return 'Please select a user';
                return null;
              },
              items: DB.activeAccounts
                  .map((e) => DropdownMenuItem(value: e.currentWallet.uuid, child: Text(e.currentWallet.metaData?.userName ?? '')))
                  .toList(),
              onChanged: (value) => selectedWalletUUID = value,
              decoration: const InputDecoration(hintText: 'Please select user'),
            ),
            TextFormField(
              controller: titleController,
              textInputAction: TextInputAction.done,
              textCapitalization: TextCapitalization.sentences,
              validator: (value) {
                if (value?.isEmpty ?? true) return 'Please enter a title';
                return null;
              },
              decoration: const InputDecoration(labelText: 'Title'),
            ),
            TextFormField(
              controller: reportController,
              textInputAction: TextInputAction.done,
              textCapitalization: TextCapitalization.sentences,
              validator: (value) {
                if (value?.isEmpty ?? true) return 'Please enter a description';
                return null;
              },
              decoration: const InputDecoration(labelText: 'Bug description'),
              maxLines: 4,
            ),
            if (images.isNotEmpty) ...[
              const SizedBox(height: 0),
              Wrap(
                spacing: 12,
                runSpacing: 12,
                children: [
                  for (final image in images)
                    Stack(
                      clipBehavior: Clip.none,
                      children: [
                        ClipRRect(
                          borderRadius: BorderRadius.circular(8),
                          child: Image(image: FileImage(File(image.path)), fit: BoxFit.cover, height: 80, width: 80),
                        ),
                        Positioned(
                          top: -8,
                          right: -8,
                          child: GestureDetector(
                            onTap: () => update(() => images.remove(image)),
                            child: DecoratedBox(
                              decoration: BoxDecoration(shape: BoxShape.circle, color: Colors.redAccent.shade100),
                              child: const Icon(Icons.remove, color: Colors.white),
                            ),
                          ),
                        ),
                      ],
                    ),
                ],
              ),
            ],
            Align(
              alignment: Alignment.centerRight,
              child: TextButton(
                onPressed: images.length >= 10
                    ? null
                    : () async {
                        final pickedImages = await MediaService.pickMultiImage();
                        if (pickedImages != null) {
                          if (pickedImages.length > 10 - images.length) {
                            ToastService.show('You can only add 10 images');
                          }
                          update(() => images.addAll(pickedImages.take(10 - images.length).map((e) => File(e.path))));
                        }
                      },
                child: const Text('Add Images', style: TextStyle(fontSize: 16), textAlign: TextAlign.center),
              ),
            ),
            CheckboxListTile(
              value: shouldAttachLogs,
              onChanged: (value) => update(() => shouldAttachLogs = value ?? false),
              title: const Text('Attach logs', style: TextStyle(fontWeight: FontWeight.w500)),
              subtitle: const Text('Helps us troubleshoot the bugs, might contain sensitive information.'),
              contentPadding: EdgeInsets.zero,
              controlAffinity: ListTileControlAffinity.leading,
            ),
            Row(
              spacing: 8,
              children: [
                Expanded(
                  child: ElevatedButton(
                    onPressed: () => AppRouter.pop(),
                    style: ElevatedButton.styleFrom(
                      backgroundColor: Colors.white,
                      foregroundColor: Colors.grey,
                      visualDensity: VisualDensity.standard,
                    ),
                    child: const Text('Cancel'),
                  ),
                ),
                Expanded(
                  child: ElevatedButton(
                    onPressed: () async {
                      if (selectedWalletUUID == null) {
                        return ToastService.show('Please select a wallet');
                      }
                      if (formKey.currentState?.validate() ?? false) {
                        startLoader();
                        File? logZip;
                        if (shouldAttachLogs) {
                          try {
                            final zipData = await LogManager.exportLogs(confirm: false);
                            if (zipData != null) {
                              final temp = await getTemporaryDirectory();
                              logZip = File('${temp.path}/${DateTime.now().millisecondsSinceEpoch}.zip');
                              await logZip.writeAsBytes(zipData);
                            }
                          } catch (e, s) {
                            logE(e, stackTrace: s);
                          }
                        }
                        if (await DbService.submitBugReport(
                          uuid: selectedWalletUUID!,
                          title: titleController.text.trim(),
                          description: reportController.text.trim(),
                          images: images,
                          logZip: logZip,
                        )) {
                          ToastService.show('Report submitted successfully');
                          AppRouter.pop();
                        } else {
                          ToastService.show('Failed to submit report');
                        }
                        stopLoader();
                      }
                    },
                    style: ElevatedButton.styleFrom(visualDensity: VisualDensity.standard),
                    child: const Text('Submit'),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 8),
          ],
        ),
      ),
    );
  }
}
