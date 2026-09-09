import 'dart:convert';

import 'package:manna/models/misc.dart';
import 'package:manna/models/wallet.dart';
import 'package:manna/services/db.dart';
import 'package:manna/services/nostr_service.dart';
import 'package:manna/utils/extensions.dart';
import 'package:manna/utils/parser.dart';
import 'package:manna_core/manna_core.dart' show WalletType;
import 'package:uuid/uuid.dart';

class Contact {
  Contact({
    required this.uuid,
    required this.walletId,
    required this.walletType,
    required this._name,
    required this._lnurl,
    this._about,
    this._picture,
    this._banner,
    this._npub,
    this.chatPubKeyBase64,
    this.isMannaUser = false,
    this.isFavorite = false,
    this.customizedContact,
  });

  factory Contact.fromMap(Map<String, dynamic> map) => Contact(
    uuid: parseString(map['uuid']),
    walletId: parseString(map['walletId']),
    walletType: WalletType.values[parseIntN(map['walletType']) ?? 0],
    name: parseString(map['name']),
    lnurl: parseString(map['lnurl']),
    about: parseStringN(map['about']),
    picture: parseStringN(map['picture']),
    banner: parseStringN(map['banner']),
    npub: parseStringN(map['npub']),
    chatPubKeyBase64: parseStringN(map['chatPubKeyBase64']),
    isMannaUser: parseBool(map['isMannaUser']),
    isFavorite: parseBool(map['isFavorite']),
    customizedContact: map['customizedContact'] != null ? Contact.fromMap(map['customizedContact']) : null,
  );

  factory Contact.fromSupabaseMap(Map<String, dynamic> map, Wallet wallet) => Contact(
    uuid: parseString(map['uuid']),
    walletId: wallet.uuid,
    walletType: wallet.type,
    name: parseString(map['user_name']),
    lnurl: parseString(map['user_name']).toMannaLNURL(),
    about: parseStringN(map['about']),
    picture: parseStringN(map['picture']),
    banner: parseStringN(map['banner']),
    npub: parseStringN(map['npub']),
    chatPubKeyBase64: parseStringN(map['wallet_chat_keys']?['pubkey']),
    isMannaUser: true,
  );

  factory Contact.fromNostrEvent(Map<String, dynamic> map, String pubKey, Wallet wallet) => Contact(
    uuid: const Uuid().v5(Namespace.url.value, pubKey),
    walletId: wallet.uuid,
    walletType: wallet.type,
    name: parseString(map['name']),
    lnurl: parseString(map['lud16']),
    about: parseString(map['about']),
    picture: parseString(map['picture']),
    banner: parseStringN(map['banner']),
    npub: pubKey.pubKeyToNpub,
  );

  final String uuid;
  final String walletId;
  final WalletType walletType;

  String _name;
  String _lnurl;
  String? _about;
  String? _picture;
  String? _banner;
  String? _npub;
  String? chatPubKeyBase64;
  bool isMannaUser;
  bool isFavorite;
  Contact? customizedContact;

  String name({bool original = false}) => original ? _name : customizedContact?._name ?? _name;

  String lnurl({bool original = false, bool wrap = false}) {
    final lnurl = original ? _lnurl : customizedContact?._lnurl ?? _lnurl;
    return wrap ? lnurl.replaceFirst('@', '\u200b@') : lnurl;
  }

  String? about({bool original = false}) => original ? _about : customizedContact?._about ?? _about;
  // Either base64 image or url
  String? picture({bool original = false}) => original ? _picture : customizedContact?._picture ?? _picture;
  // Either base64 image or url
  String? banner({bool original = false}) => original ? _banner : customizedContact?._banner ?? _banner;
  String? npub({bool original = false}) => original ? _npub : customizedContact?._npub ?? _npub;

  Future<void> saveCustomizedCopy({
    required String name,
    required String lnurl,
    String? about,
    String? picture,
    String? banner,
    String? npub,
  }) {
    customizedContact = Contact(
      uuid: uuid,
      walletId: walletId,
      walletType: walletType,
      name: name,
      lnurl: lnurl,
      about: about,
      picture: picture,
      banner: banner,
      npub: npub,
      isMannaUser: lnurl.isMannaUserName,
      isFavorite: isFavorite,
      chatPubKeyBase64: chatPubKeyBase64,
    );
    return save();
  }

  IdWithWalletAndType get metaId => IdWithWalletAndType(id: uuid, walletId: walletId, walletType: walletType);

  Future<void> save() async {
    // This is to avoid removing customized contact from DB
    final id = metaId;
    customizedContact ??= DB.contactsBox.get(id.toString())?.customizedContact;
    await DB.contactsBox.put(id.toString(), this);
    final c = DB.contactsBox.get(id.toString());
    if (c != null) {
      DB.contacts[id] = c;
    }
  }

  Future<void> delete() async {
    await DB.contactsBox.delete(metaId.toString());
    DB.contacts.remove(metaId);
  }

  Map<String, dynamic> toMap() => {
    'uuid': uuid,
    'walletId': walletId,
    'walletType': walletType.index,
    'name': name(),
    'lnurl': lnurl(),
    'about': about(),
    'picture': picture(),
    'banner': banner(),
    'npub': npub(),
    'chatPubKeyBase64': chatPubKeyBase64,
    'isMannaUser': isMannaUser,
    'isFavorite': isFavorite,
    'customizedContact': customizedContact?.toMap(),
  }.toEncodeReady();

  @override
  String toString() => jsonEncode(toMap());

  bool isEqual(Contact other) =>
      _name == other._name &&
      _lnurl == other._lnurl &&
      _about == other._about &&
      _picture == other._picture &&
      _banner == other._banner;
}
