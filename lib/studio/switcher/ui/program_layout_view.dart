import 'package:flutter/material.dart';
import '../../../theme/sd_icons.dart';
import '../../../theme/samba_theme.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart';
import 'package:samba_protocol/samba_protocol.dart';
import '../mixer/program_mixer.dart';
import '../transport/subscriber.dart';

/// Renders the composed Program view based on ProgramMixer layout (Single, Split-Screen, PiP).
class ProgramLayoutView extends StatelessWidget {
  final ProgramMixer mixer;
  final WebRtcSubscriber subscriber;
  final List<Peer> cameras;
  // Cámara local del switcher: su renderer no está en el subscriber (es captura
  // local), así que se resuelve aparte.
  final RTCVideoRenderer? localRenderer;
  final String? localPeerId;

  const ProgramLayoutView({
    super.key,
    required this.mixer,
    required this.subscriber,
    required this.cameras,
    this.localRenderer,
    this.localPeerId,
  });

  RTCVideoRenderer? _resolveRenderer(String? id) {
    if (id == null) return null;
    if (localPeerId != null && id == localPeerId) return localRenderer;
    return subscriber.getRenderer(id);
  }

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: mixer,
      builder: (context, _) {
        final primaryId = mixer.primaryPeerId;
        final secondaryId = mixer.secondaryPeerId;

        final primaryCam = cameras.where((c) => c.id == primaryId).firstOrNull;
        final secondaryCam = cameras.where((c) => c.id == secondaryId).firstOrNull;

        final primaryRenderer = _resolveRenderer(primaryId);
        final secondaryRenderer = _resolveRenderer(secondaryId);

        final hasPrimaryVideo = primaryRenderer != null && primaryRenderer.srcObject != null;
        final hasSecondaryVideo = secondaryRenderer != null && secondaryRenderer.srcObject != null;

        debugPrint('[ProgramLayout] mode=${mixer.mode} primary=$primaryId '
            '(r=${primaryRenderer != null} vid=$hasPrimaryVideo) '
            'secondary=$secondaryId (r=${secondaryRenderer != null} vid=$hasSecondaryVideo) '
            'localPeerId=$localPeerId localR=${localRenderer != null}');

        return ClipRRect(
          borderRadius: BorderRadius.circular(14),
          child: switch (mixer.mode) {
            LayoutMode.single => _buildSingleView(primaryCam, primaryRenderer, hasPrimaryVideo),
            LayoutMode.splitScreen => _buildSplitView(
                primaryCam,
                primaryRenderer,
                hasPrimaryVideo,
                secondaryCam,
                secondaryRenderer,
                hasSecondaryVideo,
              ),
            LayoutMode.pip => _buildPipView(
                primaryCam,
                primaryRenderer,
                hasPrimaryVideo,
                secondaryCam,
                secondaryRenderer,
                hasSecondaryVideo,
              ),
          },
        );
      },
    );
  }

  Widget _buildSingleView(Peer? cam, RTCVideoRenderer? renderer, bool hasVideo) {
    if (hasVideo && renderer != null) {
      return RTCVideoView(
        renderer,
        objectFit: RTCVideoViewObjectFit.RTCVideoViewObjectFitCover,
      );
    }
    return _buildPlaceholder(cam?.name ?? 'Sin cámara', 'Tocá una cámara del multiview para ponerla al aire');
  }

  Widget _buildSplitView(
    Peer? pCam,
    RTCVideoRenderer? pRenderer,
    bool pHasVideo,
    Peer? sCam,
    RTCVideoRenderer? sRenderer,
    bool sHasVideo,
  ) {
    return Row(
      children: [
        // Left Side: Primary Camera
        Expanded(
          flex: (mixer.splitRatio * 100).toInt(),
          child: Container(
            color: Sd.void_,
            child: pHasVideo && pRenderer != null
                ? RTCVideoView(
                    pRenderer,
                    objectFit: RTCVideoViewObjectFit.RTCVideoViewObjectFitCover,
                  )
                : _buildPlaceholder(pCam?.name ?? 'Principal', 'Mitad izquierda'),
          ),
        ),

        // Divider
        Container(width: 2, color: Sd.wash(Sd.t1, 0.25)),

        // Right Side: Secondary Camera
        Expanded(
          flex: ((1.0 - mixer.splitRatio) * 100).toInt(),
          child: Container(
            color: Sd.void_,
            child: sHasVideo && sRenderer != null
                ? RTCVideoView(
                    sRenderer,
                    objectFit: RTCVideoViewObjectFit.RTCVideoViewObjectFitCover,
                  )
                : _buildPlaceholder(sCam?.name ?? 'Segunda cámara', 'Mitad derecha'),
          ),
        ),
      ],
    );
  }

  Widget _buildPipView(
    Peer? pCam,
    RTCVideoRenderer? pRenderer,
    bool pHasVideo,
    Peer? sCam,
    RTCVideoRenderer? sRenderer,
    bool sHasVideo,
  ) {
    return Stack(
      children: [
        // Background: Full Primary Camera
        Positioned.fill(
          child: pHasVideo && pRenderer != null
              ? RTCVideoView(
                  pRenderer,
                  objectFit: RTCVideoViewObjectFit.RTCVideoViewObjectFitCover,
                )
              : _buildPlaceholder(pCam?.name ?? 'Principal', 'Pantalla completa'),
        ),

        // PiP Inset Window
        _buildPipInset(sCam, sRenderer, sHasVideo),
      ],
    );
  }

  Widget _buildPipInset(Peer? sCam, RTCVideoRenderer? sRenderer, bool sHasVideo) {
    const double pipWidth = 180.0;
    const double pipHeight = 101.25; // 16:9
    const double margin = 16.0;

    double? top;
    double? bottom;
    double? left;
    double? right;

    switch (mixer.pipPosition) {
      case PipPosition.bottomRight:
        bottom = margin;
        right = margin;
        break;
      case PipPosition.bottomLeft:
        bottom = margin;
        left = margin;
        break;
      case PipPosition.topRight:
        top = margin + 40; // below top bar badges
        right = margin;
        break;
      case PipPosition.topLeft:
        top = margin + 40;
        left = margin;
        break;
    }

    return Positioned(
      top: top,
      bottom: bottom,
      left: left,
      right: right,
      width: pipWidth,
      height: pipHeight,
      child: Container(
        decoration: BoxDecoration(
          color: Sd.raised,
          borderRadius: BorderRadius.circular(Sd.r2),
          border: Border.all(color: Sd.wash(Sd.cyan, 0.7), width: 1.5),
          boxShadow: const [BoxShadow(color: Color(0x99000000), blurRadius: 14)],
        ),
        clipBehavior: Clip.antiAlias,
        child: sHasVideo && sRenderer != null
            ? RTCVideoView(
                sRenderer,
                objectFit: RTCVideoViewObjectFit.RTCVideoViewObjectFitCover,
              )
            : Center(
                child: Text(
                  sCam?.name ?? 'PiP: elegir cámara',
                  style: SdText.label,
                ),
              ),
      ),
    );
  }

  Widget _buildPlaceholder(String label, String sublabel) {
    // Lifted above the layout selector that sits at the bottom of the program monitor.
    return Padding(padding: const EdgeInsets.only(bottom: 56), child: Center(
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          const Icon(SdIcons.videoCamera, size: 40, color: Sd.t3),
          const SizedBox(height: 10),
          Text(label, style: SdText.heading.copyWith(color: Sd.t2)),
          const SizedBox(height: 4),
          Text(sublabel, style: SdText.caption),
        ],
      ),
    ));
  }
}
