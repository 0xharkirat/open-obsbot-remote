#include "log.h"
#include <util/comm.hpp>
#include <cstdio>

namespace obs {

static void sdk_log_handler(int32_t lvl, const char* msg, va_list args, void* /*p*/) {
    const char* level = "info ";
    switch (lvl) {
        case DEV_ERROR: level = "error"; break;
        case DEV_WARN:  level = "warn "; break;
        case DEV_INFO:  level = "info "; break;
        case DEV_DEBUG: level = "debug"; break;
    }
    std::lock_guard<std::mutex> g(log_mutex());
    std::fprintf(stderr, "[sdk %s] ", level);
    std::vfprintf(stderr, msg, args);
    std::fputc('\n', stderr);
    std::fflush(stderr);
}

void install_sdk_log_handler() {
    dev_set_log_handler(sdk_log_handler, nullptr);
}

}
