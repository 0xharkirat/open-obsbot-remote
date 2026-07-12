# Contributing  -  branch + PR workflow

Effective from v1.1.0. Pre-1.1 commits landed directly on `main` for
speed; from now on every change goes through a pull request.

## Branch model

```
main           ← protected; only fast-forward / squash-merge from PRs
└── release/*  ← branched off main when cutting a tag (release/v1.1.x)
└── feat/*     ← topic branches off main; one focused change set
└── fix/*      ← bug fix branches off main; backportable
└── chore/*    ← infra, deps, ci, build scripts
└── docs/*     ← docs-only
```

Branch names are lowercase, hyphenated, scoped:
`feat/cinema-speed`, `fix/joystick-scroll-eat`, `chore/upgrade-flutter-3.42`.

## PR workflow

1. Branch off latest `main`:

   ```bash
   git fetch origin
   git checkout -b fix/<short-description> origin/main
   ```

2. Implement the change. **Keep PRs small**  -  one logical change per PR
   (joystick fix and cinema speed are two PRs, not one).

3. Run regression locally before pushing:

   ```bash
   ./scripts/build-bridge-mac.sh                       # full clean build
   pkill -9 -f obsbot-bridge && open "apps/bridge/build/macos/Build/Products/Release/Open OBSBOT Bridge.app"
   sleep 8
   cd tests
   node bridge_smoke.mjs        # 27 tests, connect / preset / sequence / image
   node zoom_speed.mjs          # 9  tests, zoom planner duration timings
   node slow_motion.mjs         # 7  tests, duration_ms timings 200ms to 60s
   node sequencer_save.mjs      # 6  tests, duration_ms persistence + legacy migration
   node exposure.mjs            # 8  tests, exposure mode + EV bias + anti-flicker + WB
   node zoom_smoothness.mjs     # samples zoom over 5s and 30s plans
   ```

   Plus the offline widget tests:

   ```bash
   cd apps/rc && flutter test    # 21 widget tests (tab_shell + pin_entry)
   ```

   The full battery is **78 / 78**. New PRs are expected to land green;
   if a test is flaking, fix it or document the flake in the PR
   description before merging.

   For UI / web changes also run the touch test described in
   `docs/TOUCH_FINDINGS_2026-05-10.md` reproduction recipe.

4. Push and open the PR:

   ```bash
   git push -u origin <branch>
   gh pr create --fill --base main
   ```

5. PR description must include:
   - **Problem:** what real-world symptom prompted this.
   - **Fix:** one-line summary of the change.
   - **Verification:** smoke result + touch test result + manual notes.
   - **Risk / rollout:** anything that could regress, any feature flag.

   Use `.github/PULL_REQUEST_TEMPLATE.md` (auto-loaded if present).

6. Merge strategy: **squash-and-merge**. The squashed commit message
   should follow the commit-message convention used pre-1.1
   (`fix(scope): one-line summary` + body), so the main-branch history
   stays grep-able.

7. After merge, delete the topic branch on GitHub.

## What blocks a PR

- Smoke battery does not stay at 78 / 78 (or whatever the current full
  battery count is, including any new tests this PR adds).
- New compile warnings under `flutter analyze` or `cmake --build`.
- A previously fixed flake re-opens (e.g. yaw sign regression, joystick
  scroll-eat).
- New file over 500 LOC without justification in PR description.
- Lint failures (run `dart fix --apply` first).

## Release branches

Major release work happens on `release/v<X>.<Y>.x`:

```bash
git checkout -b release/v1.1.x main
# bump pubspec versions, CHANGELOG, README badge
# ./scripts/build-bridge-mac.sh; zip the bundle
# tag and push
git tag v1.1.0
git push origin release/v1.1.x v1.1.0
gh release create v1.1.0 --notes-file CHANGELOG.md \
    Open-OBSBOT-Bridge-macOS-arm64-v1.1.0.zip
```

Patch releases (v1.1.1, v1.1.2…) cherry-pick fixes from `main` onto the
release branch. Don't re-tag `v1.1.0`.

## Convention enforcement

- `.github/PULL_REQUEST_TEMPLATE.md` populates the PR body.
- `.github/workflows/ci.yml` (TODO) runs `dart analyze`, `flutter build
  web`, and `cmake --build` on every PR. Bridge smoke battery is
  manual-verify (needs real camera).
- Branch protection on `main`: require at least one approval, require
  status checks to pass, no force-push.
