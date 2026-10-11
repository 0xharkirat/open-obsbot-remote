import 'package:flutter_test/flutter_test.dart';
import 'package:obsbot_bridge_mac/health.dart';

HealthInput input({
  BridgeRun bridge = BridgeRun.running,
  bool windowConnected = true,
  int camerasConnected = 2,
  int camerasTotal = 2,
  bool cameraAccessDenied = false,
  bool cameraBusy = false,
  bool obsReading = true,
  int wsClients = 2,
}) =>
    HealthInput(
      bridge: bridge,
      windowConnected: windowConnected,
      camerasConnected: camerasConnected,
      camerasTotal: camerasTotal,
      cameraAccessDenied: cameraAccessDenied,
      cameraBusy: cameraBusy,
      obsReading: obsReading,
      wsClients: wsClients,
    );

void main() {
  test('everything served reads as ready', () {
    final h = Health.from(input());
    expect(h.ready, isTrue);
    expect(h.answer, 'Ready for the service');
    expect(h.firstNeed, isNull);
    expect(h.places.map((p) => p.value), <String>['Running', '2 ready', 'Reading', '1 connected']);
  });

  test('places never move: always four, in pipeline order', () {
    for (final i in <HealthInput>[input(), input(bridge: BridgeRun.stopped), input(camerasTotal: 0)]) {
      expect(Health.from(i).places.map((p) => p.name), <String>['Bridge', 'Cameras', 'OBS', 'Phones']);
    }
  });

  test('the window itself is not counted as a phone', () {
    final h = Health.from(input(wsClients: 1));
    expect(h.places[3].state, PlaceState.needs);
    expect(h.places[3].fix, Fix.connectPhone);
    expect(h.answer, '1 thing needs you');
    expect(h.detail, 'No phone is connected.');
  });

  test('the leftmost need fills the fix panel', () {
    final h = Health.from(input(obsReading: false, wsClients: 1));
    expect(h.answer, '2 things need you');
    expect(h.firstNeed!.fix, Fix.setUpObs);
    // Every need is named, in place order, so none is hidden behind another.
    expect(h.detail, 'OBS is not connected. No phone is connected.');
    expect(h.needing.map((p) => p.fix), <Fix>[Fix.setUpObs, Fix.connectPhone]);
  });

  test('a camera held by another app is its own fix', () {
    final h = Health.from(input(cameraBusy: true));
    expect(h.places[1].value, 'In use elsewhere');
    expect(h.firstNeed!.fix, Fix.cameraBusy);
  });

  test('camera access denied wins over a missing camera', () {
    final h = Health.from(input(cameraAccessDenied: true, camerasTotal: 0, camerasConnected: 0));
    expect(h.firstNeed!.fix, Fix.cameraAccess);
  });

  test('an unplugged camera shows the count', () {
    final h = Health.from(input(camerasConnected: 1));
    expect(h.places[1].value, '1 of 2 ready');
    expect(h.firstNeed!.fix, Fix.plugCamera);
  });

  test('starting waits instead of alarming', () {
    final h = Health.from(input(bridge: BridgeRun.starting, windowConnected: false, wsClients: 0, obsReading: false));
    expect(h.answer, 'Starting the bridge');
    expect(h.needing, isEmpty);
    expect(h.places.every((p) => p.state == PlaceState.waiting), isTrue);
  });

  test('a stopped bridge asks to be started first', () {
    final h = Health.from(input(bridge: BridgeRun.error, windowConnected: false, obsReading: false, wsClients: 0));
    expect(h.firstNeed!.fix, Fix.startBridge);
    expect(h.places[0].value, 'Stopped');
  });
}
