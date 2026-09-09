import 'dart:async';
import 'dart:convert';
import 'dart:math' as math;

import 'package:flutter/cupertino.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_svg/flutter_svg.dart';
import 'package:intl/intl.dart';
import 'package:manna/app_state.dart';
import 'package:manna/models/account.dart';
import 'package:manna/models/country_model.dart';
import 'package:manna/screens/menu_screen.dart';
import 'package:manna/services/db.dart';
import 'package:manna/theme.dart';
import 'package:manna/utils/constants.dart';
import 'package:manna/utils/sats_extension.dart';
import 'package:manna/utils/state_extension.dart';
import 'package:manna/utils/toast_service.dart';
import 'package:manna/widgets/amount_text.dart';
import 'package:url_launcher/url_launcher.dart';

class ConvertersScreen extends StatefulWidget {
  const ConvertersScreen({super.key});

  @override
  State<ConvertersScreen> createState() => _ConvertersScreenState();
}

class _ConvertersScreenState extends State<ConvertersScreen> {
  int selectedTab = 0;
  final pageController = PageController();
  bool isAnimatingPage = false;

  final List<(CountryModel, TextEditingController)> chosenFiats = [];
  late final satAmountController = TextEditingController(text: satAmount.toString());
  int satAmount = 1000;
  bool isSelectedBTCFormat = AppState.bitcoinDisplayStyle == 2;
  bool isReordering = false;

  @override
  void initState() {
    Future(() async {
      final savedCurrencyCodes = AppState.prefs.getStringList('CurrencyConverterCodes') ?? [];
      if (savedCurrencyCodes.isNotEmpty) {
        final json = await rootBundle.loadString('assets/data/country.json');
        final countries = (jsonDecode(json) as List).map((e) => CountryModel.fromMap(e)).toList();
        final t = savedCurrencyCodes.toSet();
        final Map<String, CountryModel> savedCodes = {};
        for (final c in countries) {
          final key = '${c.currencyCode}-${c.countryCode}';
          if (t.contains(key)) {
            savedCodes[key] = c;
            t.remove(key);
          }
        }
        for (final e in savedCurrencyCodes) {
          final t = savedCodes[e];
          if (t != null) {
            chosenFiats.add((t, TextEditingController()));
          }
        }
      }
      if (chosenFiats.isEmpty) {
        chosenFiats.add((AppState.selectedCurrency, TextEditingController()));
      }
      updateRates();
      update();
    });

    super.initState();
  }

  @override
  void dispose() {
    pageController.dispose();
    satAmountController.dispose();
    amountController.dispose();
    chosenFiats.map((e) => e.$2.dispose());
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Converters')),
      body: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 600),
          child: Column(
            children: [
              Padding(
                padding: const EdgeInsets.all(16),
                child: CupertinoSlidingSegmentedControl(
                  groupValue: selectedTab,
                  onValueChanged: (val) => selectTab(val ?? 0),
                  children: {0: buildSegment('Currency Converter'), 1: buildSegment('Projected Value')},
                  padding: const EdgeInsets.all(8),
                ),
              ),
              Expanded(
                child: PageView(
                  controller: pageController,
                  onPageChanged: (value) => selectTab(value),
                  children: [currencyConverterPage(), powerLawPage()],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget buildSegment(String name) => Padding(
    padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 8),
    child: FittedBox(fit: BoxFit.scaleDown, child: Text(name)),
  );

  void selectTab(int tab) async {
    if (isAnimatingPage) return;

    selectedTab = tab;
    if (selectedTab != (pageController.page?.toInt() ?? 0)) {
      isAnimatingPage = true;
      unawaited(
        pageController
            .animateToPage(selectedTab, duration: const Duration(milliseconds: 300), curve: Curves.fastOutSlowIn)
            .then((value) => isAnimatingPage = false),
      );
    }
    update();
  }

  void updateRates({int? excludeIndex}) {
    for (final (i, e) in chosenFiats.indexed) {
      if (excludeIndex == i) continue;
      e.$2.text = satAmount.satsToFiat(targetCurrencyCode: e.$1.currencyCode).toStringAsFixed(2);
    }
    if (isReordering) {
      update(() => isReordering = false);
    }
  }

  void saveSettings() async {
    await AppState.prefs.setStringList(
      'CurrencyConverterCodes',
      chosenFiats.map((e) => '${e.$1.currencyCode}-${e.$1.countryCode}').toList(),
    );
  }

  Widget currencyConverterPage() {
    return Padding(
      padding: const EdgeInsets.all(16),
      child: Column(
        children: [
          TextFormField(
            controller: satAmountController,
            keyboardType: TextInputType.number,
            decoration: InputDecoration(
              hintText: '0',
              suffixIcon: GestureDetector(
                onTap: () {
                  isSelectedBTCFormat = !isSelectedBTCFormat;
                  satAmountController.text = isSelectedBTCFormat
                      ? satAmount.toBtc.toStringAsFixed(8)
                      : satAmount.toStringAsFixed(0);
                  update();
                },
                child: Row(
                  mainAxisSize: .min,
                  mainAxisAlignment: .center,
                  children: [
                    Text(isSelectedBTCFormat ? 'BTC' : 'SAT', style: const TextStyle(fontSize: 16)),
                    const SizedBox(width: 4),
                    const Icon(Icons.change_circle_outlined),
                    const SizedBox(width: 8),
                  ],
                ),
              ),
            ),
            onChanged: (value) async {
              final val = num.tryParse(value) ?? 0;
              satAmount = isSelectedBTCFormat ? val.toSat : val.toInt();
              updateRates();
            },
            maxLength: 10,
            inputFormatters: [
              isSelectedBTCFormat
                  ? FilteringTextInputFormatter.allow(Regexes.btcInputFilter)
                  : FilteringTextInputFormatter.digitsOnly,
            ],
            buildCounter: (context, {required currentLength, required isFocused, required maxLength}) => null,
          ),
          Expanded(
            child: chosenFiats.isEmpty
                ? const Center(child: Text('Add currency'))
                : ReorderableListView.builder(
                    padding: const EdgeInsets.symmetric(vertical: 16),
                    buildDefaultDragHandles: false,
                    itemCount: chosenFiats.length,
                    itemBuilder: (context, i) {
                      final e = chosenFiats[i];
                      return Padding(
                        key: ValueKey(e.$1),
                        padding: const EdgeInsets.symmetric(vertical: 6),
                        child: Row(
                          spacing: 8,
                          children: [
                            Expanded(
                              child: TextFormField(
                                controller: e.$2,
                                keyboardType: const TextInputType.numberWithOptions(decimal: true),
                                decoration: const InputDecoration(hintText: '0.0'),
                                onChanged: (value) async {
                                  satAmount =
                                      double.tryParse(value)?.fiatToSats(sourceCurrencyCode: e.$1.currencyCode) ?? 0;
                                  satAmountController.text = isSelectedBTCFormat
                                      ? satAmount.toBtc.toStringAsFixed(8)
                                      : satAmount.toStringAsFixed(0);
                                  updateRates(excludeIndex: i);
                                },
                                maxLength: 8,
                                inputFormatters: [FilteringTextInputFormatter.allow(Regexes.decimalFilter)],
                                buildCounter:
                                    (context, {required currentLength, required isFocused, required maxLength}) => null,
                              ),
                            ),
                            Column(
                              mainAxisSize: MainAxisSize.min,
                              spacing: 6,
                              children: [
                                Text(e.$1.currencyCode),
                                SvgPicture.asset(
                                  'assets/flags/${e.$1.countryFlag}',
                                  fit: BoxFit.fitWidth,
                                  width: 28,
                                  placeholderBuilder: (BuildContext context) => const CircularProgressIndicator(),
                                ),
                              ],
                            ),
                            CloseButton(
                              onPressed: () {
                                chosenFiats[i].$2.dispose();
                                chosenFiats.removeAt(i);
                                update();
                                saveSettings();
                              },
                            ),
                            if (isReordering)
                              ReorderableDragStartListener(index: i, child: const Icon(Icons.drag_indicator)),
                          ],
                        ),
                      );
                    },
                    onReorderItem: (oldIndex, newIndex) {
                      final entry = chosenFiats.removeAt(oldIndex);
                      chosenFiats.insert(newIndex, entry);
                      update();
                      saveSettings();
                    },
                  ),
          ),
          SizedBox(
            width: double.infinity,
            child: ElevatedButton(
              style: ElevatedButton.styleFrom(visualDensity: VisualDensity.standard),
              onPressed: () async {
                isReordering = false;
                FocusManager.instance.primaryFocus?.unfocus();
                final res = await showModalBottomSheet(
                  context: context,
                  showDragHandle: true,
                  isScrollControlled: true,
                  useSafeArea: true,
                  shape: const RoundedRectangleBorder(borderRadius: BorderRadius.vertical(top: Radius.circular(24))),
                  routeSettings: const RouteSettings(name: 'CountrySelectionBottomSheet'),
                  builder: (context) => const CountrySelectionBottomSheet(),
                );
                if (res is CountryModel) {
                  if (!chosenFiats.any((e) => e.$1 == res)) {
                    chosenFiats.add((res, TextEditingController()));
                    updateRates();
                    update();
                    saveSettings();
                  } else {
                    ToastService.show('Currency already added!');
                  }
                }
              },
              child: const Text('Add'),
            ),
          ),
          const SizedBox(height: 16),
          SizedBox(
            width: double.infinity,
            child: ElevatedButton(
              style: ElevatedButton.styleFrom(visualDensity: VisualDensity.standard),
              onPressed: () => update(() => isReordering = !isReordering),
              child: Text(isReordering ? 'Stop reordering' : 'Reorder'),
            ),
          ),
        ],
      ),
    );
  }

  DateTime selectedDate = DateTime.now().add(const Duration(days: 365 * 5));
  late int amount = DB.accounts[selectedAccId]?.currentWallet.balance ?? 0;
  String selectedAccId = selectedAccountId;
  late final amountController = TextEditingController(text: amount.toString());

  Widget powerLawPage() {
    return SingleChildScrollView(
      padding: const EdgeInsets.all(8),
      keyboardDismissBehavior: ScrollViewKeyboardDismissBehavior.onDrag,
      child: Column(
        spacing: 8,
        children: [
          Card(
            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Column(
                spacing: 16,
                children: [
                  const Align(
                    alignment: Alignment.centerLeft,
                    child: Text(
                      'Step 1: Either select a wallet or enter amount',
                      style: TextStyle(fontSize: 12, color: Colors.grey),
                    ),
                  ),
                  DropdownButtonHideUnderline(
                    child: DropdownButton<String>(
                      value: selectedAccId,
                      onChanged: (value) {
                        if (value != null) {
                          selectedAccId = value;
                          amount = DB.accounts[selectedAccId]?.currentWallet.balance ?? 0;
                          amountController.text = isSelectedBTCFormat
                              ? amount.toBtc.toStringAsFixed(8)
                              : amount.toStringAsFixed(0);
                          update();
                        }
                      },
                      items: (DB.activeAccounts..sort((a, b) => a.sortOrder.compareTo(b.sortOrder)))
                          .map(
                            (acc) => DropdownMenuItem<String>(
                              value: acc.id,
                              child: Text(
                                acc.name,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: const TextStyle(fontSize: 20),
                              ),
                            ),
                          )
                          .toList(),
                      focusColor: Colors.transparent,
                      dropdownColor: context.themedColor(bright: AppColors.primaryColor, dark: AppColors.darkCardColor),
                      borderRadius: BorderRadius.circular(16),
                    ),
                  ),
                  AmountText(
                    amountSat: amount,
                    showFiat: true,
                    btcStyle: TextStyle(
                      fontSize: 32,
                      color: context.themedColor(bright: Colors.black, dark: AppColors.primaryColor),
                      fontWeight: FontWeight.bold,
                    ),
                    fiatStyle: const TextStyle(fontSize: 18, fontWeight: FontWeight.w500),
                  ),
                  const Row(
                    spacing: 12,
                    children: [
                      Expanded(child: Divider()),
                      Text('OR'),
                      Expanded(child: Divider()),
                    ],
                  ),
                  TextFormField(
                    controller: amountController,
                    keyboardType: TextInputType.number,
                    decoration: InputDecoration(
                      hintText: '0',
                      suffixIcon: GestureDetector(
                        onTap: () {
                          isSelectedBTCFormat = !isSelectedBTCFormat;
                          amountController.text = isSelectedBTCFormat
                              ? amount.toBtc.toStringAsFixed(8)
                              : amount.toStringAsFixed(0);
                          update();
                        },
                        child: Row(
                          mainAxisSize: .min,
                          mainAxisAlignment: .center,
                          children: [
                            Text(isSelectedBTCFormat ? 'BTC' : 'SAT', style: const TextStyle(fontSize: 16)),
                            const SizedBox(width: 4),
                            const Icon(Icons.change_circle_outlined),
                            const SizedBox(width: 8),
                          ],
                        ),
                      ),
                    ),
                    onChanged: (value) async {
                      final val = num.tryParse(value) ?? 0;
                      amount = isSelectedBTCFormat ? val.toSat : val.toInt();
                      update();
                    },
                    maxLength: 10,
                    inputFormatters: [
                      isSelectedBTCFormat
                          ? FilteringTextInputFormatter.allow(Regexes.btcInputFilter)
                          : FilteringTextInputFormatter.digitsOnly,
                    ],
                    buildCounter: (context, {required currentLength, required isFocused, required maxLength}) => null,
                  ),
                ],
              ),
            ),
          ),
          GestureDetector(
            onTap: () async {
              final picked = await showDatePicker(
                context: context,
                initialDate: selectedDate,
                firstDate: DateTime.now(),
                lastDate: DateTime(2140),
                builder: (ctx, child) => child!,
              );
              if (picked != null) {
                selectedDate = picked;
                update();
              }
            },
            child: Card(
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
              child: Padding(
                padding: const EdgeInsetsGeometry.all(16),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  spacing: 8,
                  children: [
                    const Align(
                      alignment: Alignment.centerLeft,
                      child: Text('Step 2: Select date', style: TextStyle(fontSize: 12, color: Colors.grey)),
                    ),
                    Row(
                      children: [
                        const Icon(Icons.calendar_month_rounded),
                        const SizedBox(width: 12),
                        Expanded(
                          child: Text(
                            DateFormat('MMMM dd, yyyy').format(selectedDate),
                            style: TextStyle(
                              color: context.themedColor(bright: Colors.black, dark: Colors.white),
                              fontSize: 16,
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                        ),
                        const SizedBox(width: 8),
                        Icon(
                          Icons.chevron_right_rounded,
                          color: context.themedColor(bright: Colors.black38, dark: Colors.white38),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
            ),
          ),
          const Divider(),
          Card(
            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: SizedBox(
                width: double.infinity,
                child: Column(
                  spacing: 8,
                  children: [
                    Text.rich(
                      TextSpan(
                        text: 'Projected power law value',
                        children: [
                          TextSpan(
                            text: ' ℹ️',
                            recognizer: TapGestureRecognizer()
                              ..onTap = () => launchUrl(
                                Uri.parse(
                                  'https://giovannisantostasi.medium.com/the-bitcoin-power-law-theory-962dfaf99ee9',
                                ),
                              ),
                          ),
                        ],
                      ),
                      style: const TextStyle(fontSize: 22),
                    ),
                    Text(
                      '≈ ${(_powerLawPrice(selectedDate) * amount.toBtc).convertCurrency().formatFiat()}',
                      style: const TextStyle(fontSize: 20, fontWeight: FontWeight.w500),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  final genesis = DateTime(2009, 1, 3);
  double _powerLawPrice(DateTime date) {
    final days = date.difference(genesis).inDays.toDouble();
    if (days <= 0) return 0;

    return math.pow(10, -17.016 + 5.845 * math.log(days) / math.ln10).toDouble();
  }
}
