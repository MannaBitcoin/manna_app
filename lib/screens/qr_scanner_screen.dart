import 'dart:async';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';
import 'package:manna/router.dart';
import 'package:manna/services/audio_service.dart';
import 'package:manna/services/media_service.dart';
import 'package:manna/utils/de_bouncer.dart';
import 'package:manna/utils/state_extension.dart';
import 'package:manna/utils/toast_service.dart';
import 'package:mobile_scanner/mobile_scanner.dart';

class QRScannerScreen extends StatefulWidget {
  const QRScannerScreen({required this.validateQr, super.key});

  /// passes qr data return true if the qr is valid, returning true will pop the screen with qr data
  final Future<bool> Function(String qrData) validateQr;

  @override
  State<QRScannerScreen> createState() => _QRScannerScreenState();
}

class _QRScannerScreenState extends State<QRScannerScreen> with SingleTickerProviderStateMixin {
  final scannerController = MobileScannerController(
    autoZoom: defaultTargetPlatform == TargetPlatform.android,
    formats: [BarcodeFormat.qrCode],
  );
  final zoomLevels = [0.0, 0.5, 0.8, 1.0];
  double zoomLevel = 0.0;
  bool isTorchOn = false;

  @override
  void dispose() {
    scannerController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      body: Stack(
        alignment: Alignment.center,
        children: [
          MobileScanner(controller: scannerController, fit: BoxFit.contain, onDetect: (capture) => processQr(capture)),
          ValueListenableBuilder(
            valueListenable: scannerController,
            builder: (context, value, child) {
              // Not ready.
              if (!value.isInitialized || value.error != null) {
                return const SizedBox();
              }

              return StreamBuilder<BarcodeCapture>(
                stream: scannerController.barcodes,
                builder: (context, snapshot) {
                  return AnimatedBarcodeOverlay(
                    controller: scannerController,
                    boxFit: BoxFit.contain,
                    animationDuration: const Duration(milliseconds: 200),
                    defaultSize: 200,
                    strokeWidth: 4,
                    borderColor: Colors.white,
                    overlayColor: Colors.black54,
                  );
                },
              );
            },
          ),
          Align(
            alignment: Alignment.bottomCenter,
            child: Padding(
              padding: const EdgeInsets.symmetric(vertical: 24, horizontal: 16),
              child: Row(
                mainAxisAlignment: .spaceEvenly,
                children: [
                  IconButton(
                    onPressed: () async {
                      final image = await MediaService.pickImage(source: ImageSource.gallery);
                      if (image != null) {
                        final result = await scannerController.analyzeImage(
                          image.path,
                          formats: [BarcodeFormat.qrCode],
                        );

                        if (result != null) {
                          await processQr(result);
                        } else {
                          ToastService.show('No Qr found in image!');
                        }
                      }
                    },
                    icon: const Icon(Icons.photo, color: Colors.white),
                    iconSize: 32,
                  ),
                  IconButton(
                    onPressed: () {
                      isTorchOn = !isTorchOn;
                      scannerController.toggleTorch();
                      update();
                    },
                    icon: Icon(isTorchOn ? Icons.flash_on : Icons.flash_off, color: Colors.white),
                    iconSize: 32,
                  ),
                  IconButton(
                    onPressed: () {
                      zoomLevel = zoomLevels.elementAt((zoomLevels.indexOf(zoomLevel) + 1) % zoomLevels.length);
                      scannerController.setZoomScale(zoomLevel);
                    },
                    icon: zoomLevel == 0
                        ? const Icon(Icons.zoom_in, color: Colors.white)
                        : Text(switch (zoomLevel) {
                            0.5 => '2x',
                            0.8 => '3x',
                            _ => '4x',
                          }, style: const TextStyle(fontSize: 20, color: Colors.white, fontWeight: FontWeight.bold)),
                    iconSize: 32,
                  ),
                ],
              ),
            ),
          ),
          Positioned(
            top: 52,
            left: 22,
            child: IconButton(
              onPressed: () => AppRouter.pop(),
              icon: const Icon(Icons.close, color: Colors.white),
              iconSize: 30,
            ),
          ),
        ],
      ),
    );
  }

  MutexRun processQrMutex = MutexRun();
  Future<void> processQr(BarcodeCapture barcodeCapture) => processQrMutex.run(() async {
    if (barcodeCapture.barcodes.isEmpty) return;

    final qrData = barcodeCapture.barcodes.firstOrNull?.rawValue;
    if (qrData != null) {
      if (await widget.validateQr(qrData)) {
        await hapticFeedback();
        await scannerController.pause();
        Future.delayed(const Duration(milliseconds: 300), () => AppRouter.pop(qrData));
      }
    }
  });
}

class AnimatedBarcodeOverlay extends StatefulWidget {
  const AnimatedBarcodeOverlay({
    required this.controller,
    required this.boxFit,
    required this.animationDuration,
    required this.defaultSize,
    required this.strokeWidth,
    required this.borderColor,
    required this.overlayColor,
    super.key,
  });

  final MobileScannerController controller;
  final BoxFit boxFit;
  final Duration animationDuration;
  final double defaultSize;
  final double strokeWidth;
  final Color borderColor;
  final Color overlayColor;

  @override
  State<AnimatedBarcodeOverlay> createState() => _AnimatedBarcodeOverlayState();
}

class _AnimatedBarcodeOverlayState extends State<AnimatedBarcodeOverlay> with TickerProviderStateMixin {
  List<Offset>? _targetCorners;
  List<Offset>? _previousCorners;
  late final StreamSubscription<BarcodeCapture> _barcodeSubscription;
  late final AnimationController _animationController = AnimationController(
    vsync: this,
    duration: widget.animationDuration,
  );
  late final Animation<double> _animation = CurvedAnimation(parent: _animationController, curve: Curves.easeInOut);

  final DeBouncer debouncer = DeBouncer(const Duration(seconds: 1));

  @override
  void initState() {
    super.initState();
    _barcodeSubscription = widget.controller.barcodes.listen((capture) {
      if (!mounted || capture.barcodes.isEmpty) return;

      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) return;
        final box = context.findRenderObject() as RenderBox?;
        if (box == null || !box.hasSize) return;

        final size = box.size;
        final newCorners = _computeTargetCorners(capture, size);
        if (newCorners != null) {
          update(() {
            _previousCorners = _targetCorners ?? _defaultCorners(size);
            _targetCorners = newCorners;
            _animationController.reset();
            _animationController.forward();
          });

          debouncer.call(() {
            if (mounted) {
              update(() {
                _previousCorners = _targetCorners;
                _targetCorners = null;
                _animationController.reset();
                _animationController.forward();
              });
            }
          });
        }
      });
    });
  }

  @override
  void dispose() {
    _barcodeSubscription.cancel();
    _animationController.dispose();
    super.dispose();
  }

  List<Offset>? _computeTargetCorners(BarcodeCapture capture, Size size) {
    final previewSize = capture.size;
    final corners = capture.barcodes.first.corners;
    if (corners.length != 4) return null;

    final ratios = ScanWindowUtils.calculateBoxFitRatio(
      boxFit: widget.boxFit,
      cameraPreviewSize: previewSize,
      size: size,
    );

    final dx = (previewSize.width * ratios.widthRatio - size.width) / 2;
    final dy = (previewSize.height * ratios.heightRatio - size.height) / 2;

    return corners.map((pt) => Offset(pt.dx * ratios.widthRatio - dx, pt.dy * ratios.heightRatio - dy)).toList();
  }

  List<Offset> _defaultCorners(Size size) {
    final halfSize = widget.defaultSize / 2;
    final centerX = size.width / 2;
    final centerY = size.height / 2;
    return [
      Offset(centerX - halfSize, centerY - halfSize),
      Offset(centerX + halfSize, centerY - halfSize),
      Offset(centerX + halfSize, centerY + halfSize),
      Offset(centerX - halfSize, centerY + halfSize),
    ];
  }

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (ctx, constraints) {
        final size = Size(constraints.maxWidth, constraints.maxHeight);
        return AnimatedBuilder(
          animation: _animation,
          builder: (ctx, child) {
            final target = _targetCorners ?? _defaultCorners(size);
            final previous = _previousCorners ?? _defaultCorners(size);
            final value = _animation.value;
            final corners = List.generate(4, (i) => Offset.lerp(previous[i], target[i], value)!);

            return Stack(
              children: [
                Positioned.fill(
                  child: CustomPaint(
                    painter: _MaskPainter(corners: corners, color: widget.overlayColor),
                  ),
                ),
                Positioned.fill(
                  child: CustomPaint(
                    painter: _BorderPainter(
                      corners: corners,
                      color: widget.borderColor,
                      strokeWidth: widget.strokeWidth,
                    ),
                  ),
                ),
              ],
            );
          },
        );
      },
    );
  }
}

class _MaskPainter extends CustomPainter {
  _MaskPainter({required this.corners, required this.color});
  final List<Offset> corners;
  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    if (corners.length != 4) return;

    final overlay = Path()..addRect(Rect.fromLTWH(0, 0, size.width, size.height));
    final cutout = Path()
      ..moveTo(corners[0].dx, corners[0].dy)
      ..lineTo(corners[1].dx, corners[1].dy)
      ..lineTo(corners[2].dx, corners[2].dy)
      ..lineTo(corners[3].dx, corners[3].dy)
      ..close();
    final path = Path.combine(PathOperation.difference, overlay, cutout);
    canvas.drawPath(
      path,
      Paint()
        ..color = color
        ..style = PaintingStyle.fill,
    );
  }

  @override
  bool shouldRepaint(covariant _MaskPainter old) => old.corners != corners || old.color != color;
}

class _BorderPainter extends CustomPainter {
  _BorderPainter({required this.corners, required this.color, required this.strokeWidth});

  final List<Offset> corners;
  final Color color;
  final double strokeWidth;

  @override
  void paint(Canvas canvas, Size size) {
    if (corners.length != 4) return;

    final paint = Paint()
      ..color = color
      ..strokeWidth = strokeWidth
      ..style = PaintingStyle.stroke;

    final path = Path()
      ..moveTo(corners[0].dx, corners[0].dy)
      ..lineTo(corners[1].dx, corners[1].dy)
      ..lineTo(corners[2].dx, corners[2].dy)
      ..lineTo(corners[3].dx, corners[3].dy)
      ..close();

    canvas.drawPath(path, paint);
  }

  @override
  bool shouldRepaint(covariant _BorderPainter old) =>
      old.corners != corners || old.color != color || old.strokeWidth != strokeWidth;
}
