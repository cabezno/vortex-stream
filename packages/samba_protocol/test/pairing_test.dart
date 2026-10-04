import 'package:test/test.dart';
import 'package:samba_protocol/samba_protocol.dart';

void main() {
  group('PairingPayload tests', () {
    test('parses JSON payload from Switcher QR modal', () {
      const jsonStr = '{"ip":"192.168.1.42","port":8088,"room":"samba_studio"}';
      final payload = PairingPayload.parse(jsonStr);

      expect(payload.ip, '192.168.1.42');
      expect(payload.port, 8088);
      expect(payload.room, 'samba_studio');
      expect(payload.wsUrl, 'ws://192.168.1.42:8088/ws');
    });

    test('parses WebSocket URI format', () {
      const uriStr = 'ws://10.0.0.15:8090/ws';
      final payload = PairingPayload.parse(uriStr);

      expect(payload.ip, '10.0.0.15');
      expect(payload.port, 8090);
      expect(payload.wsUrl, 'ws://10.0.0.15:8090/ws');
    });

    test('parses host:port format', () {
      const hostPort = '192.168.43.1:9000';
      final payload = PairingPayload.parse(hostPort);

      expect(payload.ip, '192.168.43.1');
      expect(payload.port, 9000);
      expect(payload.wsUrl, 'ws://192.168.43.1:9000/ws');
    });

    test('parses bare IP address with default port', () {
      const bareIp = '192.168.1.105';
      final payload = PairingPayload.parse(bareIp);

      expect(payload.ip, '192.168.1.105');
      expect(payload.port, 8088);
      expect(payload.wsUrl, 'ws://192.168.1.105:8088/ws');
    });

    test('roundtrips toJson and fromJson', () {
      const original = PairingPayload(ip: '172.20.10.2', port: 8088, room: 'mobile_live');
      final json = original.toJson();
      final restored = PairingPayload.fromJson(json);

      expect(restored.ip, original.ip);
      expect(restored.port, original.port);
      expect(restored.room, original.room);
    });
  });
}
