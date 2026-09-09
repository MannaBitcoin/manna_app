import 'dart:convert';
import 'dart:math';

import 'package:hive_ce/hive.dart';
import 'package:manna/app_state.dart';
import 'package:manna/models/misc.dart';
import 'package:manna/services/connectivity_checker.dart';
import 'package:manna/services/log_service.dart';
import 'package:manna/utils/extensions.dart';
import 'package:manna/utils/parser.dart';
import 'package:manna/utils/util.dart';
import 'package:maplibre_gl/maplibre_gl.dart';

class MapService {
  static late Box<MapPlace> mapPlaceBox;
  static late Box mapIconBox;
  static late Box<MapComment> mapCommentBox;

  static final dio = globalDio.clone(options: globalDio.options.copyWith(baseUrl: 'https://api.btcmap.org/'));
  static final fields = {
    'lat',
    'lon',
    'icon',
    'name',
    'address',
    'operating_hours',
    'comments',
    'created_at',
    'updated_at',
    'deleted_at',
    'verified_at',
    'osm_id',
    'phone',
    'website',
    'twitter',
    'facebook',
    'instagram',
    'line',
    'email',
    'boosted_until',
    'osm:payment:onchain',
    'osm:payment:lightning',
    'osm:payment:lightning_contactless',
  };

  static Future<void> openHiveBoxes() async {
    mapPlaceBox = await Hive.openBox<MapPlace>('map_places');
    mapIconBox = await Hive.openBox('map_icons');
    mapCommentBox = await Hive.openBox<MapComment>('map_comments');
  }

  static Future<void> init() async {
    if (!await ConnectivityChecker.checkConnection()) return;
    try {
      final mapUpdateMs = AppState.prefs.getInt('map_last_update_time');
      final res = await dio.get(
        'v4/places',
        queryParameters: {
          'fields': fields.join(','),
          if (mapUpdateMs != null)
            'updated_since': DateTime.fromMillisecondsSinceEpoch(mapUpdateMs).toUtc().toIso8601String(),
          'include_deleted': false,
        },
      );

      if (res.isSuccess && res.data is List) {
        await Future.wait(
          (res.data as List).map((place) {
            final m = MapPlace.fromMap(place);
            if (m.deletedAtUTC != null && m.deletedAtUTC!.isBefore(DateTime.timestamp())) {
              return m.delete();
            } else {
              return m.save();
            }
          }),
        );
        await AppState.prefs.setInt('map_last_update_time', DateTime.now().millisecondsSinceEpoch);

        Future.delayed(const Duration(milliseconds: 500), () => mapPlaceBox.compact());
      }
    } catch (e, s) {
      logE(e, stackTrace: s);
    }
  }

  static Future<MapPlace?> getMapPlace(int id) async {
    final res = await dio.get('v4/places/$id', queryParameters: {'fields': fields.join(',')});
    if (res.isSuccess) {
      final mapPlace = MapPlace.fromMap(res.data);
      await mapPlace.save();
      return mapPlace;
    }
    return mapPlaceBox.get(id);
  }

  static Future<List<MapComment>> getComments(MapPlace place) async {
    if (place.commentCount == 0) return [];
    final List<MapComment> comments = mapCommentBox.values.where((c) => c.placeId == place.id).toList();
    if (comments.length == place.commentCount) return comments;

    comments.clear();
    final res = await dio.get('v4/places/${place.id}/comments');
    if (res.isSuccess && res.data is List) {
      await Future.wait(
        (res.data as List).map((commentData) {
          final comment = MapComment.fromMap(place.id, commentData);
          comments.add(comment);
          return comment.save();
        }),
      );
      Future.delayed(const Duration(milliseconds: 500), () => mapCommentBox.compact());
    }
    return comments;
  }

  static Future<int?> getCommentQuote() async {
    final res = await dio.get('v4/place-comments/quote');
    if (res.isSuccess && res.data?['quote_sat'] != null) {
      return parseIntN(res.data?['quote_sat']);
    }
    return null;
  }

  static Future<String?> postComment(int placeId, String comment) async {
    if (comment.trim().isEmpty) return null;
    final res = await dio.post('v4/place-comments', data: {'place_id': placeId.toString(), 'comment': comment.trim()});
    if (res.isSuccess && res.data?['invoice'] != null) {
      return parseStringN(res.data?['invoice']);
    }
    return null;
  }

  static Future<(int, int, int)?> getBoostQuote() async {
    final res = await dio.get('v4/place-boosts/quote');
    if (res.isSuccess && res.data?['quote_30d_sat'] != null) {
      return (
        parseInt(res.data?['quote_30d_sat']),
        parseInt(res.data?['quote_90d_sat']),
        parseInt(res.data?['quote_365d_sat']),
      );
    }
    return null;
  }

  static Future<String?> boostPlace(int placeId, int days) async {
    final res = await dio.post('v4/place-boosts', data: {'place_id': placeId.toString(), 'days': days});
    if (res.isSuccess && res.data?['invoice'] != null) {
      return parseStringN(res.data?['invoice']);
    }
    return null;
  }
}

double haversineDistance(double lat1, double lon1, double lat2, double lon2, {bool isKm = true}) {
  const earthRadiusKm = 6371.0;
  const earthRadiusMi = 3958.8;

  // Convert degrees to radians
  double toRad(double degree) => degree * pi / 180.0;

  final dLat = toRad(lat2 - lat1);
  final dLon = toRad(lon2 - lon1);

  final rLat1 = toRad(lat1);
  final rLat2 = toRad(lat2);

  final a = pow(sin(dLat / 2), 2) + pow(sin(dLon / 2), 2) * cos(rLat1) * cos(rLat2);
  final c = 2 * atan2(sqrt(a), sqrt(1 - a));

  final radius = isKm ? earthRadiusKm : earthRadiusMi;
  return radius * c;
}

class MapPlace {
  MapPlace({
    required this.id,
    required this.lat,
    required this.lon,
    required this.icon,
    required this.name,
    required this.address,
    required this.openingHours,
    required this.createdAtUTC,
    required this.updatedAtUTC,
    required this.deletedAtUTC,
    required this.verifiedAtUTC,
    required this.boostedUntilUTC,
    required this.osmId,
    required this.phone,
    required this.website,
    required this.twitter,
    required this.facebook,
    required this.instagram,
    required this.line,
    required this.email,
    required this.acceptOnChain,
    required this.acceptLightning,
    required this.acceptLightningContactLess,
    required this.commentCount,
  });

  factory MapPlace.fromMap(Map<String, dynamic> map) {
    return MapPlace(
      id: parseInt(map['id']),
      lat: parseDouble(map['lat']),
      lon: parseDouble(map['lon']),
      icon: parseString(map['icon']),
      name: parseStringN(map['name']),
      address: parseStringN(map['address']),
      openingHours: parseStringN(map['opening_hours']),
      createdAtUTC: parseDateTime(map['created_at']),
      updatedAtUTC: parseDateTime(map['updated_at']),
      deletedAtUTC: parseDateTimeN(map['deleted_at']),
      verifiedAtUTC: parseDateTimeN(map['verified_at']),
      boostedUntilUTC: parseDateTimeN(map['boosted_until']),
      osmId: parseStringN(map['osm_id']),
      phone: parseStringN(map['phone']),
      website: parseStringN(map['website']),
      twitter: parseStringN(map['twitter']),
      facebook: parseStringN(map['facebook']),
      instagram: parseStringN(map['instagram']),
      line: parseStringN(map['line']),
      email: parseStringN(map['email']),
      acceptOnChain: parseBoolN(map['osm:payment:onchain']),
      acceptLightning: parseBoolN(map['osm:payment:lightning']),
      acceptLightningContactLess: parseBoolN(map['osm:payment:lightning_contactless']),
      commentCount: parseIntN(map['comments']) ?? 0,
    );
  }

  final int id;
  final double lat;
  final double lon;
  final String icon;
  final String? name;
  final String? address;
  final String? openingHours;
  final DateTime createdAtUTC;
  final DateTime updatedAtUTC;
  final DateTime? deletedAtUTC;
  final DateTime? verifiedAtUTC;
  final DateTime? boostedUntilUTC;

  final String? osmId;
  final String? phone;
  final String? website;
  final String? twitter;
  final String? facebook;
  final String? instagram;
  final String? line;
  final String? email;

  // -1 means no state, 0 means no, 1 means yes
  final bool? acceptOnChain;
  final bool? acceptLightning;
  final bool? acceptLightningContactLess;

  final int commentCount;

  LatLng get latLong => LatLng(lat, lon);
  bool get isBoosted => boostedUntilUTC?.isAfter(DateTime.now()) ?? false;
  bool get isVerified => verifiedAtUTC?.isAfter(DateTime.now().subtract(const Duration(days: 365))) ?? false;
  String get nameToShow => name == null || name?.toLowerCase() == 'unnamed'
      ? 'Generic ${icon.split('_').map((e) => e.capitalize).join(' ')}'
      : name!;
  String? get xName => twitter == null ? null : Uri.parse(twitter!).path.replaceAll('/', '').replaceAll('@', '');
  String? get facebookName =>
      facebook == null ? null : Uri.parse(facebook!).path.replaceAll('/', '').replaceAll('@', '');
  String? get instagramName =>
      instagram == null ? null : Uri.parse(instagram!).path.replaceAll('/', '').replaceAll('@', '');
  String? get lineName => line == null ? null : Uri.parse(line!).path.replaceAll('/', '').replaceAll('@', '');

  Future<void> save() async {
    await MapService.mapPlaceBox.put(id, this);
  }

  Future<void> delete() async {
    await MapService.mapPlaceBox.delete(id);
  }

  Map<String, dynamic> toMap() => {
    'id': id,
    'lat': lat,
    'lon': lon,
    'icon': icon,
    'name': name,
    'address': address,
    'openingHours': openingHours,
    'createdAt': createdAtUTC,
    'updatedAt': updatedAtUTC,
    'deletedAt': deletedAtUTC,
    'verifiedAt': verifiedAtUTC,
    'boostedUntil': boostedUntilUTC,
    'osmId': osmId,
    'phone': phone,
    'website': website,
    'twitter': twitter,
    'facebook': facebook,
    'instagram': instagram,
    'line': line,
    'email': email,
    'acceptOnChain': acceptOnChain,
    'acceptLightning': acceptLightning,
    'acceptLightningContactLess': acceptLightningContactLess,
    'commentCount': commentCount,
  };

  @override
  String toString() => jsonEncode(toMap().toEncodeReady());
}

class MapComment {
  MapComment({required this.id, required this.placeId, required this.text, required this.createAt});

  factory MapComment.fromMap(int placeId, Map<String, dynamic> map) => MapComment(
    id: parseInt(map['id']),
    placeId: placeId,
    text: parseString(map['text']),
    createAt: parseDateTime(map['created_at']),
  );

  final int id;
  final int placeId;
  final String text;
  final DateTime createAt;

  Future<void> save() => MapService.mapCommentBox.put(id, this);

  Future<void> delete() => MapService.mapCommentBox.delete(id);

  Map<String, dynamic> toMap() => {'id': id, 'placeId': placeId, 'text': text, 'createAt': createAt};

  @override
  String toString() => jsonEncode(toMap().toEncodeReady());
}
