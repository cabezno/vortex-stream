import 'package:flutter/foundation.dart';
import '../encode/program_encoder.dart';
import '../room/room_host.dart';

enum LayoutMode {
  single,       // 1 full camera
  splitScreen,  // 2 cameras side-by-side (50/50)
  pip,          // 1 main camera + 1 picture-in-picture in the corner
}

enum PipPosition {
  bottomRight,
  bottomLeft,
  topRight,
  topLeft,
}

/// Manages Program video layout composition and coordinates multi-camera
/// layer promotion with RoomHost (e.g. promoting 2 cameras to Layer.high
/// during split-screen or PiP), synchronizing the native GPU compositor.
class ProgramMixer extends ChangeNotifier {
  final RoomHost roomHost;
  final ProgramEncoder? encoder;

  LayoutMode _mode = LayoutMode.single;
  String? _primaryPeerId;
  String? _secondaryPeerId;
  PipPosition _pipPosition = PipPosition.bottomRight;
  double _splitRatio = 0.5; // 50/50 split

  ProgramMixer({required this.roomHost, this.encoder}) {
    roomHost.addListener(_syncFromRoomHost);
  }

  LayoutMode get mode => _mode;
  // La cámara de programa DEBE seguir a la activa en vivo (manualCut/auto-switch),
  // no quedar clavada en la primera. Antes era `_primaryPeerId ?? activePeerId`,
  // pero `_primaryPeerId` se cacheaba una sola vez y el programa no cambiaba nunca.
  // Ahora la activa manda; `_primaryPeerId` queda solo como fallback.
  String? get primaryPeerId => roomHost.activePeerId ?? _primaryPeerId;
  String? get secondaryPeerId => _secondaryPeerId;
  PipPosition get pipPosition => _pipPosition;
  double get splitRatio => _splitRatio;

  bool get isComposed => _mode != LayoutMode.single && _secondaryPeerId != null;

  void _syncFromRoomHost() {
    // Redibujar el programa cada vez que cambia la cámara activa (o join/leave):
    // el getter primaryPeerId ya lee activePeerId en vivo, solo hay que notificar.
    if (_mode != LayoutMode.single) _autoSecondary();
    notifyListeners();
  }

  /// Split / PiP need a second camera: if none is chosen (or the chosen one left, or it became the on-air one),
  /// take the first OTHER connected camera instead of leaving half the program black with "SELECCIONAR CÁMARA 2"
  /// (found 2026-10-04 with three phones). A camera the user picked is kept while it is valid.
  void _autoSecondary() {
    final primary = primaryPeerId;
    final others = roomHost.cameras.where((p) => p.connected && p.id != primary).map((p) => p.id).toList();
    if (_secondaryPeerId != null && others.contains(_secondaryPeerId)) return;
    final next = others.isNotEmpty ? others.first : null;
    if (next == _secondaryPeerId) return;
    _secondaryPeerId = next;
    _applyLayerPromotions();
  }

  /// Sets the program composition layout mode
  void setLayoutMode(LayoutMode newMode) {
    if (_mode == newMode) return;
    _mode = newMode;
    _autoSecondary();
    encoder?.setLayoutMode(newMode.name);
    _applyLayerPromotions();
    notifyListeners();
  }

  /// Sets the primary on-air camera
  void setPrimary(String? peerId) {
    _primaryPeerId = peerId;
    roomHost.setActiveCamera(peerId);
    _applyLayerPromotions();
    notifyListeners();
  }

  /// Sets the secondary camera for split-screen or PiP
  void setSecondary(String? peerId) {
    _secondaryPeerId = peerId;
    _applyLayerPromotions();
    notifyListeners();
  }

  /// Updates PiP position
  void setPipPosition(PipPosition position) {
    _pipPosition = position;
    notifyListeners();
  }

  /// Updates split ratio (e.g. 0.5 = 50/50, 0.6 = 60/40)
  void setSplitRatio(double ratio) {
    _splitRatio = ratio.clamp(0.2, 0.8);
    notifyListeners();
  }

  /// The on-air and preview cameras are always at high quality (RoomHost); the composition adds the second camera
  /// of a split / PiP. Everything else goes to the low layer.
  void _applyLayerPromotions() {
    roomHost.extraHigh = (_mode != LayoutMode.single && _secondaryPeerId != null) ? {_secondaryPeerId!} : {};
  }

  @override
  void dispose() {
    roomHost.removeListener(_syncFromRoomHost);
    super.dispose();
  }
}
