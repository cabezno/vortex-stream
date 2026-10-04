import 'package:test/test.dart';
import 'package:samba_protocol/samba_protocol.dart';

void main() {
  group('AudioSwitcherEngine algorithmic logic', () {
    test('Onset hold filtering: requires sustained volume above threshold', () {
      final config = SwitcherConfig(
        autoSwitch: true,
        onsetMs: 80.0,
        thresholdDbfs: -40.0,
      );

      final engine = AudioSwitcherEngine(config: config);
      engine.setPeers(['cam1']);

      // 1. Audio at -30 dBFS (> -40 dBFS) but only for 50ms (< 80ms)
      engine.feedRms({'cam1': -30.0}, 50.0);
      expect(engine.tracks.first.active, isFalse, reason: 'Must not trigger before 80ms onset');

      // 2. Another 40ms continuous (total 90ms >= 80ms)
      engine.feedRms({'cam1': -30.0}, 40.0);
      expect(engine.tracks.first.active, isTrue, reason: 'Must activate after fulfilling 80ms onset');

      // 3. Drops below threshold
      engine.feedRms({'cam1': -55.0}, 20.0);
      expect(engine.tracks.first.active, isFalse, reason: 'Must deactivate immediately on level drop');
    });

    test('Switching rules: single speaker, anti-chatter, overlap, silence', () {
      final config = SwitcherConfig(
        autoSwitch: true,
        holdSec: 1.0,
        silenceSec: 2.0,
        silencePeerId: 'cam_wide',
        overlapPeerId: 'cam_split',
      );

      final events = <SwitchEvent>[];
      final engine = AudioSwitcherEngine(
        config: config,
        onSwitch: (e) => events.add(e),
      );
      engine.setPeers(['cam1', 'cam2', 'cam_wide', 'cam_split']);
      engine.setActivePeer('cam_init', resetHoldTimer: false);

      // Speaker 1 active sustained
      engine.feedRms({'cam1': -20.0, 'cam2': -60.0}, 100.0);
      final res1 = engine.tick(0.1);
      expect(res1, isNotNull);
      expect(res1!.targetPeerId, 'cam1');
      expect(events.length, 1);
      expect(events.last.targetPeerId, 'cam1');

      // Anti-chatter: speaker 2 starts speaking, but only 0.5s passed (< holdSec of 1.0s)
      engine.feedRms({'cam1': -60.0, 'cam2': -20.0}, 100.0);
      final resHold = engine.tick(0.5);
      expect(resHold, isNull, reason: 'Anti-chatter must hold the current scene');
      expect(events.length, 1);

      // Now pass hold_time (0.6s + 0.5s = 1.1s > 1.0s) -> Switch to cam2!
      final resSwitch = engine.tick(0.6);
      expect(resSwitch, isNotNull);
      expect(resSwitch!.targetPeerId, 'cam2');
      expect(events.length, 2);
      expect(events.last.targetPeerId, 'cam2');

      // Overlap: both speak at the same time -> should switch to cam_split
      // (Wait for holdSec first)
      engine.tick(1.1);
      engine.feedRms({'cam1': -15.0, 'cam2': -18.0}, 100.0);
      final resOverlap = engine.tick(0.1);
      expect(resOverlap, isNotNull);
      expect(resOverlap!.targetPeerId, 'cam_split');
      expect(events.last.targetPeerId, 'cam_split');

      // Silence: total silence for 2.5s (> silenceSec 2.0s) -> should switch to cam_wide
      engine.tick(1.1); // satisfy hold timer
      engine.feedRms({'cam1': -70.0, 'cam2': -70.0}, 100.0);
      final resSilence = engine.tick(2.5);
      expect(resSilence, isNotNull);
      expect(resSilence!.targetPeerId, 'cam_wide');
      expect(events.last.targetPeerId, 'cam_wide');
    });

    test('Loudest tie-breaker when overlapPeerId is null', () {
      final config = SwitcherConfig(
        autoSwitch: true,
        holdSec: 0.5,
        overlapPeerId: null, // No overlap scene, use loudest
      );

      final engine = AudioSwitcherEngine(config: config);
      engine.setPeers(['cam1', 'cam2']);
      engine.setActivePeer('cam1');

      // Let holdSec elapse
      engine.tick(0.6);

      // Both are active (> -40 dBFS), but cam2 (-12 dBFS) is louder than cam1 (-25 dBFS)
      engine.feedRms({'cam1': -25.0, 'cam2': -12.0}, 100.0);
      final res = engine.tick(0.1);
      expect(res, isNotNull);
      expect(res!.targetPeerId, 'cam2');
      expect(res.reason, contains('Desempate por volumen'));
    });
  });
}
