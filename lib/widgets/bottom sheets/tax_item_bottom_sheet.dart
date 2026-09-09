import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:manna/models/tax.dart';
import 'package:manna/router.dart';
import 'package:manna/services/db.dart';
import 'package:manna/theme.dart';
import 'package:manna/utils/parser.dart';
import 'package:manna/utils/state_extension.dart';

class TaxItemBottomSheet extends StatefulWidget {
  const TaxItemBottomSheet({this.texItem, super.key});

  final Tax? texItem;

  @override
  State<TaxItemBottomSheet> createState() => _TaxItemBottomSheetState();
}

class _TaxItemBottomSheetState extends State<TaxItemBottomSheet> {
  late final nameController = TextEditingController(text: widget.texItem?.name);
  late final taxController = TextEditingController(text: widget.texItem?.tax.toStringAsFixed(2));
  late final Set<String> categories = widget.texItem?.categories ?? {};
  final GlobalKey<FormState> formKey = GlobalKey();

  @override
  void dispose() {
    nameController.dispose();
    taxController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return SingleChildScrollView(
      padding: const EdgeInsets.only(left: 16.0, right: 16.0, bottom: 16) + context.keyboardPadding,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: .start,
        children: [
          widget.texItem == null
              ? const SizedBox()
              : Container(
                  margin: const EdgeInsets.only(bottom: 12, right: 8),
                  alignment: Alignment.centerRight,
                  child: GestureDetector(onTap: () => AppRouter.pop(false), child: const Icon(Icons.close)),
                ),
          Text(
            widget.texItem == null ? 'Add New Tax' : 'Edit Tax',
            style: const TextStyle(fontSize: 20, fontWeight: FontWeight.bold),
          ),
          const SizedBox(height: 16),
          Form(
            key: formKey,
            autovalidateMode: AutovalidateMode.onUserInteraction,
            child: Theme(
              data: Theme.of(context).copyWith(listTileTheme: const ListTileThemeData(horizontalTitleGap: 0)),
              child: Column(
                crossAxisAlignment: .start,
                children: [
                  TextFormField(
                    controller: nameController,
                    decoration: const InputDecoration(labelText: 'Tax Name', hintText: 'Tax Name (example: Sales Tax)'),
                    maxLength: 50,
                    textCapitalization: TextCapitalization.sentences,
                    buildCounter: (context, {required currentLength, required isFocused, required maxLength}) => null,
                    validator: (value) {
                      if (value == null || value.isEmpty) {
                        return 'Please enter tax name';
                      }
                      if (DB.taxes.values.any((e) => e.name == value.trim() && e.id != widget.texItem?.id)) {
                        return 'Same tax name already exists';
                      }
                      return null;
                    },
                  ),
                  const SizedBox(height: 12),
                  TextFormField(
                    controller: taxController,
                    keyboardType: const TextInputType.numberWithOptions(decimal: true),
                    decoration: const InputDecoration(
                      labelText: 'Tax Percentage',
                      hintText: '0.00 (Tax percentage)',
                      suffixIcon: Icon(Icons.percent),
                    ),
                    validator: (value) {
                      final tax = parseDouble(value);
                      if (tax <= 0 || tax > 200) {
                        return 'Please enter valid tax percentage';
                      }
                      return null;
                    },
                    inputFormatters: [FilteringTextInputFormatter.allow(RegExp(r'^\d{0,3}\.?\d{0,3}'))],
                  ),
                  const SizedBox(height: 12),
                  ExpansionTile(
                    title: const Text('Apply to', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 18)),
                    subtitle: Text(
                      categories.isEmpty ? 'All Categories' : categories.join(', '),
                      style: const TextStyle(fontSize: 15),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                    tilePadding: const EdgeInsets.symmetric(horizontal: 8),
                    dense: true,
                    shape: InputBorder.none,
                    children: [
                      CheckboxListTile(
                        value: categories.isEmpty,
                        onChanged: (val) => update(() => categories.clear()),
                        title: const Text('All Categories'),
                        controlAffinity: ListTileControlAffinity.leading,
                        contentPadding: EdgeInsets.zero,
                        dense: true,
                        horizontalTitleGap: 8,
                      ),
                      for (final cat in DB.shopItems.values.map((e) => e.category).where((e) => e.isNotEmpty).toSet())
                        CheckboxListTile(
                          value: categories.contains(cat),
                          onChanged: (val) =>
                              update(() => categories.contains(cat) ? categories.remove(cat) : categories.add(cat)),
                          title: Text(cat),
                          controlAffinity: ListTileControlAffinity.leading,
                          contentPadding: EdgeInsets.zero,
                          dense: true,
                          horizontalTitleGap: 8,
                        ),
                    ],
                  ),
                ],
              ),
            ),
          ),
          const SizedBox(height: 16),
          Row(
            children: [
              Expanded(
                child: ElevatedButton(
                  onPressed: () async {
                    if (widget.texItem == null) {
                      AppRouter.pop(false);
                      return;
                    }
                    final data = await showDialog<bool>(
                      context: context,
                      builder: (context) => AlertDialog(
                        title: Text('Are you sure you want to delete Tax ${widget.texItem?.name}?'),
                        actions: [
                          TextButton(onPressed: () => AppRouter.pop(false), child: const Text('No')),
                          TextButton(
                            onPressed: () async {
                              await widget.texItem!.delete();
                              AppRouter.pop(true);
                            },
                            child: const Text('Yes'),
                          ),
                        ],
                      ),
                    );
                    if (data ?? false) AppRouter.pop(data);
                  },
                  style: ElevatedButton.styleFrom(
                    backgroundColor: Colors.white,
                    foregroundColor: widget.texItem == null ? AppColors.accentColor : Colors.red,
                    visualDensity: VisualDensity.standard,
                  ),
                  child: Text(widget.texItem == null ? 'Cancel' : 'Delete'),
                ),
              ),
              const SizedBox(width: 16),
              Expanded(
                child: ElevatedButton(
                  style: ElevatedButton.styleFrom(visualDensity: VisualDensity.standard),
                  onPressed: () async {
                    if (formKey.currentState?.validate() ?? false) {
                      final tax = parseDoubleN(taxController.text.trim()) ?? 0.0;
                      if (widget.texItem != null) {
                        await widget.texItem!.update(
                          name: nameController.text.trim(),
                          categories: categories,
                          tax: tax,
                        );
                      } else {
                        await Tax(
                          id: DateTime.now().millisecondsSinceEpoch % 4294967295,
                          name: nameController.text.trim(),
                          categories: categories,
                          tax: tax,
                        ).save();
                      }
                      AppRouter.pop(true);
                    }
                  },
                  child: Text(widget.texItem == null ? 'Add Tax' : 'Update Tax', textAlign: TextAlign.center),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}
