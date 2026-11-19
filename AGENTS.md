# BetterDollar working agreement

Native Swift 6 and SwiftUI for iOS 26. XcodeGen generates `BetterDollar.xcodeproj` from `project.yml`; never commit the project.

- `Packages/BetterDollarCore` stays dependency-free: models, money math (whole cents), Plaid client/sync, CSV, backups.
- `Packages/BetterDollarCoach` is the only place third-party code is allowed (mlx-swift-lm, swift-transformers), pinned exactly.
- Privacy rules: no server, no analytics, no cloud AI. Secrets go in the Keychain (`ThisDeviceOnly`); anything written to disk outside the store is encrypted. Never assign a transaction on the user's behalf; suggestions are hints only.
- Schema changes must stay CloudKit-compatible (defaults on every property, optional relationships).
- Look and copy: banknote engraving theme in `BetterDollar/Design` (Ink tokens, Typeface, Guilloche). The page is currency stock, a pale green-gray, never cream or white. Sentence case, plain verbs, no all-caps labels.
- Objects and print: only three things get their own surface. The note (`.engravedPlate`, the one solid block of greenback, one per screen), receipt slips, and loose notices (`.card()`). Everything else (budget groups, transactions, stats, forms) is printed on the page as a ruled ledger: a serif heading over a 1.5pt ink rule, hairlines between lines. Paper has crisp corners (`Layout.cardRadius`); only controls are round.
- Seal red only for overspending/errors, and once per object: the figure or a rule carries it, not the copy around it. A plate in trouble is reprinted as a pale red-seal note with `PlateInk(alarm: true)` rather than putting red on green.
- Build screens from the shared pieces in `Theme.swift` so system gray never shows on the paper: `ScreenHeader` on every tab (no system large titles), `LedgerForm` instead of `Form` with `Section(ledger:)` or `LedgerHeading` for its section headings, `LedgerTabs` instead of a segmented `Picker`, `MoneyFigure` for headline amounts, `SpendRule` for progress, `Layout.margin` for side margins. Serif (New York) for titles and headings, SF for text and amounts, wide heavy SF (`Typeface.figure`) for headline figures, as the numerals on a note are.
- Color providers and `Shape.path(in:)` must be `nonisolated`; SwiftUI calls them off the main thread (drag previews crashed before this was fixed).

Commands (see `scripts/dev.sh`): `test-core` (46 Swift Testing tests), `test-coach` (15, macOS), `test-ui` (10 journeys incl. a screenshot tour and the cash flow layouts, simulator; the coach journey needs Apple Intelligence in the simulator and skips otherwise), `run -BDDemo` (or `-BDFirstMonth` for the sample household with one month of history, `-BDEmpty` for no data).
Simulator results are not physical-iPhone validation; say which one you ran.
