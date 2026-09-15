import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/scheduler.dart';

/// Bakes the app background image, blurred once, and lets glass surfaces that
/// sit *over the background* sample the region under themselves instead of each
/// running its own `BackdropFilter`.
///
/// Why this exists: Flutter's `BackdropFilter` grouping (`backdropId`) only
/// caches the *unfiltered* backdrop — every filter still runs its own blur
/// (see `dart:ui` `pushBackdropFilter`). With a screen full of large glass cards
/// that is many blur passes per frame. This bakes one blurred texture and turns
/// those passes into texture lookups.
///
/// Only valid where the backdrop under the surface is the static app background
/// (the background does not scroll; the content scrolls over it). Surfaces over
/// moving content must keep a real [BackdropFilter].
class CardBackdrop extends StatefulWidget {
  final ImageProvider image;
  final double sigma;
  final Widget child;

  const CardBackdrop({
    super.key,
    required this.image,
    required this.sigma,
    required this.child,
  });

  /// The baked backdrop for the nearest [CardBackdrop], or null when there is
  /// none (no image background, or not baked yet).
  static CardBackdropData? of(BuildContext context) => context
      .dependOnInheritedWidgetOfExactType<_CardBackdropScope>()
      ?.data;

  @override
  State<CardBackdrop> createState() => _CardBackdropState();
}

class CardBackdropData {
  final ui.Image image;

  /// Scale from logical to baked pixels.
  final double devicePixelRatio;

  const CardBackdropData(this.image, this.devicePixelRatio);
}

class _CardBackdropState extends State<CardBackdrop> {
  ImageStream? _stream;
  ImageStreamListener? _listener;
  ui.Image? _source;
  ui.Image? _baked;

  Size _size = Size.zero;
  double _dpr = 1.0;
  bool _bakeScheduled = false;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _resolve();
  }

  @override
  void didUpdateWidget(covariant CardBackdrop oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.image != oldWidget.image || widget.sigma != oldWidget.sigma) {
      _invalidateBake();
      _resolve();
    }
  }

  @override
  void dispose() {
    _detach();
    _source?.dispose();
    _baked?.dispose();
    super.dispose();
  }

  void _detach() {
    final listener = _listener;
    if (listener != null) _stream?.removeListener(listener);
    _stream = null;
    _listener = null;
  }

  void _invalidateBake() {
    _baked?.dispose();
    _baked = null;
  }

  void _resolve() {
    if (widget.sigma <= 0) return;
    final stream = widget.image.resolve(createLocalImageConfiguration(context));
    if (stream.key == _stream?.key) return;
    _detach();
    final listener = ImageStreamListener(
      (info, _) {
        final image = info.image.clone();
        info.dispose();
        if (!mounted) {
          image.dispose();
          return;
        }
        _source?.dispose();
        _source = image;
        _scheduleBake();
      },
      onError: (_, _) {},
    );
    _listener = listener;
    _stream = stream..addListener(listener);
  }

  void _scheduleBake() {
    if (_bakeScheduled) return;
    _bakeScheduled = true;
    SchedulerBinding.instance.addPostFrameCallback((_) {
      _bakeScheduled = false;
      if (mounted) _bake();
    });
    SchedulerBinding.instance.scheduleFrame();
  }

  void _bake() {
    final source = _source;
    if (source == null || _size.isEmpty || !_size.isFinite) return;
    if (widget.sigma <= 0) return;
    final width = (_size.width * _dpr).round().clamp(1, 1 << 15);
    final height = (_size.height * _dpr).round().clamp(1, 1 << 15);
    final bounds = Rect.fromLTWH(0, 0, width.toDouble(), height.toDouble());
    final logical = Rect.fromLTWH(0, 0, _size.width, _size.height);

    final recorder = ui.PictureRecorder();
    final canvas = Canvas(recorder, bounds);
    canvas.scale(_dpr);
    canvas.saveLayer(
      logical,
      Paint()
        ..imageFilter = ui.ImageFilter.blur(
          sigmaX: widget.sigma,
          sigmaY: widget.sigma,
          tileMode: TileMode.clamp,
        ),
    );
    paintImage(
      canvas: canvas,
      rect: logical,
      image: source,
      fit: BoxFit.cover,
      filterQuality: FilterQuality.medium,
    );
    canvas.restore();
    final picture = recorder.endRecording();
    final baked = picture.toImageSync(width, height);
    picture.dispose();

    if (!mounted) {
      baked.dispose();
      return;
    }
    setState(() {
      _baked?.dispose();
      _baked = baked;
    });
  }

  @override
  Widget build(BuildContext context) {
    final dpr = MediaQuery.devicePixelRatioOf(context);
    return LayoutBuilder(
      builder: (context, constraints) {
        final size = constraints.biggest;
        if (size != _size || dpr != _dpr) {
          _size = size;
          _dpr = dpr;
          _invalidateBake();
          if (_source != null) _scheduleBake();
        }
        final baked = _baked;
        return _CardBackdropScope(
          data: baked == null ? null : CardBackdropData(baked, _dpr),
          child: widget.child,
        );
      },
    );
  }
}

class _CardBackdropScope extends InheritedWidget {
  final CardBackdropData? data;

  const _CardBackdropScope({required this.data, required super.child});

  @override
  bool updateShouldNotify(covariant _CardBackdropScope oldWidget) =>
      oldWidget.data?.image != data?.image;
}

/// Paints the region of a [CardBackdrop] texture under this box, then its child.
///
/// Drop-in replacement for a `BackdropFilter` on a surface that only has the
/// static app background behind it: the texture is already blurred, so this is
/// a texture lookup, not a blur pass.
class CardBackdropSample extends SingleChildRenderObjectWidget {
  final CardBackdropData data;

  const CardBackdropSample({super.key, required this.data, required Widget child})
    : super(child: child);

  @override
  RenderObject createRenderObject(BuildContext context) =>
      _RenderCardBackdropSample(data);

  @override
  void updateRenderObject(BuildContext context, RenderObject renderObject) {
    (renderObject as _RenderCardBackdropSample).data = data;
  }
}

class _RenderCardBackdropSample extends RenderProxyBox {
  _RenderCardBackdropSample(this._data);

  CardBackdropData _data;
  set data(CardBackdropData value) {
    if (!identical(value, _data)) {
      _data = value;
      markNeedsPaint();
    }
  }

  @override
  void paint(PaintingContext context, Offset offset) {
    if (size.isEmpty) {
      super.paint(context, offset);
      return;
    }
    // Include scroll: sliver paint transforms carry the scroll offset, so the
    // global rect of this box is what the background was blurred against.
    final global = localToGlobal(Offset.zero);
    final dpr = _data.devicePixelRatio;
    final src = Rect.fromLTWH(
      global.dx * dpr,
      global.dy * dpr,
      size.width * dpr,
      size.height * dpr,
    );
    context.canvas.drawImageRect(
      _data.image,
      src,
      offset & size,
      Paint()
        ..filterQuality = FilterQuality.medium
        ..isAntiAlias = true,
    );
    super.paint(context, offset);
  }
}
