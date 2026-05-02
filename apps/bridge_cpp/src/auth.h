#pragma once
#include <string>
#include <unordered_set>
#include <mutex>

namespace obs {

// Tiny in-memory + JSON-on-disk auth store.
// - PIN: 6-digit shown in bridge UI (also persisted to disk so it survives
//   restart). User can rotate from the UI.
// - Tokens: random 32-byte hex, issued after correct PIN. Stored on disk.
//   Phone keeps the token for next connect. Revocable from UI.
class AuthStore {
public:
    explicit AuthStore(const std::string& store_path);

    std::string current_pin() const;        // user-visible PIN string
    void rotate_pin();                      // generate new PIN, revoke nothing
    void revoke_all_tokens();

    // Returns a fresh token string on success, empty on bad PIN.
    std::string verify_pin_and_issue(const std::string& pin);
    bool is_valid_token(const std::string& token) const;

private:
    void load();
    void save() const;

    mutable std::mutex mu_;
    std::string path_;
    std::string pin_;
    std::unordered_set<std::string> tokens_;
};

}  // namespace obs
