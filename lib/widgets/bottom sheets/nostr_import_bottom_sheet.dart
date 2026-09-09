import 'package:flutter/material.dart';
import 'package:manna/app_state.dart';
import 'package:manna/router.dart';
import 'package:manna/services/nostr_service.dart';
import 'package:manna/utils/state_extension.dart';
import 'package:manna/utils/toast_service.dart';

class NostrImportBottomSheet extends StatefulWidget {
  const NostrImportBottomSheet({super.key});

  @override
  State<NostrImportBottomSheet> createState() => _NostrImportBottomSheetState();
}

class _NostrImportBottomSheetState extends State<NostrImportBottomSheet> {
  String npub = AppState.prefs.getString('lastSyncedNpub') ?? '';
  bool isLoading = false;

  @override
  Widget build(BuildContext context) {
    return SingleChildScrollView(
      padding: const EdgeInsets.all(16) - const EdgeInsets.only(top: 16) + context.keyboardPadding,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: .start,
        spacing: 8,
        children: [
          const Center(
            child: Text('Import contacts from Nostr', style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold)),
          ),
          TextFormField(
            initialValue: npub,
            decoration: const InputDecoration(labelText: 'Npub', hintText: 'Enter Npub'),
            buildCounter: (context, {required currentLength, required isFocused, required maxLength}) => null,
            onChanged: (value) {
              if (value.startsWith('npub') && value.npubToPubKey != null) {
                npub = value.trim();
              } else {
                npub = value.pubKeyToNpub ?? '';
              }
              AppState.prefs.setString('lastSyncedNpub', npub);
              update();
            },
          ),
          SizedBox(
            width: double.infinity,
            child: ElevatedButton(
              onPressed: npub.isNotEmpty
                  ? () async {
                      update(() => isLoading = true);
                      if (await NostrService.syncNostrContacts(npub)) {
                        ToastService.show('All contacts are imported from Nostr.');
                        AppRouter.pop(true);
                      }
                      update(() => isLoading = false);
                    }
                  : null,
              style: ElevatedButton.styleFrom(visualDensity: VisualDensity.standard),
              child: isLoading
                  ? const SizedBox.square(dimension: 16, child: CircularProgressIndicator(color: Colors.white))
                  : const Text('Import Contacts', textAlign: TextAlign.center),
            ),
          ),
        ],
      ),
    );
  }
}
