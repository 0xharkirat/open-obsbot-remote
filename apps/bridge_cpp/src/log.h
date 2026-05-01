#pragma once
#include <cstdio>
#include <cstdarg>
#include <chrono>
#include <mutex>

namespace obs {

inline std::mutex& log_mutex() {
    static std::mutex m;
    return m;
}

inline void log(const char* level, const char* fmt, ...) {
    std::lock_guard<std::mutex> g(log_mutex());
    auto now = std::chrono::system_clock::now();
    auto t = std::chrono::system_clock::to_time_t(now);
    auto ms = std::chrono::duration_cast<std::chrono::milliseconds>(now.time_since_epoch()).count() % 1000;
    char timebuf[32];
    std::tm tm_buf{};
    localtime_r(&t, &tm_buf);
    std::strftime(timebuf, sizeof(timebuf), "%H:%M:%S", &tm_buf);
    std::fprintf(stderr, "[%s.%03lld %s] ", timebuf, (long long)ms, level);
    va_list args;
    va_start(args, fmt);
    std::vfprintf(stderr, fmt, args);
    va_end(args);
    std::fputc('\n', stderr);
    std::fflush(stderr);
}

#define LOGI(...) ::obs::log("info ", __VA_ARGS__)
#define LOGW(...) ::obs::log("warn ", __VA_ARGS__)
#define LOGE(...) ::obs::log("error", __VA_ARGS__)
#define LOGD(...) ::obs::log("debug", __VA_ARGS__)

void install_sdk_log_handler();

}
