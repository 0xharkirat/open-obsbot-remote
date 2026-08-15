#pragma once
#include <string>
#include <unordered_set>
#include <mutex>

namespace obs {

// Where auth.json lives, per platform, with the parent directory created.
//
// macOS keeps per-user state in ~/Library/Application Support. Linux has no
// such directory, and creating one would put a folder no Linux tool knows
// about into $HOME, so it follows the XDG base directory spec:
// $XDG_CONFIG_HOME/open-obsbot-bridge, or ~/.config/open-obsbot-bridge when
// that variable is unset. Falls back to /tmp when there is no HOME at all,
// which is the case under some service managers.
std::string auth_store_path();

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
