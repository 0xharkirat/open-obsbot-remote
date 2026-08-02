#pragma once
#include <cstdio>
#include <cstdarg>
#include <cstdlib>
#include <chrono>
#include <ctime>
#include <mutex>
#include <string>

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

// Append one line straight to ~/Library/Logs/Open OBSBOT Bridge/bridge.log,
// bypassing stderr.
//
// Everything else logs to stderr, which the Flutter supervisor reads off a pipe
// and writes to that file for us. That works right up until the moment the
// supervisor is the thing that died - and the parent-death watchdog runs
// exactly then, so its one diagnostic line would go to a pipe with no reader
// and be lost. Without this, a watchdog exit is indistinguishable from a crash
// when reading the log after the fact.
inline void log_line_to_file(const char* msg) {
    const char* home = std::getenv("HOME");
    if (home == nullptr) return;
    std::string path = std::string(home) +
        "/Library/Logs/Open OBSBOT Bridge/bridge.log";
    std::FILE* f = std::fopen(path.c_str(), "a");
    if (f == nullptr) return;
    auto now = std::chrono::system_clock::now();
    auto t = std::chrono::system_clock::to_time_t(now);
    char timebuf[32];
    std::tm tm_buf{};
    localtime_r(&t, &tm_buf);
    std::strftime(timebuf, sizeof(timebuf), "%H:%M:%S", &tm_buf);
    std::fprintf(f, "[%s info ] %s\n", timebuf, msg);
    std::fflush(f);   // _Exit skips stream flushing, so do it here
    std::fclose(f);
}

#define LOGI(...) ::obs::log("info ", __VA_ARGS__)
#define LOGW(...) ::obs::log("warn ", __VA_ARGS__)
#define LOGE(...) ::obs::log("error", __VA_ARGS__)
#define LOGD(...) ::obs::log("debug", __VA_ARGS__)

void install_sdk_log_handler();

}
