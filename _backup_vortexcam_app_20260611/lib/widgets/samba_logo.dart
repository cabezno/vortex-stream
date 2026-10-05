import 'dart:math' as math;
import 'package:flutter/material.dart';

enum SambaLogoState { idle, streaming }

class SambaLogo extends StatefulWidget {
  final SambaLogoState state;
  final double size;

  const SambaLogo({super.key, required this.state, this.size = 80});

  @override
  State<SambaLogo> createState() => _SambaLogoState();
}

class _SambaLogoState extends State<SambaLogo>
    with SingleTickerProviderStateMixin {
  late final AnimationController _ctrl;

  @override
  void initState() {
    super.initState();
    _ctrl = AnimationController(
      vsync: this,
      duration: const Duration(seconds: 4),
    );
    _syncAnim();
  }

  @override
  void didUpdateWidget(SambaLogo old) {
    super.didUpdateWidget(old);
    if (old.state != widget.state) _syncAnim();
  }

  void _syncAnim() {
    if (widget.state == SambaLogoState.streaming) {
      _ctrl.repeat();
    } else {
      _ctrl.stop();
      _ctrl.reset();
    }
  }

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: _ctrl,
      builder: (_, __) => CustomPaint(
        size: Size(widget.size, widget.size),
        painter: _SambaLogoPainter(widget.state, _ctrl.value),
      ),
    );
  }
}

class _SambaLogoPainter extends CustomPainter {
  final SambaLogoState state;
  final double t; // 0..1 rotation progress

  const _SambaLogoPainter(this.state, this.t);

  static const _kBlack  = Color(0xFF0A0A0A);
  static const _kRed    = Color(0xFFD41A1A);
  static const _kViolet = Color(0xFF4A14C8);
  static const _kOrange = Color(0xFFFF8C00);

  @override
  void paint(Canvas canvas, Size size) {
    final R        = size.width / 2;
    final center   = Offset(R, R);
    final rRingOut = R * 0.86;
    final rRingIn  = R * 0.63;
    final rMid     = (rRingIn + rRingOut) / 2;
    final rWidth   = rRingOut - rRingIn;

    if (state == SambaLogoState.idle) {
      // Black outer
      canvas.drawCircle(center, R, Paint()..color = _kBlack);
      // Red static ring
      canvas.drawCircle(
        center, rMid,
        Paint()
          ..color = _kRed
          ..style = PaintingStyle.stroke
          ..strokeWidth = rWidth,
      );
      // Black inner
      canvas.drawCircle(center, rRingIn, Paint()..color = _kBlack);
    } else {
      // Streaming: orange inner + gradient rotating ring
      canvas.drawCircle(center, R, Paint()..color = _kBlack);

      // Orange inner circle with subtle warm gradient
      final warmPaint = Paint()
        ..shader = RadialGradient(
          colors: [const Color(0xFFFFCC00), _kOrange, const Color(0xFFCC2200)],
          stops: const [0.0, 0.5, 1.0],
        ).createShader(Rect.fromCircle(center: center, radius: rRingIn));
      canvas.drawCircle(center, rRingIn, warmPaint);

      // Rotating gradient ring
      final sweepStart = t * math.pi * 2;
      final ringPaint = Paint()
        ..shader = SweepGradient(
          colors: const [_kRed, _kViolet, _kRed],
          startAngle: sweepStart,
          endAngle: sweepStart + math.pi * 2,
        ).createShader(Rect.fromCircle(center: center, radius: rRingOut))
        ..style = PaintingStyle.stroke
        ..strokeWidth = rWidth;
      canvas.drawCircle(center, rMid, ringPaint);
    }
  }

  @override
  bool shouldRepaint(_SambaLogoPainter old) =>
      old.state != state || old.t != t;
}
