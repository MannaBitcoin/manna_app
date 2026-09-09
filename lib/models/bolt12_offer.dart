import 'package:manna/models/swap.dart';
import 'package:manna/models/wallet.dart';
import 'package:manna/services/db.dart';
import 'package:manna/utils/parser.dart';
import 'package:manna_core/manna_core.dart' show WalletType, KeyPair;

class Bolt12Offer {
  Bolt12Offer({required this.walletId, required this.walletType, required this.signingKey, required this.offer});

  factory Bolt12Offer.fromMap(Map<String, dynamic> map) => Bolt12Offer(
    walletId: parseString(map['walletId']),
    walletType: WalletType.values[parseInt(map['walletType'])],
    offer: parseString(map['offer']),
    signingKey: KeyPairExtension.fromMap(map['signingKey']),
  );

  final String walletId;
  final WalletType walletType;
  final String offer;
  final KeyPair signingKey;

  Wallet? get wallet => walletType == WalletType.full ? DB.fullWallets[walletId] : DB.woWallets[walletId];
  String get id => '${walletId}_${walletType.index}';

  Future<void> save() => DB.bolt12Offers.box.put(id, this);

  Future<void> delete() => DB.bolt12Offers.box.delete(id);

  Map<String, dynamic> toMap() => {
    'walletId': walletId,
    'walletType': walletType.index,
    'offer': offer,
    'signingKey': signingKey.toMap(),
  };
}
