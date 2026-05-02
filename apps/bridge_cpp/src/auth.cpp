#include "auth.h"
#include "log.h"

#include <json.hpp>

#include <cstdlib>
#include <fstream>
#include <random>
#include <sstream>
#include <sys/stat.h>

namespace obs {

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
}

}  // namespace obs
