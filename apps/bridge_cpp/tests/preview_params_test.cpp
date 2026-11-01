#include "preview_params.h"
#include <cstdint>
#include <cstdio>
#include <string>
#include <vector>

using namespace obs::preview;

static int failures = 0;
static void check(bool ok, const std::string& what) {
    std::printf("  %s %s\n", ok ? "PASS" : "FAIL", what.c_str());
    if (!ok) ++failures;
}

static Params q(const std::string& query) { return parse_query(query); }
static Params req(const std::string& request) {
    return parse_query(request_query(request));
}
static bool size_is(const Params& p, int w, int h) { return p.w == w && p.h == h; }
static bool defaults(const Params& p) {
    return p.w == 1920 && p.h == 1080 && p.fps == 0 && p.q_pct == 85 &&
           p.token.empty() && p.full();
}

// Feed the pacer a camera's frame times: each frame goes out when the pacer is
// ready at its arrival, else it is skipped. Returns the send times in
// microseconds. Frames stop arriving during [stall_from_us, stall_to_us).
static std::vector<int64_t> simulate(int src_fps, int cap_fps, int64_t secs,
                                     int64_t stall_from_us = -1,
                                     int64_t stall_to_us = -1) {
    Pacer pacer(cap_fps);
    std::vector<int64_t> sends;
    for (int64_t i = 0;; ++i) {
        const int64_t t = i * 1000000 / src_fps;
        if (t >= secs * 1000000) break;
        if (t >= stall_from_us && t < stall_to_us) continue;
        if (!pacer.ready(t)) continue;
        sends.push_back(t);
        pacer.sent(t);
    }
    return sends;
}

// The most sends in any half-open 1 s window.
static int max_per_second(const std::vector<int64_t>& sends) {
    int best = 0;
    for (size_t i = 0; i < sends.size(); ++i) {
        int n = 0;
        for (size_t j = i; j < sends.size() && sends[j] < sends[i] + 1000000; ++j) ++n;
        if (n > best) best = n;
    }
    return best;
}

int main() {
    // ---- 1. Size: clamp 160..1920, even width, 16:9 even height.
    std::printf("\n[1] w clamps and sets a 16:9 height\n");
    check(size_is(q("w=640"), 640, 360), "w=640 -> 640x360");
    check(size_is(q("w=960"), 960, 540), "w=960 -> 960x540");
    check(size_is(q("w=99999"), 1920, 1080), "w=99999 -> 1920x1080");
    check(size_is(q("w=-5"), 160, 90), "w=-5 -> 160x90");
    check(size_is(q("w=1001"), 1000, 562), "w=1001 -> 1000x562");
    check(size_is(q("w=160"), 160, 90), "w=160 -> 160x90");
    check(size_is(q("w=1920"), 1920, 1080), "w=1920 -> 1920x1080");
    check(size_is(q("w=0"), 160, 90), "w=0 -> 160x90");

    // ---- 2. Malformed values are ignored, as if absent.
    std::printf("\n[2] malformed values give the default\n");
    check(q("w=abc").w == 1920, "w=abc -> default width");
    check(q("w=").w == 1920, "w= -> default width");
    check(q("w=640px").w == 1920, "w=640px -> default width");
    check(q("w=6.4").w == 1920, "w=6.4 -> default width");
    check(q("w=-").w == 1920, "w=- -> default width");
    check(q("q=nan").q_pct == 85, "q=nan -> default quality");
    check(q("q=inf").q_pct == 85, "q=inf -> default quality");
    check(q("q=").q_pct == 85, "q= -> default quality");
    check(q("q=.").q_pct == 85, "q=. -> default quality");
    check(q("q=0.6x").q_pct == 85, "q=0.6x -> default quality");
    check(q("q=1e3").q_pct == 85, "q=1e3 -> default quality");
    check(q("fps=ten").fps == 0, "fps=ten -> no rate cap");
    check(q("fps= 10").fps == 0, "fps=<space>10 -> no rate cap");

    // ---- 3. fps and q clamp; q rounds to the nearest 0.05.
    std::printf("\n[3] fps and q clamp\n");
    check(q("fps=0").fps == 1, "fps=0 -> 1");
    check(q("fps=500").fps == 30, "fps=500 -> 30");
    check(q("fps=-3").fps == 1, "fps=-3 -> 1");
    check(q("fps=10").fps == 10, "fps=10 -> 10");
    check(q("q=2").q_pct == 95, "q=2 -> 0.95");
    check(q("q=0.1").q_pct == 30, "q=0.1 -> 0.3");
    check(q("q=0.62").q_pct == 60, "q=0.62 -> 0.6");
    check(q("q=0.63").q_pct == 65, "q=0.63 -> 0.65");
    check(q("q=.7").q_pct == 70, "q=.7 -> 0.7");
    check(q("q=-1").q_pct == 30, "q=-1 -> 0.3");

    // ---- 4. Overflow, repeats, unknown keys, empty query.
    std::printf("\n[4] hostile and odd queries\n");
    const std::string digits30 = "123456789012345678901234567890";
    check(size_is(q("w=" + digits30), 1920, 1080), "30-digit w -> 1920");
    check(size_is(q("w=-" + digits30), 160, 90), "30-digit negative w -> 160");
    check(q("fps=" + digits30).fps == 30, "30-digit fps -> 30");
    check(q("q=" + std::string(400, '9')).q_pct == 95, "400-digit q -> 0.95");
    check(q("q=0." + std::string(400, '6')).q_pct == 65, "400 decimals q -> 0.65");
    check(q("w=640&w=960").w == 640, "repeated w keeps the first value");
    check(q("w=abc&w=960").w == 960, "a malformed first w counts as absent");
    check(q("foo=1&w=640").w == 640 && q("foo=1&w=640").fps == 0,
          "unknown key ignored");
    check(defaults(q("")), "empty query -> all defaults");
    check(defaults(q("&&&")), "only separators -> all defaults");
    check(q("W=640").w == 1920, "uppercase key ignored");
    check(q("w&fps=10").w == 1920 && q("w&fps=10").fps == 10,
          "pair with no = ignored");
    check(q("=640&w=640").w == 640, "empty key ignored");
    // A view that stops mid-buffer: the parser must not read past its end.
    const std::string longer = "w=640&fps=10";
    const Params cut = parse_query(std::string_view(longer.data(), 4));
    check(cut.w == 160 && cut.fps == 0, "parser stops at the view end (w=64)");
    // Deterministic fuzz: random bytes from the query alphabet, invariants hold.
    uint32_t seed = 12345;
    bool fuzz_ok = true;
    const char alphabet[] = "wfpsqt=&.-0123456789naiex%+ ";
    for (int i = 0; i < 20000 && fuzz_ok; ++i) {
        std::string s;
        const int len = (int)(seed % 40);
        for (int k = 0; k < len; ++k) {
            seed = seed * 1103515245u + 12345u;
            s += alphabet[(seed >> 16) % (sizeof(alphabet) - 1)];
        }
        seed = seed * 1103515245u + 12345u;
        const Params p = q(s);
        fuzz_ok = p.w >= 160 && p.w <= 1920 && p.w % 2 == 0 &&
                  p.h == height_for(p.w) && p.fps >= 0 && p.fps <= 30 &&
                  p.q_pct >= 30 && p.q_pct <= 95 && p.q_pct % 5 == 0;
    }
    check(fuzz_ok, "20000 random queries keep every value in range");

    // ---- 5. The request target and the token at any position.
    std::printf("\n[5] request target and token\n");
    {
        auto a = req("GET /preview/active.mjpg?t=abc&w=640 HTTP/1.1\r\n\r\n");
        check(a.token == "abc" && a.w == 640, "?t=abc&w=640 -> token abc, w 640");
        auto b = req("GET /preview/active.mjpg?w=640&t=abc HTTP/1.1\r\n\r\n");
        check(b.token == "abc" && b.w == 640, "?w=640&t=abc -> token abc, w 640");
        auto c = req("GET /preview.mjpeg HTTP/1.1\r\nReferer: http://x/?t=abc\r\n");
        check(c.token.empty(), "a ?t= in a header is not the token");
        auto d = req("GET /preview/SN1.mjpg?t=abc&t=def HTTP/1.1\r\n");
        check(d.token == "abc", "repeated t keeps the first");
        check(request_query("").empty() && request_query("GET").empty() &&
              request_query("GET /x?").empty(),
              "truncated request lines give an empty query");
        check(request_query("GET /x?w=640").compare("w=640") == 0,
              "a request cut before the HTTP version still parses");
    }

    // ---- 6. full(): no extra encode for the program size and quality.
    std::printf("\n[6] full stream detection\n");
    check(q("fps=10").full() && q("fps=10").fps == 10,
          "fps alone keeps the full stream, rate capped");
    check(q("w=1920&q=0.86").full(), "w=1920 q=0.86 rounds to the full stream");
    check(!q("w=640").full(), "w=640 is a small stream");
    check(!q("q=0.6").full(), "q=0.6 at full width is a separate encode");

    // ---- 7. Pacer.
    std::printf("\n[7] pacer\n");
    {
        auto s = simulate(25, 10, 10);
        check(s.size() >= 95 && s.size() <= 105,
              "25 fps at fps=10: " + std::to_string(s.size()) + " frames in 10 s (95..105)");
        check(max_per_second(s) <= 11,
              "25 fps at fps=10: max " + std::to_string(max_per_second(s)) + " in any 1 s");
        auto t = simulate(30, 10, 10);
        check(t.size() >= 99 && t.size() <= 101,
              "30 fps at fps=10: " + std::to_string(t.size()) + " frames in 10 s (99..101)");
        check(max_per_second(t) <= 11, "30 fps at fps=10: max 11 in any 1 s");
        auto e = simulate(8, 10, 10);
        check(e.size() == 80, "8 fps at fps=10: every frame (" +
                                  std::to_string(e.size()) + "/80)");
        auto st = simulate(25, 10, 10, 3000000, 5000000);
        check(max_per_second(st) <= 11,
              "after a 2 s stall: max " + std::to_string(max_per_second(st)) + " in any 1 s");
        auto u = simulate(30, 30, 10);
        check(max_per_second(u) <= 31, "30 fps at fps=30: max 31 in any 1 s");
        Pacer none(0);
        bool always = true;
        for (int64_t t2 = 0; t2 < 1000; ++t2) {
            always = always && none.ready(t2);
            none.sent(t2);
        }
        check(always, "fps=0 never holds a frame back");
    }

    // ---- 8. Shared-encode reference count.
    std::printf("\n[8] variant reference count\n");
    {
        VariantRefs refs;
        const VariantKey a{640, 60}, b{640, 70};
        check(refs.claim(a) == 1, "first claim starts the variant (count 1)");
        check(refs.claim(a) == 2, "second claim of the same (w, q) shares it");
        check(refs.live().size() == 1, "2 claims of the same (w, q) -> 1 live variant");
        refs.claim(b);
        check(refs.live().size() == 2, "a different q -> 2 live variants");
        check(refs.release(a) == 1 && refs.live().size() == 2,
              "releasing 1 of 2 claims keeps the variant");
        check(refs.release(a) == 0, "the last release stops the variant (count 0)");
        check(refs.release(b) == 0, "releasing b stops it");
        check(refs.live().empty(), "0 live variants after every release");
        check(refs.release(a) == -1 && refs.live().empty(),
              "releasing an unclaimed variant is a no-op");
    }

    std::printf("\n%s  (%d failure%s)\n",
                failures == 0 ? "ALL PREVIEW PARAMS TESTS PASS"
                              : "PREVIEW PARAMS TESTS FAILED",
                failures, failures == 1 ? "" : "s");
    return failures == 0 ? 0 : 1;
}
