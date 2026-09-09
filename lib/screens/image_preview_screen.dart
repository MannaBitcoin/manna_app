import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:manna/services/log_service.dart';
import 'package:photo_view/photo_view.dart';

class ImagePreviewScreen extends StatelessWidget {
  const ImagePreviewScreen({required this.appBarTitle, required this.image, super.key});

  final String appBarTitle;

  /// any of file, url or uint8list, base64 or asset string
  final dynamic image;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: Text(appBarTitle), centerTitle: false),
      body: Builder(
        builder: (context) {
          final provider = getImageProvider(image);
          if (provider != null) {
            return PhotoView(imageProvider: provider, filterQuality: FilterQuality.high);
          }

          return const Text('Invalid image data');
        },
      ),
    );
  }
}

/// [image] should be any of file, uint8list, url, base64 or asset string
ImageProvider? getImageProvider(dynamic image) {
  if (image == null) return null;
  if (image is File) {
    return FileImage(image);
  }
  if (image is Uint8List) {
    return MemoryImage(image);
  }
  if (image is String) {
    try {
      if (image.startsWith('http')) {
        return CachedNetworkImageProvider(image, errorListener: (value) => logD(value));
      } else if (image.startsWith('assets')) {
        return AssetImage(image);
      } else {
        return MemoryImage(base64Decode(image));
      }
    } catch (_) {}
  }
  return null;
}

Widget imageLoadingBuilder(BuildContext context, Widget child, ImageChunkEvent? loadingProgress) {
  if (loadingProgress == null) return child;
  final progress = loadingProgress.expectedTotalBytes != null
      ? loadingProgress.cumulativeBytesLoaded / loadingProgress.expectedTotalBytes!
      : null;
  return Center(child: CircularProgressIndicator(value: (progress ?? 0) < 10 ? null : progress));
}
