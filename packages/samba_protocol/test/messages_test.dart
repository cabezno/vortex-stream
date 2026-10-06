import 'package:test/test.dart';
import 'package:samba_protocol/samba_protocol.dart';

void main() {
  group('SambaMessage serialization', () {
    test('JoinMessage encode and decode', () {
      const msg = JoinMessage(peerId: 'cam1', name: 'Left Angle', role: PeerRole.camera);
      final encoded = msg.encode();
      final decoded = SambaMessage.decode(encoded);

      expect(decoded, isA<JoinMessage>());
      final join = decoded as JoinMessage;
      expect(join.peerId, 'cam1');
      expect(join.name, 'Left Angle');
      expect(join.role, PeerRole.camera);
    });

    test('AudioLevelMessage encode and decode', () {
      const msg = AudioLevelMessage(peerId: 'cam2', dbfs: -18.4);
      final encoded = msg.encode();
      final decoded = SambaMessage.decode(encoded);

      expect(decoded, isA<AudioLevelMessage>());
      final audio = decoded as AudioLevelMessage;
      expect(audio.peerId, 'cam2');
      expect(audio.dbfs, closeTo(-18.4, 0.001));
    });

    test('SetLayerMessage encode and decode', () {
      const msg = SetLayerMessage(peerId: 'cam1', layer: Layer.high);
      final encoded = msg.encode();
      final decoded = SambaMessage.decode(encoded);

      expect(decoded, isA<SetLayerMessage>());
      final setLayer = decoded as SetLayerMessage;
      expect(setLayer.peerId, 'cam1');
      expect(setLayer.layer, Layer.high);
    });

    test('RosterMessage encode and decode', () {
      final peers = [
        Peer(id: 'cam1', name: 'Camera 1', activeLayer: Layer.high),
        Peer(id: 'cam2', name: 'Camera 2', activeLayer: Layer.low),
      ];
      final msg = RosterMessage(peers: peers, activePeerId: 'cam1');
      final encoded = msg.encode();
      final decoded = SambaMessage.decode(encoded);

      expect(decoded, isA<RosterMessage>());
      final roster = decoded as RosterMessage;
      expect(roster.peers.length, 2);
      expect(roster.activePeerId, 'cam1');
      expect(roster.peers[0].id, 'cam1');
      expect(roster.peers[0].activeLayer, Layer.high);
      expect(roster.previewPeerId, isNull);
    });

    test('RosterMessage carries the preview camera (PGM/PVW)', () {
      final msg = RosterMessage(peers: [Peer(id: 'cam1', name: 'A'), Peer(id: 'cam2', name: 'B')],
          activePeerId: 'cam1', previewPeerId: 'cam2');
      final roster = SambaMessage.decode(msg.encode()) as RosterMessage;
      expect(roster.activePeerId, 'cam1');
      expect(roster.previewPeerId, 'cam2');
    });

    test('CamInfoMessage encode and decode', () {
      const msg = CamInfoMessage(peerId: 'cam1', captureDelayMs: 42, mic: 'Galaxy Buds', micDelayMs: 160,
          maxHeight: 2160, clockOffsetMs: -7);
      final info = SambaMessage.decode(msg.encode()) as CamInfoMessage;
      expect(info.peerId, 'cam1');
      expect(info.captureDelayMs, 42);
      expect(info.mic, 'Galaxy Buds');
      expect(info.micDelayMs, 160);
      expect(info.maxHeight, 2160);
      expect(info.clockOffsetMs, -7);
    });

    test('CamInfoMessage defaults for an older camera', () {
      final info = SambaMessage.decode('{"t":"cam_info","peerId":"c"}') as CamInfoMessage;
      expect(info.mic, 'phone');
      expect(info.maxHeight, 1080);
    });
  });
}
