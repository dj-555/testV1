import 'package:flutter/material.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart';
import 'package:quran_live_class_client/features/live_class/presentation/widgets/glass_card.dart';

class LiveClassStreamsLayout extends StatelessWidget {
  static const int _globalQuarterTurnOffset = 2;

  final String selectedRole;
  final bool isConnected;
  final String? currentPeerId;
  final String? activeStudentId;
  final String activeStudentName;
  final RTCVideoRenderer localRenderer;
  final RTCVideoRenderer teacherRenderer;
  final RTCVideoRenderer activeStudentRenderer;
  final bool studentPipSwapped;
  final bool teacherPipSwapped;
  final VoidCallback onToggleStudentPipSwap;
  final VoidCallback onToggleTeacherPipSwap;

  const LiveClassStreamsLayout({
    super.key,
    required this.selectedRole,
    required this.isConnected,
    required this.currentPeerId,
    required this.activeStudentId,
    required this.activeStudentName,
    required this.localRenderer,
    required this.teacherRenderer,
    required this.activeStudentRenderer,
    required this.studentPipSwapped,
    required this.teacherPipSwapped,
    required this.onToggleStudentPipSwap,
    required this.onToggleTeacherPipSwap,
  });

  @override
  Widget build(BuildContext context) {
    if (selectedRole == 'student' && isConnected) {
      return _buildStudentPictureInPictureLayout();
    }
    if (selectedRole == 'teacher' && isConnected) {
      return _buildTeacherPictureInPictureLayout();
    }

    final streams = _buildStreamSpecs();

    return Column(
      children: streams
          .map(
            (stream) => Padding(
              padding: const EdgeInsets.only(bottom: 12),
              child: _buildVideoCard(
                context,
                title: stream.title,
                renderer: stream.renderer,
                isLocal: stream.isLocal,
                preferContain: stream.preferContain,
                preferPortraitFallback: stream.preferPortraitFallback,
              ),
            ),
          )
          .toList(),
    );
  }

  Widget _buildStudentPictureInPictureLayout() {
    final isMyTurn =
        activeStudentId != null && activeStudentId == currentPeerId;

    final teacherStream = _StreamCardSpec(
      title: 'Teacher',
      renderer: teacherRenderer,
      preferContain: true,
      preferPortraitFallback: true,
    );

    final secondStream = isMyTurn
        ? _StreamCardSpec(
            title: 'You (Live)',
            renderer: localRenderer,
            isLocal: true,
            preferContain: true,
            preferPortraitFallback: true,
          )
        : _StreamCardSpec(
            title: activeStudentId == null
                ? 'No active student'
                : 'Turn: $activeStudentName',
            renderer: activeStudentRenderer,
            preferContain: true,
            preferPortraitFallback: true,
          );

    var mainStream = teacherStream;
    var insetStream = secondStream;
    var mainEmptyLabel = 'Teacher stream unavailable';
    var insetEmptyLabel =
        isMyTurn ? 'Your camera is off' : 'Student stream unavailable';

    if (studentPipSwapped) {
      mainStream = secondStream;
      insetStream = teacherStream;
      mainEmptyLabel = insetEmptyLabel;
      insetEmptyLabel = 'Teacher stream unavailable';
    }

    return GlassCard(
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: _buildPictureInPictureStage(
          mainStream: mainStream,
          insetStream: insetStream,
          mainEmptyLabel: mainEmptyLabel,
          insetEmptyLabel: insetEmptyLabel,
          onSwap: onToggleStudentPipSwap,
        ),
      ),
    );
  }

  Widget _buildTeacherPictureInPictureLayout() {
    final teacherStream = _StreamCardSpec(
      title: 'You (Teacher)',
      renderer: localRenderer,
      isLocal: true,
      preferContain: true,
      preferPortraitFallback: true,
    );

    final studentStream = _StreamCardSpec(
      title: activeStudentId == null
          ? 'No active student'
          : 'Turn: $activeStudentName',
      renderer: activeStudentRenderer,
      preferContain: true,
      preferPortraitFallback: true,
    );

    var mainStream = teacherStream;
    var insetStream = studentStream;
    var mainEmptyLabel = 'Your camera is off';
    var insetEmptyLabel = activeStudentId == null
        ? 'No active student yet'
        : 'Student stream unavailable';

    if (teacherPipSwapped) {
      mainStream = studentStream;
      insetStream = teacherStream;
      mainEmptyLabel = insetEmptyLabel;
      insetEmptyLabel = 'Your camera is off';
    }

    return GlassCard(
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: _buildPictureInPictureStage(
          mainStream: mainStream,
          insetStream: insetStream,
          mainEmptyLabel: mainEmptyLabel,
          insetEmptyLabel: insetEmptyLabel,
          onSwap: onToggleTeacherPipSwap,
        ),
      ),
    );
  }

  Widget _buildPictureInPictureStage({
    required _StreamCardSpec mainStream,
    required _StreamCardSpec insetStream,
    required String mainEmptyLabel,
    required String insetEmptyLabel,
    required VoidCallback onSwap,
  }) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final mainQuarterTurns = _normalizedQuarterTurnsWithOffset(
          renderer: mainStream.renderer,
          isLocal: mainStream.isLocal,
          preferPortraitFallback: mainStream.preferPortraitFallback,
        );
        final mainAspectRatio = _clampAspectRatio(
          _resolveDisplayAspectRatio(
            renderer: mainStream.renderer,
            quarterTurns: mainQuarterTurns,
            preferPortraitFallback: mainStream.preferPortraitFallback,
          ),
        );
        final mainHeight =
            _resolveVideoHeight(constraints.maxWidth, mainAspectRatio);

        final insetQuarterTurns = _normalizedQuarterTurnsWithOffset(
          renderer: insetStream.renderer,
          isLocal: insetStream.isLocal,
          preferPortraitFallback: insetStream.preferPortraitFallback,
        );
        final insetAspectRatio = _clampAspectRatio(
          _resolveDisplayAspectRatio(
            renderer: insetStream.renderer,
            quarterTurns: insetQuarterTurns,
            preferPortraitFallback: insetStream.preferPortraitFallback,
          ),
        );

        var insetWidth = constraints.maxWidth * 0.34;
        if (insetWidth < 112) insetWidth = 112;
        if (insetWidth > 168) insetWidth = 168;

        final maxInsetWidth = constraints.maxWidth - 24;
        if (maxInsetWidth.isFinite && insetWidth > maxInsetWidth) {
          insetWidth = maxInsetWidth;
        }
        if (insetWidth < 72) insetWidth = 72;

        var insetHeight = insetWidth / insetAspectRatio;
        final maxInsetHeight = mainHeight * 0.45;
        if (insetHeight > maxInsetHeight) {
          insetHeight = maxInsetHeight;
        }

        return GestureDetector(
          onTap: onSwap,
          behavior: HitTestBehavior.opaque,
          child: SizedBox(
            width: double.infinity,
            height: mainHeight,
            child: Stack(
              children: <Widget>[
                Positioned.fill(
                  child: _buildPipVideoSurface(
                    renderer: mainStream.renderer,
                    isLocal: mainStream.isLocal,
                    preferContain: mainStream.preferContain,
                    quarterTurns: mainQuarterTurns,
                    emptyLabel: mainEmptyLabel,
                    borderRadius: 14,
                    viewKey: 'pip-main-${mainStream.title}',
                  ),
                ),
                Positioned(
                  top: 10,
                  left: 10,
                  child: _buildPipBadge(mainStream.title),
                ),
                Positioned(
                  top: 10,
                  right: 10,
                  child: _buildPipHintBadge('Tap to swap'),
                ),
                Positioned(
                  right: 10,
                  bottom: 10,
                  child: SizedBox(
                    width: insetWidth,
                    height: insetHeight,
                    child: DecoratedBox(
                      decoration: BoxDecoration(
                        borderRadius: BorderRadius.circular(12),
                        border: Border.all(color: Colors.white24),
                        color: Colors.black.withOpacity(0.55),
                        boxShadow: const <BoxShadow>[
                          BoxShadow(
                            color: Colors.black45,
                            blurRadius: 10,
                            offset: Offset(0, 4),
                          ),
                        ],
                      ),
                      child: Padding(
                        padding: const EdgeInsets.all(4),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: <Widget>[
                            Padding(
                              padding: const EdgeInsets.symmetric(
                                horizontal: 6,
                                vertical: 2,
                              ),
                              child: Text(
                                insetStream.title,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: const TextStyle(
                                  color: Colors.white,
                                  fontSize: 11,
                                  fontWeight: FontWeight.w600,
                                ),
                              ),
                            ),
                            Expanded(
                              child: _buildPipVideoSurface(
                                renderer: insetStream.renderer,
                                isLocal: insetStream.isLocal,
                                preferContain: insetStream.preferContain,
                                quarterTurns: insetQuarterTurns,
                                emptyLabel: insetEmptyLabel,
                                borderRadius: 9,
                                viewKey: 'pip-inset-${insetStream.title}',
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                  ),
                ),
              ],
            ),
          ),
        );
      },
    );
  }

  Widget _buildPipBadge(String text) {
    return DecoratedBox(
      decoration: BoxDecoration(
        color: Colors.black.withOpacity(0.48),
        borderRadius: BorderRadius.circular(999),
      ),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
        child: Text(
          text,
          style: const TextStyle(
            color: Colors.white,
            fontSize: 11,
            fontWeight: FontWeight.w600,
          ),
        ),
      ),
    );
  }

  Widget _buildPipHintBadge(String text) {
    return DecoratedBox(
      decoration: BoxDecoration(
        color: Colors.black.withOpacity(0.42),
        borderRadius: BorderRadius.circular(999),
      ),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
        child: Text(
          text,
          style: const TextStyle(
            color: Colors.white70,
            fontSize: 10,
            fontWeight: FontWeight.w600,
          ),
        ),
      ),
    );
  }

  Widget _buildPipVideoSurface({
    required RTCVideoRenderer renderer,
    required bool isLocal,
    required bool preferContain,
    required int quarterTurns,
    required String emptyLabel,
    required double borderRadius,
    required String viewKey,
  }) {
    final hasStream = renderer.srcObject != null;

    return ClipRRect(
      borderRadius: BorderRadius.circular(borderRadius),
      child: ColoredBox(
        color: Colors.black,
        child: AnimatedSwitcher(
          duration: const Duration(milliseconds: 220),
          child: hasStream
              ? _buildRotatedVideoView(
                  key: ValueKey<String>(viewKey),
                  renderer: renderer,
                  mirror: isLocal,
                  preferContain: preferContain,
                  quarterTurns: quarterTurns,
                )
              : Center(
                  key: ValueKey<String>('empty-$viewKey'),
                  child: Padding(
                    padding: const EdgeInsets.all(8),
                    child: Text(
                      emptyLabel,
                      textAlign: TextAlign.center,
                      style: const TextStyle(
                        color: Colors.white70,
                        fontSize: 11,
                      ),
                    ),
                  ),
                ),
        ),
      ),
    );
  }

  List<_StreamCardSpec> _buildStreamSpecs() {
    if (selectedRole == 'student') {
      return <_StreamCardSpec>[
        _StreamCardSpec(
          title: 'Teacher Stream',
          renderer: teacherRenderer,
          preferContain: true,
          preferPortraitFallback: true,
        ),
        _StreamCardSpec(
          title: 'Your Camera (only when approved)',
          renderer: localRenderer,
          isLocal: true,
          preferContain: true,
          preferPortraitFallback: true,
        ),
      ];
    }

    return <_StreamCardSpec>[
      _StreamCardSpec(
        title: 'Your Local Preview',
        renderer: localRenderer,
        isLocal: true,
        preferContain: true,
        preferPortraitFallback: true,
      ),
      _StreamCardSpec(
        title: 'Active Student Stream',
        renderer: activeStudentRenderer,
        preferContain: true,
        preferPortraitFallback: true,
      ),
    ];
  }

  Widget _buildVideoCard(
    BuildContext context, {
    required String title,
    required RTCVideoRenderer renderer,
    bool isLocal = false,
    bool preferContain = false,
    bool preferPortraitFallback = false,
  }) {
    final hasStream = renderer.srcObject != null;
    final quarterTurns = _normalizedQuarterTurnsWithOffset(
      renderer: renderer,
      isLocal: isLocal,
      preferPortraitFallback: preferPortraitFallback,
    );
    final aspectRatio = _clampAspectRatio(
      _resolveDisplayAspectRatio(
        renderer: renderer,
        quarterTurns: quarterTurns,
        preferPortraitFallback: preferPortraitFallback,
      ),
    );
    final videoMeta = _videoMetaLabel(
      renderer,
      quarterTurns: quarterTurns,
      preferPortraitFallback: preferPortraitFallback,
    );

    return LayoutBuilder(
      builder: (context, constraints) {
        final targetHeight =
            _resolveVideoHeight(constraints.maxWidth, aspectRatio);

        return Card(
          color: Colors.white.withOpacity(0.94),
          elevation: 2,
          shape:
              RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
          child: Padding(
            padding: const EdgeInsets.all(12),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                Row(
                  children: <Widget>[
                    Expanded(
                      child: Text(
                        title,
                        style: const TextStyle(fontWeight: FontWeight.w600),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 4),
                Text(
                  videoMeta,
                  style: TextStyle(
                    color: Theme.of(context).colorScheme.onSurfaceVariant,
                    fontSize: 12,
                  ),
                ),
                const SizedBox(height: 8),
                SizedBox(
                  width: double.infinity,
                  height: targetHeight,
                  child: ClipRRect(
                    borderRadius: BorderRadius.circular(10),
                    child: ColoredBox(
                      color: Colors.black,
                      child: AnimatedSwitcher(
                        duration: const Duration(milliseconds: 240),
                        child: hasStream
                            ? _buildRotatedVideoView(
                                key: ValueKey<String>('video-$title'),
                                renderer: renderer,
                                mirror: isLocal,
                                preferContain: preferContain,
                                quarterTurns: quarterTurns,
                              )
                            : const Center(
                                key: ValueKey<String>('empty-video'),
                                child: Text(
                                  'No stream',
                                  style: TextStyle(color: Colors.white70),
                                ),
                              ),
                      ),
                    ),
                  ),
                ),
              ],
            ),
          ),
        );
      },
    );
  }

  Widget _buildRotatedVideoView({
    Key? key,
    required RTCVideoRenderer renderer,
    required bool mirror,
    required bool preferContain,
    required int quarterTurns,
  }) {
    Widget view = RTCVideoView(
      key: key,
      renderer,
      mirror: mirror,
      objectFit: preferContain
          ? RTCVideoViewObjectFit.RTCVideoViewObjectFitContain
          : RTCVideoViewObjectFit.RTCVideoViewObjectFitCover,
    );

    if (quarterTurns != 0) {
      view = RotatedBox(
        quarterTurns: quarterTurns,
        child: view,
      );
    }

    return view;
  }

  int _normalizedQuarterTurnsWithOffset({
    required RTCVideoRenderer renderer,
    required bool isLocal,
    required bool preferPortraitFallback,
  }) {
    return _normalizeQuarterTurns(
      _resolveQuarterTurns(
            renderer,
            isLocal: isLocal,
            preferPortraitFallback: preferPortraitFallback,
          ) +
          _globalQuarterTurnOffset,
    );
  }

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

class _StreamCardSpec {
  final String title;
  final RTCVideoRenderer renderer;
  final bool isLocal;
  final bool preferContain;
  final bool preferPortraitFallback;

  const _StreamCardSpec({
    required this.title,
    required this.renderer,
    this.isLocal = false,
    this.preferContain = false,
    this.preferPortraitFallback = false,
  });
}
