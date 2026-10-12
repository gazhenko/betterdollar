# BetterDollar working agreement

Native Swift 6 and SwiftUI for iOS 26. XcodeGen generates `BetterDollar.xcodeproj` from `project.yml`; never commit the project.

- `Packages/BetterDollarCore` stays dependency-free: models, money math (whole cents), Plaid client/sync, CSV, backups.
- `Packages/BetterDollarCoach` is the only place third-party code is allowed (mlx-swift-lm, swift-transformers), pinned exactly.
- Privacy rules: no server, no analytics, no cloud AI. Secrets go in the Keychain (`ThisDeviceOnly`); anything written to disk outside the store is encrypted. Never assign a transaction on the user's behalf; suggestions are hints only.
- Schema changes must stay CloudKit-compatible (defaults on every property, optional relationships).
- Look and copy: banknote engraving theme in `BetterDollar/Design` (Ink tokens, Typeface, Guilloche). Seal red only for overspending/errors. Sentence case, plain verbs, no all-caps labels.
- Color providers and `Shape.path(in:)` must be `nonisolated`; SwiftUI calls them off the main thread (drag previews crashed before this was fixed).

Commands (see `scripts/dev.sh`): `test-core` (24 Swift Testing tests), `test-coach` (15, macOS), `test-ui` (8 journeys incl. a screenshot tour, simulator; the coach journey needs Apple Intelligence in the simulator and skips otherwise), `run -BDDemo`.
Simulator results are not physical-iPhone validation; say which one you ran.
