import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/foundation.dart';
import 'package:manna/models/tax.dart';
import 'package:manna/services/db.dart';
import 'package:manna/utils/parser.dart';

import 'misc.dart';

class ShopItem {
  ShopItem({
    required this.id,
    required this.name,
    required this.price,
    this.category = '',
    this.imageBytes,
    this.quantity = 0,
  });

  factory ShopItem.fromMap(Map<String, dynamic> map) => ShopItem(
    id: parseInt(map['id']),
    name: parseString(map['name']),
    price: parseDouble(map['price']),
    category: parseString(map['category']),
    imageBytes: map['imageBytes'] != null ? base64Decode(map['imageBytes']) : null,
  );

  final int id;
  String name;
  double price;
  String category;
  Uint8List? imageBytes;

  double quantity;

  double get totalPrice => price * quantity;

  double get totalTax =>
      price *
      quantity *
      DB.taxes.values
          .where((e) => e.categories.isEmpty || e.categories.contains(category))
          .fold(0.0, (a, b) => a + b.tax / 100);

  double particularTax(Tax t) =>
      price * quantity * ((t.categories.isEmpty || t.categories.contains(category)) ? t.tax / 100 : 0);

  Future<void> update({String? name, double? price, String? category, Nullable<Uint8List?>? imageBytes}) {
    this.name = name ?? this.name;
    this.price = price ?? this.price;
    this.category = category ?? this.category;
    this.imageBytes = imageBytes != null ? imageBytes.value : this.imageBytes;
    return save();
  }

  Future<void> save() async {
    await DB.shopItemBox.put(id, this);
    final s = DB.shopItemBox.get(id);
    if (s != null) {
      DB.shopItems[s.id] = s;
    }
  }

  Future<void> delete() async {
    await DB.shopItemBox.delete(id);
    DB.shopItems.remove(id);
  }

  Map<String, dynamic> toMap() => {
    'id': id,
    'name': name,
    'price': price,
    'category': category,
    'imageBytes': imageBytes == null ? null : base64Encode(imageBytes!),
  }.toEncodeReady();

  @override
  String toString() => jsonEncode(toMap());
}
