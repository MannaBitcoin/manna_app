import 'package:flutter/material.dart';
import 'package:manna/router.dart';
import 'package:manna/services/db.dart';
import 'package:manna/utils/state_extension.dart';
import 'package:manna/utils/util.dart';

class TransactionCategoriesBottomSheet extends StatefulWidget {
  const TransactionCategoriesBottomSheet({required this.selectedCategories, super.key});

  final Set<String> selectedCategories;

  @override
  State<TransactionCategoriesBottomSheet> createState() => _TransactionCategoriesBottomSheetState();
}

class _TransactionCategoriesBottomSheetState extends State<TransactionCategoriesBottomSheet> {
  Set<String> allCategories = {};
  Set<String> selectedCategories = {};
  final newCategoryController = TextEditingController();

  @override
  void initState() {
    selectedCategories = widget.selectedCategories;
    allCategories = DB.transactions.values
        .map((e) => e.categories)
        .fold(<String>{}, (prev, e) => {...prev, ...e})
        .toSet();
    super.initState();
  }

  @override
  void dispose() {
    newCategoryController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final cats = allCategories.difference(selectedCategories);
    return SingleChildScrollView(
      padding: const EdgeInsets.only(left: 16, right: 16, bottom: 16) + context.keyboardPadding,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        spacing: 16,
        children: [
          TextFormField(
            autofocus: isDesktop,
            controller: newCategoryController,
            onChanged: (value) => update(),
            decoration: InputDecoration(
              hintText: 'Add new',
              suffixIcon: newCategoryController.text.isEmpty
                  ? null
                  : IconButton(
                      tooltip: 'Add category',
                      onPressed: () {
                        update(() => selectedCategories.add(newCategoryController.text.trim()));
                        newCategoryController.clear();
                      },
                      icon: const Icon(Icons.add),
                    ),
            ),
          ),
          if (selectedCategories.isNotEmpty) ...[
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                for (final cat in selectedCategories)
                  Chip(
                    materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
                    label: Text(cat),
                    onDeleted: () => update(() => selectedCategories.remove(cat)),
                  ),
              ],
            ),
            const Divider(height: 0),
          ],
          if (allCategories.isEmpty)
            const Text('No categories yet!')
          else if (cats.isNotEmpty)
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                for (final cat in cats)
                  ChoiceChip(
                    materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
                    label: Text(cat),
                    selected: false,
                    onSelected: (value) => update(() => selectedCategories.add(cat)),
                  ),
              ],
            ),
          SizedBox(
            width: double.infinity,
            child: ElevatedButton(
              style: ElevatedButton.styleFrom(visualDensity: VisualDensity.standard),
              onPressed: () {
                final catName = newCategoryController.text.trim();
                if (catName.isNotEmpty) {
                  selectedCategories.add(catName);
                }
                AppRouter.pop(selectedCategories);
              },
              child: const Text('save'),
            ),
          ),
        ],
      ),
    );
  }
}
