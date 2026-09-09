import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:manna/app_state.dart';
import 'package:manna/models/misc.dart';
import 'package:manna/models/shop_item.dart';
import 'package:manna/router.dart';
import 'package:manna/screens/image_preview_screen.dart';
import 'package:manna/services/db.dart';
import 'package:manna/services/media_service.dart';
import 'package:manna/theme.dart';
import 'package:manna/utils/parser.dart';
import 'package:manna/utils/sats_extension.dart';
import 'package:manna/utils/state_extension.dart';
import 'package:manna/utils/toast_service.dart';
import 'package:manna/widgets/amount_text.dart';

class ShopItemBottomSheet extends StatefulWidget {
  const ShopItemBottomSheet({this.item, super.key});

  final ShopItem? item;

  @override
  State<ShopItemBottomSheet> createState() => _ShopItemBottomSheetState();
}

class _ShopItemBottomSheetState extends State<ShopItemBottomSheet> {
  final nameController = TextEditingController();
  final priceController = TextEditingController();
  final GlobalKey<FormState> formKey = GlobalKey<FormState>();

  File? imageFile;
  Uint8List? imageBytes;
  bool isPickingImage = false;

  bool isSatsSelected = false;
  double amount = 0.0;
  String catName = '';

  @override
  void initState() {
    if (widget.item != null) {
      imageBytes = widget.item?.imageBytes;
      nameController.text = widget.item!.name;
      amount = widget.item!.price;
      priceController.text = amount.toStringAsFixed(2);
      catName = widget.item!.category;
    }
    super.initState();
  }

  @override
  void dispose() {
    nameController.dispose();
    priceController.dispose();
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
          widget.item == null
              ? const SizedBox()
              : Container(
                  margin: const EdgeInsets.only(bottom: 12, right: 8),
                  alignment: Alignment.centerRight,
                  child: GestureDetector(onTap: () => AppRouter.pop(false), child: const Icon(Icons.close)),
                ),
          Row(
            children: [
              Expanded(
                child: Text(
                  widget.item == null ? 'Add New Item' : 'Edit Item',
                  style: const TextStyle(fontSize: 20, fontWeight: FontWeight.bold),
                ),
              ),
              const SizedBox(width: 16),
              GestureDetector(
                onTap: () async {
                  FocusManager.instance.primaryFocus?.unfocus();
                  update(() => isPickingImage = true);
                  final res = await MediaService.pickMedia(context: context, crop: true);
                  update(() => isPickingImage = false);
                  if (res != null) {
                    imageFile = res;
                  }
                  update();
                },
                onLongPress: (imageFile ?? imageBytes) == null
                    ? null
                    : () => AppRouter.push(
                        ImagePreviewScreen(appBarTitle: nameController.text.trim(), image: imageFile ?? imageBytes),
                      ),
                child: Stack(
                  clipBehavior: Clip.none,
                  alignment: Alignment.center,
                  children: [
                    Container(
                      height: 64,
                      width: 64,
                      clipBehavior: Clip.antiAlias,
                      decoration: BoxDecoration(
                        shape: BoxShape.circle,
                        color: AppColors.accentColor.withValues(alpha: 0.2),
                      ),
                      child: Builder(
                        builder: (context) {
                          final provider = getImageProvider(imageFile ?? imageBytes);
                          const fallback = Center(child: Icon(Icons.camera_alt_outlined));
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
                    ),
                    if (isPickingImage) const CircularProgressIndicator(),
                    Positioned(
                      right: -4,
                      bottom: -4,
                      child: GestureDetector(
                        onTap: imageFile != null || imageBytes != null
                            ? () => update(() => imageFile = imageBytes = null)
                            : null,
                        child: Container(
                          height: 32,
                          width: 32,
                          decoration: BoxDecoration(
                            color: Colors.white,
                            shape: BoxShape.circle,
                            border: Border.all(color: AppColors.accentColor, width: 1.5),
                          ),
                          child: Icon(
                            imageFile != null || imageBytes != null ? Icons.delete_forever_outlined : Icons.edit,
                            color: AppColors.accentColor,
                            size: 12,
                          ),
                        ),
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(width: 12),
            ],
          ),
          const SizedBox(height: 16),
          Form(
            key: formKey,
            autovalidateMode: AutovalidateMode.onUserInteraction,
            child: Column(
              children: [
                TextFormField(
                  controller: nameController,
                  decoration: const InputDecoration(labelText: 'Item Name', hintText: 'Item Name (example: Coffee)'),
                  maxLength: 50,
                  textCapitalization: TextCapitalization.words,
                  buildCounter: (context, {required currentLength, required isFocused, required maxLength}) => null,
                  validator: (value) {
                    if (value == null || value.isEmpty) {
                      return 'Please enter item name';
                    }
                    if (DB.shopItems.values.any((e) => e.name == value.trim() && e.id != widget.item?.id)) {
                      return 'Same item name already exists';
                    }
                    return null;
                  },
                ),
                const SizedBox(height: 12),
                TextFormField(
                  controller: priceController,
                  keyboardType: TextInputType.numberWithOptions(decimal: !isSatsSelected),
                  decoration: InputDecoration(
                    labelText:
                        'Price ${isSatsSelected ? getBitcoinDisplayStyle() : AppState.selectedCurrency.currencyCode}',
                    hintText: '0.00',
                    suffixIcon: DropdownButtonHideUnderline(
                      child: DropdownButton<bool>(
                        value: isSatsSelected,
                        items: [
                          DropdownMenuItem(value: true, child: Text(getBitcoinDisplayStyle())),
                          DropdownMenuItem(
                            value: false,
                            child: Row(children: [Text(AppState.selectedCurrency.currencyCode)]),
                          ),
                        ],
                        onChanged: (value) {
                          if (isSatsSelected != value && value != null) {
                            if (value) {
                              amount = double.tryParse(priceController.text.trim())?.fiatToSats().toDouble() ?? 0.0;
                            } else {
                              amount = amount.toInt().satsToFiat();
                            }
                            priceController.text = amount > 0
                                ? value
                                      ? amount.toStringAsFixed(0)
                                      : amount.formatFiat()
                                : '';
                            isSatsSelected = value;
                            update();
                          }
                        },
                      ),
                    ),
                  ),
                  validator: (value) {
                    if (parseDouble(value) <= 0) {
                      return 'Please enter item price';
                    }
                    return null;
                  },
                  inputFormatters: [FilteringTextInputFormatter.allow(RegExp(r'^\d{0,5}\.?\d{0,2}'))],
                  onChanged: (value) => amount = parseDouble(priceController.text),
                ),
                const SizedBox(height: 12),
                Autocomplete(
                  initialValue: widget.item?.category.isNotEmpty ?? false
                      ? TextEditingValue(text: widget.item!.category)
                      : null,
                  optionsBuilder: (text) {
                    catName = text.text.trim();
                    return DB.shopItems.values
                        .map((e) => e.category)
                        .where((e) => e.isNotEmpty && e.contains(catName))
                        .toSet();
                  },
                  optionsViewOpenDirection: OptionsViewOpenDirection.up,
                  onSelected: (option) => catName = option,
                  optionsViewBuilder: (context, onSelected, options) {
                    final ScrollController scrollController = ScrollController();

                    return ClipRRect(
                      borderRadius: BorderRadiusGeometry.circular(8),
                      child: Material(
                        elevation: 4.0,
                        child: ConstrainedBox(
                          constraints: const BoxConstraints(maxHeight: 200),
                          child: Scrollbar(
                            controller: scrollController,
                            thumbVisibility: true,
                            child: ListView.builder(
                              controller: scrollController,
                              padding: EdgeInsets.zero,
                              itemCount: options.length,
                              shrinkWrap: true,
                              itemBuilder: (BuildContext context, int index) {
                                final String option = options.elementAt(index);
                                return ListTile(title: Text(option), onTap: () => onSelected(option));
                              },
                            ),
                          ),
                        ),
                      ),
                    );
                  },
                  fieldViewBuilder: (context, controller, focusNode, onFieldSubmitted) {
                    return TextFormField(
                      focusNode: focusNode,
                      controller: controller,
                      keyboardType: TextInputType.name,
                      textCapitalization: TextCapitalization.sentences,
                      decoration: const InputDecoration(labelText: 'Category', hintText: 'Category (example: Drinks)'),
                      onFieldSubmitted: (value) => onFieldSubmitted(),
                    );
                  },
                ),
              ],
            ),
          ),
          const SizedBox(height: 16),
          Row(
            children: [
              Expanded(
                child: ElevatedButton(
                  onPressed: () async {
                    if (widget.item == null) {
                      AppRouter.pop(false);
                      return;
                    }
                    final data = await showDialog<bool>(
                      context: context,
                      builder: (context) => AlertDialog(
                        title: Text(
                          'Are you sure you want to delete ${widget.item?.name}?',
                          style: const TextStyle(fontSize: 16),
                        ),
                        actions: [
                          TextButton(onPressed: () => AppRouter.pop(false), child: const Text('No')),
                          TextButton(
                            onPressed: () async {
                              await widget.item!.delete();
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
                    foregroundColor: widget.item == null ? AppColors.accentColor : Colors.red,
                    visualDensity: VisualDensity.standard,
                  ),
                  child: Text(widget.item == null ? 'Cancel' : 'Delete'),
                ),
              ),
              const SizedBox(width: 16),
              Expanded(
                child: ElevatedButton(
                  onPressed: () async {
                    if (formKey.currentState?.validate() ?? false) {
                      if (widget.item != null) {
                        await widget.item!.update(
                          name: nameController.text.trim(),
                          category: catName,
                          price: isSatsSelected ? amount.ceil().satsToFiat() : amount,
                          imageBytes: Nullable(imageFile != null ? await imageFile!.readAsBytes() : imageBytes),
                        );
                      } else {
                        await ShopItem(
                          id: DateTime.now().millisecondsSinceEpoch % 4294967295,
                          name: nameController.text.trim(),
                          category: catName,
                          price: isSatsSelected ? amount.ceil().satsToFiat() : amount,
                          imageBytes: imageFile != null ? await imageFile!.readAsBytes() : null,
                        ).save();
                      }
                      AppRouter.pop(true);
                    }
                  },
                  style: ElevatedButton.styleFrom(visualDensity: VisualDensity.standard),
                  child: Text(widget.item == null ? 'Add Item' : 'Update Item', textAlign: TextAlign.center),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

class CategoryBottomSheet extends StatefulWidget {
  const CategoryBottomSheet({required this.categoryName, super.key});

  final String categoryName;

  @override
  State<CategoryBottomSheet> createState() => _CategoryBottomSheetState();
}

class _CategoryBottomSheetState extends State<CategoryBottomSheet> {
  late final categoryNameController = TextEditingController(text: widget.categoryName);
  late Uint8List? categoryImage = DB.categoryImages[widget.categoryName];
  File? imageFile;
  bool isPickingImage = false;

  @override
  void dispose() {
    categoryNameController.dispose();
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
          Container(
            margin: const EdgeInsets.only(right: 8),
            alignment: Alignment.centerRight,
            child: GestureDetector(onTap: () => AppRouter.pop(false), child: const Icon(Icons.close)),
          ),
          const SizedBox(height: 16),
          Row(
            children: [
              const Expanded(
                child: Text('Update Category', style: TextStyle(fontSize: 20, fontWeight: FontWeight.bold)),
              ),
              const SizedBox(width: 16),
              GestureDetector(
                onTap: () async {
                  FocusManager.instance.primaryFocus?.unfocus();
                  if (imageFile != null || categoryImage != null) {
                    imageFile = categoryImage = null;
                    await DB.categoryImages.box.delete(widget.categoryName);
                    for (final tax in DB.taxes.values) {
                      if (tax.categories.contains(widget.categoryName)) {
                        await tax.update(categories: tax.categories..remove(widget.categoryName));
                      }
                    }
                  } else {
                    update(() => isPickingImage = true);
                    final res = await MediaService.pickMedia(context: context, crop: true);
                    update(() => isPickingImage = false);
                    if (res != null) {
                      imageFile = res;
                    }
                  }
                  update();
                },
                onLongPress: (imageFile ?? categoryImage) == null
                    ? null
                    : () => AppRouter.push(
                        ImagePreviewScreen(
                          appBarTitle: categoryNameController.text.trim(),
                          image: imageFile ?? categoryImage,
                        ),
                      ),
                child: Stack(
                  clipBehavior: Clip.none,
                  alignment: Alignment.center,
                  children: [
                    Container(
                      height: 64,
                      width: 64,
                      clipBehavior: Clip.antiAlias,
                      decoration: BoxDecoration(
                        shape: BoxShape.circle,
                        color: AppColors.accentColor.withValues(alpha: 0.2),
                      ),
                      child: Builder(
                        builder: (context) {
                          final provider = getImageProvider(imageFile ?? categoryImage);
                          const fallback = Center(child: Icon(Icons.camera_alt_outlined));
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
                    ),
                    if (isPickingImage) const CircularProgressIndicator(),
                    Positioned(
                      right: -4,
                      bottom: -4,
                      child: Container(
                        height: 32,
                        width: 32,
                        decoration: BoxDecoration(
                          color: Colors.white,
                          shape: BoxShape.circle,
                          border: Border.all(color: AppColors.accentColor, width: 1.5),
                        ),
                        child: Icon(
                          imageFile != null || categoryImage != null ? Icons.delete_forever_outlined : Icons.edit,
                          color: AppColors.accentColor,
                          size: 12,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(width: 12),
            ],
          ),
          const SizedBox(height: 16),
          TextFormField(
            controller: categoryNameController,
            decoration: const InputDecoration(labelText: 'Category', hintText: 'Category (example: Drinks)'),
            textCapitalization: TextCapitalization.words,
            validator: (value) {
              if (value == null || value.isEmpty) {
                return 'Please enter category name';
              }
              return null;
            },
          ),
          const SizedBox(height: 16),
          Row(
            children: [
              Expanded(
                child: ElevatedButton(
                  onPressed: () async {
                    final data = await showDialog<bool>(
                      context: context,
                      builder: (context) => AlertDialog(
                        title: Text(
                          'Are you sure you want to delete ${widget.categoryName}?',
                          style: const TextStyle(fontSize: 16),
                        ),
                        actions: [
                          TextButton(onPressed: () => AppRouter.pop(false), child: const Text('No')),
                          TextButton(
                            onPressed: () async {
                              await Future.wait(
                                DB.shopItems.values
                                    .where((e) => e.category == widget.categoryName)
                                    .map((i) => i.update(category: '')),
                              );
                              ToastService.show('Category deleted!');
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
                    foregroundColor: Colors.red,
                    visualDensity: VisualDensity.standard,
                  ),
                  child: const Text('Delete'),
                ),
              ),
              const SizedBox(width: 16),
              Expanded(
                child: ElevatedButton(
                  onPressed: categoryNameController.text.trim().isEmpty
                      ? null
                      : () async {
                          final catName = categoryNameController.text.trim();
                          await Future.wait(
                            DB.shopItems.values
                                .where((e) => e.category == widget.categoryName)
                                .map((i) => i.update(category: catName)),
                          );

                          await DB.categoryImages.box.delete(widget.categoryName);
                          if (imageFile != null) {
                            await DB.categoryImages.box.put(catName, imageFile!.readAsBytesSync());
                          }
                          ToastService.show('Category updated!');
                          AppRouter.pop(true);
                        },
                  style: ElevatedButton.styleFrom(visualDensity: VisualDensity.standard),
                  child: const Text('Update Category', textAlign: TextAlign.center),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}
