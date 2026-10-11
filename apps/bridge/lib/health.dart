/// The bridge window's one question, "is everything OK for the service?",
/// answered from four set places: Bridge, Cameras, OBS and Phones.
///
/// Pure logic, no Flutter: the window and the tests build a [HealthInput]
/// from the supervisor and the local WebSocket client, and render whatever
/// [Health] decides.
library;

enum PlaceState { served, waiting, needs }

/// What the fix panel shows for the place that needs the user.
enum Fix {
  startBridge,
  plugCamera,
  cameraAccess,
  cameraBusy,
  setUpObs,
  connectPhone,
}

class Place {
  const Place(this.name, this.state, this.value, [this.fix]);

  final String name;
  final PlaceState state;

  /// The real value behind the state, never a bare "OK".
  final String value;

  /// Set only when [state] is [PlaceState.needs].
  final Fix? fix;
}

enum BridgeRun { starting, running, stopped, error }

class HealthInput {
  const HealthInput({
    required this.bridge,
    this.bridgeError,
    required this.windowConnected,
    required this.camerasConnected,
    required this.camerasTotal,
    required this.cameraAccessDenied,
    required this.cameraBusy,
    required this.obsReading,
    required this.wsClients,
  });

  final BridgeRun bridge;
  final String? bridgeError;

  /// The window's own WebSocket client is connected (it counts as one of
  /// [wsClients], and it is how the window knows the camera list).
  final bool windowConnected;
  final int camerasConnected;
  final int camerasTotal;
  final bool cameraAccessDenied;
  final bool cameraBusy;
  final bool obsReading;
  final int wsClients;
}

class Health {
  Health(this.places);

  factory Health.from(HealthInput i) {
    final up = i.bridge == BridgeRun.running;

    final bridge = switch (i.bridge) {
      BridgeRun.running => const Place('Bridge', PlaceState.served, 'Running'),
      BridgeRun.starting => const Place('Bridge', PlaceState.waiting, 'Starting'),
      BridgeRun.stopped => const Place('Bridge', PlaceState.needs, 'Stopped', Fix.startBridge),
      BridgeRun.error => const Place('Bridge', PlaceState.needs, 'Stopped', Fix.startBridge),
    };

    final Place cameras;
    if (!up || !i.windowConnected) {
      cameras = const Place('Cameras', PlaceState.waiting, 'Waiting');
    } else if (i.cameraAccessDenied) {
      cameras = const Place('Cameras', PlaceState.needs, 'No access', Fix.cameraAccess);
    } else if (i.cameraBusy) {
      cameras = const Place('Cameras', PlaceState.needs, 'In use elsewhere', Fix.cameraBusy);
    } else if (i.camerasTotal == 0) {
      cameras = const Place('Cameras', PlaceState.needs, 'None found', Fix.plugCamera);
    } else if (i.camerasConnected < i.camerasTotal) {
      cameras = Place('Cameras', PlaceState.needs,
          '${i.camerasConnected} of ${i.camerasTotal} ready', Fix.plugCamera);
    } else {
      cameras = Place('Cameras', PlaceState.served,
          i.camerasTotal == 1 ? '1 ready' : '${i.camerasTotal} ready');
    }

    final Place obs;
    if (!up) {
      obs = const Place('OBS', PlaceState.waiting, 'Waiting');
    } else if (i.obsReading) {
      obs = const Place('OBS', PlaceState.served, 'Reading');
    } else {
      obs = const Place('OBS', PlaceState.needs, 'Not connected', Fix.setUpObs);
    }

    final Place phones;
    final phonesNow = (i.wsClients - (i.windowConnected ? 1 : 0)).clamp(0, 99);
    if (!up) {
      phones = const Place('Phones', PlaceState.waiting, 'Waiting');
    } else if (phonesNow > 0) {
      phones = Place('Phones', PlaceState.served,
          phonesNow == 1 ? '1 connected' : '$phonesNow connected');
    } else {
      phones = const Place('Phones', PlaceState.needs, 'None connected', Fix.connectPhone);
    }

    return Health(<Place>[bridge, cameras, obs, phones]);
  }

  /// Always four, always in this order: places never move.
  final List<Place> places;

  List<Place> get needing =>
      places.where((p) => p.state == PlaceState.needs).toList();

  /// The leftmost place that needs the user. Its fix fills the panel.
  Place? get firstNeed {
    final n = needing;
    return n.isEmpty ? null : n.first;
  }

  bool get starting =>
      places.first.state == PlaceState.waiting;

  bool get ready => places.every((p) => p.state == PlaceState.served);

  /// The one sentence in the runner band.
  String get answer {
    if (starting) return 'Starting the bridge';
    final n = needing.length;
    if (n == 0) return 'Ready for the service';
    return n == 1 ? '1 thing needs you' : '$n things need you';
  }

  /// The plain line under it: every need, in place order, one short
  /// sentence each.
  String get detail {
    if (starting) return 'This takes a few seconds.';
    final n = needing;
    if (n.isEmpty) return 'The cameras, OBS and phones are all connected.';
    return n.map((p) => sentenceFor(p.fix!)).join(' ');
  }

  static String sentenceFor(Fix fix) => switch (fix) {
        Fix.startBridge => 'The bridge is not running.',
        Fix.plugCamera => 'A camera is not connected.',
        Fix.cameraAccess => 'This computer blocks camera access.',
        Fix.cameraBusy => 'A different app is using the camera.',
        Fix.setUpObs => 'OBS is not connected.',
        Fix.connectPhone => 'No phone is connected.',
      };
}
