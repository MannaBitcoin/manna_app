import 'dart:async';
import 'dart:convert';
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:fl_chart/fl_chart.dart';
import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:manna/app_state.dart';
import 'package:manna/config.dart';
import 'package:manna/models/account.dart';
import 'package:manna/services/audio_service.dart';
import 'package:manna/services/connectivity_checker.dart';
import 'package:manna/services/db_service.dart';
import 'package:manna/services/log_service.dart';
import 'package:manna/theme.dart';
import 'package:manna/utils/extensions.dart';
import 'package:manna/utils/parser.dart';
import 'package:manna/utils/sats_extension.dart';
import 'package:manna/utils/state_extension.dart';
import 'package:manna/utils/util.dart';
import 'package:manna/widgets/shimmer.dart';
import 'package:manna_core/manna_core.dart';
import 'package:web_socket_channel/io.dart';

enum TimeRange {
  hour1('1H'),
  hour24('24H'),
  days7('7D'),
  month1('1M'),
  month3('3M'),
  year1('1Y'),
  all('ALL');

  const TimeRange(this.label);
  final String label;
}

class TradeHistoryData extends ChangeNotifier {
  (DateTime? dateTime, double price) _currentPoint = (null, 0.0);
  double? _startingPrice;

  String timeString(TimeRange selectedRange) {
    return _currentPoint.$1 != null
        ? DateFormat(
            _currentPoint.$1!.isBefore(DateTime.now().subtract(const Duration(days: 7)))
                ? 'dd MMM yyyy, hh:mm a'
                : 'EEEE, hh:mm:ss a',
          ).format(_currentPoint.$1!)
        : switch (selectedRange) {
            TimeRange.hour1 => 'Past hour',
            TimeRange.hour24 => 'Today',
            TimeRange.days7 => 'Past week',
            TimeRange.month1 => 'Past month',
            TimeRange.month3 => 'Past 3 months',
            TimeRange.year1 => 'Past year',
            TimeRange.all => 'All time',
          };
  }

  double get currentPrice => _currentPoint.$2;
  double? get startingPrice => _startingPrice;

  set currentPoint((DateTime?, double) value) {
    _currentPoint = value;
    notifyListeners();
  }

  set startingPrice(double value) {
    _startingPrice = value;
    notifyListeners();
  }

  void _update() => notifyListeners();
}

class BtcPriceSocket {
  IOWebSocketChannel? _channel;
  StreamSubscription? _subscription;

  final _controller = StreamController.broadcast();
  Stream<dynamic> get priceStream => _controller.stream;

  bool _isConnecting = false;
  bool _shouldConnect = true;

  Timer? _reconnectTimer;
  static const _reconnectDelays = [1, 2, 5, 10, 15, 30, 60];
  int _reconnectAttempt = 0;

  void connect() async {
    if (!_shouldConnect) return;
    if (_isConnecting || _channel != null) return;

    _isConnecting = true;

    try {
      _channel = IOWebSocketChannel.connect('wss://2140data.io/', pingInterval: const Duration(seconds: 30));
      _subscription = _channel!.stream.listen(
        (data) {
          _reconnectAttempt = 0;
          if (!_controller.isClosed) {
            _controller.add(data);
          }
        },
        onError: (error) => _handleDisconnect(error),
        onDone: () => _handleDisconnect('Connection closed by server'),
        cancelOnError: false,
      );
      await _channel?.ready;

      _isConnecting = false;
    } catch (e) {
      _handleDisconnect(e);
    }
  }

  void _handleDisconnect(dynamic reason) {
    _isConnecting = false;
    _cleanUp();

    if (_shouldConnect) {
      _scheduleReconnect();
    }
  }

  void _scheduleReconnect() {
    _reconnectTimer?.cancel();

    final delaySec = _reconnectDelays[_reconnectAttempt.clamp(0, _reconnectDelays.length - 1)];
    _reconnectAttempt++;

    _reconnectTimer = Timer(Duration(seconds: delaySec), connect);
  }

  void disconnect() {
    _shouldConnect = false;
    _cleanUp();
    _reconnectTimer?.cancel();
    _reconnectAttempt = 0;
  }

  void reconnect() {
    disconnect();
    _shouldConnect = true;
    connect();
  }

  void _cleanUp() {
    _subscription?.cancel();
    _subscription = null;

    _channel?.sink.close();
    _channel = null;

    // To update the state on listener and update UI
    _controller.add(null);
  }

  Future<void> dispose() async {
    disconnect();
    await _controller.close();
  }
}

class TradeScreen extends StatefulWidget {
  const TradeScreen({required this.onBack, required this.onPanning, super.key});

  final Function() onBack;
  final Function(bool isPanning) onPanning;

  @override
  State<TradeScreen> createState() => _TradeScreenState();
}

class _TradeScreenState extends State<TradeScreen> {
  TimeRange selectedTimeRange = TimeRange.hour24;
  final Map<TimeRange, (DateTime fetchTime, List<(double millis, double price)> data)> data = {};
  final viewData = TradeHistoryData();
  final transformationController = TransformationController();
  double get currentChartZoom => transformationController.value.row0[0];
  final listenerKey = GlobalKey();
  int? doubleTapTimeMs;
  bool isPanning = false;

  bool isScaleVisible = false;
  bool isLogView = false;
  bool showPowerLaw = false;

  final priceSocket = BtcPriceSocket();
  bool isPriceSocketConnected = false;
  final collectLiveDataEvery = 2;
  final List<(double millis, double price)> liveData = [];

  StreamSubscription? priceSubscription;

  @override
  void initState() {
    fetchBtcData();
    priceSocket.connect();
    priceSubscription = priceSocket.priceStream.listen((event) {
      try {
        if (event == null) {
          return update(() => isPriceSocketConnected = false);
        }
        isPriceSocketConnected = true;
        final data = jsonDecode(event);
        final price = parseDouble(data['prices']?['coinbase'] ?? data['weightedPrice']);

        final now = DateTime.now();
        if (now.second % collectLiveDataEvery == 0) {
          liveData.add((now.millisecondsSinceEpoch.toDouble(), price));
          transformationController.value = translate(transformationController.value, const Offset(-1, 0));
        }
        if (scrubSpotNotifier.value == null) {
          viewData.currentPoint = (DateTime.now(), price);
        } else {
          viewData._update();
        }
      } catch (_) {}
    });

    Future.delayed(const Duration(seconds: 1), () => AppState.prefs.setBool('didUserKnowAboutTradePage', true));
    super.initState();
  }

  @override
  void dispose() {
    priceSubscription?.cancel();
    transformationController.dispose();
    priceSocket.dispose();
    scrubSpotNotifier.dispose();
    super.dispose();
  }

  Future<void> fetchBtcData({bool force = false}) async {
    try {
      DateTime? lastFetchTime;
      if (!force && data.containsKey(selectedTimeRange)) {
        lastFetchTime = data[selectedTimeRange]!.$1;
      }
      if (!await ConnectivityChecker.checkConnection()) return;
      if (lastFetchTime == null || DateTime.now().difference(lastFetchTime).inMinutes > 1) {
        transformationController.value = Matrix4.identity();
        if (selectedTimeRange == TimeRange.hour1) {
          final now = DateTime.now().toUtc();
          final pastHour = now.subtract(const Duration(hours: 1)).toUtc();
          final rows = await DbService.useSupabase(
            (supabase) => supabase
                .from('btc_price_history')
                .select()
                .gte('timestamp', pastHour.toIso8601String())
                .lte('timestamp', now.toIso8601String())
                .limit(60),
          );
          if (rows != null && rows.isNotEmpty) {
            data[TimeRange.hour1] = (
              DateTime.now(),
              rows
                  .map(
                    (e) =>
                        (parseDateTime(e['timestamp']).millisecondsSinceEpoch.toDouble(), 1 / parseDouble(e['value'])),
                  )
                  .toList(),
            );
          }
        } else {
          final res = await globalDio.get(Config.current.getServerCDNEndpoint('/chart/data/${selectedTimeRange.name}'));
          if (res.isSuccess && res.data is List) {
            final dataList = parseList(res.data, (e) => (parseDouble(e[0]), parseDouble(e[1])));
            data[selectedTimeRange] = (DateTime.now(), dataList);
          }
        }
      }
      final dataList = data[selectedTimeRange]?.$2;
      if (dataList != null) {
        viewData.startingPrice = dataList.first.$2;
        final ms = data[TimeRange.hour1]?.$2.lastOrNull?.$1.toInt() ?? dataList.last.$1.toInt();
        if (viewData._currentPoint.$1 == null) {
          viewData.currentPoint = (
            DateTime.fromMillisecondsSinceEpoch(ms),
            data[TimeRange.hour1]?.$2.lastOrNull?.$2 ?? dataList.last.$2,
          );
        }
      }
      update();
    } catch (e, s) {
      logE(e, stackTrace: s);
    }
  }

  @override
  Widget build(BuildContext context) {
    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (didPop, result) {
        if (!didPop) {
          widget.onBack();
        }
      },
      child: Scaffold(
        backgroundColor: context.isDarkMode ? null : AppColors.primaryColor,
        body: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const SizedBox(height: 12),
            // Header data view
            Column(
              children: [
                ListenableBuilder(
                  listenable: viewData,
                  builder: (context, child) {
                    return Column(
                      children: [
                        Text(viewData.timeString(selectedTimeRange), style: const TextStyle(color: Colors.white70)),
                        ShimmerWidget.fromColors(
                          baseColor: Colors.white,
                          highlightColor: Colors.grey,
                          shimmerState: !isPriceSocketConnected ? ShimmerState.running : ShimmerState.stopped,
                          child: Text(
                            AppState.selectedCurrency.currencySymbol +
                                NumberFormat('###,###,##0.00').format(viewData.currentPrice.convertCurrency()),
                            style: const TextStyle(color: Colors.white, fontSize: 42, fontWeight: FontWeight.bold),
                          ),
                        ),
                        if (viewData.startingPrice != null)
                          Builder(
                            builder: (context) {
                              final difference = viewData.currentPrice - viewData.startingPrice!;
                              final percentChange = (difference / viewData.startingPrice!) * 100;
                              final changeColor = difference >= 0 ? Colors.green.shade300 : Colors.red.shade300;
                              final changeSymbol = difference >= 0 ? '+' : '';

                              return Row(
                                spacing: 8,
                                mainAxisAlignment: .center,
                                children: [
                                  Text(
                                    '$changeSymbol${percentChange.toStringAsFixed(2)}%',
                                    style: TextStyle(color: changeColor, fontSize: 16, fontWeight: FontWeight.w600),
                                  ),
                                  Text(
                                    '$changeSymbol${AppState.selectedCurrency.currencySymbol}${NumberFormat('###,###,##0.00').format(difference.convertCurrency())}',
                                    style: TextStyle(color: changeColor, fontSize: 16, fontWeight: FontWeight.w600),
                                  ),
                                ],
                              );
                            },
                          ),
                      ],
                    );
                  },
                ),
              ],
            ),

            // Chart
            Expanded(
              child: Stack(
                children: [
                  Center(
                    child: Padding(
                      padding: const EdgeInsets.only(bottom: 22.0),
                      child: Builder(
                        builder: (context) {
                          if (data[selectedTimeRange]?.$2.isNotEmpty == true) {
                            return GestureDetector(
                              onDoubleTapDown: (_) => doubleTapTimeMs = DateTime.now().millisecondsSinceEpoch,
                              child: Listener(
                                key: listenerKey,
                                onPointerUp: (event) {
                                  isPanning = false;
                                  doubleTapTimeMs = null;
                                  widget.onPanning(false);
                                  _clearChartSelection();
                                },
                                onPointerCancel: (event) {
                                  isPanning = false;
                                  doubleTapTimeMs = null;
                                  widget.onPanning(false);
                                  _clearChartSelection();
                                },
                                onPointerMove: (event) {
                                  if (doubleTapTimeMs != null &&
                                      DateTime.now().millisecondsSinceEpoch - doubleTapTimeMs! < 200) {
                                    isPanning = true;
                                    doubleTapTimeMs = null;
                                    widget.onPanning(true);
                                  }
                                  if (isPanning) {
                                    transformationController.value = translate(
                                      transformationController.value,
                                      event.delta,
                                    );
                                  }
                                },
                                child: chart(),
                              ),
                            );
                          }
                          return const CircularProgressIndicator(color: Colors.white);
                        },
                      ),
                    ),
                  ),
                  Positioned(
                    bottom: 0,
                    right: 8,
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        if (isLogView)
                          GestureDetector(
                            onTap: () => update(() => showPowerLaw = !showPowerLaw),
                            child: Padding(
                              padding: const EdgeInsets.symmetric(horizontal: 12),
                              child: Text('pow', style: TextStyle(color: showPowerLaw ? Colors.white : Colors.grey)),
                            ),
                          ),
                        if (isScaleVisible && selectedTimeRange == TimeRange.all)
                          GestureDetector(
                            onTap: () => update(() {
                              isLogView = !isLogView;
                              if (!isLogView) showPowerLaw = false;
                            }),
                            child: Padding(
                              padding: const EdgeInsets.symmetric(horizontal: 12),
                              child: Text('log', style: TextStyle(color: isLogView ? Colors.white : Colors.grey)),
                            ),
                          ),
                        GestureDetector(
                          onTap: () => update(() => isScaleVisible = !isScaleVisible),
                          child: Padding(
                            padding: const EdgeInsets.symmetric(horizontal: 12),
                            child: Icon(
                              isScaleVisible ? Icons.candlestick_chart : Icons.candlestick_chart_outlined,
                              color: Colors.white,
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),

            // Time Range Buttons
            Container(
              decoration: BoxDecoration(color: Colors.white12, borderRadius: BorderRadius.circular(16)),
              margin: const EdgeInsets.symmetric(horizontal: 12, vertical: 12.0),
              clipBehavior: Clip.hardEdge,
              constraints: const BoxConstraints(maxWidth: 450),
              child: Row(
                children: TimeRange.values
                    .map(
                      (range) => Expanded(
                        child: GestureDetector(
                          onTap: () {
                            scrubSpotNotifier.value = null;

                            widget.onPanning(false);
                            transformationController.value = Matrix4.identity();
                            selectedTimeRange = range;
                            if (selectedTimeRange != TimeRange.all) {
                              isLogView = showPowerLaw = false;
                            }
                            update();
                            fetchBtcData();
                          },
                          child: Container(
                            padding: const EdgeInsets.symmetric(vertical: 8),
                            decoration: BoxDecoration(
                              color: selectedTimeRange == range ? Colors.white38 : Colors.transparent,
                              borderRadius: BorderRadius.circular(16),
                            ),
                            alignment: Alignment.center,
                            child: Text(
                              range.label,
                              style: TextStyle(
                                color: selectedTimeRange == range ? Colors.white : Colors.grey.shade400,
                                fontWeight: FontWeight.bold,
                              ),
                            ),
                          ),
                        ),
                      ),
                    )
                    .toList(),
              ),
            ),
            if (selectedWallet.type == WalletType.full)
              Padding(
                padding: const EdgeInsets.all(12),
                child: Row(
                  spacing: 8,
                  children: [
                    Expanded(
                      child: ElevatedButton(
                        onPressed: () async {
                          unawaited(
                            showDialog(
                              context: context,
                              builder: (context) => Dialog(
                                constraints: const BoxConstraints(maxWidth: 245, maxHeight: 220),
                                child: ClipRRect(
                                  borderRadius: BorderRadius.circular(16),
                                  child: Image.asset('assets/images/why_sell.gif'),
                                ),
                              ),
                            ),
                          );
                        },
                        style: ElevatedButton.styleFrom(
                          backgroundColor: context.themedColor(bright: Colors.white, dark: AppColors.darkCardColor),
                          foregroundColor: context.themedColor(bright: AppColors.primaryColor, dark: Colors.white),
                          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                          visualDensity: VisualDensity.standard,
                        ),
                        child: const Text('Sell Bitcoin', textAlign: TextAlign.center),
                      ),
                    ),
                    Expanded(
                      child: ElevatedButton(
                        onPressed: () async {
                          if (Config.network != Network.testnet) {
                            // await AppRouter.push(const BuyBitcoinScreen());
                            // update();
                          }
                        },
                        style: ElevatedButton.styleFrom(
                          backgroundColor: context.themedColor(bright: Colors.white, dark: AppColors.darkCardColor),
                          foregroundColor: context.themedColor(bright: AppColors.primaryColor, dark: Colors.white),
                          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                          visualDensity: VisualDensity.standard,
                        ),
                        child: const Text('Buy Bitcoin', textAlign: TextAlign.center),
                      ),
                    ),
                  ],
                ),
              ),
          ],
        ),
      ),
    );
  }

  Matrix4 translate(Matrix4 matrix, Offset translation) {
    if (translation == Offset.zero) return matrix;

    final nextMatrix = matrix.clone()..translateByDouble(translation.dx / 3, 0, 0, 1);
    final viewportWidth = (listenerKey.currentContext!.findRenderObject() as RenderBox).size.width;

    final currentTranslation = nextMatrix.row0[3];
    final maxAllowedScroll = (viewportWidth - yAxisWidth) * (currentChartZoom - 1);

    if (currentTranslation <= 0 && currentTranslation.abs() <= maxAllowedScroll) {
      return nextMatrix;
    }

    return matrix;
  }

  final min = 60000;
  final hr = 3600_000;
  final day = 86400_000;
  late final month = day * 30;

  int _getHomogeneousInterval(double targetInterval) {
    final cleanSteps = switch (selectedTimeRange) {
      TimeRange.hour1 => [min, 2 * min, 5 * min, 10 * min, 15 * min, 30 * min],
      TimeRange.hour24 => [hr, 2 * hr, 3 * hr, 4 * hr, 6 * hr, 12 * hr],
      TimeRange.days7 => [6 * hr, 12 * hr, 24 * hr, 48 * hr],
      TimeRange.month1 => [day, 2 * day, 3 * day, 4 * day, 5 * day, 6 * day, 7 * day, 15 * day],
      TimeRange.all => [366 * day, 731 * day, 1097 * day],
      _ => const <int>[],
    };

    for (final step in cleanSteps) {
      if (targetInterval <= step) return step;
    }
    return cleanSteps.last;
  }

  String formatPrice(double price) {
    String resultNumber = price.toString(), symbol = '';
    if (price >= 1000000000) {
      resultNumber = (price / 1000000000).toStringAsFixed(2);
      symbol = 'B';
    } else if (price >= 1000000) {
      resultNumber = (price / 1000000).toStringAsFixed(2);
      symbol = 'M';
    } else if (price >= 1000) {
      resultNumber = (price / 1000).toStringAsFixed(2);
      symbol = 'K';
    } else {
      resultNumber = resultNumber.substring(0, resultNumber.length.clamp(0, 6));
    }
    return '$resultNumber$symbol';
  }

  final ValueNotifier<FlSpot?> scrubSpotNotifier = ValueNotifier(null);

  final placeholder = const SizedBox.shrink();
  final yAxisWidth = 40.0;
  final xAxisHeight = 18.0;

  void _clearChartSelection() {
    scrubSpotNotifier.value = null;
    widget.onPanning(false);
  }

  int genesisTimeMillis = 1230921000000;
  double getLogX(int timestampMillis) {
    int daysSinceGenesis = Duration(milliseconds: timestampMillis - genesisTimeMillis).inDays;
    if (daysSinceGenesis <= 1) daysSinceGenesis = 1;
    return math.log(daysSinceGenesis) / math.ln10;
  }

  Widget chart() {
    return ListenableBuilder(
      listenable: viewData,
      builder: (context, child) {
        final spots = isLogView
            ? _buildVisibleSpots()
                  .map((e) => FlSpot(showPowerLaw ? getLogX(e.x.toInt()) : e.x, math.log(e.y) / math.ln10))
                  .toList()
            : _buildVisibleSpots();

        if (spots.isEmpty) {
          return const Center(child: CircularProgressIndicator());
        }

        final minY = spots.map((e) => e.y).reduce(math.min).floor();
        final maxY = spots.map((e) => e.y).reduce(math.max).ceil();
        final buffer = (maxY - minY) * 0.12;

        return LayoutBuilder(
          builder: (context, constraints) {
            final timeScaleItemCount = (constraints.maxWidth * currentChartZoom) ~/ 60;
            final interval = ({TimeRange.month3, TimeRange.year1}.contains(selectedTimeRange))
                ? day
                : _getHomogeneousInterval(
                    switch (selectedTimeRange) {
                          TimeRange.hour1 => hr,
                          TimeRange.hour24 => day,
                          TimeRange.days7 => 7 * day,
                          TimeRange.month1 => month,
                          _ => (spots.last.x - spots.first.x),
                        } /
                        timeScaleItemCount,
                  );

            final chartMinX = spots.first.x;
            final chartMaxX = spots.last.x;
            final chartMinY = minY - buffer;
            final chartMaxY = maxY + buffer;
            final rightPad = isScaleVisible ? yAxisWidth : 0.0;
            final bottomPad = isScaleVisible ? xAxisHeight : 0.0;
            final haloColor = context.isDarkMode ? AppColors.primaryColor : Colors.white;

            final Set<int> powerLawYears = {};
            return ValueListenableBuilder<FlSpot?>(
              valueListenable: scrubSpotNotifier,
              builder: (context, scrubSpot, _) {
                return Stack(
                  fit: StackFit.expand,
                  children: [
                    LineChart(
                      LineChartData(
                        gridData: const FlGridData(show: false),
                        extraLinesData: ExtraLinesData(
                          verticalLines: [
                            if (scrubSpot != null) VerticalLine(x: scrubSpot.x, color: Colors.white24, strokeWidth: 1),
                          ],
                        ),
                        titlesData: FlTitlesData(
                          leftTitles: const AxisTitles(),
                          topTitles: const AxisTitles(),
                          rightTitles: AxisTitles(
                            sideTitles: SideTitles(
                              showTitles: isScaleVisible,
                              reservedSize: yAxisWidth,
                              maxIncluded: false,
                              minIncluded: false,
                              getTitlesWidget: (value, meta) {
                                final val = isLogView ? math.pow(10, value) : value;
                                return FittedBox(
                                  fit: BoxFit.scaleDown,
                                  alignment: AlignmentDirectional.centerStart,
                                  child: Text(
                                    formatPrice(val.convertCurrency()),
                                    style: const TextStyle(color: Colors.white, fontSize: 10),
                                  ),
                                );
                              },
                            ),
                          ),
                          bottomTitles: AxisTitles(
                            sideTitles: SideTitles(
                              showTitles: isScaleVisible,
                              reservedSize: xAxisHeight,
                              minIncluded: false,
                              maxIncluded: false,
                              interval: showPowerLaw ? 0.001 : interval.toDouble(),
                              getTitlesWidget: (value, meta) {
                                final timestamp = showPowerLaw
                                    ? DateTime.fromMillisecondsSinceEpoch(genesisTimeMillis)
                                          .add(Duration(days: math.pow(10, value).toInt()))
                                          .millisecondsSinceEpoch
                                          .toDouble()
                                    : value;
                                final date = DateTime.fromMillisecondsSinceEpoch(timestamp.toInt());

                                String formatString = '';
                                if ({TimeRange.hour1, TimeRange.hour24}.contains(selectedTimeRange)) {
                                  formatString = 'HH:mm';
                                } else if (TimeRange.days7 == selectedTimeRange) {
                                  final count = timestamp / day;
                                  // This is second entry after the day so use hour format
                                  formatString = count - count.floor() > 0 ? 'HH:mm' : 'dd MMM';
                                } else if (TimeRange.all == selectedTimeRange) {
                                  formatString = showPowerLaw ? 'yy' : 'MMM yy';
                                } else {
                                  formatString = 'dd MMM';
                                }

                                final child = SideTitleWidget(
                                  meta: meta,
                                  space: 0,
                                  fitInside: SideTitleFitInsideData.fromTitleMeta(meta),
                                  child: FittedBox(
                                    alignment: Alignment.topCenter,
                                    fit: BoxFit.scaleDown,
                                    child: Text(
                                      DateFormat(formatString).format(date),
                                      style: const TextStyle(color: Colors.white60, fontSize: 10),
                                    ),
                                  ),
                                );
                                if ({
                                      TimeRange.hour1,
                                      TimeRange.hour24,
                                      TimeRange.days7,
                                      TimeRange.month1,
                                    }.contains(selectedTimeRange) ||
                                    (TimeRange.all == selectedTimeRange && !showPowerLaw)) {
                                  return child;
                                }

                                if (selectedTimeRange == TimeRange.month3) {
                                  if ({
                                    1,
                                    if (timeScaleItemCount >= 12) ...{
                                      8,
                                      15,
                                      22,
                                    } else if (timeScaleItemCount >= 9) ...{
                                      11,
                                      21,
                                    } else if (timeScaleItemCount >= 6)
                                      16,
                                  }.contains(date.day)) {
                                    return child;
                                  }
                                } else if (selectedTimeRange == TimeRange.year1) {
                                  if (timeScaleItemCount >= 24 && {1, 15}.contains(date.day)) {
                                    return child;
                                  } else if (date.day == 1) {
                                    if (timeScaleItemCount >= 12) {
                                      return child;
                                    } else {
                                      if (date.month %
                                              (timeScaleItemCount >= 6
                                                  ? 2
                                                  : timeScaleItemCount >= 4
                                                  ? 3
                                                  : 4) ==
                                          0) {
                                        return child;
                                      }
                                    }
                                  }
                                } else if (selectedTimeRange == TimeRange.all) {
                                  if (!powerLawYears.contains(date.year)) {
                                    powerLawYears.add(date.year);
                                    if (timeScaleItemCount < 8) {
                                      if (date.year % 2 == 0) return child;
                                    } else {
                                      return child;
                                    }
                                  }
                                }
                                return placeholder;
                              },
                            ),
                          ),
                        ),
                        borderData: FlBorderData(show: false),

                        minX: chartMinX,
                        maxX: chartMaxX,
                        minY: chartMinY,
                        maxY: chartMaxY,

                        lineBarsData: [
                          LineChartBarData(
                            spots: spots,
                            isStrokeCapRound: true,
                            color: Colors.white70,
                            barWidth: 1.5,
                            dotData: const FlDotData(show: false),
                            belowBarData: BarAreaData(
                              show: true,
                              gradient: LinearGradient(
                                colors: context.isDarkMode
                                    ? [
                                        AppColors.primaryColor,
                                        AppColors.primaryColor.withValues(alpha: 0.3),
                                        Colors.transparent,
                                      ]
                                    : [Colors.white30, Colors.white12, Colors.transparent],
                                begin: Alignment.topCenter,
                                end: Alignment.bottomCenter,
                              ),
                            ),
                          ),
                        ],
                        lineTouchData: LineTouchData(
                          touchSpotThreshold: 12 * currentChartZoom,
                          longPressDuration: const Duration(milliseconds: 350),
                          touchTooltipData: LineTouchTooltipData(
                            getTooltipItems: (touchedSpots) => [for (final _ in touchedSpots) null],
                          ),
                          getTouchedSpotIndicator: (barData, spotIndexes) => spotIndexes.map((idx) {
                            return TouchedSpotIndicatorData(
                              const FlLine(strokeWidth: 0),
                              FlDotData(
                                getDotPainter: (_, _, _, _) => FlDotCirclePainter(radius: 0, color: Colors.transparent),
                              ),
                            );
                          }).toList(),
                          touchCallback: (touchEvent, e) {
                            if (!mounted) return;

                            if (!touchEvent.isInterestedForInteractions ||
                                touchEvent is FlTapUpEvent ||
                                touchEvent is FlPanEndEvent ||
                                touchEvent is FlLongPressEnd ||
                                touchEvent is FlPointerExitEvent) {
                              _clearChartSelection();
                              return;
                            }

                            final touchIndex = e?.lineBarSpots?.firstOrNull?.spotIndex.clamp(0, spots.length - 1);
                            if (touchIndex == null) {
                              return;
                            }

                            widget.onPanning(true);
                            final touchedSpot = spots[touchIndex];
                            scrubSpotNotifier.value = touchedSpot;

                            viewData.currentPoint = (
                              showPowerLaw
                                  ? DateTime.fromMillisecondsSinceEpoch(
                                      genesisTimeMillis,
                                    ).add(Duration(days: math.pow(10, touchedSpot.x).toInt()))
                                  : DateTime.fromMillisecondsSinceEpoch(touchedSpot.x.toInt()),
                              (isLogView ? math.pow(10, touchedSpot.y) : touchedSpot.y).toDouble(),
                            );

                            if (touchEvent is FlLongPressStart) {
                              hapticFeedback();
                            }
                          },
                        ),
                      ),
                      transformationConfig: FlTransformationConfig(
                        transformationController: transformationController,
                        scaleAxis: FlScaleAxis.horizontal,
                        maxScale: 5,
                        panEnabled: false,
                      ),
                      duration: Duration.zero,
                    ),
                    if (scrubSpot != null)
                      Positioned(
                        left: 0,
                        top: 0,
                        right: rightPad,
                        bottom: bottomPad,
                        child: ListenableBuilder(
                          listenable: transformationController,
                          builder: (context, asyncSnapshot) {
                            return IgnorePointer(
                              child: CustomPaint(
                                painter: BulbLightPainter(
                                  spots: spots,
                                  scrubSpot: scrubSpot,
                                  minX: chartMinX,
                                  maxX: chartMaxX,
                                  minY: chartMinY,
                                  maxY: chartMaxY,
                                  haloColor: haloColor,
                                  transformation: transformationController.value,
                                ),
                              ),
                            );
                          },
                        ),
                      ),
                  ],
                );
              },
            );
          },
        );
      },
    );
  }

  Set<TimeRange> showLiveDataIn = {TimeRange.hour1};
  List<FlSpot> _buildVisibleSpots() {
    final allPoints = data[selectedTimeRange]?.$2 ?? [];

    if (TimeRange.hour1 == selectedTimeRange) {
      for (final (i, l) in liveData.indexed) {
        if (i * collectLiveDataEvery % 60 == 0) {
          allPoints.add(l);
        }
      }
    }

    if (allPoints.isEmpty) return [];

    allPoints.sort((a, b) => a.$1.compareTo(b.$1));

    final nowMs = DateTime.now().millisecondsSinceEpoch;
    final cutoffMs = switch (selectedTimeRange) {
      TimeRange.hour1 => hr,
      TimeRange.hour24 => day,
      TimeRange.days7 => 7 * day,
      TimeRange.month1 => month,
      TimeRange.month3 => 90 * day,
      TimeRange.year1 => 365 * day,
      TimeRange.all => 9999999999999,
    };

    final filtered = showLiveDataIn.contains(selectedTimeRange)
        ? allPoints.skipWhile((p) => nowMs - p.$1 > cutoffMs).toList()
        : allPoints.toList();

    if (liveData.isNotEmpty) {
      filtered.add(liveData.last);
    }

    // Downsampling for performance
    if (filtered.length > 600) {
      final t = _downsample(filtered, maxPoints: 1000).map((e) => FlSpot(e.$1, e.$2)).toList();
      return t;
    }

    return filtered.map((p) => FlSpot(p.$1, p.$2)).toList();
  }

  List<(double, double)> _downsample(List<(double, double)> points, {required int maxPoints}) {
    if (points.length <= maxPoints || points.length < 2) return points;

    final startTime = points.first.$1;
    final endTime = points.last.$1;
    final totalDuration = endTime - startTime;

    // The time width of each bucket
    final interval = totalDuration / (maxPoints / 2);

    final result = <(double, double)>[];
    result.add(points.first);

    int currentIndex = 1;
    for (int i = 0; i < (maxPoints / 2); i++) {
      final bucketEnd = startTime + (interval * (i + 1));

      (double, double)? minPoint;
      (double, double)? maxPoint;

      // Collect all points that fall within this time window
      while (currentIndex < points.length - 1 && points[currentIndex].$1 < bucketEnd) {
        final p = points[currentIndex];

        if (minPoint == null || p.$2 < minPoint.$2) minPoint = p;
        if (maxPoint == null || p.$2 > maxPoint.$2) maxPoint = p;

        currentIndex++;
      }

      if (minPoint != null && maxPoint != null) {
        if (minPoint.$1 <= maxPoint.$1) {
          result.add(minPoint);
          if (minPoint != maxPoint) result.add(maxPoint);
        } else {
          result.add(maxPoint);
          result.add(minPoint);
        }
      }
    }

    // include last point
    if (result.last != points.last) {
      result.add(points.last);
    }

    return result;
  }
}

// class BulbLightPainter extends CustomPainter {
//   const BulbLightPainter({
//     required this.spots,
//     required this.scrubSpot,
//     required this.minX,
//     required this.maxX,
//     required this.minY,
//     required this.maxY,
//     required this.haloColor,
//   });
//
//   final List<FlSpot> spots;
//   final FlSpot scrubSpot;
//   final double minX;
//   final double maxX;
//   final double minY;
//   final double maxY;
//   final Color haloColor;
//
//   static const double surfaceStrength = 1.0;
//
//   @override
//   void paint(Canvas canvas, Size size) {
//     if (spots.length < 2 || size.width <= 0 || size.height <= 0) return;
//     if (maxX <= minX || maxY <= minY) return; // Prevent division by zero
//
//     final origin = _map(scrubSpot, size);
//     final falloffPx = (size.width * 0.12).clamp(40.0, 72.0);
//
//     canvas.drawRect(
//       Offset.zero & size,
//       Paint()
//         ..shader = ui.Gradient.radial(
//           origin,
//           falloffPx * 1.4,
//           [
//             Colors.white.withValues(alpha: 0.2),
//             Colors.white.withValues(alpha: 0.1),
//             Colors.white.withValues(alpha: 0.0),
//           ],
//           const [0.0, 0.35, 1.0],
//         ),
//     );
//
//     final path = Path();
//     for (var i = 0; i < spots.length; i++) {
//       final pt = _map(spots[i], size);
//       if (i == 0) {
//         path.moveTo(pt.dx, pt.dy);
//       } else {
//         path.lineTo(pt.dx, pt.dy);
//       }
//     }
//
//     final radius = falloffPx * 1.5;
//     canvas.drawPath(
//       path,
//       Paint()
//         ..style = PaintingStyle.stroke
//         ..strokeWidth = 1.6 + (6.5 * surfaceStrength)
//         ..strokeCap = StrokeCap.round
//         ..strokeJoin = StrokeJoin.round
//         ..shader = ui.Gradient.radial(
//           origin,
//           radius,
//           [
//             Colors.white.withValues(alpha: 0.5 * surfaceStrength),
//             Colors.white.withValues(alpha: 0.18 * surfaceStrength),
//             Colors.transparent,
//           ],
//           const [0.0, 0.4, 1.0],
//         )
//         ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 4),
//     );
//
//     canvas.drawPath(
//       path,
//       Paint()
//         ..style = PaintingStyle.stroke
//         ..strokeWidth = 1.4 + (1.8 * surfaceStrength)
//         ..strokeCap = StrokeCap.round
//         ..strokeJoin = StrokeJoin.round
//         ..shader = ui.Gradient.radial(
//           origin,
//           radius * 0.9,
//           [
//             Colors.white.withValues(alpha: 0.95 * surfaceStrength),
//             Colors.white.withValues(alpha: 0.45 * surfaceStrength),
//             Colors.transparent,
//           ],
//           const [0.0, 0.35, 1.0],
//         ),
//     );
//
//     canvas.drawCircle(origin, 4.5, Paint()..color = Colors.white.withValues(alpha: 0.95));
//   }
//
//   Offset _map(FlSpot s, Size size) {
//     final rangeX = maxX - minX;
//     final rangeY = maxY - minY;
//
//     final nx = rangeX == 0 ? 0.0 : ((s.x - minX) / rangeX).clamp(0.0, 1.0);
//     final ny = rangeY == 0 ? 0.0 : ((s.y - minY) / rangeY).clamp(0.0, 1.0);
//
//     return Offset(nx * size.width, (1 - ny) * size.height);
//   }
//
//   @override
//   bool shouldRepaint(covariant BulbLightPainter old) {
//     return old.scrubSpot != scrubSpot ||
//         old.haloColor != haloColor ||
//         old.minX != minX ||
//         old.maxX != maxX ||
//         old.minY != minY ||
//         old.maxY != maxY ||
//         old.spots != spots;
//   }
// }

class BulbLightPainter extends CustomPainter {
  const BulbLightPainter({
    required this.spots,
    required this.scrubSpot,
    required this.minX,
    required this.maxX,
    required this.minY,
    required this.maxY,
    required this.haloColor,
    required this.transformation,
  });

  final List<FlSpot> spots;
  final FlSpot scrubSpot;
  final double minX;
  final double maxX;
  final double minY;
  final double maxY;
  final Color haloColor;
  final Matrix4 transformation;

  static const double surfaceStrength = 1.0;

  @override
  void paint(Canvas canvas, Size size) {
    if (spots.length < 2 || size.width <= 0 || size.height <= 0) return;
    if (maxX <= minX || maxY <= minY) return;

    final origin = _transform(_map(scrubSpot, size));
    final falloffPx = (size.width * 0.12).clamp(40.0, 72.0);

    canvas.drawRect(
      Offset.zero & size,
      Paint()
        ..shader = ui.Gradient.radial(
          origin,
          falloffPx * 2.8,
          [
            Colors.white.withValues(alpha: 0.1),
            Colors.white.withValues(alpha: 0.05),
            Colors.white.withValues(alpha: 0.0),
          ],
          const [0.0, 0.5, 1.0],
        ),
    );

    final path = Path();
    for (var i = 0; i < spots.length; i++) {
      final pt = _transform(_map(spots[i], size));
      if (i == 0) {
        path.moveTo(pt.dx, pt.dy);
      } else {
        path.lineTo(pt.dx, pt.dy);
      }
    }

    final radius = falloffPx * 1.5;
    canvas.drawPath(
      path,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1.6 + (6.5 * surfaceStrength)
        ..strokeCap = StrokeCap.round
        ..strokeJoin = StrokeJoin.round
        ..shader = ui.Gradient.radial(
          origin,
          radius,
          [
            Colors.white.withValues(alpha: 0.5 * surfaceStrength),
            Colors.white.withValues(alpha: 0.18 * surfaceStrength),
            Colors.transparent,
          ],
          const [0.0, 0.4, 1.0],
        )
        ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 4),
    );

    canvas.drawPath(
      path,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1.4 + (1.8 * surfaceStrength)
        ..strokeCap = StrokeCap.round
        ..strokeJoin = StrokeJoin.round
        ..shader = ui.Gradient.radial(
          origin,
          radius * 0.9,
          [
            Colors.white.withValues(alpha: 0.95 * surfaceStrength),
            Colors.white.withValues(alpha: 0.45 * surfaceStrength),
            Colors.transparent,
          ],
          const [0.0, 0.35, 1.0],
        ),
    );

    canvas.drawCircle(origin, 4.5, Paint()..color = Colors.white.withValues(alpha: 0.95));
  }

  Offset _map(FlSpot s, Size size) {
    final rangeX = maxX - minX;
    final rangeY = maxY - minY;

    final nx = rangeX == 0 ? 0.0 : ((s.x - minX) / rangeX).clamp(0.0, 1.0);
    final ny = rangeY == 0 ? 0.0 : ((s.y - minY) / rangeY).clamp(0.0, 1.0);

    return Offset(nx * size.width, (1 - ny) * size.height);
  }

  Offset _transform(Offset point) {
    final m = transformation.storage;
    return Offset(m[0] * point.dx + m[12], point.dy);
  }

  @override
  bool shouldRepaint(covariant BulbLightPainter old) {
    return old.scrubSpot != scrubSpot ||
        old.haloColor != haloColor ||
        old.minX != minX ||
        old.maxX != maxX ||
        old.minY != minY ||
        old.maxY != maxY ||
        old.spots != spots ||
        old.transformation != transformation;
  }
}
