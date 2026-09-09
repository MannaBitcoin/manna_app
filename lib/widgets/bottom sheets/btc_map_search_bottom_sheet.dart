import 'package:flutter/material.dart';
import 'package:manna/router.dart';
import 'package:manna/services/map_service.dart';
import 'package:manna/theme.dart';
import 'package:manna/utils/de_bouncer.dart';
import 'package:manna/utils/state_extension.dart';
import 'package:maplibre_gl/maplibre_gl.dart';
import 'package:text_search/text_search.dart';

class BtcMapSearchBottomSheet extends StatefulWidget {
  const BtcMapSearchBottomSheet({required this.currentLocation, super.key});

  final LatLng currentLocation;

  @override
  State<BtcMapSearchBottomSheet> createState() => _BtcMapSearchBottomSheetState();
}

class _BtcMapSearchBottomSheetState extends State<BtcMapSearchBottomSheet> {
  final searchDeBouncer = DeBouncer(const Duration(milliseconds: 100));
  List<MapPlace> places = [];
  final textSearch = TextSearch(
    MapService.mapPlaceBox.values
        .map(
          (e) => TextSearchItem.fromTerms(
            e,
            [e.name, e.icon, e.phone, e.address, e.email, e.website?.replaceFirst('https://', '')].nonNulls,
          ),
        )
        .toList(),
  );

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: context.keyboardPadding,
      child: SizedBox(
        height: 450,
        child: Column(
          children: [
            Padding(
              padding: const EdgeInsets.all(16),
              child: TextFormField(
                autofocus: true,
                onChanged: (value) => searchDeBouncer.call(() {
                  places.clear();
                  final search = value.toLowerCase().trim();
                  if (search.length > 2) {
                    places = textSearch.fastSearch(search);
                  }
                  update();
                }),
                decoration: const InputDecoration(
                  contentPadding: EdgeInsets.all(10.0),
                  prefixIcon: Icon(Icons.search),
                  hintText: 'Search...',
                  filled: true,
                ),
              ),
            ),
            Expanded(
              child: ListView.builder(
                itemCount: places.length,
                padding: const EdgeInsets.all(16),
                itemBuilder: (context, index) {
                  final place = places[index];

                  return ListTile(
                    onTap: () => AppRouter.pop(place.id),
                    contentPadding: const EdgeInsets.symmetric(horizontal: 8),
                    leading: Container(
                      height: 45,
                      width: 45,
                      clipBehavior: Clip.antiAlias,
                      decoration: BoxDecoration(
                        shape: BoxShape.circle,
                        color: AppColors.primaryColor.withValues(alpha: 0.5),
                      ),
                      child: Center(
                        child: Text(
                          place.icon,
                          style: const TextStyle(color: Colors.white, fontSize: 24, fontFamily: 'MaterialIcons2'),
                        ),
                      ),
                    ),
                    title: Row(
                      spacing: 8,
                      children: [
                        Flexible(
                          child: Text(place.nameToShow, style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w500)),
                        ),
                        Text(
                          '(${haversineDistance(widget.currentLocation.latitude, widget.currentLocation.longitude, place.lat, place.lon).toStringAsFixed(2)} km)',
                          style: const TextStyle(fontSize: 12, color: Colors.grey),
                        ),
                      ],
                    ),
                    subtitle: place.address?.isNotEmpty ?? false ? Text(place.address!) : null,
                  );
                },
              ),
            ),
          ],
        ),
      ),
    );
  }
}
