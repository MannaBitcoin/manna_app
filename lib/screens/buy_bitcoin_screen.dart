import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_svg/flutter_svg.dart';
import 'package:manna/app_state.dart';
import 'package:manna/config.dart';
import 'package:manna/globals.dart';
import 'package:manna/models/account.dart';
import 'package:manna/models/boltz_fees.dart';
import 'package:manna/models/country_model.dart';
import 'package:manna/models/misc.dart';
import 'package:manna/models/swap.dart';
import 'package:manna/models/wallet.dart';
import 'package:manna/router.dart';
import 'package:manna/screens/image_preview_screen.dart';
import 'package:manna/screens/menu_screen.dart';
import 'package:manna/services/boltz_service.dart';
import 'package:manna/services/db.dart';
import 'package:manna/services/log_service.dart';
import 'package:manna/services/transaction_service.dart';
import 'package:manna/theme.dart';
import 'package:manna/utils/constants.dart';
import 'package:manna/utils/de_bouncer.dart';
import 'package:manna/utils/extensions.dart';
import 'package:manna/utils/parser.dart';
import 'package:manna/utils/sats_extension.dart';
import 'package:manna/utils/state_extension.dart';
import 'package:manna/utils/toast_service.dart';
import 'package:manna/utils/util.dart';
import 'package:manna/widgets/amount_text.dart';
import 'package:manna_core/manna_core.dart' hide Wallet;
import 'package:url_launcher/url_launcher_string.dart';

enum ExchangePartner {
  cashApp(
    'Cash app',
    'https://static.afterpaycdn.com/en-US/integration/logo/squared-badge/color.svg',
    'https://cash.app/help',
  );

  const ExchangePartner(this.name, this.logoURL, this.supportLink);
  final String name;
  final String logoURL;
  final String supportLink;
}

typedef DepositData = ({String swapId, String address, int sats, double fiat});

class BuyBitcoinScreen extends StatefulWidget {
  const BuyBitcoinScreen({super.key});

  @override
  State<BuyBitcoinScreen> createState() => _BuyBitcoinScreenState();
}

class _BuyBitcoinScreenState extends State<BuyBitcoinScreen> {
  CountryModel selectedCurrency = AppState.selectedCurrency;
  final fiatAmountController = TextEditingController();

  bool isLoadingQuote = false;
  final Map<ExchangePartner, Quote> quotes = {};
  MapEntry<ExchangePartner, Quote>? selectedQuote;
  final quoteUpdateDebouncer = DeBouncer(const Duration(milliseconds: 800));
  double? minBoltz, maxBoltz;

  Wallet wallet = selectedWallet;

  @override
  void initState() {
    final chainPair = BoltzFees.getReverseFeesAndLimits();
    minBoltz = chainPair.lbtcLimits.minimal.satsToFiat(targetCurrencyCode: selectedCurrency.currencyCode);
    maxBoltz = chainPair.lbtcLimits.maximal.satsToFiat(targetCurrencyCode: selectedCurrency.currencyCode);
    super.initState();
  }

  String? getError(double fiat) {
    // final min = math.max(selectedPaymentOption!.minAmount, minBoltz ?? 0.0);
    final min = minBoltz ?? 0;
    if (fiat < min) {
      return 'Min ${min.formatFiat(targetCurrencyCode: selectedCurrency.currencyCode)}';
    }

    // final max = math.min(selectedPaymentOption!.maxAmount, maxBoltz ?? double.infinity);
    final max = maxBoltz ?? 0;
    if (fiat > max) {
      return 'Max ${max.formatFiat(targetCurrencyCode: selectedCurrency.currencyCode)}';
    }
    return null;
  }

  Future<void> updateQuote() async {
    final chainPair = BoltzFees.getReverseFeesAndLimits();
    minBoltz = chainPair.lbtcLimits.minimal.satsToFiat(targetCurrencyCode: selectedCurrency.currencyCode);
    maxBoltz = chainPair.lbtcLimits.maximal.satsToFiat(targetCurrencyCode: selectedCurrency.currencyCode);

    final fiatAmount = double.tryParse(fiatAmountController.text.trim()) ?? 0;
    if (getError(fiatAmount) != null) {
      update(() => quotes.clear());
      return;
    }

    quoteUpdateDebouncer.call(() async {
      FocusManager.instance.primaryFocus?.unfocus();
      update(() => isLoadingQuote = true);

      quotes.clear();
      if ({
            'us',
            'uk',
            'gb',
            if (kDebugMode) 'in',
          }.contains(WidgetsBinding.instance.platformDispatcher.locale.countryCode?.toLowerCase()) &&
          fiatAmount < 999) {
        // cash app
        quotes[ExchangePartner.cashApp] = Quote(
          conversionPrice: AppState.btcPrice,
          fiatAmount: fiatAmount,
          cryptoAmount: AppState.btcPrice * fiatAmount,
          totalFee: 0,
          feeBreakDown: [],
        );
        selectedQuote = quotes.entries.firstOrNull;
      }
      update(() => isLoadingQuote = false);
    });
  }

  @override
  void dispose() {
    fiatAmountController.dispose();
    super.dispose();
  }

  Future<DepositData?> getDepositData() async {
    if (selectedQuote == null) return null;

    final chainPair = BoltzFees.getChainFeesAndLimits();
    final minimum = chainPair.btcLimits.minimal;
    final maximum = chainPair.btcLimits.maximal;
    final sats = selectedQuote!.value.cryptoAmount.toSat;
    if (sats < minimum || sats > maximum) {
      ToastService.show(
        'For on-chain transactions, amount must be between ${getSatInBitcoinStyle(minimum)} and ${getSatInBitcoinStyle(maximum)}.',
      );
      return null;
    }
    final sendAmount = (await calculateFeeAndAmounts(wallet: wallet, amount: sats, type: TraType.btcToLbtc)).sendAmount;
    final swap = await BoltzService.createBtcToLBtcSwap(selectedAccount, sendAmount, note: 'Manna BTC Buy');
    if (swap == null) {
      ToastService.show('Error creating swap to buy bitcoin!');
      return null;
    }
    swap.isExchangeSwap = true;
    swap.expectedLockupAmount = selectedQuote!.value.cryptoAmount.toSat.bigInt;
    await swap.save();
    final btcAddress = swap.chain?.lockupDetails.lockupAddress;
    if (btcAddress == null) {
      ToastService.show('Error creating swap to buy bitcoin!');
      return null;
    }
    return (swapId: swap.id, address: btcAddress, sats: sendAmount, fiat: selectedQuote!.value.fiatAmount);
  }

  @override
  Widget build(BuildContext context) {
    final fiat = double.tryParse(fiatAmountController.text.trim()) ?? 0;

    return Scaffold(
      appBar: AppBar(
        title: const Text('Buy Bitcoin'),
        actions: [
          GestureDetector(
            onTap: () async {
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
                selectedCurrency = res;
                update();
              }
            },
            child: Container(
              decoration: BoxDecoration(
                color: AppColors.primaryColor.withValues(alpha: 0.1),
                borderRadius: BorderRadius.circular(99),
              ),
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
              child: Row(
                children: [
                  SvgPicture.asset(
                    'assets/flags/${selectedCurrency.countryFlag}',
                    fit: BoxFit.fitWidth,
                    width: 24,
                    placeholderBuilder: (BuildContext context) => const CircularProgressIndicator(),
                  ),
                  const SizedBox(width: 8),
                  Text(selectedCurrency.currencyCode.toUpperCase(), style: const TextStyle(fontSize: 16)),
                  const Icon(Icons.keyboard_arrow_down),
                ],
              ),
            ),
          ),
          const SizedBox(width: 8),
        ],
      ),
      body: Stack(
        fit: StackFit.expand,
        children: [
          Column(
            children: [
              Expanded(
                child: Center(
                  child: SingleChildScrollView(
                    keyboardDismissBehavior: ScrollViewKeyboardDismissBehavior.onDrag,
                    padding: const EdgeInsets.all(16),
                    child: Column(
                      children: [
                        IntrinsicWidth(
                          child: TextFormField(
                            controller: fiatAmountController,
                            keyboardType: const TextInputType.numberWithOptions(decimal: true),
                            style: const TextStyle(fontSize: 58, fontWeight: FontWeight.w400),
                            decoration: InputDecoration(
                              hintText: '0',
                              border: InputBorder.none,
                              enabledBorder: InputBorder.none,
                              focusedBorder: InputBorder.none,
                              errorBorder: InputBorder.none,
                              focusedErrorBorder: InputBorder.none,
                              disabledBorder: InputBorder.none,
                              suffixIcon: Align(
                                alignment: Alignment.bottomRight,
                                widthFactor: 1,
                                child: Padding(
                                  padding: const EdgeInsets.symmetric(horizontal: 8),
                                  child: Text(
                                    selectedCurrency.currencyCode.toUpperCase(),
                                    style: TextStyle(
                                      fontSize: 20,
                                      fontWeight: FontWeight.w500,
                                      color: context.themedColor(bright: Colors.black54, dark: Colors.white54),
                                    ),
                                  ),
                                ),
                              ),
                            ),
                            autofocus: true,
                            onChanged: (value) => updateQuote(),
                            maxLength: 8,
                            inputFormatters: [FilteringTextInputFormatter.allow(Regexes.decimalFilter)],
                            buildCounter: (context, {required currentLength, required isFocused, required maxLength}) =>
                                null,
                          ),
                        ),

                        Center(
                          child: Padding(
                            padding: const EdgeInsets.symmetric(horizontal: 16),
                            child: Builder(
                              builder: (context) {
                                final error = getError(fiat);

                                if (fiat > 0) {
                                  if (error != null) {
                                    return Text(
                                      error,
                                      style: const TextStyle(color: Colors.red),
                                      textAlign: TextAlign.center,
                                    );
                                  } else if (!isLoadingQuote && quotes.isEmpty) {
                                    return const Text(
                                      'No match found for your region, selected currency and amount.',
                                      style: TextStyle(fontWeight: FontWeight.w600, fontSize: 16, color: Colors.grey),
                                      textAlign: TextAlign.center,
                                    );
                                  }
                                }
                                return const SizedBox.shrink();
                              },
                            ),
                          ),
                        ),

                        if (isLoadingQuote)
                          const CircularProgressIndicator()
                        else if (quotes.isNotEmpty) ...[
                          const SizedBox(height: 16),
                          ...quotes.entries.map((e) {
                            final isSelected = e.value == selectedQuote?.value;
                            return ListTile(
                              selected: isSelected,
                              onTap: () => update(() => selectedQuote = e),
                              leading: Row(
                                mainAxisSize: MainAxisSize.min,
                                spacing: 16,
                                children: [
                                  if (isSelected) const Icon(Icons.check_circle),
                                  Builder(
                                    builder: (context) {
                                      if (e.key.logoURL.endsWith('.svg')) {
                                        return SvgPicture.network(e.key.logoURL, fit: BoxFit.cover);
                                      }

                                      final provider = getImageProvider(e.key.logoURL);
                                      final fallback = Center(child: Text(e.key.name));
                                      if (provider != null) {
                                        return Image(
                                          image: provider,
                                          fit: BoxFit.cover,
                                          errorBuilder: (context, error, stackTrace) => fallback,
                                          loadingBuilder: imageLoadingBuilder,
                                        );
                                      }
                                      return fallback;
                                    },
                                  ),
                                ],
                              ),
                              title: Text(e.key.name),
                              subtitle: e.value.totalFee > 0
                                  ? Text(e.value.totalFee.formatFiat(targetCurrencyCode: selectedCurrency.currencyCode))
                                  : null,
                              trailing: AmountText(
                                amountSat: e.value.cryptoAmount.toSat,
                                isLongTapDisable: true,
                                isTapDisable: false,
                                scale: 1.2,
                                showFiat: true,
                              ),
                            );
                          }),
                        ],
                      ],
                    ),
                  ),
                ),
              ),
              if (selectedQuote != null) ...[
                SizedBox(
                  width: double.infinity,
                  child: Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 16),
                    child: Column(
                      spacing: 16,
                      children: [
                        DropdownButtonFormField(
                          validator: (value) {
                            if (value == null) return 'Please select a wallet';
                            return null;
                          },
                          items: DB.activeAccounts
                              .map((e) => DropdownMenuItem(value: e.currentWallet, child: Text(e.name)))
                              .toList(),
                          onChanged: (value) {
                            if (value != null) wallet = value;
                          },
                          decoration: const InputDecoration(hintText: 'Please select wallet'),
                        ),
                        ElevatedButton(
                          child: const Text(
                            'Buy',
                            style: TextStyle(fontWeight: FontWeight.w500, fontSize: 16),
                            textAlign: TextAlign.center,
                          ),
                          style: ElevatedButton.styleFrom(visualDensity: VisualDensity.standard),
                          onPressed: selectedQuote?.key == ExchangePartner.cashApp && getError(fiat) != null
                              ? null
                              : () async {
                                  try {
                                    startLoader();

                                    if (Config.network == Network.regtest) {
                                      final btcAddress = await getDepositData();
                                      if (btcAddress == null) return;
                                      final res = await globalDio.postUri(
                                        Uri(
                                          scheme: 'https',
                                          host: 'wallets.${Config.apiConfig.regtest.serverUrl}',
                                          path: 'api/bitcoin',
                                        ),
                                        data: {
                                          'action': 'send',
                                          'address': btcAddress.address,
                                          'amount': btcAddress.sats,
                                        },
                                      );
                                      if (res.isSuccess && res.data['txid'] != null) {
                                        ToastService.show('Buy order placed!');
                                        AppRouter.pop();
                                      }
                                    } else if (Config.network == Network.mainnet) {
                                      final chainPair = BoltzFees.getReverseFeesAndLimits();
                                      final minimum = chainPair.lbtcLimits.minimal;
                                      final maximum = chainPair.lbtcLimits.maximal;
                                      final sats = selectedQuote!.value.cryptoAmount.toSat;
                                      if (sats < minimum || sats > maximum) {
                                        ToastService.show(
                                          'Amount must be between ${getSatInBitcoinStyle(minimum)} and ${getSatInBitcoinStyle(maximum)}.',
                                        );
                                        return;
                                      }
                                      final sendAmount = (await calculateFeeAndAmounts(
                                        wallet: wallet,
                                        amount: sats,
                                        type: TraType.lnToLbtc,
                                      )).sendAmount;
                                      final liquidAddress = await wallet.getConfidentialAddress();
                                      if (liquidAddress == null) {
                                        ToastService.show('Failed to fetch liquid address');
                                        return;
                                      }
                                      final swap = await BoltzService.createLightningToLbtcSwap(
                                        wallet.account,
                                        liquidAddress,
                                        amount: sendAmount,
                                        note: 'Manna BTC Buy',
                                      );
                                      if (swap == null) {
                                        ToastService.show('Error creating swap to buy bitcoin!');
                                        return;
                                      }
                                      swap.isExchangeSwap = true;
                                      swap.expectedLockupAmount = selectedQuote!.value.cryptoAmount.toSat.bigInt;
                                      await swap.save();

                                      final invoice = swap.reverse?.swapCreateRes.invoice;
                                      if (invoice == null) {
                                        ToastService.show('Error creating swap to buy bitcoin!');
                                        return;
                                      }

                                      if (!await launchUrlString(
                                        'https://cash.app/launch/lightning/$invoice',
                                        mode: LaunchMode.externalApplication,
                                      )) {
                                        ToastService.show('Failed to open cash app!');
                                      }
                                    }
                                  } catch (e, s) {
                                    logE(e, stackTrace: s);
                                  } finally {
                                    stopLoader();
                                  }
                                },
                        ),
                      ],
                    ),
                  ),
                ),
                const SizedBox(height: 16),
              ],
            ],
          ),
        ],
      ),
    );
  }
}

class Quote {
  Quote({
    required this.conversionPrice,
    required this.fiatAmount,
    required this.cryptoAmount,
    required this.totalFee,
    required this.feeBreakDown,
  });

  factory Quote.fromMap(Map<String, dynamic> data) => Quote(
    conversionPrice: parseDouble(data['conversionPrice']),
    fiatAmount: parseDouble(data['fiatAmount']),
    cryptoAmount: parseDouble(data['cryptoAmount']),
    totalFee: parseDouble(data['totalFee']),
    feeBreakDown: parseList(
      data['feeBreakdown'],
      (e) => (id: parseString(e['id']), name: parseString(e['name']), value: parseDouble(e['value'])),
    ),
  );

  final double conversionPrice;
  final double fiatAmount;
  final double cryptoAmount;
  final double totalFee;
  final List<({String id, String name, double value})> feeBreakDown;

  @override
  String toString() => jsonEncode(
    {
      'conversionPrice': conversionPrice,
      'fiatAmount': fiatAmount,
      'cryptoAmount': cryptoAmount,
      'totalFee': totalFee,
      'feeBreakDown': feeBreakDown.map((e) => {'id': e.id, 'name': e.name, 'value': e.value}).toList(),
    }.toEncodeReady,
  );
}
