#include "preview_params.h"

#include <algorithm>
#include <cmath>

namespace obs::preview {

namespace {

constexpr int kMinW = 160;
constexpr int kMinFps = 1, kMaxFps = 30;
constexpr double kMinQ = 0.30, kMaxQ = 0.95;

bool is_digit(char c) { return c >= '0' && c <= '9'; }

// An optionally negative decimal integer that fills `s` exactly. Saturates far
// above every limit instead of overflowing, so a 30-digit value still clamps.
bool parse_int(std::string_view s, long long& out) {
    size_t i = 0;
    const bool neg = !s.empty() && s[0] == '-';
    if (neg) ++i;
    if (i == s.size()) return false;
    long long v = 0;
    for (; i < s.size(); ++i) {
        if (!is_digit(s[i])) return false;
        if (v < 1000000000LL) v = v * 10 + (s[i] - '0');
    }
    out = neg ? -v : v;
    return true;
}

// An optionally negative decimal number: digits, an optional `.`, more digits,
// at least 1 digit in all. No exponent, no nan, no inf. Saturates like above.
bool parse_decimal(std::string_view s, double& out) {
    size_t i = 0;
    const bool neg = !s.empty() && s[0] == '-';
    if (neg) ++i;
    double v = 0;
    bool digits = false;
    for (; i < s.size() && is_digit(s[i]); ++i) {
        digits = true;
        if (v < 1e6) v = v * 10 + (s[i] - '0');
    }
    if (i < s.size() && s[i] == '.') {
        double scale = 0.1;
        for (++i; i < s.size() && is_digit(s[i]); ++i) {
            digits = true;
            v += (s[i] - '0') * scale;
            scale /= 10;
        }
    }
    if (!digits || i != s.size()) return false;
    out = neg ? -v : v;
    return true;
}

}  // namespace

int height_for(int w) { return (w * 9 / 16) & ~1; }

std::string_view request_query(std::string_view req) {
    const size_t sp = req.find(' ');
    if (sp == std::string_view::npos) return {};
    size_t end = sp + 1;
    while (end < req.size() && req[end] != ' ' && req[end] != '\r' &&
           req[end] != '\n' && req[end] != '\0')
        ++end;
    const std::string_view target = req.substr(sp + 1, end - sp - 1);
    const size_t qm = target.find('?');
    return qm == std::string_view::npos ? std::string_view{}
                                        : target.substr(qm + 1);
}

Params parse_query(std::string_view query) {
    Params p;
    bool have_w = false, have_fps = false, have_q = false, have_t = false;
    size_t pos = 0;
    while (pos <= query.size()) {
        size_t amp = query.find('&', pos);
        if (amp == std::string_view::npos) amp = query.size();
        const std::string_view pair = query.substr(pos, amp - pos);
        pos = amp + 1;
        const size_t eq = pair.find('=');
        if (eq == std::string_view::npos) continue;
        const std::string_view key = pair.substr(0, eq);
        const std::string_view val = pair.substr(eq + 1);
        long long n = 0;
        double d = 0;
        if (key == "w" && !have_w && parse_int(val, n)) {
            have_w = true;
            p.w = (int)std::clamp<long long>(n, kMinW, kFullW) & ~1;
        } else if (key == "fps" && !have_fps && parse_int(val, n)) {
            have_fps = true;
            p.fps = (int)std::clamp<long long>(n, kMinFps, kMaxFps);
        } else if (key == "q" && !have_q && parse_decimal(val, d)) {
            have_q = true;
            p.q_pct = (int)std::lround(std::clamp(d, kMinQ, kMaxQ) * 20) * 5;
        } else if (key == "t" && !have_t) {
            have_t = true;
            p.token = std::string(val);
        }
    }
    p.h = height_for(p.w);
    return p;
}

// Rounding the interval up keeps any 1 s window at fps + 1 sends or fewer.
Pacer::Pacer(int fps)
    : interval_us_(fps > 0 ? (1000000 + fps - 1) / fps : 0) {}

bool Pacer::ready(int64_t now_us) const {
    return interval_us_ == 0 || !started_ || now_us >= deadline_us_;
}

void Pacer::sent(int64_t now_us) {
    if (interval_us_ == 0) return;
    if (!started_ || now_us - deadline_us_ > interval_us_) {
        deadline_us_ = now_us + interval_us_;   // first send, or after a stall
    } else {
        deadline_us_ += interval_us_;            // hold the cadence
    }
    started_ = true;
}

int VariantRefs::claim(const VariantKey& k) { return ++counts_[k]; }

int VariantRefs::release(const VariantKey& k) {
    auto it = counts_.find(k);
    if (it == counts_.end()) return -1;
    if (--it->second > 0) return it->second;
    counts_.erase(it);
    return 0;
}

std::vector<VariantKey> VariantRefs::live() const {
    std::vector<VariantKey> out;
    out.reserve(counts_.size());
    for (const auto& kv : counts_) out.push_back(kv.first);
    return out;
}

}  // namespace obs::preview
