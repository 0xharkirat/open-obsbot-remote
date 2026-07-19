#include "mix_solver.h"
#include <cmath>
#include <cstdio>
#include <string>
#include <vector>

static int failures = 0;
static void check(bool ok, const std::string& what) {
    std::printf("  %s %s\n", ok ? "PASS" : "FAIL", what.c_str());
    if (!ok) ++failures;
}

// Shot angles, so we can control which on-air pan is cheapest.
// 3 -> 4 is only 5 degrees apart; everything else is 90+.
static float ANG[5] = {0.f, 90.f, 180.f, 270.f, 275.f};
static mix::PanCost cost = [](const std::string&, int a, int b) {
    if (a < 0 || b < 0 || a > 4 || b > 4) return 0.f;
    return std::fabs(ANG[a] - ANG[b]);
};

static std::vector<mix::Cue> cues(std::vector<int> shots) {
    std::vector<mix::Cue> v;
    for (int s : shots) {
        mix::Cue c;
        c.preset_id = s;
        c.hold_s = 15;
        v.push_back(c);
    }
    return v;
}

static int forced_count(const mix::Plan& p) {
    int k = 0;
    for (auto& c : p.cues) if (c.on_air_move) ++k;
    return k;
}

int main() {
    const std::vector<std::string> two = {"CAM_A", "CAM_B"};
    const std::vector<std::string> three = {"CAM_A", "CAM_B", "CAM_C"};

    // ---- 1. Six cues, forward loop, 2 cams. Even cycle -> perfectly clean.
    std::printf("\n[1] n=6 even cycle, 2 cams\n");
    {
        auto p = mix::solve(cues({0, 1, 2, 3, 4, 1}), two, /*cycle=*/true, cost);
        check(p.cues.size() == 6, "6 planned cues");
        bool alt = true;
        for (int i = 0; i < 6; ++i)
            if (p.cues[i].camera_sn != two[i % 2]) alt = false;
        check(alt, "cameras alternate A,B,A,B,A,B");
        check(forced_count(p) == 0, "no on-air move anywhere");
        check(p.forced_move_at == -1, "forced_move_at == -1");

        // THE REDUNDANCY PROOF: every meanwhile is exactly the next cue.
        bool derived_equals_next = true;
        for (int i = 0; i < 6; ++i) {
            const auto& mw = p.cues[i].meanwhile;
            if (mw.size() != 1) { derived_equals_next = false; break; }
            const auto& nxt = p.cues[(i + 1) % 6];
            if (mw[0].camera_sn != nxt.camera_sn) derived_equals_next = false;
            if (mw[0].preset_id != nxt.preset_id) derived_equals_next = false;
        }
        check(derived_equals_next,
              "every meanwhile == the NEXT cue's (camera, shot)  <-- the hand-typed pointer");
    }

    // ---- 2. Five cues, forward loop, 2 cams. Odd cycle -> exactly one bad edge,
    //         and it must land on the CHEAPEST pan (shots 3->4, only 5 degrees).
    std::printf("\n[2] n=5 ODD cycle, 2 cams\n");
    {
        auto p = mix::solve(cues({0, 1, 2, 3, 4}), two, /*cycle=*/true, cost);
        check(forced_count(p) == 1, "exactly ONE on-air move (not zero, not two)");
        check(p.forced_move_at == 4, "sacrifice landed on the cheapest edge (3->4, 5 deg)");
        check(p.cues[4].camera_sn == p.cues[3].camera_sn,
              "the bad edge really is same-camera");
        check(p.cues[4].move_ms == mix::kForcedPanMs,
              "the forced pan got a real duration, not a snap");
        check(p.cues[4].fade_ms == 0, "no crossfade on a same-camera edge");
        check(!p.forced_reason.empty(), "engine explains itself");
        // every OTHER edge must still be clean
        int clean = 0;
        for (int i = 0; i < 5; ++i)
            if (!p.cues[i].on_air_move) ++clean;
        check(clean == 4, "the other 4 transitions are still crossfades");
    }

    // ---- 3. Same five cues as a PATH (ping-pong). No wrap edge -> fully clean.
    std::printf("\n[3] n=5 odd, but PING-PONG (a path)\n");
    {
        auto p = mix::solve(cues({0, 1, 2, 3, 4}), two, /*cycle=*/false, cost);
        check(forced_count(p) == 0, "odd length, yet ZERO on-air moves");
        check(p.forced_move_at == -1, "ping-pong escapes the parity problem");
    }

    // ---- 4. Odd cycle rescued by a third camera.
    std::printf("\n[4] n=5 ODD cycle, 3 cams\n");
    {
        auto p = mix::solve(cues({0, 1, 2, 3, 4}), three, /*cycle=*/true, cost);
        check(forced_count(p) == 0, "third camera removes the forced move");
        check(p.cues[4].camera_sn == "CAM_C", "last node takes the third colour");
        check(p.cues[0].meanwhile.size() == 2, "2 idle cameras => 2 meanwhile targets");
    }

    // ---- 5. Disable a step out of the six. 5 live -> odd -> one forced move.
    std::printf("\n[5] 6 cues with one DISABLED\n");
    {
        auto v = cues({0, 1, 2, 3, 4, 1});
        v[2].enabled = false;  // drop "Men Sitting"
        auto p = mix::solve(v, two, /*cycle=*/true, cost);
        check(p.cues.size() == 5, "disabled cue is dropped from the plan");
        check(forced_count(p) == 1, "5 live cues -> odd -> exactly one on-air move");
        bool maps_back = true;
        for (auto& c : p.cues) if (c.cue_index == 2) maps_back = false;
        check(maps_back, "the disabled cue never appears in the plan");
    }
    std::printf("\n[5b] same, but disable TWO -> even again\n");
    {
        auto v = cues({0, 1, 2, 3, 4, 1});
        v[2].enabled = false;
        v[5].enabled = false;
        auto p = mix::solve(v, two, /*cycle=*/true, cost);
        check(p.cues.size() == 4, "4 live cues");
        check(forced_count(p) == 0, "back to even -> clean again");
    }

    // ---- 6. Back-compat: a pre-2.1 sequence names a camera on every cue.
    std::printf("\n[6] fully pinned (pre-2.1 saved sequence)\n");
    {
        auto v = cues({0, 1, 2, 3});
        v[0].pin_sn = "CAM_B";
        v[1].pin_sn = "CAM_A";
        v[2].pin_sn = "CAM_B";
        v[3].pin_sn = "CAM_A";
        auto p = mix::solve(v, two, /*cycle=*/true, cost);
        check(p.cues[0].camera_sn == "CAM_B" && p.cues[1].camera_sn == "CAM_A" &&
              p.cues[2].camera_sn == "CAM_B" && p.cues[3].camera_sn == "CAM_A",
              "pins honoured verbatim -> old sequences behave exactly as before");
        check(forced_count(p) == 0, "and this one is still clean");
    }

    // ---- 7. Degenerate: one camera only.
    std::printf("\n[7] only ONE camera connected\n");
    {
        auto p = mix::solve(cues({0, 1, 2}), {"CAM_A"}, true, cost);
        check(forced_count(p) == 3, "every transition moves on air");
        check(!p.warnings.empty(), "and the engine warns about it");
    }

    std::printf("\n%s  (%d failure%s)\n",
                failures == 0 ? "ALL SOLVER TESTS PASS" : "SOLVER TESTS FAILED",
                failures, failures == 1 ? "" : "s");
    return failures == 0 ? 0 : 1;
}
