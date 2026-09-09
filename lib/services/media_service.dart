import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui';

import 'package:croppy/croppy.dart';
import 'package:flutter/material.dart';
import 'package:flutter_image_compress/flutter_image_compress.dart';
import 'package:image_picker/image_picker.dart';
import 'package:manna/router.dart';
import 'package:manna/services/db.dart';
import 'package:manna/utils/state_extension.dart';
import 'package:manna/utils/util.dart';
import 'package:path_provider/path_provider.dart';

class MediaService {
  static final _picker = ImagePicker();

  static Future<File?> pickMedia({
    required BuildContext context,
    bool crop = false,
    CropAspectRatio? aspectRatio = const CropAspectRatio(width: 1, height: 1),
  }) async {
    final selectedItem = await showModalBottomSheet<int>(
      context: context,
      showDragHandle: true,
      isScrollControlled: true,
      useSafeArea: true,
      shape: const RoundedRectangleBorder(borderRadius: BorderRadius.vertical(top: Radius.circular(24))),
      builder: (context) {
        return Column(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            const SizedBox(height: 8),
            if (DB.shopItems.values.any((e) => e.imageBytes != null) || DB.categoryImages.isNotEmpty)
              ListTile(
                leading: const Icon(Icons.upload_file_outlined),
                title: const Text('Uploads'),
                onTap: () => AppRouter.pop(0),
              ),
            ListTile(
              leading: const Icon(Icons.photo_library),
              title: const Text('Gallery'),
              onTap: () => AppRouter.pop(1),
            ),
            if (!isDesktop)
              ListTile(
                leading: const Icon(Icons.photo_camera),
                title: const Text('Camera'),
                onTap: () => AppRouter.pop(2),
              ),
            const SizedBox(height: 8),
          ],
        );
      },
    );
    if (selectedItem == null) return null;

    switch (selectedItem) {
      case 0:
        if (context.mounted) {
          final Uint8List? res = await showModalBottomSheet(
            context: context,
            showDragHandle: true,
            isScrollControlled: true,
            useSafeArea: true,
            shape: const RoundedRectangleBorder(borderRadius: BorderRadius.vertical(top: Radius.circular(24))),
            routeSettings: const RouteSettings(name: 'UploadsBottomSheet'),
            builder: (context) => const UploadsBottomSheet(),
          );
          if (res != null) {
            final appDir = await getApplicationSupportDirectory();
            final file = File('${appDir.path}/${DateTime.now().millisecondsSinceEpoch}.png');
            await file.writeAsBytes(res, flush: true);
            return file;
          }
        }
      case 1:
        return pickImage(source: ImageSource.gallery, crop: crop, aspectRatio: aspectRatio);
      case 2:
        return pickImage(source: ImageSource.camera, crop: crop, aspectRatio: aspectRatio);
    }

    return null;
  }

  static Future<File?> pickImage({required ImageSource source, bool crop = false, CropAspectRatio? aspectRatio}) async {
    try {
      final image = await _picker.pickImage(source: source);
      if (image != null) {
        if (crop) {
          final res = await cropImage(
            path: image.path,
            aspectRatio: aspectRatio
          );
          if (res != null) {
            return res;
          }
        }
        return File(image.path);
      }
    } catch (_) {}
    return null;
  }

  static Future<List<XFile>?> pickMultiImage({int limit = 10}) async {
    final List<XFile> images = await _picker.pickMultiImage(limit: limit);
    return images;
  }

  static Future<File?> cropImage({String path = '', CropAspectRatio? aspectRatio}) async {
    CropImageResult? cropResult;
    final imageProvider = FileImage(File(path));
    final image = await obtainImage(imageProvider);
    final imageSize = Size(image.width.toDouble(), image.height.toDouble());

    final minSideLength = math.min(imageSize.width, imageSize.height);
    final isWidthShortest = minSideLength == imageSize.width;

    final initialData = CroppableImageData(
      imageSize: imageSize,
      cropShape: CropShape.aabb(Aabb2.minMax(Vector2.zero(), Vector2(imageSize.width, imageSize.height))),
      cropRect: Rect.fromLTWH(
        isWidthShortest ? 0 : (imageSize.width - minSideLength) / 2,
        isWidthShortest ? (imageSize.height - minSideLength) / 2 : 0,
        imageSize.width,
        imageSize.height,
      ),
      imageTransform: Matrix4.identity(),
      currentImageTransform: Matrix4.identity(),
      baseTransformations: BaseTransformations.initial(imageSize),
    );

    if (AppRouter.navigatorContext.mounted) {
      if (isApple) {
        cropResult = await showCupertinoImageCropper(
          AppRouter.navigatorContext,
          imageProvider: imageProvider,
          initialData: initialData,
          allowedAspectRatios: aspectRatio != null ? [aspectRatio] : null,
        );
      } else {
        cropResult = await showMaterialImageCropper(
          AppRouter.navigatorContext,
          imageProvider: imageProvider,
          initialData: initialData,
          allowedAspectRatios: aspectRatio != null ? [aspectRatio] : null,
        );
      }
    }

    if (cropResult != null) {
      final image = cropResult.uiImage;
      final bytes = await image.toByteData(format: ImageByteFormat.png);

      final temp = await getTemporaryDirectory();
      final file = File('${temp.path}/${DateTime.now().millisecondsSinceEpoch}.png');

      if (bytes != null) {
        final cropped = bytes.buffer.asUint8List();
        final compressed = await compress(cropped);
        await file.writeAsBytes(compressed.isNotEmpty ? compressed : cropped, flush: true);
      }
      image.dispose();

      // clear the flutter image cache, cause we use same file name for cropped images.
      await FileImage(file).evict();
      return file;
    }
    return null;
  }

  static Future<Uint8List> compress(Uint8List image) => FlutterImageCompress.compressWithList(image, quality: 60);
}

class UploadsBottomSheet extends StatelessWidget {
  const UploadsBottomSheet({super.key});

  @override
  Widget build(BuildContext context) {
    final itemImages = DB.shopItems.values.where((e) => e.imageBytes != null).toList();
    final catImages = DB.categoryImages.values.nonNulls.toList();

    return SingleChildScrollView(
      padding: const EdgeInsets.all(16) + context.keyboardPadding,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: .start,
        children: [
          if (itemImages.isNotEmpty) ...[
            const Text('Items', style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold)),
            const Divider(),
            GridView.builder(
              shrinkWrap: true,
              gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
                crossAxisCount: (context.screenWidth / 100).floor(),
                mainAxisSpacing: 8,
                crossAxisSpacing: 8,
              ),
              itemCount: itemImages.length,
              itemBuilder: (context, index) {
                return InkWell(
                  onTap: () => AppRouter.pop(itemImages[index].imageBytes),
                  child: ClipRRect(
                    borderRadius: BorderRadius.circular(12),
                    child: Image.memory(itemImages[index].imageBytes!, fit: BoxFit.cover),
                  ),
                );
              },
            ),
          ],
          if (catImages.isNotEmpty) ...[
            const Text('Categories', style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold)),
            const Divider(),
            GridView.builder(
              shrinkWrap: true,
              gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
                crossAxisCount: (context.screenWidth / 100).floor(),
                mainAxisSpacing: 8,
                crossAxisSpacing: 8,
              ),
              itemCount: catImages.length,
              itemBuilder: (context, index) {
                final bytes = catImages[index];
                return InkWell(
                  onTap: () => AppRouter.pop(bytes),
                  child: ClipRRect(
                    borderRadius: BorderRadius.circular(12),
                    child: Image.memory(bytes, fit: BoxFit.cover),
                  ),
                );
              },
            ),
          ],
        ],
      ),
    );
  }
}
