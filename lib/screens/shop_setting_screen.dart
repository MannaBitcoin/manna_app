import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:manna/app_state.dart';
import 'package:manna/services/shop_service.dart';
import 'package:manna/theme.dart';
import 'package:manna/utils/constants.dart';
import 'package:manna/utils/de_bouncer.dart';
import 'package:manna/utils/state_extension.dart';

class ShopSettingScreen extends StatefulWidget {
  const ShopSettingScreen({super.key});

  @override
  State<ShopSettingScreen> createState() => _ShopSettingScreenState();
}

class _ShopSettingScreenState extends State<ShopSettingScreen> {
  final shopNameController = TextEditingController(text: ShopService.shopName);
  final updateDebouncer = DeBouncer(const Duration(milliseconds: 500));

  @override
  void dispose() {
    shopNameController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Shop settings')),
      body: SingleChildScrollView(
        padding: const EdgeInsets.symmetric(vertical: 16),
        child: Column(
          spacing: 8,
          children: [
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16),
              child: TextFormField(
                controller: shopNameController,
                decoration: const InputDecoration(
                  labelText: 'Shop Name',
                  suffixIcon: Tooltip(
                    triggerMode: TooltipTriggerMode.tap,
                    showDuration: Duration(seconds: 3),
                    message: 'Included in lightning invoices',
                    child: Icon(Icons.info_outline, color: AppColors.accentColor),
                  ),
                ),
                inputFormatters: [FilteringTextInputFormatter.allow(Regexes.shopNameFilter)],
                maxLength: 40,
                buildCounter: (context, {required currentLength, required isFocused, required maxLength}) => null,
                onChanged: (value) => updateDebouncer.call(() => ShopService.shopName = value.trim()),
              ),
            ),
            SwitchListTile(
              title: const Text('Payer pays fee'),
              subtitle: const Text('You will receive full amount, but payer has to pay higher than bill amount'),
              value: AppState.payerPayShopFee,
              secondary: const Icon(Icons.toll),
              onChanged: (bool value) => update(() => AppState.payerPayShopFee = value),
            ),
            SwitchListTile(
              title: const Text('Enable Tips'),
              value: AppState.isShopTipsOn,
              secondary: const Icon(Icons.attach_money_outlined),
              onChanged: (bool value) => update(() => AppState.isShopTipsOn = value),
            ),
            SwitchListTile(
              title: const Text('Open shop on boot'),
              value: AppState.openShopOnBoot,
              onChanged: (value) => update(() => AppState.openShopOnBoot = value),
            ),
          ],
        ),
      ),
    );
  }
}
