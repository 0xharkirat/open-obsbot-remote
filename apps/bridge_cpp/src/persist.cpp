#include "persist.h"
#include "log.h"

#include <cstdlib>
#include <fstream>
#include <mutex>
#include <sstream>
#include <sys/stat.h>

namespace obs::persist {

namespace {

// One lock guards every file touched here. Persistence writes are infrequent
// (a user saving a sequence or renaming a camera), so a single global lock is
// simpler than per-file locks and cannot deadlock.
std::mutex g_mu;

std::string support_dir() {
    const char* home = std::getenv("HOME");
    if (!home) return "/tmp";
    std::string dir = std::string(home) +
        "/Library/Application Support/Open OBSBOT Bridge";
    ::mkdir(dir.c_str(), 0755);
    return dir;
}

std::string path_for(const char* file) {
    return support_dir() + "/" + file;
}

nlohmann::json read_json(const std::string& path) {
    std::ifstream f(path);
    if (!f) return nlohmann::json::object();
    try {
        nlohmann::json j;
        f >> j;
        return j;
    } catch (...) {
        return nlohmann::json::object();
    }
}

void write_json(const std::string& path, const nlohmann::json& j) {
    std::ofstream f(path);
    if (f) f << j.dump(2);
}

// A v1 sequences.json / active-sequence entry is an object that directly holds
// a "steps" array. A v2 per-SN map holds SN keys whose values are (for the
// library) name -> sequence maps, never a bare steps array at that level.
bool looks_like_sequence(const nlohmann::json& j) {
    return j.is_object() && j.contains("steps") && j["steps"].is_array();
}

}  // namespace

nlohmann::json load_active_sequence(const std::string& sn) {
    std::lock_guard<std::mutex> g(g_mu);
    nlohmann::json j = read_json(path_for("sequence.json"));
    if (j.is_object() && j.contains(sn) && j[sn].is_object()) return j[sn];
    return nlohmann::json::object();
}

void store_active_sequence(const std::string& sn, const nlohmann::json& seq) {
    std::lock_guard<std::mutex> g(g_mu);
    std::string path = path_for("sequence.json");
    nlohmann::json j = read_json(path);
    if (!j.is_object()) j = nlohmann::json::object();
    j[sn] = seq;
    write_json(path, j);
}

nlohmann::json load_sequence_library(const std::string& sn) {
    std::lock_guard<std::mutex> g(g_mu);
    nlohmann::json j = read_json(path_for("sequences.json"));
    if (j.is_object() && j.contains(sn) && j[sn].is_object()) return j[sn];
    return nlohmann::json::object();
}

void store_sequence_library(const std::string& sn, const nlohmann::json& lib) {
    std::lock_guard<std::mutex> g(g_mu);
    std::string path = path_for("sequences.json");
    nlohmann::json j = read_json(path);
    if (!j.is_object()) j = nlohmann::json::object();
    j[sn] = lib;
    write_json(path, j);
}

nlohmann::json load_active_mix() {
    std::lock_guard<std::mutex> g(g_mu);
    nlohmann::json j = read_json(path_for("mix.json"));
    return j.is_object() ? j : nlohmann::json::object();
}

void store_active_mix(const nlohmann::json& mix) {
    std::lock_guard<std::mutex> g(g_mu);
    write_json(path_for("mix.json"), mix);
}

nlohmann::json load_mix_library() {
    std::lock_guard<std::mutex> g(g_mu);
    nlohmann::json j = read_json(path_for("mix_sequences.json"));
    return j.is_object() ? j : nlohmann::json::object();
}

void store_mix_library(const nlohmann::json& lib) {
    std::lock_guard<std::mutex> g(g_mu);
    write_json(path_for("mix_sequences.json"), lib);
}

nlohmann::json export_library() {
    std::lock_guard<std::mutex> g(g_mu);
    nlohmann::json out;
    out["version"] = 1;
    out["sequences"] = read_json(path_for("sequences.json"));
    out["mix"] = read_json(path_for("mix_sequences.json"));
    out["names"] = read_json(path_for("device_names.json"));
    return out;
}

void import_library(const nlohmann::json& blob) {
    std::lock_guard<std::mutex> g(g_mu);
    auto merge_into = [](const char* file, const nlohmann::json& incoming) {
        if (!incoming.is_object()) return;
        std::string p = path_for(file);
        nlohmann::json cur = read_json(p);
        if (!cur.is_object()) cur = nlohmann::json::object();
        for (auto& it : incoming.items()) cur[it.key()] = it.value();  // incoming wins
        write_json(p, cur);
    };
    if (blob.is_object()) {
        if (blob.contains("sequences")) merge_into("sequences.json", blob["sequences"]);
        if (blob.contains("mix")) merge_into("mix_sequences.json", blob["mix"]);
        if (blob.contains("names")) merge_into("device_names.json", blob["names"]);
    }
}

std::map<std::string, std::string> load_device_names() {
    std::lock_guard<std::mutex> g(g_mu);
    nlohmann::json j = read_json(path_for("device_names.json"));
    std::map<std::string, std::string> out;
    if (j.is_object()) {
        for (auto& it : j.items()) {
            if (it.value().is_string()) out[it.key()] = it.value().get<std::string>();
        }
    }
    return out;
}

void store_device_name(const std::string& sn, const std::string& name) {
    std::lock_guard<std::mutex> g(g_mu);
    std::string path = path_for("device_names.json");
    nlohmann::json j = read_json(path);
    if (!j.is_object()) j = nlohmann::json::object();
    if (name.empty()) j.erase(sn);
    else j[sn] = name;
    write_json(path, j);
}

std::string load_active_device() {
    std::lock_guard<std::mutex> g(g_mu);
    nlohmann::json j = read_json(path_for("active.json"));
    if (j.is_object()) return j.value("active_device_sn", std::string{});
    return "";
}

void store_active_device(const std::string& sn) {
    std::lock_guard<std::mutex> g(g_mu);
    nlohmann::json j;
    j["active_device_sn"] = sn;
    write_json(path_for("active.json"), j);
}

std::map<std::string, std::string> load_sources() {
    std::lock_guard<std::mutex> g(g_mu);
    nlohmann::json j = read_json(path_for("sources.json"));
    std::map<std::string, std::string> out;
    if (j.is_object()) {
        for (auto& it : j.items()) {
            if (it.value().is_string()) out[it.key()] = it.value().get<std::string>();
        }
    }
    return out;
}

void store_source(const std::string& unique_id, const std::string& label) {
    std::lock_guard<std::mutex> g(g_mu);
    std::string path = path_for("sources.json");
    nlohmann::json j = read_json(path);
    if (!j.is_object()) j = nlohmann::json::object();
    if (label.empty()) j.erase(unique_id);
    else j[unique_id] = label;
    write_json(path, j);
}

void migrate_v1_if_needed(const std::string& sn) {
    if (sn.empty()) return;
    std::lock_guard<std::mutex> g(g_mu);

    // sequence.json: v1 is a single sequence object with a top-level "steps"
    // array. Re-key it under the SN and drop the legacy "loop" bool.
    {
        std::string path = path_for("sequence.json");
        nlohmann::json j = read_json(path);
        if (looks_like_sequence(j)) {
            nlohmann::json v2 = nlohmann::json::object();
            v2[sn] = {
                {"mode", j.value("mode", std::string("forward"))},
                {"steps", j["steps"]},
            };
            write_json(path, v2);
            LOGI("persist: migrated sequence.json to v2 under sn=%s", sn.c_str());
        }
    }

    // sequences.json: v1 is { "<name>": {steps...} }. Detect by the first
    // value being a bare sequence. Re-key the whole map under the SN.
    {
        std::string path = path_for("sequences.json");
        nlohmann::json j = read_json(path);
        if (j.is_object() && !j.empty() &&
            looks_like_sequence(j.begin().value())) {
            nlohmann::json v2 = nlohmann::json::object();
            v2[sn] = j;
            write_json(path, v2);
            LOGI("persist: migrated sequences.json to v2 under sn=%s (%zu entries)",
                 sn.c_str(), j.size());
        }
    }
}

}  // namespace obs::persist
