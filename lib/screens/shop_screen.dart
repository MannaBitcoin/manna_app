import 'dart:async';
import 'dart:convert';
import 'dart:math' as math;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:keyboard_detection/keyboard_detection.dart';
import 'package:manna/models/account.dart';
import 'package:manna/models/shop_item.dart';
import 'package:manna/models/tax.dart';
import 'package:manna/router.dart';
import 'package:manna/screens/all_transaction_screen.dart';
import 'package:manna/screens/image_preview_screen.dart';
import 'package:manna/screens/shop_setting_screen.dart';
import 'package:manna/utils/constants.dart';
import 'package:manna/utils/extensions.dart';
import 'package:manna/widgets/bottom sheets/shop_bottom_sheets.dart';
import 'package:manna/screens/shop_tax_screen.dart';
import 'package:manna/services/audio_service.dart';
import 'package:manna/services/db.dart';
import 'package:manna/services/shop_service.dart';
import 'package:manna/theme.dart';
import 'package:manna/utils/date_extension.dart';
import 'package:manna/utils/sats_extension.dart';
import 'package:manna/utils/state_extension.dart';
import 'package:manna/utils/util.dart';
import 'package:manna/widgets/amount_text.dart';
import 'package:manna/widgets/bottom sheets/shop_checkout_bottom_sheet.dart';
import 'package:manna/widgets/bottom sheets/shop_receipt_bottom_sheet.dart';
import 'package:math_expressions/math_expressions.dart' hide Stack;

class ShopScreen extends StatefulWidget {
  const ShopScreen({super.key});

  @override
  ShopScreenState createState() => ShopScreenState();
}

class ShopScreenState extends State<ShopScreen> with SingleTickerProviderStateMixin {
  late final tabController = TabController(length: 2, vsync: this);
  String expression = '0.0';
  double currentResult = 0.0;
  final List<CalcData> calculations = [];
  final keyboardNode = FocusNode();
  final parser = ShuntingYardParser();
  final searchController = TextEditingController();
  bool isAscending = true;
  bool showSat = false;

  final textMarqueeController = ScrollController();
  bool isKeyboardVisible = false;

  @override
  void initState() {
    postFrameCallBack(scroll);

    tabController.addListener(refresh);
    super.initState();
  }

  @override
  void dispose() {
    textMarqueeController.dispose();
    searchController.dispose();
    tabController.removeListener(refresh);
    tabController.dispose();
    super.dispose();
  }

  void scroll() async {
    const pauseDuration = Duration(milliseconds: 1000);
    final animationDuration = Duration(milliseconds: ShopService.shopName.length * 100);

    while (textMarqueeController.hasClients) {
      await Future.delayed(pauseDuration);
      if (textMarqueeController.hasClients) {
        await textMarqueeController.animateTo(
          textMarqueeController.position.maxScrollExtent,
          duration: animationDuration,
          curve: Curves.ease,
        );
      }
      await Future.delayed(pauseDuration);
      if (textMarqueeController.hasClients) {
        await textMarqueeController.animateTo(0.0, duration: animationDuration, curve: Curves.easeOut);
      }
    }
  }

  void refresh() {
    if (tabController.index == 1) {
      keyboardNode.requestFocus();
    }
    update();
  }

  @override
  Widget build(BuildContext context) {
    final amount =
        (calculations.fold(0.0, (a, b) => a + (b.totalPrice + b.totalTax)) +
                DB.shopItems.values.map((e) => e.totalPrice + e.totalTax).fold(0.0, (a, b) => a + b))
            .clamp(0.0, double.infinity);
    return Scaffold(
      resizeToAvoidBottomInset: false,
      appBar: AppBar(
        title: ScrollConfiguration(
          behavior: ScrollConfiguration.of(context).copyWith(scrollbars: false),
          child: SingleChildScrollView(
            controller: textMarqueeController,
            physics: const NeverScrollableScrollPhysics(),
            scrollDirection: Axis.horizontal,
            child: Text(ShopService.shopName),
          ),
        ),
        centerTitle: false,
        actions: [
          IconButton(
            onPressed: () => AppRouter.push(AllTransactionScreen(accountId: selectedAccountId)),
            icon: const Icon(Icons.history),
            tooltip: 'All Transactions',
          ),
          PopupMenuButton<String>(
            icon: const Icon(Icons.more_vert),
            onSelected: (value) async {
              if (context.mounted) {
                switch (value) {
                  case 'tax':
                    await AppRouter.push(const ShopTaxScreen());
                    update();
                  case 'import':
                    await ShopService.importShopData();
                    update();
                  case 'export':
                    unawaited(
                      showModalBottomSheet(
                        context: context,
                        showDragHandle: true,
                        isScrollControlled: true,
                        useSafeArea: true,
                        shape: const RoundedRectangleBorder(
                          borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
                        ),
                        builder: (context) => Column(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            ListTile(
                              leading: const Icon(Icons.share, size: 17),
                              onTap: () async {
                                final accountId = await showAccountSelectionDialog(context);
                                if (accountId is String) {
                                  final wallet = DB.accounts[accountId]?.currentWallet;
                                  if (wallet != null) {
                                    await ShopService.exportShopData(wallet);
                                  }
                                }
                                AppRouter.pop();
                              },
                              title: const Text(
                                'Send Shop Catalog',
                                style: TextStyle(fontSize: 16, fontWeight: FontWeight.w400),
                              ),
                            ),
                            ListTile(
                              leading: const Icon(Icons.file_download, size: 20),
                              onTap: () async {
                                final accountId = await showAccountSelectionDialog(context);
                                if (accountId is String) {
                                  final wallet = DB.accounts[accountId]?.currentWallet;
                                  if (wallet != null) {
                                    await ShopService.downloadShopData(wallet);
                                  }
                                }

                                AppRouter.pop();
                              },
                              title: const Text(
                                'Download Shop Catalog',
                                style: TextStyle(fontSize: 16, fontWeight: FontWeight.w400),
                              ),
                            ),
                            const SizedBox(height: 16),
                          ],
                        ),
                      ),
                    );
                  case 'delete':
                    unawaited(
                      showDialog(
                        context: context,
                        builder: (context) => AlertDialog(
                          title: const Text('Are you sure you want to delete all items?'),
                          actions: [
                            TextButton(onPressed: () => AppRouter.pop(false), child: const Text('No')),
                            TextButton(
                              onPressed: () async {
                                await DB.shopItemBox.clear();
                                DB.loadShopItems();
                                update();
                                AppRouter.pop();
                              },
                              child: const Text('Yes'),
                            ),
                          ],
                        ),
                      ),
                    );
                  case 'settings':
                    unawaited(AppRouter.push(const ShopSettingScreen()).then((value) => update()));
                }
              }
            },
            itemBuilder: (BuildContext context) => [
              const PopupMenuItem(value: 'tax', child: Text('Taxes')),
              const PopupMenuItem(value: 'settings', child: Text('Settings')),
              const PopupMenuItem(value: 'import', child: Text('Import Shop Catalog')),
              if (DB.shopItems.isNotEmpty) ...[
                const PopupMenuItem(value: 'export', child: Text('Export Shop Catalog')),
                const PopupMenuItem(value: 'delete', child: Text('Delete Shop Catalog')),
              ],
            ],
          ),
        ],
      ),
      floatingActionButton: tabController.index == 0
          ? FloatingActionButton(
              child: const Icon(Icons.add),
              onPressed: () async {
                FocusManager.instance.primaryFocus?.unfocus();
                final res = await showModalBottomSheet(
                  context: context,
                  showDragHandle: true,
                  isScrollControlled: true,
                  useSafeArea: true,
                  isDismissible: false,
                  shape: const RoundedRectangleBorder(borderRadius: BorderRadius.vertical(top: Radius.circular(24))),
                  routeSettings: const RouteSettings(name: 'ShopItemBottomSheet'),
                  builder: (context) => const ShopItemBottomSheet(),
                );
                if (res is bool && res) update();
              },
            )
          : null,
      body: KeyboardDetection(
        controller: KeyboardDetectionController(
          onChanged: (value) => update(() => isKeyboardVisible = value == KeyboardState.visible),
        ),
        child: Column(
          children: [
            const SizedBox(height: 16),
            ConstrainedBox(
              constraints: BoxConstraints(maxWidth: 600, maxHeight: isKeyboardVisible ? 0 : double.infinity),
              child: Column(
                children: [
                  Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 16),
                    child: SizedBox(
                      height: 56,
                      child: Row(
                        crossAxisAlignment: .stretch,
                        children: [
                          if (amount > 0) ...[
                            GestureDetector(
                              onTap: () {
                                DB.shopItems.forEach((key, value) {
                                  value.quantity = 0;
                                });
                                calculations.clear();
                                update();
                              },
                              child: Container(
                                decoration: BoxDecoration(
                                  color: AppColors.primaryColor.withValues(alpha: 0.7),
                                  borderRadius: BorderRadius.circular(16),
                                ),
                                padding: const EdgeInsets.symmetric(horizontal: 16),
                                child: const Icon(Icons.close, color: Colors.white),
                              ),
                            ),
                            const SizedBox(width: 8),
                          ],
                          Expanded(
                            child: GestureDetector(
                              onTap: () => update(() => showSat = !showSat),
                              child: Container(
                                decoration: BoxDecoration(
                                  color: AppColors.primaryColor.withValues(alpha: 0.7),
                                  borderRadius: BorderRadius.circular(16),
                                ),
                                alignment: Alignment.center,
                                padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
                                child: FittedBox(
                                  child: AmountText(
                                    key: Key(showSat.toString()),
                                    amountSat: amount.fiatToSats(),
                                    showSat: showSat,
                                    btcStyle: const TextStyle(color: Colors.white, fontSize: 18),
                                    scale: 1.2,
                                  ),
                                ),
                              ),
                            ),
                          ),
                          const SizedBox(width: 8),
                          if (amount > 0) ...[
                            GestureDetector(
                              onTap: () async {
                                unawaited(
                                  showModalBottomSheet(
                                    context: context,
                                    showDragHandle: true,
                                    isScrollControlled: true,
                                    useSafeArea: true,
                                    shape: const RoundedRectangleBorder(
                                      borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
                                    ),
                                    routeSettings: const RouteSettings(name: 'ShopReceiptBottomSheet'),
                                    builder: (context) => ShopReceiptBottomSheet(
                                      calculations: calculations,
                                      items: DB.shopItems.values.where((e) => e.quantity > 0).toList(),
                                    ),
                                  ),
                                );
                              },
                              child: Container(
                                decoration: BoxDecoration(
                                  color: AppColors.primaryColor.withValues(alpha: 0.7),
                                  borderRadius: BorderRadius.circular(16),
                                ),
                                padding: const EdgeInsets.symmetric(horizontal: 16),
                                child: const Icon(Icons.receipt_long, color: Colors.white),
                              ),
                            ),
                            const SizedBox(width: 8),
                          ],
                          IconButton(
                            onPressed: amount > 0
                                ? () async {
                                    final itemList = [
                                      ...DB.shopItems.values
                                          .where((e) => e.quantity > 0)
                                          .map((e) => '${e.name}x${e.quantity}:${e.price.formatFiat()}'),
                                      ...calculations
                                          .where((e) => e.qty > 0)
                                          .map((e) => '${e.name}x${e.qty}:${e.price.formatFiat()}'),
                                    ].join(', ');

                                    String memo =
                                        '${ShopService.shopName.isNotEmpty ? ShopService.shopName : 'Manna Shop'}: ${amount.formatFiat()} (${DateTime.now().format()}) '
                                        'for $itemList';
                                    try {
                                      memo = utf8
                                          .decode(memo.runes.toList(), allowMalformed: true)
                                          .replaceAll('\uFFFD', '');
                                    } catch (_) {}

                                    if (context.mounted) {
                                      unawaited(
                                        showModalBottomSheet(
                                          context: context,
                                          showDragHandle: true,
                                          isScrollControlled: true,
                                          useSafeArea: true,
                                          shape: const RoundedRectangleBorder(
                                            borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
                                          ),
                                          routeSettings: const RouteSettings(name: 'ShopCheckoutBottomSheet'),
                                          builder: (context) => ShopCheckoutBottomSheet(
                                            calculations: calculations,
                                            items: DB.shopItems.values.where((e) => e.quantity > 0).toList(),
                                            amount: amount.fiatToSats(),
                                            memo: memo,
                                          ),
                                        ),
                                      );
                                    }
                                  }
                                : null,
                            padding: const EdgeInsets.symmetric(horizontal: 16),
                            style: IconButton.styleFrom(
                              backgroundColor: AppColors.primaryColor,
                              disabledBackgroundColor: Colors.grey.shade400.withValues(alpha: 0.7),
                              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
                            ),
                            icon: const Icon(Icons.qr_code, color: Colors.white),
                          ),
                        ],
                      ),
                    ),
                  ),
                  TabBar(
                    controller: tabController,
                    indicatorSize: TabBarIndicatorSize.label,
                    tabs: const [
                      Tab(icon: Icon(Icons.folder_outlined), child: Text('Items')),
                      Tab(icon: Icon(Icons.calculate), child: Text('Calculator')),
                    ],
                  ),
                ],
              ),
            ),
            Expanded(
              child: TabBarView(controller: tabController, children: [itemsList(), calculatorWidget()]),
            ),
          ],
        ),
      ),
    );
  }

  void handleCalcButtonClick(String buttonText) async {
    await hapticFeedback();

    if (buttonText == 'AC' || buttonText == 'C') {
      if (buttonText == 'AC') {
        update(() => calculations.clear());
      }
      expression = '0.0';
    } else if (buttonText == '=') {
      if (currentResult != 0) {
        String calcName = '';
        if (mounted) {
          await showDialog(
            context: context,
            builder: (context) {
              void addCalculation() {
                calculations.add(
                  CalcData(
                    name: calcName.isNotEmpty
                        ? calcName
                        : 'Calc ${calculations.where((e) => e.name.startsWith('Calc')).length + 1}',
                    price: currentResult,
                    qty: 1,
                  ),
                );
                AppRouter.pop();
              }

              return AlertDialog(
                shape: const RoundedRectangleBorder(borderRadius: BorderRadius.all(Radius.circular(16))),
                contentPadding: const EdgeInsets.all(16),
                title: const Text('Add Calculation'),
                content: TextFormField(
                  autofocus: true,
                  decoration: const InputDecoration(
                    contentPadding: EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                    labelText: 'Calculation name',
                    hintText: 'Enter calculation name',
                  ),
                  textCapitalization: TextCapitalization.sentences,
                  onChanged: (value) => calcName = value,
                  onFieldSubmitted: (value) => addCalculation(),
                ),
                actions: [
                  TextButton(
                    child: const Text('Cancel', style: TextStyle(color: Colors.grey, fontSize: 16)),
                    onPressed: () => AppRouter.pop(),
                  ),
                  TextButton(
                    onPressed: addCalculation,
                    child: const Text('Add', style: TextStyle(color: AppColors.primaryColor, fontSize: 16)),
                  ),
                ],
              );
            },
          );
        }
      }
      expression = '0.0';
    } else if (buttonText == '⌫') {
      expression = expression.length > 1 ? expression.substring(0, expression.length - 1) : '0.0';
    } else {
      if (expression == '0.0') {
        expression = buttonText;
      } else {
        if (!(buttonText == '.' && expression.endsWith('.'))) {
          expression += buttonText;
        }
      }
    }
    try {
      final evaluator = RealEvaluator();
      currentResult = evaluator.evaluate(parser.parse(expression.replaceAll('×', '*').replaceAll('÷', '/'))).toDouble();
    } catch (e) {
      currentResult = 0;
    }
    update();
  }

  Widget buildCalcButton(String buttonText, {Color? textColor, int flex = 1}) {
    return Expanded(
      flex: flex,
      child: GestureDetector(
        onTap: () => handleCalcButtonClick(buttonText),
        child: Card(
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
          child: Container(
            margin: const EdgeInsets.all(8),
            alignment: Alignment.center,
            child: FittedBox(
              child: Text(
                buttonText == '=' ? '=\nSubmit' : buttonText,
                style: TextStyle(fontSize: buttonText == '=' ? 18 : 24, fontWeight: FontWeight.bold, color: textColor),
                textAlign: TextAlign.center,
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget calculatorWidget() {
    final Map<LogicalKeyboardKey, String> keyMap = {
      LogicalKeyboardKey.digit0: '0',
      LogicalKeyboardKey.digit1: '1',
      LogicalKeyboardKey.digit2: '2',
      LogicalKeyboardKey.digit3: '3',
      LogicalKeyboardKey.digit4: '4',
      LogicalKeyboardKey.digit5: '5',
      LogicalKeyboardKey.digit6: '6',
      LogicalKeyboardKey.digit7: '7',
      LogicalKeyboardKey.digit8: '8',
      LogicalKeyboardKey.digit9: '9',

      LogicalKeyboardKey.numpad0: '0',
      LogicalKeyboardKey.numpad1: '1',
      LogicalKeyboardKey.numpad2: '2',
      LogicalKeyboardKey.numpad3: '3',
      LogicalKeyboardKey.numpad4: '4',
      LogicalKeyboardKey.numpad5: '5',
      LogicalKeyboardKey.numpad6: '6',
      LogicalKeyboardKey.numpad7: '7',
      LogicalKeyboardKey.numpad8: '8',
      LogicalKeyboardKey.numpad9: '9',

      LogicalKeyboardKey.period: '.',
      LogicalKeyboardKey.numpadDecimal: '.',

      LogicalKeyboardKey.add: '+',
      LogicalKeyboardKey.numpadAdd: '+',
      LogicalKeyboardKey.minus: '-',
      LogicalKeyboardKey.numpadSubtract: '-',
      LogicalKeyboardKey.asterisk: '*',
      LogicalKeyboardKey.numpadMultiply: '*',
      LogicalKeyboardKey.slash: '/',
      LogicalKeyboardKey.numpadDivide: '/',

      LogicalKeyboardKey.backspace: '⌫',
      LogicalKeyboardKey.equal: '=',
      LogicalKeyboardKey.numpadEqual: '=',
      LogicalKeyboardKey.enter: '=',
      LogicalKeyboardKey.numpadEnter: '=',
      LogicalKeyboardKey.insert: '=',

      LogicalKeyboardKey.delete: 'C',
    };
    return Focus(
      focusNode: keyboardNode,
      autofocus: true,
      onKeyEvent: (node, event) {
        if (keyMap.containsKey(event.logicalKey)) {
          if (event is KeyUpEvent) {
            handleCalcButtonClick(keyMap[event.logicalKey]!);
          }
          return KeyEventResult.handled;
        }
        return KeyEventResult.ignored;
      },
      child: Row(
        crossAxisAlignment: .start,
        spacing: 16,
        children: [
          if (context.screenWidth >= 800)
            Expanded(
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 20.0),
                child: Column(
                  crossAxisAlignment: .end,
                  children: [
                    Text(
                      expression,
                      style: TextStyle(
                        fontSize: 40,
                        color: context.themedColor(bright: Colors.grey.shade600, dark: Colors.grey.shade400),
                      ),
                      textAlign: TextAlign.end,
                    ),
                    if (currentResult != 0)
                      Text(
                        '=${currentResult.toStringAsFixed(2)}',
                        style: TextStyle(
                          fontSize: 28,
                          color: context.themedColor(bright: Colors.grey.shade400, dark: Colors.grey.shade600),
                        ),
                      ),
                  ],
                ),
              ),
            ),
          Expanded(
            flex: 2,
            child: Column(
              spacing: 16,
              children: [
                if (context.screenWidth < 800)
                  ConstrainedBox(
                    constraints: const BoxConstraints(minHeight: 100),
                    child: Align(
                      alignment: Alignment.centerRight,
                      child: Padding(
                        padding: const EdgeInsets.symmetric(horizontal: 20.0),
                        child: Column(
                          crossAxisAlignment: .end,
                          children: [
                            Text(
                              expression,
                              style: TextStyle(
                                fontSize: 40,
                                color: context.themedColor(bright: Colors.grey.shade600, dark: Colors.grey.shade400),
                              ),
                              textAlign: TextAlign.end,
                            ),
                            if (currentResult != 0)
                              Text(
                                '=${currentResult.toStringAsFixed(2)}',
                                style: TextStyle(
                                  fontSize: 28,
                                  color: context.themedColor(bright: Colors.grey.shade400, dark: Colors.grey.shade600),
                                ),
                              ),
                          ],
                        ),
                      ),
                    ),
                  ),
                Expanded(
                  child: Align(
                    alignment: context.screenWidth < 800 ? Alignment.bottomCenter : Alignment.bottomRight,
                    child: LayoutBuilder(
                      builder: (context, constraints) {
                        return SizedBox.square(
                          dimension: math.min(constraints.maxHeight, constraints.maxWidth),
                          child: Container(
                            decoration: BoxDecoration(
                              color: context.themedColor(bright: Colors.white, dark: AppColors.darkCardColor),
                              borderRadius: const BorderRadius.vertical(top: Radius.circular(30)),
                            ),
                            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 12),
                            child: Column(
                              children: [
                                Expanded(
                                  child: Row(
                                    children: [
                                      buildCalcButton('AC', textColor: Colors.red),
                                      buildCalcButton('C', textColor: Colors.red),
                                      buildCalcButton('⌫', textColor: Colors.red),
                                      buildCalcButton('÷', textColor: Colors.green),
                                    ],
                                  ),
                                ),
                                Expanded(
                                  child: Row(
                                    children: [
                                      buildCalcButton('7'),
                                      buildCalcButton('8'),
                                      buildCalcButton('9'),
                                      buildCalcButton('×', textColor: Colors.green),
                                    ],
                                  ),
                                ),
                                Expanded(
                                  child: Row(
                                    children: [
                                      buildCalcButton('4'),
                                      buildCalcButton('5'),
                                      buildCalcButton('6'),
                                      buildCalcButton('-', textColor: Colors.green),
                                    ],
                                  ),
                                ),
                                Expanded(
                                  child: Row(
                                    children: [
                                      buildCalcButton('1'),
                                      buildCalcButton('2'),
                                      buildCalcButton('3'),
                                      buildCalcButton('+', textColor: Colors.green),
                                    ],
                                  ),
                                ),
                                Expanded(
                                  child: Row(
                                    children: [
                                      buildCalcButton('.', textColor: Colors.green),
                                      buildCalcButton('0'),
                                      buildCalcButton('=', textColor: Colors.green, flex: 2),
                                    ],
                                  ),
                                ),
                              ],
                            ),
                          ),
                        );
                      },
                    ),
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget itemsList() {
    final searchTerm = searchController.text.trim().toLowerCase();
    final filteredItems = DB.shopItems.values
        .where((item) => '${item.category} ${item.name}'.toLowerCase().contains(searchTerm))
        .toList();

    final categories =
        getCateMap(filteredItems).entries
            .map(
              (e) => (
                name: e.key,
                items: e.value..sort((a, b) => isAscending ? a.name.compareTo(b.name) : b.name.compareTo(a.name)),
              ),
            )
            .toList()
          ..sort((a, b) => isAscending ? a.name.compareTo(b.name) : b.name.compareTo(a.name));
    final soloItems = filteredItems.where((e) => e.category.isEmpty).toList()
      ..sort((a, b) => isAscending ? a.name.compareTo(b.name) : b.name.compareTo(a.name));

    return Padding(
      padding: const EdgeInsets.all(12) - const EdgeInsets.only(bottom: 12),
      child: Column(
        children: [
          ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 600),
            child: TextFormField(
              autofocus: isDesktop,
              controller: searchController,
              onChanged: (value) => update(),
              decoration: InputDecoration(
                contentPadding: const EdgeInsets.all(10.0),
                prefixIcon: const Icon(Icons.search),
                suffixIcon: GestureDetector(
                  onTap: () => update(() => isAscending = !isAscending),
                  child: Transform.flip(flipY: isAscending, child: const Icon(Icons.sort)),
                ),
                hintText: 'Search...',
              ),
            ),
          ),
          Expanded(
            child: filteredItems.isEmpty && calculations.isEmpty
                ? const Center(child: Text('Items Not Found', style: TextStyle(fontSize: 16)))
                : LayoutBuilder(
                    builder: (context, constraints) {
                      final allItems = [
                        for (final cat in categories)
                          Builder(
                            builder: (context) {
                              final qty = cat.items.fold(0.0, (p, i) => p + i.quantity);
                              final amount = cat.items.fold(0.0, (p, e) => p + e.totalPrice + e.totalTax);
                              return GestureDetector(
                                onLongPress: () async {
                                  final res = await showModalBottomSheet(
                                    context: context,
                                    showDragHandle: true,
                                    isScrollControlled: true,
                                    useSafeArea: true,
                                    isDismissible: false,
                                    shape: const RoundedRectangleBorder(
                                      borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
                                    ),
                                    routeSettings: const RouteSettings(name: 'CategoryBottomSheet'),
                                    builder: (context) => CategoryBottomSheet(categoryName: cat.name),
                                  );
                                  if (res is bool && res) update();
                                },
                                child: Card(
                                  child: ExpansionTile(
                                    title: Text(
                                      cat.name,
                                      style: const TextStyle(fontWeight: FontWeight.w500, fontSize: 18),
                                    ),
                                    tilePadding:
                                        const EdgeInsets.symmetric(horizontal: 8) +
                                        const EdgeInsets.only(bottom: 8, top: 4),
                                    childrenPadding: const EdgeInsets.only(left: 16),
                                    shape: const RoundedRectangleBorder(
                                      borderRadius: BorderRadius.all(Radius.circular(12)),
                                    ),
                                    collapsedShape: const RoundedRectangleBorder(
                                      borderRadius: BorderRadius.all(Radius.circular(12)),
                                    ),
                                    leading: Builder(
                                      builder: (context) {
                                        final provider = getImageProvider(DB.categoryImages[cat.name]);
                                        final fallback = SizedBox(
                                          width: 52,
                                          height: 52,
                                          child: Center(
                                            child: Wrap(
                                              children: [
                                                for (final i in cat.items.take(4))
                                                  Container(
                                                    width: cat.items.length > 1 ? 24 : 52,
                                                    height: cat.items.length > 1 ? 24 : 52,
                                                    margin: EdgeInsets.all(cat.items.length > 1 ? 1 : 0),
                                                    decoration: BoxDecoration(
                                                      borderRadius: BorderRadius.circular(
                                                        cat.items.length > 1 ? 4 : 999,
                                                      ),
                                                      color: AppColors.primaryColor.withValues(alpha: 0.5),
                                                    ),
                                                    child: Builder(
                                                      builder: (context) {
                                                        final provider = getImageProvider(i.imageBytes);
                                                        final fallback = Center(
                                                          child: Text(
                                                            i.name.shortName,
                                                            style: const TextStyle(color: Colors.white),
                                                          ),
                                                        );
                                                        if (provider != null) {
                                                          return ClipRRect(
                                                            borderRadius: BorderRadius.circular(
                                                              cat.items.length > 1 ? 4 : 999,
                                                            ),
                                                            child: Image(
                                                              image: provider,
                                                              fit: BoxFit.cover,
                                                              errorBuilder: (context, error, stackTrace) => fallback,
                                                            ),
                                                          );
                                                        }
                                                        return fallback;
                                                      },
                                                    ),
                                                  ),
                                              ],
                                            ),
                                          ),
                                        );
                                        if (provider != null) {
                                          return ClipRRect(
                                            borderRadius: BorderRadius.circular(999),
                                            child: Image(
                                              image: provider,
                                              fit: BoxFit.cover,
                                              errorBuilder: (context, error, stackTrace) => fallback,
                                            ),
                                          );
                                        }
                                        return fallback;
                                      },
                                    ),
                                    subtitle: qty <= 0
                                        ? null
                                        : Text('x$qty (${amount.formatFiat()})', style: const TextStyle(fontSize: 16)),
                                    children: [for (final item in cat.items) itemView(item)],
                                  ),
                                ),
                              );
                            },
                          ),
                        for (final item in soloItems) itemView(item),
                        for (final calc in calculations) calcView(calc),
                      ];

                      int columnCount = 1;
                      if (constraints.maxWidth > 1200) {
                        columnCount = 3;
                      } else if (constraints.maxWidth > 700) {
                        columnCount = 2;
                      }

                      final totalItems = allItems.length;
                      final itemsPerColumn = (totalItems / columnCount).ceil();

                      final groups = List.generate(
                        columnCount,
                        (i) => allItems.skip(i * itemsPerColumn).take(itemsPerColumn).toList(),
                      );

                      return Row(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        spacing: 8,
                        children: [
                          for (final g in groups)
                            Expanded(
                              child: ListView(padding: const EdgeInsets.only(bottom: 60, top: 8), children: g),
                            ),
                        ],
                      );
                    },
                  ),
          ),
        ],
      ),
    );
  }

  Widget itemView(ShopItem item) {
    return ListTile(
      onTap: () => update(() => item.quantity = item.quantity + 1),
      contentPadding: const EdgeInsets.symmetric(horizontal: 8),
      onLongPress: () async {
        final res = await showModalBottomSheet(
          context: context,
          showDragHandle: true,
          isScrollControlled: true,
          useSafeArea: true,
          isDismissible: false,
          shape: const RoundedRectangleBorder(borderRadius: BorderRadius.vertical(top: Radius.circular(24))),
          routeSettings: const RouteSettings(name: 'ShopItemBottomSheet'),
          builder: (context) => ShopItemBottomSheet(item: item),
        );
        if (res is bool && res) update();
      },
      leading: GestureDetector(
        onTap: item.imageBytes == null
            ? null
            : () => AppRouter.push(ImagePreviewScreen(appBarTitle: item.name, image: item.imageBytes)),
        child: Container(
          height: 45,
          width: 45,
          clipBehavior: Clip.antiAlias,
          decoration: BoxDecoration(shape: BoxShape.circle, color: AppColors.primaryColor.withValues(alpha: 0.5)),
          child: Builder(
            builder: (context) {
              final provider = getImageProvider(item.imageBytes);
              final fallback = Center(
                child: Text(item.name.shortName, style: const TextStyle(color: Colors.white, fontSize: 24)),
              );
              if (provider != null) {
                return Image(
                  image: provider,
                  fit: BoxFit.cover,
                  errorBuilder: (context, error, stackTrace) => fallback,
                );
              }
              return fallback;
            },
          ),
        ),
      ),
      title: Text(item.name, style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w500)),
      subtitle: Align(
        alignment: Alignment.centerLeft,
        child: AmountText(
          key: Key(showSat.toString()),
          amountSat: item.price.fiatToSats(),
          showSat: showSat,
          btcStyle: const TextStyle(color: Colors.grey, fontWeight: FontWeight.w500),
        ),
      ),
      trailing: item.quantity > 0
          ? GestureDetector(
              onTap: () {
                String value = '';

                void save(String value) {
                  update(() => item.quantity = (double.tryParse(value) ?? 0.0).clamp(0, double.maxFinite));
                  AppRouter.pop();
                }

                showDialog(
                  context: context,
                  builder: (context) {
                    return AlertDialog(
                      shape: const RoundedRectangleBorder(borderRadius: BorderRadius.all(Radius.circular(16))),
                      contentPadding: const EdgeInsets.all(16),
                      title: const Text('Edit Quantity'),
                      content: TextFormField(
                        autofocus: true,
                        initialValue: item.quantity.toString(),
                        textAlign: TextAlign.center,
                        keyboardType: TextInputType.number,
                        inputFormatters: [FilteringTextInputFormatter.allow(Regexes.decimalFilter)],
                        decoration: const InputDecoration(contentPadding: EdgeInsets.all(8), labelText: 'Quantity'),
                        onFieldSubmitted: save,
                        onChanged: (str) => value = str,
                      ),
                      actions: [
                        TextButton(
                          child: const Text('Clear', style: TextStyle(color: Colors.red)),
                          onPressed: () {
                            item.quantity = 0;
                            update();
                            AppRouter.pop();
                          },
                        ),
                        TextButton(child: const Text('Done'), onPressed: () => save(value)),
                      ],
                    );
                  },
                );
              },
              child: DecoratedBox(
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(10),
                  color: AppColors.primaryColor.withValues(alpha: 0.7),
                ),
                child: Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                  child: Text(
                    'x${item.quantity}',
                    style: const TextStyle(color: Colors.white, fontWeight: FontWeight.w500, fontSize: 16),
                  ),
                ),
              ),
            )
          : null,
    );
  }

  Widget calcView(CalcData calc) {
    return ListTile(
      onTap: () => update(() => calc.qty = (calc.qty + 1).clamp(0, double.maxFinite.floor())),
      contentPadding: const EdgeInsets.symmetric(horizontal: 8),
      leading: Container(
        height: 45,
        width: 45,
        clipBehavior: Clip.antiAlias,
        decoration: BoxDecoration(shape: BoxShape.circle, color: AppColors.primaryColor.withValues(alpha: 0.5)),
        child: Center(
          child: Text(calc.name.shortName, style: const TextStyle(color: Colors.white, fontSize: 24)),
        ),
      ),
      title: Text(calc.name, style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w500)),
      subtitle: Align(
        alignment: Alignment.centerLeft,
        child: AmountText(
          key: Key(showSat.toString()),
          amountSat: calc.price.fiatToSats(),
          showSat: showSat,
          btcStyle: const TextStyle(color: Colors.grey, fontWeight: FontWeight.w500),
        ),
      ),
      trailing: GestureDetector(
        onTap: () {
          showDialog(
            context: context,
            builder: (context) {
              String value = '';

              void save(String value) {
                calc.qty = (int.tryParse(value) ?? 0).clamp(0, double.maxFinite.floor());
                if (calc.qty == 0) {
                  calculations.remove(calc);
                }
                update();
                AppRouter.pop();
              }

              return AlertDialog(
                shape: const RoundedRectangleBorder(borderRadius: BorderRadius.all(Radius.circular(16))),
                contentPadding: const EdgeInsets.all(16),
                title: const Text('Edit Quantity'),
                content: TextFormField(
                  autofocus: true,
                  initialValue: calc.qty.toString(),
                  textAlign: TextAlign.center,
                  keyboardType: TextInputType.number,
                  inputFormatters: [FilteringTextInputFormatter.digitsOnly],
                  decoration: const InputDecoration(contentPadding: EdgeInsets.all(8), labelText: 'Quantity'),
                  onChanged: (str) => value = str,
                  onFieldSubmitted: save,
                ),
                actions: [
                  TextButton(
                    child: const Text('Clear', style: TextStyle(color: Colors.red)),
                    onPressed: () {
                      calculations.remove(calc);
                      update();
                      AppRouter.pop();
                    },
                  ),
                  TextButton(child: const Text('Done'), onPressed: () => save(value)),
                ],
              );
            },
          );
        },
        child: DecoratedBox(
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(10),
            color: AppColors.primaryColor.withValues(alpha: 0.7),
          ),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
            child: Text(
              'x${calc.qty}',
              style: const TextStyle(color: Colors.white, fontWeight: FontWeight.w500, fontSize: 16),
            ),
          ),
        ),
      ),
    );
  }
}

Future<String?> showAccountSelectionDialog(BuildContext context) {
  String? selectedId = selectedAccountId;
  final List<Account> accounts = DB.activeAccounts.toList();

  return showDialog<String>(
    context: context,
    builder: (context) => AlertDialog(
      title: const Text('Shop export'),
      content: StatefulBuilder(
        builder: (context, setState) {
          return Column(
            mainAxisSize: MainAxisSize.min,
            spacing: 16,
            children: [
              const Text(
                'Select wallet that you wish to export along with the shop catalog, This is the wallet that will be used to receive bitcoin on the importing device.\nThe wallet included in the export is a watch-only wallet, importer cannot spend from the watch-only wallet.',
              ),
              Row(
                spacing: 12,
                children: [
                  const Text('Select wallet :', style: TextStyle(fontSize: 16, fontWeight: FontWeight.w600)),
                  Expanded(
                    child: DropdownButtonHideUnderline(
                      child: DropdownButton<String>(
                        value: selectedId,
                        onChanged: (value) => setState(() => selectedId = value),
                        items:
                            [
                                  ...accounts.where((acc) => acc.isMainAccount),
                                  ...accounts.where((acc) => !acc.isDisabled && !acc.isMainAccount),
                                ]
                                .map(
                                  (acc) => DropdownMenuItem(
                                    value: acc.id,
                                    child: Text(acc.name, maxLines: 2, overflow: TextOverflow.ellipsis),
                                  ),
                                )
                                .toList(),
                        style: const TextStyle(
                          color: AppColors.primaryColor,
                          fontSize: 18,
                          letterSpacing: 1.1,
                          fontWeight: FontWeight.w500,
                        ),
                        borderRadius: BorderRadius.circular(16),
                        alignment: Alignment.center,
                      ),
                    ),
                  ),
                ],
              ),
            ],
          );
        },
      ),
      actions: [
        TextButton(onPressed: () => AppRouter.pop(), child: const Text('Cancel')),
        TextButton(onPressed: selectedId == null ? null : () => AppRouter.pop(selectedId), child: const Text('Export')),
      ],
    ),
  );
}

Map<String, List<ShopItem>> getCateMap(List<ShopItem> items) {
  final Map<String, List<ShopItem>> catMap = {};
  for (final i in items.where((e) => e.category.isNotEmpty)) {
    if (!catMap.containsKey(i.category)) {
      catMap[i.category] = [i];
    } else {
      catMap.update(i.category, (value) => value..add(i));
    }
  }
  return catMap;
}

class CalcData {
  CalcData({required this.name, required this.price, required this.qty});

  String name;
  double price;
  int qty;

  double get totalPrice => price * qty;

  double get totalTax =>
      price * qty * DB.taxes.values.where((e) => e.categories.isEmpty).fold(0.0, (a, b) => a + b.tax / 100);

  double particularTax(Tax t) => price * qty * (t.categories.isEmpty ? t.tax / 100 : 0);
}
