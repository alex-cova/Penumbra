# ACP adapter UI tests

Run on a logged-in macOS desktop with Xcode and UI automation access enabled:

```sh
xcodebuild test -project Umbra/Umbra.xcodeproj -scheme UmbraACPUI -destination 'platform=macOS' -derivedDataPath /tmp/umbra-acp-ui-derived
```

Xcode builds the current checkout. Ordinary tests use temporary adapter, workspace, session and defaults directories, captured registry responses and a fake npm installer. Node.js at `/opt/homebrew/bin/node`, `/usr/local/bin/node`, or `/usr/bin/node` is required for the fake ACP process; tests needing it skip if it is absent. The live test is opt-in with `UMBRA_LIVE_ACP_UI=1` in the test runner environment. Its optional `UMBRA_ACP_UI_ROOT` can point at installed adapters; loading the store may clean up interrupted staging files.

The tests inspect accessibility labels and progress values and exercise Escape and Return. A manual VoiceOver pass is still needed for rotor order, announcement timing and whether changing progress and errors are spoken without moving focus. Check the visible keyboard focus ring as well.

CI runs the same suite (without the opt-in live test) through `Scripts/ci-acp-ui-tests.sh` and fails unless all 19 tests execute and pass with none skipped. See `docs/CI.md` for the guards, the runner requirements and the self-hosted fallback. Locally, `Scripts/ci-gui-preflight.sh` then `Scripts/ci-acp-ui-tests.sh` is the same path CI takes.
