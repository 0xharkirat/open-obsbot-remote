#pragma once

// Small filesystem helpers shared by the parts of the bridge that write to
// disk: the auth store, the H.264 segment cache, and the recorder.
//
// This exists because `make_dirs` had drifted into two near-identical copies
// with different modes and different error handling, and the recorder would
// have made a third. Header-only and inline, so it stays one translation unit
// per caller and needs no CMake change.

#include <sys/stat.h>
#include <sys/statvfs.h>

#include <cerrno>
#include <cstdint>
#include <string>

namespace obs {
namespace fsutil {

// mkdir -p. Returns false only when a component could not be created for a
// reason other than already existing.
//
// `mode` matters: the auth store holds tokens and wants 0700, while a segment
// cache or recording directory is ordinary content at 0755. Defaulting to the
// restrictive one would be the safer mistake, but it would also silently make
// recordings unreadable by anything but the service account, so the caller
// states what it wants.
inline bool make_dirs(const std::string& path, mode_t mode = 0755) {
    if (path.empty()) return false;
    std::string acc;
    size_t i = 0;
    if (path[0] == '/') { acc = "/"; i = 1; }
    while (i <= path.size()) {
        const size_t slash = path.find('/', i);
        const std::string part =
            path.substr(i, slash == std::string::npos ? std::string::npos : slash - i);
        if (!part.empty()) {
            if (!acc.empty() && acc.back() != '/') acc += '/';
            acc += part;
            if (::mkdir(acc.c_str(), mode) != 0 && errno != EEXIST) return false;
        }
        if (slash == std::string::npos) break;
        i = slash + 1;
    }
    return true;
}

// Free space on the volume containing `path`, in bytes. Returns 0 when the
// path cannot be stat'd, which callers should treat as "refuse" rather than
// "unlimited": a missing directory reading as infinite space is exactly the
// wrong way round.
//
// f_bavail rather than f_bfree, because the reserved blocks f_bfree includes
// are not available to a non-root writer, and the recorder is not root.
inline uint64_t free_bytes(const std::string& path) {
    struct statvfs st{};
    if (::statvfs(path.c_str(), &st) != 0) return 0;
    return static_cast<uint64_t>(st.f_bavail) * static_cast<uint64_t>(st.f_frsize);
}

}  // namespace fsutil
}  // namespace obs
