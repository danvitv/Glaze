import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/rendering.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter/widgets.dart';

import 'baked_blur.dart';

/// Bakes the app background, already blurred, and lets glass surfaces that sit
/// *directly over it* sample the region under themselves instead of each
/// running a `BackdropFilter`.
///
/// Why this exists, precisely: Flutter's backdrop grouping (`backdropId`) does
/// collapse several filters into one blur — Impeller keeps a
/// `shared_filter_snapshot` and every member after the first only draws a rect
/// of it — but that shared snapshot is rendered over the *whole* backdrop, with
/// no coverage hint (there is an upstream TODO for it). So grouping trades N
/// small blurs for one screen-sized one; it removes the per-surface render
/// passes, not the blur. This removes the blur as well, for the one case where
/// the backdrop is known ahead of time.
///
/// That case is a surface whose backdrop is only the static app background:
/// the background is pinned to the screen and content scrolls over it, so a
/// card at any scroll offset just reads a different part of the same texture.
/// Surfaces over *moving* content — a header over a list, the nav bar — must
/// keep a real [BackdropFilter]; there is nothing to pre-bake for them.
///
/// The precondition is the whole risk here: if anything is painted between the
/// background and the surface, the sample shows the background instead of what
/// is actually there, and it does so silently. [GlassSurface] closes the scope
/// around its own children so glass inside glass can never sample, and
/// [CardBackdrop.closed] is the manual escape hatch for anything else that
/// paints its own surface under content.
class CardBackdrop extends StatefulWidget {
  final ImageProvider image;

  /// Blur sigma in logical pixels, as the sampling surfaces would have used.
  /// When the background image is itself blurred, this must be the *combined*
  /// sigma — see [CardBackdrop.combineSigma].
  final double sigma;

  /// Flat black wash the background paints over the image, baked in so a
  /// sample carries it instead of covering it up.
  final double dim;

  final Widget child;

  const CardBackdrop({
    super.key,
    required this.image,
    required this.sigma,
    required this.dim,
    required this.child,
  });

  /// Two Gaussians in a row are one Gaussian: blurring by `a` and then by `b`
  /// is exactly blurring by `sqrt(a² + b²)`. The backdrop under a card is the
  /// background image blurred by the preset's `bgBlur` and then by the card's
  /// own `elementBlur`, so this is the sigma the bake has to use — baking at
  /// `elementBlur` alone leaves the card visibly sharper than its neighbours
  /// whenever `bgBlur` is on.
  static double combineSigma(double a, double b) =>
      a <= 0 ? b : (b <= 0 ? a : math.sqrt(a * a + b * b));

  /// The baked backdrop for the nearest [CardBackdrop], or null when there is
  /// none — no background image, not baked yet, or an enclosing scope was
  /// closed.
  static CardBackdropData? of(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<_CardBackdropScope>()?.data;

  /// Closes any enclosing [CardBackdrop] for [child]: surfaces inside go back
  /// to their own [BackdropFilter]. Use it in anything that paints a surface of
  /// its own between the app background and its content — a sheet's fill, a
  /// floating window, a scrim.
  static Widget closed({Key? key, required Widget child}) =>
      _CardBackdropScope(key: key, data: null, child: child);

  @override
  State<CardBackdrop> createState() => _CardBackdropState();
}

/// The baked texture plus the scale it was baked at.
@immutable
class CardBackdropData {
  final ui.Image image;

  /// Baked texels per logical pixel. Well below the device pixel ratio — a
  /// blur carries no detail finer than its own kernel.
  final double scale;

  const CardBackdropData(this.image, this.scale);
}

class _CardBackdropState extends State<CardBackdrop> {
  ImageStream? _stream;
  ImageStreamListener? _listener;

  /// Owned clone of the decoded source, so an eviction from Flutter's image
  /// cache cannot dispose the pixels out from under a bake.
  ui.Image? _source;

  /// Owned clone of the cached bake currently on offer.
  ui.Image? _baked;
  BakedBlurKey? _bakedKey;
  BakedBlurKey? _scheduledKey;

  Size _size = Size.zero;
  double _devicePixelRatio = 1.0;

  bool get _enabled => widget.sigma > 0;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _resolveSource();
  }

  @override
  void didUpdateWidget(covariant CardBackdrop oldWidget) {
    super.didUpdateWidget(oldWidget);
    // Sigma matters here as well as the image: a surface that started with no
    // blur never resolved a source, so switching the blur on would otherwise
    // have nothing to bake.
    if (widget.image != oldWidget.image || widget.sigma != oldWidget.sigma) {
      _resolveSource();
    }
  }

  @override
  void dispose() {
    _detachStream();
    _source?.dispose();
    _baked?.dispose();
    super.dispose();
  }

  void _detachStream() {
    final listener = _listener;
    if (listener != null) _stream?.removeListener(listener);
    _stream = null;
    _listener = null;
  }

  void _resolveSource() {
    if (!_enabled) {
      _detachStream();
      return;
    }
    final stream = widget.image.resolve(createLocalImageConfiguration(context));
    if (stream.key == _stream?.key) return;
    _detachStream();
    final listener = ImageStreamListener(_onSourceReady, onError: _onError);
    _listener = listener;
    _stream = stream..addListener(listener);
  }

  void _onSourceReady(ImageInfo info, bool synchronousCall) {
    final image = info.image.clone();
    info.dispose();
    if (!mounted) {
      image.dispose();
      return;
    }
    _source?.dispose();
    _source = image;
    _bakeIfNeeded();
  }

  void _onError(Object error, StackTrace? stack) {
    // Nothing to recover: with no bake the surfaces keep their own blur, which
    // is the pre-existing behaviour.
    FlutterError.reportError(
      FlutterErrorDetails(
        exception: error,
        stack: stack,
        library: 'glaze',
        context: ErrorDescription('resolving the card backdrop image'),
        silent: true,
      ),
    );
  }

  /// Safe to call from `build`: the work is deferred to a post-frame callback,
  /// and repeated calls for the same key collapse into one.
  void _bakeIfNeeded() {
    if (!_enabled || _source == null || _size.isEmpty || !_size.isFinite) {
      return;
    }
    final key = BakedBlurKey(
      provider: widget.image,
      sigma: widget.sigma,
      dim: widget.dim,
      size: _size,
      devicePixelRatio: _devicePixelRatio,
    );
    if (key == _bakedKey || key == _scheduledKey) return;
    _scheduledKey = key;
    SchedulerBinding.instance.addPostFrameCallback((_) {
      if (!mounted || _scheduledKey != key) return;
      _scheduledKey = null;
      final source = _source;
      if (source == null) return;
      final baked = BakedBlurCache.obtain(key, source);
      if (!mounted) {
        baked.dispose();
        return;
      }
      setState(() {
        _baked?.dispose();
        _baked = baked;
        _bakedKey = key;
      });
    });
    // Nothing else schedules a frame: the decode that gets us here finishes
    // outside the frame loop, and on a still screen no other frame may come.
    SchedulerBinding.instance.scheduleFrame();
  }

  @override
  Widget build(BuildContext context) {
    _devicePixelRatio = MediaQuery.devicePixelRatioOf(context);
    return LayoutBuilder(
      builder: (context, constraints) {
        _size = constraints.biggest;
        _bakeIfNeeded();
        final baked = _baked;
        final key = _bakedKey;
        return _CardBackdropScope(
          data: baked == null || key == null
              ? null
              : CardBackdropData(baked, key.scale),
          child: widget.child,
        );
      },
    );
  }
}

class _CardBackdropScope extends InheritedWidget {
  final CardBackdropData? data;

  const _CardBackdropScope({
    super.key,
    required this.data,
    required super.child,
  });

  @override
  bool updateShouldNotify(covariant _CardBackdropScope oldWidget) =>
      oldWidget.data?.image != data?.image ||
      oldWidget.data?.scale != data?.scale;
}

/// Paints the region of a [CardBackdrop] texture that lies under this box, then
/// its child. Drop-in replacement for a `BackdropFilter` on a surface whose
/// backdrop is only the static app background: the texture is already blurred,
/// so this is a texture lookup rather than a blur pass.
class CardBackdropSample extends SingleChildRenderObjectWidget {
  final CardBackdropData data;

  const CardBackdropSample({
    super.key,
    required this.data,
    required Widget child,
  }) : super(child: child);

  @override
  RenderObject createRenderObject(BuildContext context) =>
      RenderCardBackdropSample(data);

  @override
  void updateRenderObject(
    BuildContext context,
    covariant RenderCardBackdropSample renderObject,
  ) {
    renderObject.data = data;
  }
}

class RenderCardBackdropSample extends RenderProxyBox {
  RenderCardBackdropSample(this._data);

  CardBackdropData _data;
  set data(CardBackdropData value) {
    if (identical(value, _data)) return;
    _data = value;
    _shader = null;
    markNeedsPaint();
  }

  ui.ImageShader? _shader;
  Float64List? _shaderMatrix;

  /// The matrix the last shader was built for. Test-only hook: it is what
  /// decides whether the texture stays pinned to the screen.
  @visibleForTesting
  Float64List? get debugShaderMatrix => _shaderMatrix;

  @override
  void paint(PaintingContext context, Offset offset) {
    if (size.isEmpty) {
      super.paint(context, offset);
      return;
    }
    // Pin the texture to the *screen*, not to this box. A real BackdropFilter
    // reads pixels that are already on screen, so a card under any transform —
    // the Android overscroll stretch (a plain scale Transform in this app), a
    // route slide, the desktop floating window — shows an untransformed
    // backdrop through a transformed card. Sampling an axis-aligned crop with
    // `localToGlobal` would instead drag the backdrop along with the card.
    final inverse = Matrix4.tryInvert(getTransformTo(null));
    if (inverse == null) {
      // Degenerate transform (a zero-scale transition); nothing sensible to
      // sample, and the surface's own fill still paints below.
      super.paint(context, offset);
      return;
    }
    // texel -> screen logical -> this box's local -> canvas
    final matrix = Matrix4.translationValues(offset.dx, offset.dy, 0)
      ..multiply(inverse)
      ..multiply(Matrix4.diagonal3Values(1 / _data.scale, 1 / _data.scale, 1));
    final storage = matrix.storage;
    if (_shader == null || !_sameMatrix(storage)) {
      _shader?.dispose();
      _shaderMatrix = Float64List.fromList(storage);
      _shader = ui.ImageShader(
        _data.image,
        TileMode.clamp,
        TileMode.clamp,
        storage,
        filterQuality: FilterQuality.medium,
      );
    }
    context.canvas.drawRect(offset & size, Paint()..shader = _shader);
    super.paint(context, offset);
  }

  bool _sameMatrix(Float64List storage) {
    final previous = _shaderMatrix;
    if (previous == null) return false;
    for (var i = 0; i < storage.length; i++) {
      if (previous[i] != storage[i]) return false;
    }
    return true;
  }

  @override
  void dispose() {
    _shader?.dispose();
    _shader = null;
    super.dispose();
  }
}
