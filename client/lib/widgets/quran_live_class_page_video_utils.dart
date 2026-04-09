part of '../quran_live_class_page.dart';

extension _QuranLiveClassPageVideoUtils on _QuranLiveClassPageState {
  double _resolveVideoHeight(double width, double aspectRatio) {
    const minHeight = 220.0;
    const maxHeight = 640.0;

    final naturalHeight = width / aspectRatio;
    if (naturalHeight < minHeight) return minHeight;
    if (naturalHeight > maxHeight) return maxHeight;
    return naturalHeight;
  }

  double _clampAspectRatio(double ratio) {
    const minRatio = 9 / 16;
    const maxRatio = 16 / 9;
    if (ratio < minRatio) return minRatio;
    if (ratio > maxRatio) return maxRatio;
    return ratio;
  }

  String _videoMetaLabel(
    RTCVideoRenderer renderer, {
    required int quarterTurns,
    required bool preferPortraitFallback,
  }) {
    final width = renderer.videoWidth;
    final height = renderer.videoHeight;

    if (width <= 0 || height <= 0) {
      return 'Waiting for video frames';
    }

    final displayAspectRatio = _resolveDisplayAspectRatio(
      renderer: renderer,
      quarterTurns: quarterTurns,
      preferPortraitFallback: preferPortraitFallback,
    );
    final orientation = displayAspectRatio < 1 ? 'Portrait' : 'Landscape';

    return '$width x $height - $orientation';
  }

  double _resolveBaseAspectRatio(
    RTCVideoRenderer renderer, {
    required bool preferPortraitFallback,
  }) {
    final width = renderer.videoWidth.toDouble();
    final height = renderer.videoHeight.toDouble();

    if (width > 0 && height > 0) {
      final ratio = width / height;
      if (ratio.isFinite && ratio > 0) {
        return ratio;
      }
    }

    return preferPortraitFallback ? (9 / 16) : (16 / 9);
  }

  double _resolveDisplayAspectRatio({
    required RTCVideoRenderer renderer,
    required int quarterTurns,
    required bool preferPortraitFallback,
  }) {
    final baseRatio = _resolveBaseAspectRatio(
      renderer,
      preferPortraitFallback: preferPortraitFallback,
    );

    if (quarterTurns.isOdd) {
      return 1 / baseRatio;
    }

    return baseRatio;
  }

  int _resolveQuarterTurns(
    RTCVideoRenderer renderer, {
    required bool isLocal,
    required bool preferPortraitFallback,
  }) {
    final normalizedRotation =
        _normalizeRotationDegrees(renderer.value.rotation);
    if (normalizedRotation % 90 == 0 && normalizedRotation != 0) {
      final turnsFromMetadata = (normalizedRotation / 90).round();

      if (isLocal) {
        return _normalizeQuarterTurns(turnsFromMetadata);
      }

      return _normalizeQuarterTurns(-turnsFromMetadata);
    }

    final baseRatio = _resolveBaseAspectRatio(
      renderer,
      preferPortraitFallback: preferPortraitFallback,
    );
    return baseRatio > 1 ? 1 : 0;
  }

  int _normalizeRotationDegrees(int value) {
    final normalized = value % 360;
    return normalized < 0 ? normalized + 360 : normalized;
  }

  int _normalizeQuarterTurns(int value) {
    final normalized = value % 4;
    return normalized < 0 ? normalized + 4 : normalized;
  }
}
