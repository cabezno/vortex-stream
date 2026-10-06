import 'dart:convert';

/// Domain models for SAMBA Móvil Studio.

enum PeerRole {
  camera,
  switcher;

  String toJson() => name;
  static PeerRole fromJson(String value) =>
      PeerRole.values.firstWhere((e) => e.name == value, orElse: () => PeerRole.camera);
}

enum Layer {
  low,
  high;

  String toJson() => name;
  static Layer fromJson(String value) =>
      Layer.values.firstWhere((e) => e.name == value, orElse: () => Layer.low);
}

class Peer {
  final String id;
  final String name;
  final PeerRole role;
  bool connected;
  Layer activeLayer;
  double lastAudioDbfs;
  DateTime lastSeen;

  Peer({
    required this.id,
    required this.name,
    this.role = PeerRole.camera,
    this.connected = true,
    this.activeLayer = Layer.low,
    this.lastAudioDbfs = -100.0,
    DateTime? lastSeen,
  }) : lastSeen = lastSeen ?? DateTime.now();

  Map<String, dynamic> toJson() => {
    'id': id,
    'name': name,
    'role': role.toJson(),
    'connected': connected,
    'activeLayer': activeLayer.toJson(),
    'lastAudioDbfs': lastAudioDbfs,
    'lastSeen': lastSeen.toIso8601String(),
  };

  factory Peer.fromJson(Map<String, dynamic> json) => Peer(
    id: json['id'] as String,
    name: json['name'] as String? ?? 'Cam',
    role: PeerRole.fromJson(json['role'] as String? ?? 'camera'),
    connected: json['connected'] as bool? ?? true,
    activeLayer: Layer.fromJson(json['activeLayer'] as String? ?? 'low'),
    lastAudioDbfs: (json['lastAudioDbfs'] as num?)?.toDouble() ?? -100.0,
    lastSeen: json['lastSeen'] != null ? DateTime.tryParse(json['lastSeen'] as String) : null,
  );

  Peer copyWith({
    String? id,
    String? name,
    PeerRole? role,
    bool? connected,
    Layer? activeLayer,
    double? lastAudioDbfs,
    DateTime? lastSeen,
  }) {
    return Peer(
      id: id ?? this.id,
      name: name ?? this.name,
      role: role ?? this.role,
      connected: connected ?? this.connected,
      activeLayer: activeLayer ?? this.activeLayer,
      lastAudioDbfs: lastAudioDbfs ?? this.lastAudioDbfs,
      lastSeen: lastSeen ?? this.lastSeen,
    );
  }
}

class SwitcherConfig {
  bool autoSwitch;
  double onsetMs;
  double holdSec;
  double silenceSec;
  double thresholdDbfs;
  String? overlapPeerId;
  String? silencePeerId;
  int crossfadeMs;
  int programWidth;
  int programHeight;
  int programBitrateKbps;
  bool abr;

  SwitcherConfig({
    this.autoSwitch = false,
    this.onsetMs = 80.0,
    this.holdSec = 1.5,
    this.silenceSec = 3.0,
    this.thresholdDbfs = -40.0,
    this.overlapPeerId,
    this.silencePeerId,
    this.crossfadeMs = 120,
    this.programWidth = 1280,
    this.programHeight = 720,
    this.programBitrateKbps = 3500,
    this.abr = true,
  });

  Map<String, dynamic> toJson() => {
    'autoSwitch': autoSwitch,
    'onsetMs': onsetMs,
    'holdSec': holdSec,
    'silenceSec': silenceSec,
    'thresholdDbfs': thresholdDbfs,
    if (overlapPeerId != null) 'overlapPeerId': overlapPeerId,
    if (silencePeerId != null) 'silencePeerId': silencePeerId,
    'crossfadeMs': crossfadeMs,
    'programWidth': programWidth,
    'programHeight': programHeight,
    'programBitrateKbps': programBitrateKbps,
    'abr': abr,
  };

  factory SwitcherConfig.fromJson(Map<String, dynamic> json) => SwitcherConfig(
    autoSwitch: json['autoSwitch'] as bool? ?? false,
    onsetMs: (json['onsetMs'] as num?)?.toDouble() ?? 80.0,
    holdSec: (json['holdSec'] as num?)?.toDouble() ?? 1.5,
    silenceSec: (json['silenceSec'] as num?)?.toDouble() ?? 3.0,
    thresholdDbfs: (json['thresholdDbfs'] as num?)?.toDouble() ?? -40.0,
    overlapPeerId: json['overlapPeerId'] as String?,
    silencePeerId: json['silencePeerId'] as String?,
    crossfadeMs: json['crossfadeMs'] as int? ?? 120,
    programWidth: json['programWidth'] as int? ?? 1280,
    programHeight: json['programHeight'] as int? ?? 720,
    programBitrateKbps: json['programBitrateKbps'] as int? ?? 3500,
    abr: json['abr'] as bool? ?? true,
  );
}

class ProgramState {
  String? activePeerId;
  bool live;
  bool recording;

  ProgramState({
    this.activePeerId,
    this.live = false,
    this.recording = false,
  });

  Map<String, dynamic> toJson() => {
    if (activePeerId != null) 'activePeerId': activePeerId,
    'live': live,
    'recording': recording,
  };

  factory ProgramState.fromJson(Map<String, dynamic> json) => ProgramState(
    activePeerId: json['activePeerId'] as String?,
    live: json['live'] as bool? ?? false,
    recording: json['recording'] as bool? ?? false,
  );
}

class Room {
  final String id;
  final Map<String, Peer> peers;
  String? activePeerId;
  /// PVW: the camera prepared to go on air next (kept at high quality so the cut is instant).
  String? previewPeerId;
  SwitcherConfig config;
  ProgramState programState;

  Room({
    required this.id,
    Map<String, Peer>? peers,
    this.activePeerId,
    SwitcherConfig? config,
    ProgramState? programState,
  })  : peers = peers ?? <String, Peer>{},
        config = config ?? SwitcherConfig(),
        programState = programState ?? ProgramState();

  Map<String, dynamic> toJson() => {
    'id': id,
    'peers': peers.map((k, v) => MapEntry(k, v.toJson())),
    if (activePeerId != null) 'activePeerId': activePeerId,
    'config': config.toJson(),
    'programState': programState.toJson(),
  };

  factory Room.fromJson(Map<String, dynamic> json) {
    final rawPeers = json['peers'] as Map<String, dynamic>? ?? {};
    final peers = rawPeers.map(
      (k, v) => MapEntry(k, Peer.fromJson(v as Map<String, dynamic>)),
    );
    return Room(
      id: json['id'] as String,
      peers: peers,
      activePeerId: json['activePeerId'] as String?,
      config: json['config'] != null
          ? SwitcherConfig.fromJson(json['config'] as Map<String, dynamic>)
          : SwitcherConfig(),
      programState: json['programState'] != null
          ? ProgramState.fromJson(json['programState'] as Map<String, dynamic>)
          : ProgramState(),
    );
  }
}

/// Pairing configuration exchanged via QR Code or direct IP input.
class PairingPayload {
  final String ip;
  final int port;
  final String room;
  /// The switcher's OWN network (local hotspot), when it created one: the camera joins it before the room.
  final String? wifiSsid;
  final String? wifiPassword;

  const PairingPayload({
    required this.ip,
    this.port = 8088,
    this.room = 'samba_studio',
    this.wifiSsid,
    this.wifiPassword,
  });

  bool get hasWifi => wifiSsid != null && wifiSsid!.isNotEmpty;

  String get wsUrl => 'ws://$ip:$port/ws';

  Map<String, dynamic> toJson() => {
    'ip': ip,
    'port': port,
    'room': room,
    if (hasWifi) 'wifi': {'ssid': wifiSsid, 'pass': wifiPassword ?? ''},
  };

  factory PairingPayload.fromJson(Map<String, dynamic> json) => PairingPayload(
    ip: json['ip'] as String? ?? '127.0.0.1',
    port: json['port'] as int? ?? 8088,
    room: json['room'] as String? ?? 'samba_studio',
    wifiSsid: (json['wifi'] is Map) ? (json['wifi']['ssid'] as String?) : null,
    wifiPassword: (json['wifi'] is Map) ? (json['wifi']['pass'] as String?) : null,
  );

  /// Robust parser for QR code strings, JSON payloads, ws:// or http:// URLs,
  /// host:port strings, or bare IP addresses.
  static PairingPayload parse(String raw) {
    final trimmed = raw.trim();
    if (trimmed.isEmpty) {
      return const PairingPayload(ip: '127.0.0.1');
    }

    // 1. Try parsing JSON (e.g. generated by Switcher QR modal)
    if (trimmed.startsWith('{') && trimmed.endsWith('}')) {
      try {
        final decoded = jsonDecode(trimmed);
        if (decoded is Map<String, dynamic>) {
          return PairingPayload.fromJson(decoded);
        }
      } catch (_) {}
    }

    // 2. Try parsing URL (e.g. ws://192.168.1.50:8088/ws or http://...)
    if (trimmed.startsWith('ws://') ||
        trimmed.startsWith('wss://') ||
        trimmed.startsWith('http://') ||
        trimmed.startsWith('https://')) {
      try {
        final uri = Uri.parse(trimmed);
        return PairingPayload(
          ip: uri.host.isNotEmpty ? uri.host : '127.0.0.1',
          port: uri.hasPort ? uri.port : 8088,
          room: uri.pathSegments.isNotEmpty ? uri.pathSegments.first : 'samba_studio',
        );
      } catch (_) {}
    }

    // 3. Try parsing "host:port"
    if (trimmed.contains(':')) {
      final parts = trimmed.split(':');
      final host = parts[0].trim();
      final port = int.tryParse(parts[1].trim()) ?? 8088;
      return PairingPayload(
        ip: host.isNotEmpty ? host : '127.0.0.1',
        port: port,
      );
    }

    // 4. Default: Bare IP or hostname
    return PairingPayload(ip: trimmed);
  }
}
