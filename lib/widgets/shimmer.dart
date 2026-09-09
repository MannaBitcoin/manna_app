import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';

///
/// An enum defines all supported directions of shimmer effect
///
/// * [ShimmerDirection.ltr] left to right direction
/// * [ShimmerDirection.rtl] right to left direction
/// * [ShimmerDirection.ttb] top to bottom direction
/// * [ShimmerDirection.btt] bottom to top direction
/// * [ShimmerDirection.blttr] bottomLeft to topRight direction
/// * [ShimmerDirection.brttl] bottomRight to topLeft direction
/// * [ShimmerDirection.tltbr] topLeft to bottomRight direction
/// * [ShimmerDirection.trtbl] topRight to BottomLeft direction
///
enum ShimmerDirection { ltr, rtl, ttb, btt, blttr, brttl, tltbr, trtbl }

///
/// An enum defines all supported states of shimmer effect
///
/// * [ShimmerDirection.running] shimmer effect is presenting and animation is running
/// * [ShimmerDirection.paused] shimmer effect is presenting and animation is paused
/// * [ShimmerDirection.stopped] shimmer effect is presenting and animation is pausedExpand commentComment on line R28Resolved
///
enum ShimmerState { running, paused, stopped }

///
/// A widget renders shimmer effect over [child] widget tree.
///
/// [child] defines an area that shimmer effect blends on. You can build [child]
/// from whatever [Widget] you like but there're some notices in order to get
/// exact expected effect and get better rendering performance:
///
/// * Use static [Widget] (which is an instance of [StatelessWidget]).
/// * [Widget] should be a solid color element. Every colors you set on these
/// [Widget]s will be overridden by colors of [gradient].
/// * Shimmer effect only affects to opaque areas of [child], transparent areas
/// still stays transparent.
///
/// [period] controls the speed of shimmer effect. The default value is 1500
/// milliseconds.
///
/// [direction] controls the direction of shimmer effect. The default value
/// is [ShimmerDirection.ltr].
///
/// [gradient] controls colors of shimmer effect.
///
/// [loop] the number of animation loop, set value of `0` to make animation run
/// forever.
///
/// [shimmerState] controls if shimmer effect is active.
/// The default value is [ShimmerState.running].
///

class ShimmerWidget extends StatefulWidget {
  const ShimmerWidget({
    required this.child,
    required this.gradient,
    this.direction = ShimmerDirection.ltr,
    this.period = const Duration(milliseconds: 1500),
    this.loop = 0,
    this.curve = Curves.linear,
    this.shimmerState = ShimmerState.running,
    super.key,
  });

  ///
  /// A convenient constructor provides an easy and convenient way to create a
  /// [ShimmerWidget] which [gradient] is [LinearGradient] made up of `baseColor` and
  /// `highlightColor`.
  ///
  ShimmerWidget.fromColors({
    required this.child,
    required Color baseColor,
    required Color highlightColor,
    this.period = const Duration(milliseconds: 2000),
    this.direction = ShimmerDirection.ltr,
    this.loop = 0,
    this.curve = Curves.linear,
    this.shimmerState = ShimmerState.running,
    super.key,
  }) : gradient = LinearGradient(
         begin: Alignment.topLeft,
         colors: <Color>[baseColor, baseColor, highlightColor, baseColor, baseColor],
         stops: const <double>[0.0, 0.35, 0.5, 0.65, 1.0],
       );

  final Widget child;
  final Duration period;
  final ShimmerDirection direction;
  final ShimmerState shimmerState;
  final Gradient gradient;
  final int loop;
  final Curve curve;

  @override
  ShimmerWidgetState createState() => ShimmerWidgetState();

  @override
  void debugFillProperties(DiagnosticPropertiesBuilder properties) {
    super.debugFillProperties(properties);
    properties.add(DiagnosticsProperty<Gradient>('gradient', gradient, defaultValue: null));
    properties.add(EnumProperty<ShimmerDirection>('direction', direction));
    properties.add(DiagnosticsProperty<Duration>('period', period, defaultValue: null));
    properties.add(DiagnosticsProperty<ShimmerState>('shimmerState', shimmerState, defaultValue: null));
    properties.add(DiagnosticsProperty<int>('loop', loop, defaultValue: 0));
  }
}

class ShimmerWidgetState extends State<ShimmerWidget> with TickerProviderStateMixin {
  AnimationController? _controller;
  Animation<double>? _animation;
  int _count = 0;

  @override
  void initState() {
    super.initState();
    initController();
    switch (widget.shimmerState) {
      case ShimmerState.running:
        _controller?.forward();
        break;
      default:
        break;
    }
  }

  @override
  void didUpdateWidget(ShimmerWidget oldWidget) {
    if (oldWidget.period != widget.period) {
      initController();
    }
    switch (widget.shimmerState) {
      case ShimmerState.running:
        _controller?.forward();
      case ShimmerState.paused:
        _controller?.stop();
      case ShimmerState.stopped:
        _controller?.stop();
        _controller?.reset();
    }
    super.didUpdateWidget(oldWidget);
  }

  void initController() async {
    _controller?.dispose();

    _controller = null;
    _animation = null;

    _controller = AnimationController(vsync: this, duration: widget.period)
      ..addStatusListener((AnimationStatus status) {
        if (status != AnimationStatus.completed) {
          return;
        }
        _count++;
        if (widget.loop <= 0) {
          _controller?.repeat();
        } else if (_count < widget.loop) {
          _controller?.forward(from: 0.0);
        }
      });
    _animation = CurvedAnimation(parent: _controller!, curve: widget.curve);
  }

  @override
  Widget build(BuildContext context) {
    if (_animation != null) {
      return AnimatedBuilder(
        animation: _animation!,
        child: widget.child,
        builder: (context, child) =>
            _Shimmer(direction: widget.direction, gradient: widget.gradient, percent: _animation!.value, child: child),
      );
    }

    return const SizedBox.shrink();
  }

  @override
  void dispose() {
    _controller?.dispose();
    super.dispose();
  }
}

@immutable
class _Shimmer extends SingleChildRenderObjectWidget {
  const _Shimmer({required this.percent, required this.direction, required this.gradient, super.child});

  final double percent;
  final ShimmerDirection direction;
  final Gradient gradient;

  @override
  _ShimmerFilter createRenderObject(BuildContext context) => _ShimmerFilter(percent, direction, gradient);

  @override
  void updateRenderObject(BuildContext context, _ShimmerFilter shimmer) {
    shimmer.percent = percent;
    shimmer.gradient = gradient;
    shimmer.direction = direction;
  }
}

class _ShimmerFilter extends RenderProxyBox {
  _ShimmerFilter(this._percent, this._direction, this._gradient);

  Gradient _gradient;
  ShimmerDirection _direction;
  double _percent;

  @override
  bool get alwaysNeedsCompositing => child != null;

  set percent(double newValue) {
    if (newValue == _percent) {
      return;
    }
    _percent = newValue;
    markNeedsPaint();
  }

  set gradient(Gradient newValue) {
    if (newValue == _gradient) {
      return;
    }
    _gradient = newValue;
    markNeedsPaint();
  }

  set direction(ShimmerDirection newDirection) {
    if (newDirection == _direction) {
      return;
    }
    _direction = newDirection;
    markNeedsLayout();
  }

  @override
  ShaderMaskLayer? get layer => super.layer as ShaderMaskLayer?;

  @override
  void paint(PaintingContext context, Offset offset) {
    if (child == null) {
      layer = null;
      return;
    }
    assert(needsCompositing);

    final width = child!.size.width;
    final height = child!.size.height;
    Rect rect;
    double dx, dy;
    switch (_direction) {
      case ShimmerDirection.ltr:
        dx = _offset(-width, width, _percent);
        dy = 0.0;
        rect = Rect.fromLTWH(dx - width, dy, 3 * width, height);
      case ShimmerDirection.rtl:
        dx = _offset(width, -width, _percent);
        dy = 0.0;
        rect = Rect.fromLTWH(offset.dx - width, offset.dy, 3 * width, height);
      case ShimmerDirection.ttb:
        dx = 0.0;
        dy = _offset(-height, height, _percent);
        rect = Rect.fromLTWH(offset.dx, offset.dy - height, width, 3 * height);
      case ShimmerDirection.btt:
        dx = 0.0;
        dy = _offset(height, -height, _percent);
        rect = Rect.fromLTWH(offset.dx, offset.dy - height, width, 3 * height);
      case ShimmerDirection.blttr:
        dx = _offset(width, -width, _percent);
        dy = _offset(height, height, _percent);
        rect = Rect.fromLTWH(dx - width, dy - height, 3 * width, 3 * height);
      case ShimmerDirection.brttl:
        dx = _offset(width, -width, _percent);
        dy = _offset(height, -height, _percent);
        rect = Rect.fromLTWH(dx - width, dy - height, 4 * width, 6 * height);
      case ShimmerDirection.tltbr:
        dx = _offset(-width, width, _percent);
        dy = _offset(-height, height, _percent);
        rect = Rect.fromLTWH(dx - width, dy - height, 4 * width, 6 * height);
      case ShimmerDirection.trtbl:
        dx = _offset(width, -width, _percent);
        dy = _offset(-height, height, _percent);
        rect = Rect.fromLTWH(dx - width, dy, 3 * width, -2 * height);
    }

    layer ??= ShaderMaskLayer();
    layer!
      ..shader = _gradient.createShader(rect)
      ..maskRect = offset & size
      ..blendMode = BlendMode.srcIn;
    context.pushLayer(layer!, super.paint, offset);
  }

  double _offset(double start, double end, double percent) => start + (end - start) * percent;
}
