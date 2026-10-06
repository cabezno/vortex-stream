import 'dart:convert';
import 'models.dart';

/// Sealed message protocol for SAMBA Móvil Studio.
/// Supports control, audio telemetry, and WebRTC signaling.
sealed class SambaMessage {
  final String t;

  const SambaMessage(this.t);

  Map<String, dynamic> toJson();

  String encode() => jsonEncode(toJson());

  static SambaMessage decode(String jsonStr) {
    final map = jsonDecode(jsonStr) as Map<String, dynamic>;
    final t = map['t'] as String?;
    return switch (t) {
      'join' => JoinMessage.fromJson(map),
      'audio_level' => AudioLevelMessage.fromJson(map),
      'heartbeat' => HeartbeatMessage.fromJson(map),
      'roster' => RosterMessage.fromJson(map),
      'set_layer' => SetLayerMessage.fromJson(map),
      'bye' => ByeMessage.fromJson(map),
      'cam_info' => CamInfoMessage.fromJson(map),
      'offer' => OfferMessage.fromJson(map),
      'answer' => AnswerMessage.fromJson(map),
      'candidate' => IceCandidateMessage.fromJson(map),
      _ => throw FormatException('Unknown message type: $t'),
    };
  }
}

/// Camera -> Switcher: Requests to join the room.
class JoinMessage extends SambaMessage {
  final String peerId;
  final String name;
  final PeerRole role;

  const JoinMessage({
    required this.peerId,
    required this.name,
    this.role = PeerRole.camera,
  }) : super('join');

  @override
  Map<String, dynamic> toJson() => {
    't': t,
    'peerId': peerId,
    'name': name,
    'role': role.toJson(),
  };

  factory JoinMessage.fromJson(Map<String, dynamic> json) => JoinMessage(
    peerId: json['peerId'] as String,
    name: json['name'] as String? ?? 'Camera',
    role: PeerRole.fromJson(json['role'] as String? ?? 'camera'),
  );
}

/// Camera -> Switcher: Periodic audio telemetry (RMS dBFS, typically sent every ~100ms).
class AudioLevelMessage extends SambaMessage {
  final String peerId;
  final double dbfs;

  const AudioLevelMessage({
    required this.peerId,
    required this.dbfs,
  }) : super('audio_level');

  @override
  Map<String, dynamic> toJson() => {
    't': t,
    'peerId': peerId,
    'dbfs': dbfs,
  };

  factory AudioLevelMessage.fromJson(Map<String, dynamic> json) => AudioLevelMessage(
    peerId: json['peerId'] as String,
    dbfs: (json['dbfs'] as num).toDouble(),
  );
}

/// Keep-alive heartbeat message.
class HeartbeatMessage extends SambaMessage {
  final String peerId;
  final int timestampMs;

  HeartbeatMessage({
    required this.peerId,
    int? timestampMs,
  })  : timestampMs = timestampMs ?? DateTime.now().millisecondsSinceEpoch,
        super('heartbeat');

  @override
  Map<String, dynamic> toJson() => {
    't': t,
    'peerId': peerId,
    'timestampMs': timestampMs,
  };

  factory HeartbeatMessage.fromJson(Map<String, dynamic> json) => HeartbeatMessage(
    peerId: json['peerId'] as String,
    timestampMs: json['timestampMs'] as int? ?? 0,
  );
}

/// Switcher -> All: Broadcasts active participants in the room.
class RosterMessage extends SambaMessage {
  final List<Peer> peers;
  final String? activePeerId;
  /// The camera prepared to go on air next (green tally on that phone).
  final String? previewPeerId;

  const RosterMessage({
    required this.peers,
    this.activePeerId,
    this.previewPeerId,
  }) : super('roster');

  @override
  Map<String, dynamic> toJson() => {
    't': t,
    'peers': peers.map((p) => p.toJson()).toList(),
    if (activePeerId != null) 'activePeerId': activePeerId,
    if (previewPeerId != null) 'previewPeerId': previewPeerId,
  };

  factory RosterMessage.fromJson(Map<String, dynamic> json) {
    final rawPeers = json['peers'] as List<dynamic>? ?? [];
    return RosterMessage(
      peers: rawPeers.map((p) => Peer.fromJson(p as Map<String, dynamic>)).toList(),
      activePeerId: json['activePeerId'] as String?,
      previewPeerId: json['previewPeerId'] as String?,
    );
  }
}

/// Camera -> Switcher: what the camera is and how it captures, sent after joining and whenever it changes.
/// - [captureDelayMs]: sensor exposure → handed to the encoder, measured on the phone (Camera2 SENSOR_TIMESTAMP vs
///   now); the part of the delay the network timestamps cannot see.
/// - [mic]: the microphone in use ('phone' or a Bluetooth headset name) and [micDelayMs], its extra delay.
/// - [maxHeight]: the highest height this phone's encoder can send (its own measurement), for 4K on air.
class CamInfoMessage extends SambaMessage {
  final String peerId;
  final int captureDelayMs;
  final String mic;
  final int micDelayMs;
  final int maxHeight;
  final int clockOffsetMs;

  const CamInfoMessage({
    required this.peerId,
    this.captureDelayMs = 0,
    this.mic = 'phone',
    this.micDelayMs = 0,
    this.maxHeight = 1080,
    this.clockOffsetMs = 0,
  }) : super('cam_info');

  @override
  Map<String, dynamic> toJson() => {
    't': t,
    'peerId': peerId,
    'captureDelayMs': captureDelayMs,
    'mic': mic,
    'micDelayMs': micDelayMs,
    'maxHeight': maxHeight,
    'clockOffsetMs': clockOffsetMs,
  };

  factory CamInfoMessage.fromJson(Map<String, dynamic> json) => CamInfoMessage(
    peerId: json['peerId'] as String,
    captureDelayMs: (json['captureDelayMs'] as num?)?.toInt() ?? 0,
    mic: json['mic'] as String? ?? 'phone',
    micDelayMs: (json['micDelayMs'] as num?)?.toInt() ?? 0,
    maxHeight: (json['maxHeight'] as num?)?.toInt() ?? 1080,
    clockOffsetMs: (json['clockOffsetMs'] as num?)?.toInt() ?? 0,
  );
}

/// Switcher -> Camera: Orders a camera to switch its transmission layer ('high' or 'low').
class SetLayerMessage extends SambaMessage {
  final String peerId;
  final Layer layer;

  const SetLayerMessage({
    required this.peerId,
    required this.layer,
  }) : super('set_layer');

  @override
  Map<String, dynamic> toJson() => {
    't': t,
    'peerId': peerId,
    'layer': layer.toJson(),
  };

  factory SetLayerMessage.fromJson(Map<String, dynamic> json) => SetLayerMessage(
    peerId: json['peerId'] as String,
    layer: Layer.fromJson(json['layer'] as String),
  );
}

/// Leave or kick message.
class ByeMessage extends SambaMessage {
  final String peerId;
  final String? reason;

  const ByeMessage({
    required this.peerId,
    this.reason,
  }) : super('bye');

  @override
  Map<String, dynamic> toJson() => {
    't': t,
    'peerId': peerId,
    if (reason != null) 'reason': reason,
  };

  factory ByeMessage.fromJson(Map<String, dynamic> json) => ByeMessage(
    peerId: json['peerId'] as String,
    reason: json['reason'] as String?,
  );
}

/// WebRTC Signaling: SDP Offer
class OfferMessage extends SambaMessage {
  final String from;
  final String to;
  final String sdp;

  const OfferMessage({
    required this.from,
    required this.to,
    required this.sdp,
  }) : super('offer');

  @override
  Map<String, dynamic> toJson() => {
    't': t,
    'from': from,
    'to': to,
    'sdp': sdp,
  };

  factory OfferMessage.fromJson(Map<String, dynamic> json) => OfferMessage(
    from: json['from'] as String,
    to: json['to'] as String,
    sdp: json['sdp'] as String,
  );
}

/// WebRTC Signaling: SDP Answer
class AnswerMessage extends SambaMessage {
  final String from;
  final String to;
  final String sdp;

  const AnswerMessage({
    required this.from,
    required this.to,
    required this.sdp,
  }) : super('answer');

  @override
  Map<String, dynamic> toJson() => {
    't': t,
    'from': from,
    'to': to,
    'sdp': sdp,
  };

  factory AnswerMessage.fromJson(Map<String, dynamic> json) => AnswerMessage(
    from: json['from'] as String,
    to: json['to'] as String,
    sdp: json['sdp'] as String,
  );
}

/// WebRTC Signaling: ICE Candidate
class IceCandidateMessage extends SambaMessage {
  final String from;
  final String to;
  final Map<String, dynamic> candidate;

  const IceCandidateMessage({
    required this.from,
    required this.to,
    required this.candidate,
  }) : super('candidate');

  @override
  Map<String, dynamic> toJson() => {
    't': t,
    'from': from,
    'to': to,
    'candidate': candidate,
  };

  factory IceCandidateMessage.fromJson(Map<String, dynamic> json) => IceCandidateMessage(
    from: json['from'] as String,
    to: json['to'] as String,
    candidate: json['candidate'] as Map<String, dynamic>,
  );
}
