#pragma once
#include <cstdint>
#include <map>
#include <string>
#include <string_view>
#include <vector>

// ---------------------------------------------------------------------------
// Smaller preview streams: the pure logic behind `?w=&fps=&q=` on the MJPEG
// routes. No Objective-C, no sockets, no clock - the caller passes the time -
// so a plain clang++ build tests it (tests/preview_params_test.cpp).
//
// A phone tile does not need the 1920x1080 program stream at camera rate, and
// on the venue Wi-Fi every full preview competes with the YouTube upload. A
// client asks for a smaller stream; with no parameters the route serves
// exactly what it always has, so OBS and older remotes see no change.
// ---------------------------------------------------------------------------

namespace obs::preview {

constexpr int kFullW = 1920;
constexpr int kFullQ = 85;   // JPEG quality in percent: today's 0.85

// The output height for a width: 16:9, rounded down to an even number so the
// JPEG chroma blocks line up (640 -> 360, 1001 -> 562).
int height_for(int w);

struct Params {
    int w = kFullW;     // 160..1920, even
    int h = 1080;       // height_for(w)
    int fps = 0;        // 1..30; 0 = no rate cap (the camera paces the stream)
    int q_pct = kFullQ; // 30..95, a multiple of 5
    std::string token;  // `t`, at any query position

    // True when the stream is the program frame as-is: no extra encode.
    bool full() const { return w == kFullW && q_pct == kFullQ; }
};

// The query string of an HTTP request: the text after `?` in the request
// target, up to the space before the HTTP version (or CR, LF, NUL, or the end
// of `req`). Empty when the target has no `?`.
std::string_view request_query(std::string_view req);

// Parse a query string (the part after `?`). Pairs split on `&`, each
// `key=value`. Lowercase keys only, no percent-decoding, first occurrence of a
// key wins. Unknown keys and pairs with no `=` are ignored. A malformed value
// (empty, non-numeric, trailing junk, nan, inf) is ignored as if the pair were
// absent; an out-of-range value clamps (see the field comments above).
Params parse_query(std::string_view query);

// Caps a stream's send rate at `fps`. The deadline advances by a fixed 1/fps
// step from the previous deadline, so a 25 fps camera at fps=10 averages 10,
// not the 8.3 a "now >= last send + 1/fps" rule gives. After a stall longer
// than 1 interval the deadline resets to 1 interval after the send, so the
// pacer never sends a catch-up burst. fps 0 = no cap.
class Pacer {
public:
    explicit Pacer(int fps);
    // True when a frame may go out at `now_us` (any monotonic microseconds).
    bool ready(int64_t now_us) const;
    // Record a frame sent at `now_us`.
    void sent(int64_t now_us);

private:
    int64_t interval_us_ = 0;   // 0 = no cap
    int64_t deadline_us_ = 0;
    bool started_ = false;
};

// One small encode per camera: the (width, quality) pair. fps is not part of
// the key - every stream paces itself off the shared encode.
struct VariantKey {
    int w = kFullW;
    int q_pct = kFullQ;
    bool operator<(const VariantKey& o) const {
        return w != o.w ? w < o.w : q_pct < o.q_pct;
    }
    bool operator==(const VariantKey& o) const {
        return w == o.w && q_pct == o.q_pct;
    }
};

// Reference count of the open streams per variant of one camera. A variant is
// live while its count is above 0. Not thread-safe: the owner locks.
class VariantRefs {
public:
    // Returns the client count after the claim (1 = the variant just started).
    int claim(const VariantKey& k);
    // Returns the client count after the release (0 = the variant just
    // stopped), or -1 when `k` held no claim.
    int release(const VariantKey& k);
    // The keys with at least 1 claim.
    std::vector<VariantKey> live() const;

private:
    std::map<VariantKey, int> counts_;
};

}  // namespace obs::preview
