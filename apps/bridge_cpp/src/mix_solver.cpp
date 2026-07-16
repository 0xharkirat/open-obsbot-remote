#include "mix_solver.h"

#include <algorithm>
#include <limits>

namespace mix {
namespace {

// Neighbour of `i` in a list of `n`, honouring the wrap only for a cycle.
// Returns -1 when there is no neighbour (the ends of a path).
int prev_of(int i, int n, bool is_cycle) {
    if (i > 0) return i - 1;
    return is_cycle ? n - 1 : -1;
}
int next_of(int i, int n, bool is_cycle) {
    if (i + 1 < n) return i + 1;
    return is_cycle ? 0 : -1;
}

}  // namespace

Plan solve(const std::vector<Cue>& authored,
           const std::vector<std::string>& cams,
           bool is_cycle,
           const PanCost& pan_cost,
           int default_fade_ms) {
    Plan plan;

    // Only enabled cues take part. Disabling is therefore nothing more than
    // dropping a node - the colouring and every derived "meanwhile" simply
    // re-solve around the hole. There is no re-linking code to get wrong.
    std::vector<int> live;
    for (int i = 0; i < (int)authored.size(); ++i) {
        if (authored[i].enabled) live.push_back(i);
    }
    const int n = (int)live.size();
    const int K = (int)cams.size();

    if (n == 0) return plan;
    if (K == 0) {
        plan.warnings.push_back("no cameras connected");
        return plan;
    }

    auto preset_at = [&](int i) { return authored[live[i]].preset_id; };

    // -----------------------------------------------------------------------
    // 1. Colour the nodes. colour[i] indexes into cams.
    // -----------------------------------------------------------------------
    std::vector<int> colour(n, -1);
    int pinned = 0;
    for (int i = 0; i < n; ++i) {
        const std::string& pin = authored[live[i]].pin_sn;
        if (pin.empty()) continue;
        auto it = std::find(cams.begin(), cams.end(), pin);
        if (it == cams.end()) continue;  // pinned to a camera that is not here
        colour[i] = (int)std::distance(cams.begin(), it);
        ++pinned;
    }

    if (K == 1) {
        // Nothing to alternate with. Every transition is an on-air pan.
        for (int i = 0; i < n; ++i) colour[i] = 0;
        if (n > 1) {
            plan.warnings.push_back(
                "only one camera is connected, so every transition moves on air");
        }
    } else if (pinned == 0) {
        // Clean solve. This is the interesting path.
        if (n == 1) {
            colour[0] = 0;
        } else if (!is_cycle || n % 2 == 0) {
            // A path is always 2-colourable, at any length - which is exactly
            // why ping-pong escapes the odd-loop problem. An even cycle is too.
            for (int i = 0; i < n; ++i) colour[i] = i % 2;
        } else if (K >= 3) {
            // Odd cycle, but a cycle is 3-colourable for every n >= 3. Alternate
            // and let the last node take the third camera, which breaks parity
            // on the wrap edge without touching any other edge.
            for (int i = 0; i < n; ++i) colour[i] = i % 2;
            colour[n - 1] = 2;
        } else {
            // Odd cycle, two cameras: no proper colouring exists. Exactly one
            // edge must join two cues on the same camera. We cannot avoid it,
            // but we CHOOSE it - cut the ring anywhere and the remaining path
            // 2-colours, so the cut becomes the only bad edge. Score every
            // candidate by how far that camera would really have to pan on air
            // and sacrifice the cheapest. n is tiny; brute force is the answer.
            float best_cost = std::numeric_limits<float>::max();
            int best_cut = 0, best_start = 0;
            for (int cut = 0; cut < n; ++cut) {
                const int j2 = (cut + 1) % n;
                for (int start = 0; start < 2; ++start) {
                    // Colouring the path from cut+1 leaves both ends of the cut
                    // edge on cams[start] (n is odd), so that camera does the pan.
                    const float c = pan_cost
                        ? pan_cost(cams[start], preset_at(cut), preset_at(j2))
                        : 0.0f;
                    if (c < best_cost) {
                        best_cost = c;
                        best_cut = cut;
                        best_start = start;
                    }
                }
            }
            for (int k = 0; k < n; ++k) {
                const int idx = (best_cut + 1 + k) % n;
                colour[idx] = (best_start + k) % 2;
            }
        }
    } else {
        // Some (or all) cues are pinned. A pre-2.1 saved sequence names a camera
        // on every cue, so it arrives fully pinned and is honoured verbatim -
        // it keeps behaving exactly as it always did. Fill any gaps greedily.
        for (int i = 0; i < n; ++i) {
            if (colour[i] >= 0) continue;
            const int p = prev_of(i, n, is_cycle);
            const int q = next_of(i, n, is_cycle);
            int pick = -1;
            for (int c = 0; c < K; ++c) {
                if (p >= 0 && colour[p] == c) continue;
                if (q >= 0 && colour[q] == c) continue;
                pick = c;
                break;
            }
            if (pick < 0) {
                // Boxed in by pins. Take anything that at least differs from the
                // cue before, and say so rather than quietly showing a pan.
                pick = (p >= 0 && colour[p] == 0 && K > 1) ? 1 : 0;
                plan.warnings.push_back(
                    "cue " + std::to_string(live[i] + 1) +
                    " is boxed in by pinned cameras, so its transition moves on air");
            }
            colour[i] = pick;
        }
    }

    // -----------------------------------------------------------------------
    // 2. Build the plan. A cue whose predecessor used the SAME camera has no
    //    second feed to dissolve into, so its move happens on air.
    // -----------------------------------------------------------------------
    plan.cues.resize(n);
    for (int i = 0; i < n; ++i) {
        const Cue& src = authored[live[i]];
        PlannedCue& pc = plan.cues[i];
        pc.cue_index = live[i];
        pc.camera_sn = cams[colour[i]];
        pc.preset_id = src.preset_id;
        pc.hold_s = src.hold_s < 1 ? 1 : src.hold_s;

        const int p = prev_of(i, n, is_cycle);
        pc.on_air_move = (n > 1 && p >= 0 && colour[p] == colour[i]);

        if (pc.on_air_move) {
            // There is no crossfade here - it is the same feed either side.
            // Give the pan a real duration so it reads as a cameraman following
            // the room instead of a jump cut.
            pc.fade_ms = 0;
            pc.move_ms = src.move_ms > 0 ? src.move_ms : kForcedPanMs;
            if (plan.forced_move_at < 0) plan.forced_move_at = i;
        } else {
            pc.fade_ms = src.fade_ms >= 0 ? src.fade_ms : default_fade_ms;
            // The camera was already walked here off-air by the previous cue's
            // meanwhile, so there is nothing to move.
            pc.move_ms = src.move_ms;
        }
    }

    // -----------------------------------------------------------------------
    // 3. Derive the meanwhile. While cue i is live, every OTHER camera walks to
    //    the shot it will next be live on. This is the pointer the operator used
    //    to type by hand; it was always just "the next cue that needs you".
    //    With three cameras there are two idle cameras, so it is a list.
    //
    //    Note: for ping-pong the answer depends on travel direction, so the
    //    engine recomputes it per step at run time. What we emit here is the
    //    forward pass, which is what the UI displays.
    // -----------------------------------------------------------------------
    for (int i = 0; i < n; ++i) {
        for (int c = 0; c < K; ++c) {
            if (c == colour[i]) continue;
            for (int step = 1; step < n; ++step) {
                int idx = i + step;
                if (idx >= n) {
                    if (!is_cycle) break;  // a path does not wrap
                    idx %= n;
                }
                if (colour[idx] != c) continue;
                plan.cues[i].meanwhile.push_back(Meanwhile{cams[c], preset_at(idx)});
                break;
            }
        }
    }

    // -----------------------------------------------------------------------
    // 4. Say what we did. A visible camera move the operator did not agree to
    //    is the one thing that destroys trust in a live tool.
    // -----------------------------------------------------------------------
    if (plan.forced_move_at >= 0 && pinned == 0 && K == 2 && is_cycle &&
        n % 2 == 1) {
        const PlannedCue& f = plan.cues[plan.forced_move_at];
        plan.forced_reason =
            "this loop has " + std::to_string(n) +
            " steps, which is odd, so with 2 cameras one transition has to move "
            "on air; it was placed where the pan is shortest";
        plan.warnings.push_back(
            "cue " + std::to_string(f.cue_index + 1) +
            " arrives with an on-air pan (odd loop, 2 cameras). Switch to "
            "ping-pong, or enable/disable one more cue, to remove it.");
    }

    return plan;
}

}  // namespace mix
