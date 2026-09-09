import 'dart:async';
import 'dart:convert';
import 'package:manna/models/misc.dart';
import 'package:manna/services/db.dart';
import 'package:manna/utils/parser.dart';

class Tax {
  Tax({required this.id, required this.name, required this.tax, this.categories = const <String>{}});

  factory Tax.fromMap(Map<String, dynamic> map) => Tax(
    id: parseInt(map['id']),
    name: parseString(map['name']),
    tax: parseDouble(map['tax']),
    categories: parseSet(map['categories'] ?? [], (e) => parseString(e)),
  );

  final int id;
  String name;
  double tax;
  Set<String> categories;

  Future<void> update({String? name, double? tax, Set<String>? categories}) {
    this.name = name ?? this.name;
    this.tax = tax ?? this.tax;
    this.categories = categories ?? this.categories;
    return save();
  }

  Future<void> save() => DB.taxes.box.put(id, this);

  Future<void> delete() => DB.taxes.box.delete(id);

  Map<String, dynamic> toMap() => {'id': id, 'name': name, 'tax': tax, 'categories': categories}.toEncodeReady();

  @override
  String toString() => jsonEncode(toMap());
}
