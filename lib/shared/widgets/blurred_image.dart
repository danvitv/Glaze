import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/scheduler.dart';
import 'package:flutter/widgets.dart';

import '../../core/debug/perf_debug.dart';

/// Full-bleed background image (`BoxFit.cover`) painted through a Gaussian
/// blur — with the blur **baked once** instead of re-run on every frame.
///
/// The obvious spelling, `ImageFiltered(imageFilter: blur, child: Image(...))`,
/// is a per-frame cost: an image filter layer is re-applied on every composite,
/// and under Impeller there is no raster cache to fall back on, so a
/// screen-sized sigma-30 blur is recomputed on the raster thread for every
/// frame of every scroll. On the app background — which is a still image that
/// only changes when the theme preset does — that is pure waste.
///
/// [BlurredImage] instead renders the covered image into an offscreen once,
/// blurs it there, and keeps the result as a `ui.Image` that later frames draw
/// 1:1. The offscreen is built exactly the way the widget layer would have
/// been (same `BoxFit.cover` geometry, same `saveLayer` bounds, same
/// [ui.TileMode.clamp] at the edges, sigma scaled into device pixels), so the
/// pixels are the ones [ImageFiltered] would have produced.
///
/// Baked images are shared app-wide by (provider, sigma, pixel size), so the
/// per-screen [GlazeBackground] copies all draw the same texture, and a screen
/// that is pushed and popped does not re-blur.
class BlurredImage extends StatefulWidget {
  /// Source image. Must implement value equality (all of Flutter's built-in
  /// providers do) — it is part of the bake cache key.
  final ImageProvider image;

  /// Blur sigma in logical pixels, matching [ui.ImageFilter.blur]. At zero (or
  /// with `NO_BG_BLUR` set) the image is drawn straight, with no offscreen.
  final double sigma;

  const BlurredImage({super.key, required this.image, required this.sigma});

  /// Number of baked images currently held by the app-wide cache. Test-only.
  @visibleForTesting
  static int get debugCacheSize => _BakeCache.size;

  /// Bakes performed since the last [debugResetBakeCount]. Test-only hook
  /// asserting that a steady-state repaint does not re-blur.
  @visibleForTesting
  static int get debugBakeCount => _BakeCache.bakeCount;

  @visibleForTesting
  static void debugResetBakeCount() => _BakeCache.bakeCount = 0;

  @visibleForTesting
  static void debugClearCache() => _BakeCache.clear();

  @override
  State<BlurredImage> createState() => _BlurredImageState();
}

class _BlurredImageState extends State<BlurredImage> {
  ImageStream? _stream;
  ImageStreamListener? _listener;

  /// Owned clone of the decoded source. Cloned so that an eviction from
  /// Flutter's image cache cannot dispose the pixels out from under a bake.
  ui.Image? _source;

  /// Owned clone of the cached bake currently being painted.
  ui.Image? _baked;
  _BakeKey? _bakedKey;

  /// Key the pending post-frame bake was scheduled for, so a resize storm
  /// queues one bake rather than one per frame.
  _BakeKey? _scheduledKey;

  Size _size = Size.zero;
  double _devicePixelRatio = 1.0;

  bool get _blurred => widget.sigma > 0 && !PerfDebug.noBgBlur;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _resolveSource();
  }

  @override
  void didUpdateWidget(covariant BlurredImage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.image != oldWidget.image) _resolveSource();
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
    if (!_blurred) {
      // The plain [Image] below resolves the provider itself.
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
    // An undecodable background is not worth a crash — the base colour and the
    // dim overlay behind this widget still render a usable screen.
    FlutterError.reportError(
      FlutterErrorDetails(
        exception: error,
        stack: stack,
        library: 'glaze',
        context: ErrorDescription('resolving a blurred background image'),
        silent: true,
      ),
    );
  }

  /// Bakes now if the current geometry has no cached result yet. Safe to call
  /// from `build`: the actual work is deferred to a post-frame callback, and
  /// repeated calls for the same key collapse into one.
  void _bakeIfNeeded() {
    if (!_blurred || _source == null || _size.isEmpty || !_size.isFinite) {
      return;
    }
    final key = _BakeKey.forGeometry(
      provider: widget.image,
      sigma: widget.sigma,
      size: _size,
      devicePixelRatio: _devicePixelRatio,
    );
    if (key == _bakedKey || key == _scheduledKey) return;
    _scheduledKey = key;
    SchedulerBinding.instance.addPostFrameCallback((_) {
      if (!mounted || _scheduledKey != key) return;
      _scheduledKey = null;
      _bakeNow(key);
    });
    // A post-frame callback runs at the end of the *next* frame, and nothing
    // here schedules one: the decode that gets us here finishes outside the
    // frame loop, and on a still screen no other frame may be coming. Ask for
    // one explicitly so the bake cannot sit and wait for unrelated work.
    SchedulerBinding.instance.scheduleFrame();
  }

  void _bakeNow(_BakeKey key) {
    final source = _source;
    if (source == null) return;
    final baked = _BakeCache.obtain(key, source);
    if (!mounted) {
      baked.dispose();
      return;
    }
    setState(() {
      _baked?.dispose();
      _baked = baked;
      _bakedKey = key;
    });
  }

  @override
  Widget build(BuildContext context) {
    if (!_blurred) {
      return Image(image: widget.image, fit: BoxFit.cover, gaplessPlayback: true);
    }
    _devicePixelRatio = MediaQuery.devicePixelRatioOf(context);
    return LayoutBuilder(
      builder: (context, constraints) {
        _size = constraints.biggest;
        _bakeIfNeeded();
        final baked = _baked;
        // Nothing baked yet (cold start, or a preset switch mid-bake): draw
        // nothing rather than the sharp image, which would pop into focus for
        // a frame. The base colour behind this widget covers the gap, exactly
        // as it does while the image is still decoding today.
        if (baked == null) return const SizedBox.expand();
        return CustomPaint(
          painter: _BakedImagePainter(baked),
          size: Size.infinite,
        );
      },
    );
  }
}

class _BakedImagePainter extends CustomPainter {
  final ui.Image image;

  const _BakedImagePainter(this.image);

  @override
  void paint(Canvas canvas, Size size) {
    if (size.isEmpty) return;
    // Normally an exact 1:1 device-pixel blit. `cover` only does real work in
    // the frames between a resize and the bake that follows it, where it keeps
    // the previous bake filling the screen instead of letterboxing it.
    paintImage(
      canvas: canvas,
      rect: Offset.zero & size,
      image: image,
      fit: BoxFit.cover,
      filterQuality: FilterQuality.high,
    );
  }

  @override
  bool shouldRepaint(covariant _BakedImagePainter old) => old.image != image;
}

/// Identity of one baked result: everything that changes its pixels.
@immutable
class _BakeKey {
  final ImageProvider provider;
  final double sigma;
  final int width;
  final int height;

  /// Scale from logical to baked pixels. Normally the device pixel ratio, but
  /// lowered for very large surfaces (see [_kMaxBakePixels]).
  final double scale;

  const _BakeKey({
    required this.provider,
    required this.sigma,
    required this.width,
    required this.height,
    required this.scale,
  });

  /// A 4K bake is already 32 MB of texture; beyond that the blur is baked at a
  /// reduced scale and drawn back up. At these sigmas the upscale is invisible
  /// — the image carries no detail finer than the blur kernel anyway.
  static const int _kMaxBakePixels = 1 << 23;

  factory _BakeKey.forGeometry({
    required ImageProvider provider,
    required double sigma,
    required Size size,
    required double devicePixelRatio,
  }) {
    final logicalPixels = size.width * size.height;
    final maxScale = math.sqrt(_kMaxBakePixels / logicalPixels);
    final scale = devicePixelRatio < maxScale ? devicePixelRatio : maxScale;
    return _BakeKey(
      provider: provider,
      sigma: sigma,
      width: (size.width * scale).round().clamp(1, 1 << 15),
      height: (size.height * scale).round().clamp(1, 1 << 15),
      scale: scale,
    );
  }

  @override
  bool operator ==(Object other) =>
      other is _BakeKey &&
      other.provider == provider &&
      other.sigma == sigma &&
      other.width == width &&
      other.height == height;

  @override
  int get hashCode => Object.hash(provider, sigma, width, height);
}

/// App-wide store of baked blurs.
///
/// Keyed by geometry, so every [BlurredImage] showing the same preset
/// background at the same size shares one texture: the app background is
/// rebuilt per screen, and without sharing each push would re-blur it.
abstract final class _BakeCache {
  /// One live background plus the one it is replacing (a theme switch, a
  /// rotation) is all that is ever needed at once.
  static const int _maxEntries = 2;

  static final Map<_BakeKey, ui.Image> _entries = {};

  static int bakeCount = 0;

  static int get size => _entries.length;

  static void clear() {
    for (final image in _entries.values) {
      image.dispose();
    }
    _entries.clear();
  }

  /// Returns an owned clone of the bake for [key], creating it from [source]
  /// when it is not cached yet. Callers dispose what they get back; the cache
  /// keeps its own handle, so an eviction never pulls pixels out from under a
  /// widget that is still painting them.
  static ui.Image obtain(_BakeKey key, ui.Image source) {
    final cached = _entries.remove(key);
    if (cached != null) {
      _entries[key] = cached; // refresh LRU order
      return cached.clone();
    }
    final baked = _bake(key, source);
    bakeCount++;
    _entries[key] = baked;
    while (_entries.length > _maxEntries) {
      final oldest = _entries.keys.first;
      _entries.remove(oldest)!.dispose();
    }
    return baked.clone();
  }

  static ui.Image _bake(_BakeKey key, ui.Image source) {
    final bounds = Rect.fromLTWH(0, 0, key.width.toDouble(), key.height.toDouble());
    final logical = Rect.fromLTWH(
      0,
      0,
      key.width / key.scale,
      key.height / key.scale,
    );
    final recorder = ui.PictureRecorder();
    final canvas = Canvas(recorder, bounds);
    // Draw in logical units under a device-pixel-ratio scale, exactly as the
    // widget layer would have been rasterised: the image is resampled at the
    // same net scale and the blur sigma stays in the same units the engine
    // would have applied it in. Matching the transform rather than
    // pre-multiplying by hand is what keeps the two paths interchangeable.
    canvas.scale(key.scale);
    // `saveLayer` + an image filter is what [ImageFiltered] compiles down to:
    // the child is rendered into a layer whose bounds are its paint bounds,
    // then the filter is applied with the edges clamped.
    canvas.saveLayer(
      logical,
      Paint()
        ..imageFilter = ui.ImageFilter.blur(
          sigmaX: key.sigma,
          sigmaY: key.sigma,
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
    // Sync so the texture stays on the GPU: this is drawn again every frame,
    // and a readback would trade the per-frame blur for a per-frame upload.
    final image = picture.toImageSync(key.width, key.height);
    picture.dispose();
    return image;
  }
}
