import 'dart:convert';
import 'dart:math' as math;
import 'dart:ui' as ui;
import 'dart:async';
import 'package:flutter/cupertino.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';
import 'package:flutter_svg/svg.dart';
import 'package:intl/intl.dart';
import 'package:manna/app_state.dart';
import 'package:manna/config.dart';
import 'package:manna/globals.dart';
import 'package:manna/router.dart';
import 'package:manna/screens/send_screen.dart';
import 'package:manna/services/log_service.dart';
import 'package:manna/services/map_service.dart';
import 'package:manna/theme.dart';
import 'package:manna/utils/extensions.dart';
import 'package:manna/utils/parser.dart';
import 'package:manna/utils/util.dart';
import 'package:manna/widgets/bottom sheets/btc_map_search_bottom_sheet.dart';
import 'package:maplibre_gl/maplibre_gl.dart';
import 'package:manna/utils/constants.dart';
import 'package:manna/utils/de_bouncer.dart';
import 'package:manna/utils/state_extension.dart';
import 'package:manna/widgets/amount_text.dart';
import 'package:map_launcher/map_launcher.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:scidart/numdart.dart';
import 'package:share_plus/share_plus.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:url_launcher/url_launcher_string.dart';

class BtcMapScreen extends StatefulWidget {
  const BtcMapScreen({super.key});

  @override
  State<BtcMapScreen> createState() => _BtcMapScreenState();
}

class _BtcMapScreenState extends State<BtcMapScreen> {
  Key mapKey = const Key('map');
  MapLibreMapController? mapController;
  MapLibreWebController? mapWebController;
  late CameraPosition initialCameraPosition;
  final movementHandlerThrottler = Throttler(const Duration(milliseconds: 200));
  final locationSaverDebouncer = DeBouncer(const Duration(milliseconds: 1000));
  Map<int, MapPlace> places = {};
  Map<int, MapPlace> visiblePlaces = {};
  Map<int, ClusterItem> clusters = {};
  MapPlace? selectedPlace;
  final dateFormat = DateFormat('dd MMM yyyy');
  final TextEditingController commentController = TextEditingController();
  int? commentQuote;

  bool isFiltering = true;
  bool isBoostedSelected = false, isVerifiedSelected = false;
  List<String> topCategories = [];
  Set<String> selectedCats = {};

  @override
  void initState() {
    MapService.openHiveBoxes().then((value) => applyFilter());
    final locationComponent = (AppState.prefs.getString('lastUserLocation') ?? '0,0,0')
        .split(',')
        .map((e) => parseDouble(e))
        .toList();
    if (locationComponent.length == 3) {
      initialCameraPosition = CameraPosition(
        target: LatLng(locationComponent[0], locationComponent[1]),
        zoom: locationComponent[2],
      );
    }
    MapService.getCommentQuote().then((value) => commentQuote = value);
    if (places.isEmpty) {
      postFrameCallBack(() => startLoader());
    }
    MapService.init().then((value) {
      stopLoader();
      applyFilter();
      buildIcons();
    });
    super.initState();
  }

  @override
  void dispose() {
    commentController.dispose();
    mapController?.removeListener(handleMovement);
    mapController?.onSymbolTapped.remove(onSymbolClickStub);
    super.dispose();
  }

  void applyFilter() {
    if (topCategories.isEmpty) {
      final Map<String, int> count = {};
      for (final place in MapService.mapPlaceBox.values) {
        count[place.icon] = (count[place.icon] ?? 0) + 1;
      }
      final countList = count.entries.toList();
      countList.sort((a, b) => b.value.compareTo(a.value));
      topCategories = countList.take(10).map((e) => e.key).toList();
    }

    places = Map.fromEntries(
      MapService.mapPlaceBox.values
          .where(
            (e) =>
                (isBoostedSelected
                    ? e.isBoosted
                    : isVerifiedSelected
                    ? e.isVerified
                    : true) &&
                (selectedCats.isEmpty ? true : selectedCats.contains(e.icon)),
          )
          .map((e) => MapEntry(e.id, e)),
    );

    handleMovement();
    update();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: GestureDetector(
          onTap: () => update(() => mapKey = Key(DateTime.now().millisecondsSinceEpoch.toString())),
          child: const Text('BTC Map'),
        ),
        actions: [
          IconButton(
            onPressed: () async {
              LatLng? location;
              try {
                location = await mapController?.requestMyLocationLatLng();
              } catch (_) {}
              if (!context.mounted) return;

              final placeId = await showModalBottomSheet(
                context: context,
                showDragHandle: true,
                isScrollControlled: true,
                useSafeArea: true,
                shape: const RoundedRectangleBorder(borderRadius: BorderRadius.vertical(top: Radius.circular(24))),
                routeSettings: const RouteSettings(name: 'BtcMapSearchBottomSheet'),
                builder: (context) => BtcMapSearchBottomSheet(currentLocation: location ?? const LatLng(0, 0)),
              );
              final place = places[placeId];
              if (place == null) return;
              selectPlace(place, animate: true);
            },
            icon: const Icon(Icons.search),
          ),
          PopupMenuButton(
            icon: const Icon(Icons.more_vert),
            itemBuilder: (context) => [
              PopupMenuItem(
                child: const Text('Add location'),
                onTap: () => launchUrlString('https://btcmap.org/add-location#noob'),
              ),
            ],
          ),
        ],
      ),
      body: Stack(
        children: [
          SizedBox.expand(
            child: isDesktop
                ? MapLibreWeb(
                    key: mapKey,
                    style: Config.current.getServerCDNEndpoint('map${context.isDarkMode ? '-fiord' : ''}.json'),
                    initialCameraPosition: initialCameraPosition,
                    onMapCreated: (controller) {
                      mapWebController = controller;
                      controller._web?.addJavaScriptHandler(handlerName: 'onMove', callback: (_) => handleMovement());

                      controller._web?.addJavaScriptHandler(
                        handlerName: 'markerClick',
                        callback: (args) {
                          if (args.firstOrNull case {
                            'id': final String id,
                            'isCluster': bool _,
                            'lng': double _,
                            'lat': double _,
                          }) {
                            onSymbolClicked(id);
                          }
                        },
                      );
                    },
                    onStyleLoaded: () async {
                      await buildIcons();
                    },
                  )
                : MapLibreMap(
                    key: mapKey,
                    styleString: Config.current.getServerCDNEndpoint('map${context.isDarkMode ? '-fiord' : ''}.json'),
                    initialCameraPosition: initialCameraPosition,
                    trackCameraPosition: true,
                    onMapCreated: (controller) {
                      mapController = controller;
                      controller.onSymbolTapped.add(onSymbolClickStub);
                      controller.addListener(handleMovement);
                    },
                    annotationOrder: const [
                      AnnotationType.fill,
                      AnnotationType.circle,
                      AnnotationType.line,
                      AnnotationType.symbol,
                    ],
                    onStyleLoadedCallback: () {
                      scheduleMicrotask(() async {
                        try {
                          await mapController?.symbolManager?.setIconAllowOverlap(true);
                          await mapController?.symbolManager?.setIconIgnorePlacement(true);
                        } catch (_) {}
                      });
                      buildIcons();
                    },
                    myLocationEnabled: true,
                    myLocationRenderMode: MyLocationRenderMode.compass,
                    attributionButtonPosition: AttributionButtonPosition.bottomLeft,
                    attributionButtonMargins: const math.Point(16, 16),
                  ),
          ),
          Positioned(
            top: 8,
            left: 8,
            right: 8,
            child: Align(
              alignment: Alignment.centerLeft,
              child: GestureDetector(
                onTap: () => update(() => isFiltering = !isFiltering),
                child: DecoratedBox(
                  decoration: BoxDecoration(color: Colors.white30, borderRadius: BorderRadius.circular(16)),
                  child: AnimatedCrossFade(
                    duration: const Duration(milliseconds: 300),
                    alignment: Alignment.topLeft,
                    crossFadeState: isFiltering ? CrossFadeState.showFirst : CrossFadeState.showSecond,
                    firstChild: SizedBox(
                      width: 48,
                      height: 48,
                      child: Center(
                        child: Badge(
                          isLabelVisible: selectedCats.isNotEmpty,
                          label: Text(selectedCats.length.toString()),
                          offset: const Offset(8, -8),
                          backgroundColor: AppColors.primaryColor.withValues(alpha: 0.7),
                          child: const Icon(Icons.filter_alt_outlined),
                        ),
                      ),
                    ),
                    secondChild: Padding(
                      padding: const EdgeInsets.symmetric(vertical: 8),
                      child: Column(
                        crossAxisAlignment: .start,
                        spacing: 12,
                        children: [
                          SingleChildScrollView(
                            padding: const EdgeInsets.symmetric(horizontal: 8),
                            scrollDirection: Axis.horizontal,
                            child: Row(
                              spacing: 8,
                              children: [
                                FilterChip(
                                  materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
                                  selected: selectedCats.isEmpty,
                                  label: const Text('All'),
                                  onSelected: (value) {
                                    selectedCats.clear();
                                    applyFilter();
                                  },
                                ),
                                for (final cat in topCategories)
                                  FilterChip(
                                    materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
                                    selected: selectedCats.contains(cat),
                                    label: Text(cat.split('_').map((e) => e.capitalize).join(' ')),
                                    onSelected: (value) {
                                      value ? selectedCats.add(cat) : selectedCats.remove(cat);
                                      applyFilter();
                                    },
                                  ),
                              ],
                            ),
                          ),
                          Row(
                            children: [
                              Expanded(
                                child: SingleChildScrollView(
                                  padding: const EdgeInsets.symmetric(horizontal: 8),
                                  scrollDirection: Axis.horizontal,
                                  child: Row(
                                    spacing: 8,
                                    children: [
                                      FilterChip(
                                        materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
                                        selected: !isVerifiedSelected && !isBoostedSelected,
                                        label: const Text('All'),
                                        onSelected: (value) {
                                          update(
                                            () => value
                                                ? isVerifiedSelected = isBoostedSelected = false
                                                : isVerifiedSelected = true,
                                          );
                                          applyFilter();
                                        },
                                      ),
                                      FilterChip(
                                        materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
                                        selected: isVerifiedSelected,
                                        label: const Text('Verified'),
                                        onSelected: (value) {
                                          update(() => isVerifiedSelected = !isVerifiedSelected);
                                          applyFilter();
                                        },
                                      ),
                                      FilterChip(
                                        materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
                                        selected: isBoostedSelected,
                                        label: const Text('Boosted'),
                                        onSelected: (value) {
                                          update(() => isBoostedSelected = !isBoostedSelected);
                                          applyFilter();
                                        },
                                      ),
                                    ],
                                  ),
                                ),
                              ),
                              const Icon(Icons.close),
                              const SizedBox(width: 12),
                            ],
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ),
          if (!isDesktop)
            Positioned(
              right: 16,
              bottom: 16,
              child: FloatingActionButton(
                onPressed: () async {
                  Future<bool> isPermissionGranted() async {
                    try {
                      await mapController?.requestMyLocationLatLng();
                      return true;
                    } catch (_) {}
                    return false;
                  }

                  if (!await isPermissionGranted()) {
                    await Permission.locationWhenInUse.request();
                    update(() => mapKey = Key(DateTime.now().millisecondsSinceEpoch.toString()));
                    if (!await isPermissionGranted()) {
                      // ToastService.show('Please provide location permission!');
                      return;
                    }
                  }

                  try {
                    final location = await mapController?.requestMyLocationLatLng();
                    if (location == null) return;
                    Duration animationDuration = const Duration(seconds: 1);
                    final currentPoint = mapController?.cameraPosition?.target;
                    if (currentPoint != null) {
                      final distance = haversineDistance(
                        location.latitude,
                        location.longitude,
                        currentPoint.latitude,
                        currentPoint.longitude,
                      );
                      animationDuration = Duration(milliseconds: (distance / 2).floor().clamp(500, 50000));
                    }
                    await mapController?.animateCamera(
                      CameraUpdate.newLatLngZoom(location, 14),
                      duration: animationDuration,
                    );
                  } catch (_) {}
                },
                child: const Icon(Icons.my_location),
              ),
            ),
          if (selectedPlace != null)
            NotificationListener<DraggableScrollableNotification>(
              onNotification: (notification) {
                if (notification.extent == 0) {
                  unselectPlace();
                }
                return false;
              },
              child: DraggableScrollableSheet(
                initialChildSize: 0.4,
                minChildSize: 0,
                snap: true,
                maxChildSize: 0.9,
                snapSizes: const [0.1, 0.4, 0.9],
                builder: (BuildContext context, ScrollController scrollController) {
                  return Material(
                    color: context.themedColor(bright: Colors.white, dark: AppColors.darkCardColor),
                    borderRadius: const BorderRadius.only(topLeft: Radius.circular(16), topRight: Radius.circular(16)),
                    child: SingleChildScrollView(
                      controller: scrollController,
                      padding: const EdgeInsets.all(16) + context.keyboardPadding,
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        crossAxisAlignment: .start,
                        spacing: 12,
                        children: [
                          Row(
                            spacing: 16,
                            children: [
                              Container(
                                height: 45,
                                width: 45,
                                clipBehavior: Clip.antiAlias,
                                decoration: BoxDecoration(
                                  shape: BoxShape.circle,
                                  color: AppColors.primaryColor.withValues(alpha: 0.5),
                                ),
                                child: Center(
                                  child: Text(
                                    selectedPlace!.icon,
                                    style: const TextStyle(
                                      color: Colors.white,
                                      fontSize: 24,
                                      fontFamily: 'MaterialIcons2',
                                    ),
                                  ),
                                ),
                              ),
                              Expanded(
                                child: Text(
                                  selectedPlace!.nameToShow,
                                  style: const TextStyle(fontSize: 20, fontWeight: FontWeight.bold),
                                ),
                              ),
                              IconButton(
                                onPressed: () => unselectPlace(),
                                icon: const Icon(Icons.close),
                                style: IconButton.styleFrom(
                                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(99)),
                                ),
                              ),
                            ],
                          ),
                          Row(
                            spacing: 12,
                            children: [
                              SizedBox.square(
                                dimension: 32,
                                child: Tooltip(
                                  triggerMode: TooltipTriggerMode.tap,
                                  message: selectedPlace!.acceptOnChain == null
                                      ? 'On-Chain: Unknown'
                                      : 'On-Chain ${!selectedPlace!.acceptOnChain! ? 'not ' : ''}accepted!',
                                  child: ClipRRect(
                                    borderRadius: BorderRadiusGeometry.circular(99),
                                    child: Stack(
                                      fit: StackFit.expand,
                                      children: [
                                        SvgPicture.string(
                                          AppImages.bitcoinSVG,
                                          colorFilter: ColorFilter.mode(
                                            selectedPlace!.acceptOnChain ?? false ? Colors.orange : Colors.grey,
                                            BlendMode.srcIn,
                                          ),
                                        ),
                                        if (!(selectedPlace!.acceptOnChain ?? false))
                                          Transform.rotate(
                                            angle: 0.78,
                                            child: const Divider(color: Colors.grey, thickness: 3),
                                          ),
                                      ],
                                    ),
                                  ),
                                ),
                              ),
                              SizedBox.square(
                                dimension: 32,
                                child: Tooltip(
                                  triggerMode: TooltipTriggerMode.tap,
                                  message: selectedPlace!.acceptLightning == null
                                      ? 'Lightning: Unknown'
                                      : 'Lightning ${!selectedPlace!.acceptLightning! ? 'not ' : ''}accepted!',
                                  child: Stack(
                                    fit: StackFit.expand,
                                    children: [
                                      SvgPicture.string(
                                        AppImages.lightningSVG,
                                        colorFilter: ColorFilter.mode(
                                          selectedPlace!.acceptLightning ?? false ? Colors.orange : Colors.grey,
                                          BlendMode.srcIn,
                                        ),
                                      ),
                                      if (!(selectedPlace!.acceptLightning ?? false))
                                        Transform.rotate(
                                          angle: 0.78,
                                          child: const Divider(color: Colors.grey, thickness: 3),
                                        ),
                                    ],
                                  ),
                                ),
                              ),
                              SizedBox.square(
                                dimension: 32,
                                child: Tooltip(
                                  triggerMode: TooltipTriggerMode.tap,
                                  message: selectedPlace!.acceptLightningContactLess == null
                                      ? 'Lightning contactless: Unknown'
                                      : 'Lightning contactless ${!selectedPlace!.acceptLightningContactLess! ? 'not ' : ''}accepted!',
                                  child: Stack(
                                    fit: StackFit.expand,
                                    children: [
                                      Icon(
                                        CupertinoIcons.radiowaves_right,
                                        size: 32,
                                        color: selectedPlace!.acceptLightningContactLess ?? false ? null : Colors.grey,
                                      ),
                                      if (!(selectedPlace!.acceptLightningContactLess ?? false))
                                        Transform.rotate(
                                          angle: 0.78,
                                          child: const Divider(color: Colors.grey, thickness: 3),
                                        ),
                                    ],
                                  ),
                                ),
                              ),
                            ],
                          ),
                          ElevatedButtonTheme(
                            data: ElevatedButtonThemeData(
                              style: Theme.of(context).elevatedButtonTheme.style?.copyWith(
                                shape: WidgetStatePropertyAll(
                                  RoundedRectangleBorder(borderRadius: BorderRadiusGeometry.circular(99)),
                                ),
                              ),
                            ),
                            child: Wrap(
                              spacing: 8,
                              runSpacing: 8,
                              children: [
                                ElevatedButton(
                                  onPressed: () async {
                                    final availableMaps = await MapLauncher.installedMaps;
                                    if (!context.mounted) return;
                                    if (availableMaps.isEmpty) {
                                      await launchUrlString('geo:${selectedPlace!.lat},${selectedPlace!.lon}');
                                      return;
                                    }
                                    if (availableMaps.length == 1) {
                                      await availableMaps.first.showDirections(
                                        destination: Coords(selectedPlace!.lat, selectedPlace!.lon),
                                        destinationTitle: selectedPlace!.nameToShow,
                                      );
                                      return;
                                    }
                                    await showModalBottomSheet(
                                      context: context,
                                      useSafeArea: true,
                                      builder: (BuildContext context) {
                                        return SingleChildScrollView(
                                          child: Column(
                                            children: [
                                              for (final map in availableMaps)
                                                ListTile(
                                                  onTap: () => map.showDirections(
                                                    destination: Coords(selectedPlace!.lat, selectedPlace!.lon),
                                                  ),
                                                  leading: ClipRRect(
                                                    borderRadius: BorderRadius.circular(8),
                                                    child: SvgPicture.asset(map.icon, height: 30.0, width: 30.0),
                                                  ),
                                                  title: Text(map.mapName),
                                                ),
                                            ],
                                          ),
                                        );
                                      },
                                    );
                                  },
                                  child: const Row(
                                    spacing: 8,
                                    mainAxisSize: MainAxisSize.min,
                                    children: [Icon(Icons.directions_outlined), Text('Directions')],
                                  ),
                                ),
                                ElevatedButton(
                                  onPressed: () async {
                                    await SharePlus.instance.share(
                                      ShareParams(
                                        text: 'https://btcmap.org/merchant/${selectedPlace!.osmId}',
                                        title: selectedPlace!.nameToShow,
                                        sharePositionOrigin: context.sharePlusRect,
                                      ),
                                    );
                                  },
                                  child: const Row(
                                    spacing: 8,
                                    mainAxisSize: MainAxisSize.min,
                                    children: [Icon(Icons.share_outlined), Text('Share')],
                                  ),
                                ),
                                ElevatedButton(
                                  onPressed: () =>
                                      launchUrlString('https://btcmap.org/verify-location?id=${selectedPlace!.osmId}'),
                                  child: const Row(
                                    spacing: 8,
                                    mainAxisSize: MainAxisSize.min,
                                    children: [Icon(Icons.verified_user_outlined), Text('Verify')],
                                  ),
                                ),
                                ElevatedButton(
                                  onPressed: () async {
                                    startLoader();
                                    final res = await MapService.getBoostQuote();
                                    stopLoader();
                                    if (res != null && context.mounted) {
                                      await showDialog(
                                        context: context,
                                        builder: (context) =>
                                            MapPlaceBoostDialog(placeId: selectedPlace!.id, quote: res),
                                      );
                                    }
                                  },
                                  child: const Row(
                                    spacing: 8,
                                    mainAxisSize: MainAxisSize.min,
                                    children: [Icon(Icons.arrow_circle_up), Text('Boost')],
                                  ),
                                ),
                              ],
                            ),
                          ),
                          ListTileTheme(
                            data: const ListTileThemeData(minTileHeight: 48),
                            child: Column(
                              children: [
                                if (selectedPlace!.verifiedAtUTC != null)
                                  Tooltip(
                                    triggerMode: TooltipTriggerMode.tap,
                                    message: selectedPlace!.isVerified ? 'verified' : 'Place is outdated',
                                    child: ListTile(
                                      leading: Icon(
                                        selectedPlace!.isVerified ? Icons.verified : Icons.verified_outlined,
                                        color: selectedPlace!.isVerified ? AppColors.primaryColor : Colors.red,
                                      ),
                                      title: Text(dateFormat.format(selectedPlace!.verifiedAtUTC!.toLocal())),
                                    ),
                                  ),
                                if (selectedPlace!.address?.isNotEmpty ?? false)
                                  ListTile(
                                    leading: const Icon(Icons.location_on_outlined),
                                    title: Text(selectedPlace!.address!),
                                  ),
                                ListTile(
                                  leading: const Icon(Icons.access_time),
                                  title: Text(selectedPlace!.openingHours ?? '24/7', style: const TextStyle()),
                                ),
                                if (selectedPlace!.phone?.isNotEmpty ?? false)
                                  ListTile(
                                    leading: const Icon(Icons.phone_outlined),
                                    title: Text(
                                      selectedPlace!.phone!,
                                      style: TextStyle(
                                        decoration: TextDecoration.underline,
                                        color: Colors.blue.shade600,
                                        decorationColor: Colors.blue.shade600,
                                      ),
                                    ),
                                    onTap: () => launchUrlString('tel:${selectedPlace!.phone}'),
                                  ),
                                if (selectedPlace!.email?.isNotEmpty ?? false)
                                  ListTile(
                                    leading: const Icon(Icons.email_outlined),
                                    title: Text(
                                      selectedPlace!.email!,
                                      style: TextStyle(
                                        decoration: TextDecoration.underline,
                                        color: Colors.blue.shade600,
                                        decorationColor: Colors.blue.shade600,
                                      ),
                                    ),
                                    onTap: () => launchUrlString('mailto:${selectedPlace!.email}'),
                                  ),
                                if (selectedPlace!.website?.isNotEmpty ?? false)
                                  ListTile(
                                    leading: const Icon(Icons.public),
                                    title: Text(
                                      selectedPlace!.website!,
                                      style: TextStyle(
                                        decoration: TextDecoration.underline,
                                        color: Colors.blue.shade600,
                                        decorationColor: Colors.blue.shade600,
                                      ),
                                    ),
                                    onTap: () => launchUrlString(selectedPlace!.website!),
                                  ),
                                if (selectedPlace!.twitter?.isNotEmpty ?? false)
                                  ListTile(
                                    leading: Image.asset(
                                      AppImages.x,
                                      width: 24,
                                      color: context.isDarkMode ? Colors.white : null,
                                    ),
                                    title: Text(
                                      selectedPlace!.xName!,
                                      style: TextStyle(
                                        decoration: TextDecoration.underline,
                                        color: Colors.blue.shade600,
                                        decorationColor: Colors.blue.shade600,
                                      ),
                                    ),
                                    onTap: () => launchUrlString(selectedPlace!.twitter!),
                                  ),
                                if (selectedPlace!.facebook?.isNotEmpty ?? false)
                                  ListTile(
                                    leading: Image.asset(
                                      AppImages.facebook,
                                      width: 24,
                                      color: context.isDarkMode ? Colors.white : null,
                                    ),
                                    title: Text(
                                      selectedPlace!.facebookName!,
                                      style: TextStyle(
                                        decoration: TextDecoration.underline,
                                        color: Colors.blue.shade600,
                                        decorationColor: Colors.blue.shade600,
                                      ),
                                    ),
                                    onTap: () => launchUrlString(selectedPlace!.facebook!),
                                  ),
                                if (selectedPlace!.instagram?.isNotEmpty ?? false)
                                  ListTile(
                                    leading: Image.asset(
                                      AppImages.instagram,
                                      width: 24,
                                      color: context.isDarkMode ? Colors.white : null,
                                    ),
                                    title: Text(
                                      selectedPlace!.instagramName!,
                                      style: TextStyle(
                                        decoration: TextDecoration.underline,
                                        color: Colors.blue.shade600,
                                        decorationColor: Colors.blue.shade600,
                                      ),
                                    ),
                                    onTap: () => launchUrlString(selectedPlace!.instagram!),
                                  ),
                                if (selectedPlace!.line?.isNotEmpty ?? false)
                                  ListTile(
                                    leading: Image.asset(
                                      AppImages.line,
                                      width: 24,
                                      color: context.isDarkMode ? Colors.white : null,
                                    ),
                                    title: Text(
                                      selectedPlace!.lineName!,
                                      style: TextStyle(
                                        decoration: TextDecoration.underline,
                                        color: Colors.blue.shade600,
                                        decorationColor: Colors.blue.shade600,
                                      ),
                                    ),
                                    onTap: () => launchUrlString(selectedPlace!.line!),
                                  ),
                              ],
                            ),
                          ),
                          Column(
                            crossAxisAlignment: .start,
                            spacing: 12,
                            children: [
                              Text(
                                '${selectedPlace!.commentCount} Comments',
                                style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w600),
                              ),
                              TextFormField(
                                controller: commentController,
                                decoration: const InputDecoration(
                                  hintText: 'write comment',
                                  isDense: true,
                                  contentPadding: EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                                ),
                                keyboardType: TextInputType.multiline,
                                maxLines: 3,
                                minLines: 1,
                                cursorColor: AppColors.primaryColor,
                                textInputAction: TextInputAction.send,
                                onChanged: (value) => update(),
                              ),
                              if (commentController.text.trim().isNotEmpty)
                                Column(
                                  crossAxisAlignment: .start,
                                  spacing: 4,
                                  children: [
                                    const Text(
                                      'All comments are currently anonymous. BTC-Map collect a small fee as spam protection measure.\n'
                                      "Your comment will be published after payment when BTC-Map's bots confirm the payment.",
                                    ),
                                    Row(
                                      children: [
                                        const Text('Current fee: '),
                                        AmountText(amountSat: commentQuote ?? 0),
                                      ],
                                    ),
                                    Align(
                                      alignment: Alignment.centerRight,
                                      child: ElevatedButton(
                                        onPressed: () async {
                                          startLoader();
                                          final invoice = await MapService.postComment(
                                            selectedPlace!.id,
                                            commentController.text.trim(),
                                          );
                                          stopLoader();
                                          if (invoice != null && context.mounted) {
                                            await showDialog(
                                              context: context,
                                              builder: (context) => AlertDialog(
                                                title: const Text(
                                                  'Do you want to pay given invoice to post comment on BTC-Map?',
                                                  style: TextStyle(fontSize: 16),
                                                ),
                                                actions: [
                                                  TextButton(onPressed: () => AppRouter.pop(), child: const Text('No')),
                                                  TextButton(
                                                    onPressed: () async {
                                                      AppRouter.pop();
                                                      unawaited(AppRouter.push(SendScreen(address: invoice)));
                                                    },
                                                    child: const Text('Yes'),
                                                  ),
                                                ],
                                              ),
                                            );
                                          }
                                        },
                                        style: ElevatedButton.styleFrom(
                                          shape: RoundedRectangleBorder(
                                            borderRadius: BorderRadiusGeometry.circular(99),
                                          ),
                                        ),
                                        child: const Text('Comment'),
                                      ),
                                    ),
                                  ],
                                ),
                            ],
                          ),
                          FutureBuilder(
                            future: MapService.getComments(selectedPlace!),
                            builder: (context, snapshot) {
                              if (snapshot.data != null) {
                                return Column(
                                  crossAxisAlignment: .stretch,
                                  spacing: 2,
                                  children: [
                                    for (final comment
                                        in snapshot.data!..sort((a, b) => b.createAt.compareTo(a.createAt)))
                                      Card(
                                        child: Padding(
                                          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                                          child: Stack(
                                            children: [
                                              Text.rich(
                                                TextSpan(
                                                  children: [
                                                    TextSpan(text: comment.text),
                                                    const WidgetSpan(child: SizedBox(width: 64)),
                                                  ],
                                                ),
                                              ),
                                              Positioned(
                                                bottom: 0,
                                                right: 0,
                                                child: Text(
                                                  DateFormat('dd MMM yyyy').format(comment.createAt.toLocal()),
                                                  style: const TextStyle(color: Colors.grey, fontSize: 10),
                                                ),
                                              ),
                                            ],
                                          ),
                                        ),
                                      ),
                                  ],
                                );
                              }
                              return const Center(child: CircularProgressIndicator());
                            },
                          ),
                        ],
                      ),
                    ),
                  );
                },
              ),
            ),
        ],
      ),
    );
  }

  void onSymbolClickStub(Symbol s) {
    onSymbolClicked(s.id);
  }

  void onSymbolClicked(String idString) {
    final id = parseInt(idString);
    final place = visiblePlaces[id];
    if (place != null) {
      selectPlace(place);
    } else {
      final cluster = clusters[id];
      if (cluster == null) return;
      const padding = 100.0;
      double north = -90.0;
      double south = 90.0;
      double east = -180.0;
      double west = 180.0;

      for (final id in cluster.ids) {
        final place = places[id];
        if (place == null) continue;
        final lat = place.lat;
        final lng = place.lon;

        if (lat > north) north = lat;
        if (lat < south) south = lat;
        if (lng > east) east = lng;
        if (lng < west) west = lng;
      }

      if (isDesktop) {
        mapWebController?.fitBounds(west, south, east, north, padding: padding, duration: 500);
      } else {
        mapController?.animateCamera(
          CameraUpdate.newLatLngBounds(
            LatLngBounds(southwest: LatLng(south, west), northeast: LatLng(north, east)),
            left: padding,
            bottom: padding,
            right: padding,
            top: padding,
          ),
          duration: const Duration(milliseconds: 500),
        );
      }
    }
  }

  void selectPlace(MapPlace place, {bool animate = false}) async {
    commentController.clear();
    update(() => selectedPlace = place);

    if (isDesktop) {
      await mapWebController?.updateGeoJsonSource('selected', {
        'type': 'FeatureCollection',
        'features': [
          {
            'type': 'Feature',
            'id': '-1',
            'properties': {'id': '-1', 'icon': '${place.icon}${place.isBoosted ? '-boosted' : ''}'},
            'geometry': {
              'type': 'Point',
              'coordinates': [place.lon, place.lat],
            },
          },
        ],
      });
    } else {
      await mapController?.circleManager?.add(
        Circle(
          '-1',
          CircleOptions(
            geometry: place.latLong,
            circleRadius: 20,
            circleColor: context.themedColor(bright: Colors.black, dark: Colors.white).toHexStringRGB(),
            circleOpacity: .25,
            circleBlur: .6,
          ),
        ),
      );
    }

    if (animate) {
      Duration animationDuration = const Duration(milliseconds: 500);
      final currentPoint = (isDesktop ? await mapWebController?.getCameraPosition() : mapController?.cameraPosition);
      if (currentPoint != null) {
        final distance = haversineDistance(
          place.lat,
          place.lon,
          currentPoint.target.latitude,
          currentPoint.target.longitude,
        );
        animationDuration = Duration(milliseconds: distance.floor().clamp(500, 50000));
      }
      if (isDesktop) {
        await mapWebController?.flyTo(
          CameraPosition(
            target: LatLng(place.lat, place.lon),
            zoom: currentPoint?.zoom ?? 0,
            tilt: currentPoint?.tilt ?? 0,
            bearing: currentPoint?.bearing ?? 0,
          ),
          duration: animationDuration.inMilliseconds,
        );
      } else {
        await mapController?.animateCamera(CameraUpdate.newLatLng(place.latLong), duration: animationDuration);
      }
    }
  }

  void unselectPlace({bool onlyHide = false}) async {
    if (isDesktop) {
      await mapWebController?.updateGeoJsonSource('selected', {'type': 'FeatureCollection', 'features': []});
    } else {
      await mapController?.circleManager?.remove(Circle('-1', CircleOptions.defaultOptions));
    }

    if (!onlyHide) {
      update(() => selectedPlace = null);
    }
  }

  void handleMovement() {
    movementHandlerThrottler.run(() async {
      if (isDesktop) {
        if (mapWebController == null || !mapWebController!.isReady) return;
      } else {
        if (mapController?.circleManager == null || mapController?.symbolManager == null) return;
      }

      final cameraPosition = isDesktop ? await mapWebController!.getCameraPosition() : mapController?.cameraPosition;
      locationSaverDebouncer.call(() async {
        final currentPoint = cameraPosition?.target;
        if (currentPoint != null) {
          await AppState.prefs.setString(
            'lastUserLocation',
            '${currentPoint.latitude},${currentPoint.longitude},${cameraPosition!.zoom}',
          );
        }
      });

      final region = isDesktop ? await mapWebController!.getVisibleRegion() : await mapController!.getVisibleRegion();
      if (cameraPosition != null && region != null) {
        final clusterData = DistanceCluster(
          places.values.toList(),
          radiusPx: 45,
        ).getClusters(region, cameraPosition.zoom.round());
        clusters = Map.fromEntries(clusterData.$1.map((e) => MapEntry(e.key(), e)));
        visiblePlaces = Map.fromEntries(clusterData.$2.map((e) => MapEntry(e.id, e)));

        if (selectedPlace != null) {
          if (!visiblePlaces.keys.contains(selectedPlace!.id)) {
            unselectPlace(onlyHide: true);
          } else {
            selectPlace(selectedPlace!);
          }
        }

        if (isDesktop) {
          await mapWebController!.updateGeoJsonSource('clusters', {
            'type': 'FeatureCollection',
            'features': clusters.entries.map((e) {
              final count = e.value.ids.length;

              return {
                'type': 'Feature',
                'properties': {
                  'id': e.key.toString(),
                  'count': count.toString(),
                  'radius': mapRange(count.toDouble(), 2, 3000, 12, 20),
                  'textSize': mapRange(count.toDouble(), 2, 3000, 10, 16),
                },
                'geometry': {
                  'type': 'Point',
                  'coordinates': [e.value.position.longitude, e.value.position.latitude],
                },
              };
            }).toList(),
          });

          await mapWebController!.updateGeoJsonSource('markers', {
            'type': 'FeatureCollection',
            'features': visiblePlaces.entries.map((e) {
              final iconName = '${e.value.icon}${e.value.isBoosted ? '-boosted' : ''}';
              return {
                'type': 'Feature',
                'properties': {'id': e.value.id.toString(), 'icon': iconName},
                'geometry': {
                  'type': 'Point',
                  'coordinates': [e.value.lon, e.value.lat],
                },
              };
            }).toList(),
          });
        } else {
          final Set<Circle> circlesToDelete = mapController!.circles
              .where((c) => !clusters.keys.contains(int.parse(c.id)))
              .toSet();
          final Set<int> circlesToAdd = clusters.keys.toSet().difference(
            circlesToDelete.map((e) => parseInt(e)).toSet(),
          );

          await mapController!.circleManager?.removeAll(circlesToDelete);
          await mapController!.circleManager?.addAll(
            circlesToAdd
                .where((id) => clusters.containsKey(id))
                .map(
                  (e) => Circle(
                    e.toString(),
                    CircleOptions(
                      geometry: clusters[e]!.position,
                      circleRadius: mapRange(clusters[e]!.ids.length.toDouble(), 2, 3000, 12, 20),
                      circleColor: AppColors.primaryColor.withValues(alpha: 0.8).toHexStringRGB(),
                    ),
                  ),
                ),
          );

          final Set<int> allSymbolIds = {...clusters.keys, ...visiblePlaces.keys};
          final Set<Symbol> symbolsToDelete = mapController!.symbols
              .where((s) => !allSymbolIds.contains(int.parse(s.id)))
              .toSet();
          final Set<int> clusterCountSymbolsToAdd = clusters.keys.toSet().difference(
            symbolsToDelete.map((e) => parseInt(e)).toSet(),
          );
          final Set<int> markersToAdd = visiblePlaces.keys.toSet().difference(
            symbolsToDelete.map((e) => parseInt(e)).toSet(),
          );

          await mapController!.symbolManager?.removeAll(symbolsToDelete);
          await mapController!.symbolManager?.addAll(
            clusterCountSymbolsToAdd
                .where((id) => clusters.containsKey(id))
                .map(
                  (e) => Symbol(
                    e.toString(),
                    SymbolOptions(
                      geometry: clusters[e]!.position,
                      textField: clusters[e]!.ids.length.toString(),
                      textColor: '#ffffff',
                      textSize: mapRange(clusters[e]!.ids.length.toDouble(), 2, 3000, 10, 16),
                      fontNames: ['Noto Sans Regular'],
                    ),
                  ),
                ),
          );

          await mapController!.symbolManager?.addAll(
            markersToAdd
                .where((id) => visiblePlaces.containsKey(id))
                .map(
                  (e) => Symbol(
                    e.toString(),
                    SymbolOptions(
                      geometry: visiblePlaces[e]!.latLong,
                      iconImage: '${visiblePlaces[e]!.icon}${visiblePlaces[e]!.isBoosted ? '-boosted' : ''}',
                      iconAnchor: 'bottom',
                    ),
                  ),
                ),
          );
        }
      }
    });
  }

  Future<Uint8List?> getBytesFromIconData(ui.Image markerAsset, String icon) async {
    const boostBGColor = ui.Color.fromARGB(255, 247, 147, 26);
    const double size = 96.0;
    final recorder = ui.PictureRecorder();
    final canvas = ui.Canvas(recorder);
    final iconParts = icon.split('-');
    if (iconParts.isEmpty) return null;

    canvas.drawImageRect(
      markerAsset,
      ui.Rect.fromLTRB(0, 0, markerAsset.width.toDouble(), markerAsset.height.toDouble()),
      const ui.Rect.fromLTRB(0, 0, size, size),
      ui.Paint()
        ..colorFilter = ui.ColorFilter.mode(
          iconParts.length > 1 ? boostBGColor : AppColors.primaryColor,
          ui.BlendMode.srcATop,
        ),
    );

    final builder = ui.ParagraphBuilder(
      ui.ParagraphStyle(textAlign: ui.TextAlign.center, fontSize: size / 2.1, fontFamily: 'MaterialIcons2'),
    )..addText(iconParts.first);
    final iconParagraph = builder.build()..layout(const ui.ParagraphConstraints(width: size));

    final xOffset = (size - iconParagraph.width) / 2;
    final yOffset = (size - iconParagraph.height) / 2 - size * 0.09; // to offset text slightly up

    canvas.drawParagraph(iconParagraph, ui.Offset(xOffset, yOffset));

    final image = await recorder.endRecording().toImage(size.toInt(), size.toInt());
    final byteData = await image.toByteData(format: ui.ImageByteFormat.png);

    return byteData?.buffer.asUint8List();
  }

  Future<void> buildIcons() async {
    try {
      final byteData = await rootBundle.load('assets/images/marker.png');
      final markerAsset = await decodeImageFromList(byteData.buffer.asUint8List());
      final Set<String> icons = places.values.map((e) => '${e.icon}${e.isBoosted ? '-boosted' : ''}').toSet();

      for (final icon in icons) {
        if (!MapService.mapIconBox.containsKey(icon)) {
          unawaited(MapService.mapIconBox.put(icon, await getBytesFromIconData(markerAsset, icon)));
        }
        final iconBytes = MapService.mapIconBox.get(icon);
        if (iconBytes != null) {
          if (isDesktop) {
            unawaited(
              mapWebController?.addImage(icon, iconBytes).onError((error, stackTrace) {
                //ignore
              }),
            );
          } else {
            unawaited(
              mapController?.addImage(icon, iconBytes).onError((error, stackTrace) {
                //ignore
              }),
            );
          }
        }
      }

      Future.delayed(const Duration(milliseconds: 500), () => MapService.mapIconBox.compact());
    } catch (e, s) {
      logE(e, stackTrace: s);
    }
  }
}

class MapPlaceBoostDialog extends StatefulWidget {
  const MapPlaceBoostDialog({required this.placeId, required this.quote, super.key});

  final int placeId;
  final (int, int, int) quote;

  @override
  State<MapPlaceBoostDialog> createState() => _MapPlaceBoostDialogState();
}

class _MapPlaceBoostDialogState extends State<MapPlaceBoostDialog> {
  late int selected = widget.quote.$2;

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('Boost Location'),
      content: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          spacing: 16,
          children: [
            const Text(
              'Make this merchant stand out in bitcoin orange on the map, shine in the search results, and be discovered in the exclusive boosted locations map!',
              style: TextStyle(fontSize: 16),
            ),
            plan('1 month', widget.quote.$1),
            plan('3 month', widget.quote.$2),
            plan('12 month', widget.quote.$3),
            const Text(
              "The fee is used to support the BTC-Map open source project and continue it's development.\n"
              "Merchant will be boosted after payment when BTC-Map's bots confirm the payment.",
              style: TextStyle(fontSize: 12),
            ),
          ],
        ),
      ),
      actions: [
        TextButton(onPressed: () => AppRouter.pop(false), child: const Text('No')),
        TextButton(
          onPressed: () async {
            startLoader();
            final invoice = await MapService.boostPlace(
              widget.placeId,
              selected == widget.quote.$3
                  ? 365
                  : selected == widget.quote.$2
                  ? 90
                  : 30,
            );
            stopLoader();
            if (invoice != null && context.mounted) {
              await showDialog(
                context: context,
                builder: (context) => AlertDialog(
                  title: const Text(
                    'Do you want to pay given invoice to boost merchant on BTC-Map?',
                    style: TextStyle(fontSize: 16),
                  ),
                  actions: [
                    TextButton(onPressed: () => AppRouter.pop(), child: const Text('No')),
                    TextButton(
                      onPressed: () async {
                        AppRouter.pop();
                        AppRouter.pop();
                        unawaited(AppRouter.push(SendScreen(address: invoice)));
                      },
                      child: const Text('Yes'),
                    ),
                  ],
                ),
              );
            }
          },
          child: const Text('Boost'),
        ),
      ],
    );
  }

  Widget plan(String duration, int value) {
    return GestureDetector(
      onTap: () => update(() => selected = value),
      child: Container(
        width: double.infinity,
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(16),
          border: Border.all(
            color: selected == value ? AppColors.primaryColor : Colors.grey,
            width: selected == value ? 2 : 1,
          ),
        ),
        padding: const EdgeInsets.all(16),
        child: Row(
          spacing: 8,
          children: [
            Expanded(child: Text(duration, style: const TextStyle(fontSize: 16))),
            AmountText(amountSat: value, showFiat: true),
          ],
        ),
      ),
    );
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

class ClusterItem {
  ClusterItem(this.position, this.ids);

  final LatLng position;
  final Set<int> ids;

  int key() {
    const scale = 1e6;
    final lat = (position.latitude * scale).round();
    final lng = (position.longitude * scale).round();
    return (lat & 0xFFFFFFFF) << 32 | (lng & 0xFFFFFFFF);
  }

  @override
  String toString() => 'Position: $position\nIds : $ids\n';
}

class DistanceCluster {
  DistanceCluster(this.points, {this.radiusPx = 40.0, this.extent = 512});

  final List<MapPlace> points;
  final double radiusPx;
  final int extent;

  (List<ClusterItem>, List<MapPlace>) getClusters(LatLngBounds bounds, int zoom) {
    final scale = extent * pow(2, zoom).toDouble();
    final r = radiusPx;
    final r2 = r * r;

    // Pre-project points
    final projected = <(double, double, MapPlace)>[];
    for (final p in points) {
      if (!inBounds(p.latLong, bounds)) continue;
      final (x, y) = _project(p.latLong);
      projected.add((x * scale, y * scale, p));
    }

    // Hash grid
    final cellSize = r.ceil();
    final grid = <String, List<int>>{};
    for (int i = 0; i < projected.length; i++) {
      final (px, py, p) = projected[i];
      final cx = (px / cellSize).floor();
      final cy = (py / cellSize).floor();
      final key = '$cx:$cy';
      (grid[key] ??= []).add(i);
    }

    final visited = List<bool>.filled(projected.length, false);
    final clusters = (<ClusterItem>[], <MapPlace>[]);

    for (int i = 0; i < projected.length; i++) {
      if (visited[i]) continue;
      visited[i] = true;

      final (px, py, place) = projected[i];
      double sumX = px;
      double sumY = py;

      // collect neighbors within radius
      final neighbors = <int>{place.id};
      final cx = (px / cellSize).floor();
      final cy = (py / cellSize).floor();

      for (int dx = -1; dx <= 1; dx++) {
        for (int dy = -1; dy <= 1; dy++) {
          final key = '${cx + dx}:${cy + dy}';
          final bucket = grid[key];
          if (bucket == null) continue;
          for (final j in bucket) {
            if (visited[j]) continue;
            final (qx, qy, qp) = projected[j];
            final dx2 = qx - px;
            final dy2 = qy - py;
            if (dx2 * dx2 + dy2 * dy2 <= r2) {
              visited[j] = true;
              neighbors.add(qp.id);
              sumX += qx;
              sumY += qy;
            }
          }
        }
      }

      if (neighbors.length == 1) {
        // single point cluster
        clusters.$2.add(place);
      } else {
        // average position cluster
        final center = _unProject(sumX / neighbors.length / scale, sumY / neighbors.length / scale);
        clusters.$1.add(ClusterItem(center, neighbors));
      }
    }

    return clusters;
  }

  bool inBounds(LatLng p, LatLngBounds b) {
    final sw = b.southwest;
    final ne = b.northeast;

    if (p.latitude < sw.latitude || p.latitude > ne.latitude) {
      return false;
    }

    if (ne.longitude >= sw.longitude) {
      return p.longitude >= sw.longitude && p.longitude <= ne.longitude;
    } else {
      return (p.longitude >= sw.longitude && p.longitude <= 180) ||
          (p.longitude >= -180 && p.longitude <= ne.longitude);
    }
  }

  (double, double) _project(LatLng c) {
    final x = (c.longitude + 180.0) / 360.0;
    final sinLat = sin(c.latitude * pi / 180.0);
    final y = 0.5 - log((1 + sinLat) / (1 - sinLat)) / (4 * pi);
    return (x.clamp(0.0, 1.0), y.clamp(0.0, 1.0));
  }

  LatLng _unProject(double x, double y) {
    final longitude = x * 360.0 - 180.0;
    final latitude = math.atan(sinh((0.5 - y) * 2 * pi)) * 180.0 / pi;
    return LatLng(latitude, longitude);
  }
}

class MapLibreWebController {
  InAppWebViewController? _web;
  bool _isReady = false;
  bool get isReady => _isReady;

  void _attach(InAppWebViewController controller) {
    _web = controller;
  }

  Future<dynamic> _eval(String js) async {
    if (_web == null) throw StateError('Map not ready');
    return _web!.evaluateJavascript(source: js);
  }

  Future<void> _evalVoid(String js) => _eval(js);

  String _json(Object? o) => jsonEncode(o);

  Future<void> on(String event, String jsCallbackBody) => _evalVoid("map.on('$event', $jsCallbackBody);");

  Future<void> flyTo(CameraPosition pos, {int duration = 2000}) => _evalVoid('''map.flyTo(
      {
        center: [${pos.target.longitude}, ${pos.target.latitude}],
        zoom: ${pos.zoom},
        bearing: ${pos.bearing},
      }
    );''');

  Future<LatLngBounds?> getVisibleRegion() async {
    final raw = await _eval('''
    (() => {
      const b = map.getBounds();
      return {
        southwest: { lat: b.getSouth(), lng: b.getWest() },
        northeast: { lat: b.getNorth(), lng: b.getEast() }
      };
    })()
  ''');
    if (raw case {
      'southwest': {'lat': final double lat1, 'lng': final double lng1},
      'northeast': {'lat': final double lat2, 'lng': final double lng2},
    }) {
      return LatLngBounds(southwest: LatLng(lat1, lng1), northeast: LatLng(lat2, lng2));
    }
    return null;
  }

  Future<void> fitBounds(
    double west,
    double south,
    double east,
    double north, {
    double padding = 40,
    int duration = 1000,
  }) {
    return _evalVoid('''
    map.fitBounds(
      [[$west, $south], [$east, $north]],
      { padding: $padding, duration: $duration, essential: true }
    );
  ''');
  }

  Future<CameraPosition?> getCameraPosition() async {
    final raw = await _eval('''
      (() => {
        const c = map.getCenter();
        return {
          lng: c.lng,
          lat: c.lat,
          zoom: map.getZoom(),
          bearing: map.getBearing(),
          pitch: map.getPitch()
        };
      })()
    ''');
    if (raw case {
      'lng': final double lng,
      'lat': final double lat,
      'zoom': final double zoom,
      'bearing': final double bearing,
      'pitch': final double pitch,
    }) {
      return CameraPosition(target: LatLng(lat, lng), zoom: zoom, bearing: bearing, tilt: pitch);
    }

    return null;
  }

  Future<void> addSource(String id, Map<String, dynamic> sourceSpec) =>
      _evalVoid("map.addSource('$id', ${_json(sourceSpec)});");

  Future<void> removeSource(String id) => _evalVoid("map.removeSource('$id'});");

  Future<bool> hasSource(String id) async {
    return await _eval("map.getSource('$id') != null") == true;
  }

  Future<void> addLayer(Map<String, dynamic> layer, {String? beforeId}) {
    final before = beforeId != null ? ", '$beforeId'" : '';
    return _evalVoid('map.addLayer(${_json(layer)}$before);');
  }

  Future<void> removeLayer(String id) => _evalVoid("map.removeLayer('$id');");

  Future<void> setPaintProperty(String layerId, String name, dynamic value) =>
      _evalVoid("map.setPaintProperty('$layerId', '$name', ${_json(value)});");

  Future<void> setLayoutProperty(String layerId, String name, dynamic value) =>
      _evalVoid("map.setLayoutProperty('$layerId', '$name', ${_json(value)});");

  Future<void> setFilter(String layerId, List? filter) => _evalVoid("map.setFilter('$layerId', ${_json(filter)});");

  Future<void> addImage(String id, Uint8List pngBytes) {
    final base64String = base64Encode(pngBytes);
    final dataUrl = 'data:image/png;base64,$base64String';

    return _evalVoid('''
    if (!map.hasImage('$id')) {
      map.loadImage('$dataUrl').then((response) => {
        if (response && response.data && !map.hasImage('$id')) {
          map.addImage('$id', response.data);
        }
      });
    }
  ''');
  }

  Future<bool> hasImage(String id) async => await _eval("map.hasImage('$id')") == true;

  Future<void> removeImage(String id) => _evalVoid('map.removeImage($id);');

  Future<void> addGeoJsonSource(String id, Map<String, dynamic> geojson) =>
      addSource(id, {'type': 'geojson', 'data': geojson});

  Future<void> updateGeoJsonSource(String id, Map<String, dynamic> geojson) =>
      _evalVoid("map.getSource('$id').setData(${_json(geojson)});");

  void dispose() {
    _web?.dispose();
  }
}

/// The actual Flutter widget
class MapLibreWeb extends StatefulWidget {
  const MapLibreWeb({
    required this.style,
    super.key,
    this.initialCameraPosition = const CameraPosition(target: LatLng(20, 0), zoom: 1.5),
    this.onMapCreated,
    this.onStyleLoaded,
    this.interactive = true,
  });

  final String style;
  final CameraPosition initialCameraPosition;
  final void Function(MapLibreWebController controller)? onMapCreated;
  final void Function()? onStyleLoaded;
  final bool interactive;

  @override
  State<MapLibreWeb> createState() => _MapLibreWebState();
}

class _MapLibreWebState extends State<MapLibreWeb> {
  final MapLibreWebController controller = MapLibreWebController();

  final _html = '''
<!DOCTYPE html>
<html>
<head>
  <meta charset="utf-8">
  <meta name="viewport" content="width=device-width, initial-scale=1.0, maximum-scale=1.0, user-scalable=no">
  <link href="https://unpkg.com/maplibre-gl@5.6.0/dist/maplibre-gl.css" rel="stylesheet" />
  <style>
    html, body, #map { margin:0; padding:0; width:100%; height:100%; overflow:hidden; background:#0a0a0a; }
  </style>
</head>
<body>
  <div id="map"></div>
  <script src="https://unpkg.com/maplibre-gl@5.6.0/dist/maplibre-gl.js"></script>
  <script>
    let map;
    window.initMap = function(style, center, zoom, bearing, pitch, interactive) {
      map = new maplibregl.Map({
        container: 'map',
        style: style,
        center: center,
        zoom: zoom,
        bearing: bearing,
        pitch: pitch,
        interactive: interactive,
        attributionControl: false,
        antialias: true
      });
      map.addControl(new maplibregl.AttributionControl({compact: true}), 'bottom-left');

      map.on('load', () => {
        window.flutter_inappwebview.callHandler('mapReady');
      });

      map.on('error', (e) => {
        console.error(e);
        window.flutter_inappwebview.callHandler('mapError', e.error?.message || String(e));
      });
    };

    window.map = null;
    Object.defineProperty(window, 'map', {
      get: () => map,
      set: (v) => { map = v; }
    });
  </script>
</body>
</html>
''';

  @override
  void initState() {
    PlatformInAppWebViewController.debugLoggingSettings.enabled = false;
    super.initState();
  }

  @override
  void dispose() {
    controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return InAppWebView(
      initialData: InAppWebViewInitialData(data: _html),
      initialSettings: InAppWebViewSettings(transparentBackground: true, supportZoom: false),
      onWebViewCreated: (webController) {
        controller._attach(webController);

        webController.addJavaScriptHandler(
          handlerName: 'mapReady',
          callback: (_) {
            if (!controller._isReady) {
              controller._isReady = true;
            }
            widget.onMapCreated?.call(controller);
            widget.onStyleLoaded?.call();

            setupMapLayers(controller);
          },
        );

        webController.addJavaScriptHandler(
          handlerName: 'mapError',
          callback: (args) {
            logE('MapLibre error: ${args.first}');
          },
        );
      },
      onLoadStop: (controller, url) async {
        final cam = widget.initialCameraPosition;
        await controller.evaluateJavascript(
          source:
              '''window.initMap(
                  ${jsonEncode(widget.style)},
                  [${cam.target.longitude}, ${cam.target.latitude}],
                  ${cam.zoom},
                  ${cam.bearing},
                  ${cam.tilt},
                  ${widget.interactive}
                );
              ''',
        );
      },
      shouldOverrideUrlLoading: (controller, navigationAction) async {
        final url = navigationAction.request.url;
        if (url == null) return NavigationActionPolicy.ALLOW;

        if (url.scheme == 'http' || url.scheme == 'https') {
          await launchUrl(url);
          return NavigationActionPolicy.CANCEL;
        }

        return NavigationActionPolicy.ALLOW;
      },
    );
  }

  Future<void> setupMapLayers(MapLibreWebController map) async {
    await map.addSource('clusters', {
      'type': 'geojson',
      'data': {'type': 'FeatureCollection', 'features': []},
    });
    await map.addLayer({
      'id': 'clusters-circle',
      'type': 'circle',
      'source': 'clusters',
      'paint': {
        'circle-color': AppColors.primaryColor.withValues(alpha: 0.8).toHexStringRGB(),
        'circle-radius': ['get', 'radius'],
        'circle-stroke-width': 2,
        'circle-stroke-color': '#ffffff',
      },
    });
    await map.addLayer({
      'id': 'clusters-count',
      'type': 'symbol',
      'source': 'clusters',
      'layout': {
        'text-field': ['get', 'count'],
        'text-font': ['Noto Sans Regular'],
        'text-size': ['get', 'textSize'],
        'text-allow-overlap': true,
        'text-ignore-placement': true,
      },
      'paint': {'text-color': '#ffffff'},
    });

    await map.addSource('selected', {
      'type': 'geojson',
      'data': {'type': 'FeatureCollection', 'features': []},
    });

    if (mounted) {
      await map.addLayer({
        'id': 'selected-halo',
        'type': 'circle',
        'source': 'selected',
        'paint': {
          'circle-radius': 28,
          'circle-color': context.themedColor(bright: Colors.black, dark: Colors.white).toHexStringRGB(),
          'circle-opacity': .25,
          'circle-blur': .6,
        },
      });
    }

    await map.addSource('markers', {
      'type': 'geojson',
      'data': {'type': 'FeatureCollection', 'features': []},
    });
    await map.addLayer({
      'id': 'markers-symbol',
      'type': 'symbol',
      'source': 'markers',
      'layout': {
        'icon-image': ['get', 'icon'],
        'icon-size': .5,
        'icon-anchor': 'bottom',
        'icon-allow-overlap': true,
        'icon-ignore-placement': true,
        'text-field': '',
      },
    });

    // await map.addLayer({
    //   'id': 'selected-symbol',
    //   'type': 'symbol',
    //   'source': 'selected',
    //   'layout': {
    //     'icon-image': ['get', 'icon'],
    //     'icon-size': 1.35,
    //     'icon-anchor': 'bottom',
    //     'icon-allow-overlap': true,
    //     'icon-ignore-placement': true,
    //   },
    // });

    await map.on('move', '''() => {window.flutter_inappwebview.callHandler('onMove');}''');

    await map.on('click', '''
    (e) => {
      const features = map.queryRenderedFeatures(e.point, {
        layers: ['clusters-circle', 'markers-symbol']
      });
      if (features.length === 0) return;

      const f = features[0];
      window.flutter_inappwebview.callHandler('markerClick', {
        id: f.properties.id,
        isCluster: f.layer.id === 'clusters-circle',
        lng: f.geometry.coordinates[0],
        lat: f.geometry.coordinates[1]
      });
    }
  ''');

    await map._evalVoid('''
      map.addControl(new maplibregl.NavigationControl({
        visualizePitch: true,
        showCompass: true,
        showZoom: true
      }), 'top-right');
  ''');
  }
}
