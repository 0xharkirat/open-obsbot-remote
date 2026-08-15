#include "auth.h"
#include "log.h"

#include <json.hpp>

#include <cstdlib>
#include <fstream>
#include <random>
#include <sstream>
#include <sys/stat.h>

namespace obs {

// mkdir -p for one path, ignoring "already exists". Only used for the auth
// store's parent, so it does not need to be general.
static void make_dirs(const std::string& dir) {
    std::string acc;
    size_t i = 0;
    if (!dir.empty() && dir[0] == '/') { acc = "/"; i = 1; }
    while (i <= dir.size()) {
        size_t slash = dir.find('/', i);
        std::string part = dir.substr(i, slash == std::string::npos
                                             ? std::string::npos : slash - i);
        if (!part.empty()) {
            if (acc.size() > 1 || (acc.size() == 1 && acc[0] != '/')) acc += "/";
            acc += part;
            ::mkdir(acc.c_str(), 0700);
        }
        if (slash == std::string::npos) break;
        i = slash + 1;
    }
}

std::string auth_store_path() {
    const char* home = std::getenv("HOME");

#ifdef __APPLE__
    if (home != nullptr) {
        std::string dir =
            std::string(home) + "/Library/Application Support/Open OBSBOT Bridge";
        make_dirs(dir);
        return dir + "/auth.json";
    }
#else
    // XDG_CONFIG_HOME is only honoured when absolute, per the spec; a relative
    // value is to be ignored rather than resolved against the cwd.
    const char* xdg = std::getenv("XDG_CONFIG_HOME");
    std::string base;
    if (xdg != nullptr && xdg[0] == '/') {
        base = xdg;
    } else if (home != nullptr) {
        base = std::string(home) + "/.config";
    }
    if (!base.empty()) {
        std::string dir = base + "/open-obsbot-bridge";
        make_dirs(dir);
        return dir + "/auth.json";
    }
#endif

    return "/tmp/obsbot-bridge-auth.json";
}

static std::string random_pin_6() {
    std::random_device rd;
    std::mt19937 gen(rd());
    std::uniform_int_distribution<int> d(0, 999999);
    char buf[8];
    std::snprintf(buf, sizeof(buf), "%06d", d(gen));
    return buf;
}

static std::string random_token_hex(int bytes = 32) {
    std::random_device rd;
    std::mt19937 gen(rd());
    std::uniform_int_distribution<int> d(0, 255);
    std::ostringstream ss;
    ss << std::hex;
    for (int i = 0; i < bytes; ++i) {
        int v = d(gen);
        if (v < 16) ss << '0';
        ss << v;
    }
    return ss.str();
}

AuthStore::AuthStore(const std::string& store_path) : path_(store_path) {
    // Ensure parent dir exists.
    auto slash = path_.find_last_of('/');
    if (slash != std::string::npos) {
        std::string dir = path_.substr(0, slash);
        ::mkdir(dir.c_str(), 0755);
    }
    load();
    if (pin_.empty()) {
        pin_ = random_pin_6();
        save();
    }
    LOGI("auth: pairing PIN = %s  (tokens: %zu)", pin_.c_str(), tokens_.size());
}

std::string AuthStore::current_pin() const {
    std::lock_guard<std::mutex> g(mu_);
    return pin_;
}

void AuthStore::rotate_pin() {
    std::lock_guard<std::mutex> g(mu_);
    pin_ = random_pin_6();
    save();
    LOGI("auth: PIN rotated, new PIN = %s", pin_.c_str());
}

void AuthStore::revoke_all_tokens() {
    std::lock_guard<std::mutex> g(mu_);
    tokens_.clear();
    save();
    LOGI("auth: all tokens revoked");
}

std::string AuthStore::verify_pin_and_issue(const std::string& pin) {
    std::lock_guard<std::mutex> g(mu_);
    if (pin != pin_) {
        LOGW("auth: bad PIN attempt");
        return "";
    }
    auto tok = random_token_hex(32);
    tokens_.insert(tok);
    save();
    LOGI("auth: token issued (total: %zu)", tokens_.size());
    return tok;
}

bool AuthStore::is_valid_token(const std::string& token) const {
    if (token.empty()) return false;
    std::lock_guard<std::mutex> g(mu_);
    return tokens_.count(token) > 0;
}

void AuthStore::load() {
    std::ifstream f(path_);
    if (!f) return;
    try {
        nlohmann::json j; f >> j;
        pin_ = j.value("pin", std::string{});
        tokens_.clear();
        if (j.contains("tokens") && j["tokens"].is_array()) {
            for (auto& t : j["tokens"]) tokens_.insert(t.get<std::string>());
        }
    } catch (...) { /* corrupt file: regenerate */ }
}

void AuthStore::save() const {
    nlohmann::json j;
    j["pin"] = pin_;
    j["tokens"] = nlohmann::json::array();
    for (auto& t : tokens_) j["tokens"].push_back(t);
    std::ofstream f(path_);
    if (f) f << j.dump(2);
    ::chmod(path_.c_str(), 0600);
}

}  // namespace obs
