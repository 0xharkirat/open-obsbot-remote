#pragma once

#include <json.hpp>
#include <map>
#include <string>

// Per-camera persistence for the multi-device bridge (v2 protocol).
//
// v1 stored one camera's data at the top level of each file. v2 keys every
// file by the camera SN so N cameras never collide. On first attach we detect
// a v1-shaped file structurally (no version marker exists) and re-key it under
// the attaching camera's SN, so the user never loses a saved sequence.
//
// All functions are process-safe: a single file mutex serialises every read /
// modify / write. Writes are rare (user saving a sequence / renaming a
// camera) so a global lock is the right amount of machinery here.
//
// Files live under ~/Library/Application Support/Open OBSBOT Bridge/:
//   sequence.json       active scratch, v2 shape { "<sn>": {mode, steps} }
//   sequences.json      saved library,  v2 shape { "<sn>": { "<name>": {...} } }
//   device_names.json   friendly names, { "<sn>": "Vocal" }
//   active.json         live camera,    { "active_device_sn": "RMOW..." }
//   sources.json        generic sources, { "<unique_id>": "<label>" }
//
// presets.json is intentionally absent: presets are stored on the camera
// hardware (aiAddGimbalPresetR) and read back per-camera, so multi-cam preset
// isolation is free and there is nothing to migrate.
namespace obs::persist {

// Active scratch sequence for one camera: { "mode": ..., "steps": [...] }.
// Returns an empty object if the camera has none.
nlohmann::json load_active_sequence(const std::string& sn);
void store_active_sequence(const std::string& sn, const nlohmann::json& seq);

// Saved sequence library for one camera: { "<name>": {mode, steps} }.
nlohmann::json load_sequence_library(const std::string& sn);
void store_sequence_library(const std::string& sn, const nlohmann::json& lib);

// MIX sequences span cameras, so they are bridge-level (NOT keyed by SN).
//   mix.json           active scratch, shape { mode, cues:[...] }
//   mix_sequences.json saved library,  shape { "<name>": {mode, cues:[...]} }
// Each cue: { camera_sn, preset_id, move_ms, hold_s, transition, meanwhile? }.
nlohmann::json load_active_mix();
void store_active_mix(const nlohmann::json& mix);
nlohmann::json load_mix_library();
void store_mix_library(const nlohmann::json& lib);

// Export the whole authored library (per-camera sequences + mix library +
// device names) as one JSON blob for migrating to a new Mac. Presets are NOT
// included - they live on the camera hardware. Import merges the blob back in
// (incoming entries win per key); a bridge restart / camera re-attach applies
// restored sequences to live sessions.
nlohmann::json export_library();
void import_library(const nlohmann::json& blob);

// Friendly names for every known camera.
std::map<std::string, std::string> load_device_names();
// Empty name clears the entry.
void store_device_name(const std::string& sn, const std::string& name);

// Which camera the live preview + active_device_id follow. Empty if unset.
std::string load_active_device();
void store_active_device(const std::string& sn);

// Generic (non-OBSBOT) video sources the operator added, keyed by their
// AVFoundation uniqueID, so they survive a bridge restart. Empty label
// removes the entry (mirrors store_device_name).
std::map<std::string, std::string> load_sources();
void store_source(const std::string& unique_id, const std::string& label);

// One-shot v1 -> v2 migration keyed under `sn`. Safe to call on every attach:
// only files still in v1 shape are rewritten. v1 is detected by structure, not
// a version field (v1 files carry none).
void migrate_v1_if_needed(const std::string& sn);

}  // namespace obs::persist
