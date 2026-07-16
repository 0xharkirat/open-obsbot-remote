#pragma once
#include <functional>
#include <string>
#include <vector>

// ---------------------------------------------------------------------------
// The mix camera-assignment solver.
//
// The operator authors SHOTS in order. This decides which camera takes each
// one. The rule that generates everything else: a crossfade dissolves between
// two camera feeds, so every crossfade swaps which camera is live. Therefore
// two consecutive cues can never use the same camera - otherwise there is no
// second feed to dissolve into and the camera must pan ON AIR to reach the
// next shot, which is exactly what owning two cameras exists to avoid.
//
// That is proper 2-colouring of a graph. In a forward loop the cue list is a
// CYCLE, and a cycle is 2-colourable if and only if it has an EVEN number of
// nodes. So:
//
//   path (ping-pong / once) .. always clean, any length (paths are bipartite)
//   even cycle .............. always clean
//   odd cycle, 3+ cameras ... clean (cycles are 3-colourable for all n >= 3)
//   odd cycle, 2 cameras .... impossible. Exactly ONE edge must join two cues
//                             on the same camera. We cannot remove it, but we
//                             CHOOSE it: cut the ring at any edge and the rest
//                             2-colours, so the cut edge becomes the only bad
//                             one. Score every candidate by how far the camera
//                             would actually have to pan on air, and sacrifice
//                             the cheapest. n is tiny, so brute force it.
//
// The engine must then SAY what it did. A visible camera move the operator did
// not agree to is the one thing that destroys trust in a live tool.
// ---------------------------------------------------------------------------

namespace mix {

// A cue as authored. There is deliberately no camera and no "meanwhile" here:
// both are derived. `pin_sn` is the escape hatch, and it is also what makes
// pre-2.1 saved sequences (which named a camera on every cue) keep working -
// they simply arrive fully pinned and the solver honours them verbatim.
struct Cue {
    int preset_id = -1;      // the shot. <0 = hold whatever the camera has.
    int hold_s = 10;
    bool enabled = true;
    int fade_ms = -1;        // <0 = inherit the sequence default. 0 = hard cut.
    int move_ms = 0;         // pan duration, used only when a move lands on air.
    std::string pin_sn;      // empty = derive the camera. set = pin it.
};

// One idle camera being walked to its next shot while somebody else is live.
struct Meanwhile {
    std::string camera_sn;
    int preset_id = -1;
};

// What the engine will actually do for one cue.
struct PlannedCue {
    int cue_index = -1;          // index into the AUTHORED list, so the UI can map back
    std::string camera_sn;       // derived, or the pin
    int preset_id = -1;
    int hold_s = 10;
    int fade_ms = 0;
    bool on_air_move = false;    // previous cue used the SAME camera: this pan is visible
    int move_ms = 0;
    std::vector<Meanwhile> meanwhile;  // one per idle camera. 3 cams => 2 entries.
};

struct Plan {
    std::vector<PlannedCue> cues;
    // Index into `cues` whose arrival is a forced on-air pan (-1 = none). This
    // is the sacrificed edge from the odd-cycle case.
    int forced_move_at = -1;
    std::string forced_reason;
    std::vector<std::string> warnings;
};

// Cost of panning `sn` from one preset to another, in degrees. Used only to
// choose which edge to sacrifice. Return 0 when unknown; the solver then just
// picks the first candidate, which is still correct, only less graceful.
using PanCost = std::function<float(const std::string& sn, int from_preset, int to_preset)>;

// `cams` is the connected camera roster. `is_cycle` is true for a forward loop
// (the list wraps), false for ping-pong and once (the list is a path, and a
// path has no wrap edge to violate - which is why ping-pong is the free escape
// hatch from the odd-loop problem).
Plan solve(const std::vector<Cue>& authored,
           const std::vector<std::string>& cams,
           bool is_cycle,
           const PanCost& pan_cost,
           int default_fade_ms = 500);

// A pan that is forced on air gets this duration when the cue asked for an
// instant move. A snap between two shots reads as a jump cut; a slow eased pan
// between two neighbouring shots reads as a cameraman following the room. If we
// are made to show the move, show a good one.
constexpr int kForcedPanMs = 3000;

}  // namespace mix
