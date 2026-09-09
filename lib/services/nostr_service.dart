import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';
import 'package:dart_nostr/dart_nostr.dart';
import 'package:manna/config.dart';
import 'package:manna/models/account.dart';
import 'package:manna/models/contact.dart';
import 'package:manna/models/wallet.dart';
import 'package:manna/services/log_service.dart';
import 'package:manna/utils/extensions.dart';

import 'package:manna_core/manna_core.dart' as core;
import 'package:manna_core/manna_core.dart' show Network;

class NostrService {
  static Future<void> connectRelays() async {
    try {
      final relays = {
        'nos.lol',
        'nostrue.com',
        'relay.primal.net',
        'relay.damus.io',
        // 'nostr.oxtr.dev',
        // 'nostr.wine',
        // 'nostr.mom',
        // 'nostr,bitcoiner.social',
        // 'relay.nostr.band',
        // 'relay.noswhere.com',
      };
      await Nostr.instance.services.relays.init(relaysUrl: relays.map((e) => 'wss://$e').toList());
    } catch (e, s) {
      logE(e, stackTrace: s);
    }
  }

  static Future<bool> syncNostrContacts(String npub) async {
    final completer = Completer<bool>();
    Timer? timeoutTimer;
    StreamSubscription<NostrEvent>? streamSubscription;
    int receivedCount = 0;

    try {
      if (Nostr.instance.services.relays.relaysWebSocketsRegistry.isEmpty) {
        await connectRelays();
      }
      final followEvents = await Nostr.instance.services.relays.startEventsSubscriptionAsync(
        request: NostrRequest(
          filters: [
            NostrFilter(kinds: const [3], authors: [Nostr.instance.services.bech32.decodeNpubKeyToPublicKey(npub)]),
          ],
        ),
        timeout: const Duration(seconds: 10),
        shouldThrowErrorOnTimeoutWithoutEose: false,
      );
      final List<String> followPubKeys = [];
      for (final e in followEvents) {
        for (final t in e.tags ?? []) {
          if (t.length >= 2 && t.contains('p')) {
            followPubKeys.add(t[1]);
          }
        }
      }

      if (followPubKeys.isEmpty) {
        return true;
      }

      final subscription = Nostr.instance.services.relays.startEventsSubscription(
        request: NostrRequest(
          filters: [
            NostrFilter(kinds: const [0], authors: followPubKeys),
          ],
        ),
      );
      streamSubscription = subscription.stream
          .asyncMap((event) async {
            try {
              if (event.content != null) {
                final data = jsonDecode(event.content!);
                await Contact.fromNostrEvent(data, event.pubkey, selectedWallet).save();

                receivedCount++;
                if (receivedCount >= followPubKeys.length && !completer.isCompleted) {
                  timeoutTimer?.cancel();
                  await streamSubscription?.cancel();
                  completer.complete(true);
                }
              }
            } catch (_) {}
            return event;
          })
          .listen((event) {});

      timeoutTimer = Timer(const Duration(seconds: 30), () async {
        if (!completer.isCompleted) {
          await streamSubscription?.cancel();
          completer.complete(false);
        }
      });

      return await completer.future;
    } catch (e, s) {
      logE(e, stackTrace: s);
      timeoutTimer?.cancel();
      await streamSubscription?.cancel();
    }
    return false;
  }

  /// uses NIP-05 to fetch detail from a given internet name
  static Future<Contact?> fetchUserData(String address, Wallet wallet) async {
    if (Nostr.instance.services.relays.relaysWebSocketsRegistry.isEmpty) {
      await connectRelays();
    }
    try {
      final nostrPubKey = await Nostr.instance.services.utils.pubKeyFromIdentifierNip05(internetIdentifier: address);
      if (nostrPubKey?.isNotEmpty ?? false) {
        final res = await Nostr.instance.services.relays.startEventsSubscriptionAsync(
          request: NostrRequest(
            filters: [
              NostrFilter(authors: [nostrPubKey!], kinds: const [0]),
            ],
          ),
          timeout: const Duration(seconds: 10),
          shouldThrowErrorOnTimeoutWithoutEose: false,
        );
        for (final e in res) {
          try {
            if (e.content != null) {
              final data = jsonDecode(e.content!);
              return Contact.fromNostrEvent(data, e.pubkey, wallet);
            }
          } catch (_) {}
        }
      }
    } catch (_) {}
    return null;
  }

  static Future<void> sendProfileUpdate({required Account account}) async {
    if (account.nsec?.isNotEmpty == true && Config.network == Network.mainnet && await account.hasMnemonic) {
      final keyPair = account.nsec!.parseNsec;
      if (keyPair != null && account.currentWallet.metaData?.userName != null) {
        try {
          final walletData = account.currentWallet.metaData;
          final metadata = {
            'name': walletData!.userName,
            'display_name': walletData.userName,
            'about': walletData.about,
            'picture': walletData.picture,
            'banner': walletData.banner,
            'lud16': walletData.userName.toMannaLNURL(),
            'nip05': walletData.userName.toMannaLNURL(),
          };

          if (Nostr.instance.services.relays.relaysWebSocketsRegistry.isEmpty) {
            await connectRelays();
          }
          await Nostr.instance.services.relays.sendEventToRelays(
            NostrEvent.fromPartialData(kind: 0, content: jsonEncode(metadata), keyPairs: keyPair),
          );
        } catch (e, s) {
          logE(e, stackTrace: s);
        }
      }
    }
  }

  static Future<String?> generateNsecFromSeed(core.U8Array64 seedBytes) async {
    final privateKey = (await core.Bip32.fromSeed(seed: seedBytes)).derivePath(path: "m/44'/1237'/0'/0/0").getPrivateKey();
    if (privateKey == null) return null;
    return NostrKeyPairs(private: Uint8List.fromList(privateKey).toHexString).private.privateKeyToNsec;
  }
}

extension NostrKeysExtension on String {
  String? get pubKeyToNpub {
    try {
      return Nostr.instance.services.bech32.encodePublicKeyToNpub(trim());
    } catch (_) {}
    return null;
  }

  String? get npubToPubKey {
    try {
      return Nostr.instance.services.bech32.decodeNpubKeyToPublicKey(trim());
    } catch (_) {}
    return null;
  }

  String? get privateKeyToNsec {
    try {
      return Nostr.instance.services.bech32.encodePrivateKeyToNsec(trim());
    } catch (_) {}
    return null;
  }

  String? get nsecToNpub {
    try {
      final privateKey = Nostr.instance.services.bech32.decodeNsecKeyToPrivateKey(trim());
      return Nostr.instance.services.bech32.encodePublicKeyToNpub(NostrKeyPairs(private: privateKey).public);
    } catch (_) {}
    return null;
  }

  NostrKeyPairs? get parseNsec {
    try {
      final privateKey = Nostr.instance.services.bech32.decodeNsecKeyToPrivateKey(trim());
      return NostrKeyPairs(private: privateKey);
    } catch (_) {}
    return null;
  }
}
