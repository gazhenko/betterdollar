# BetterDollar

A free, open-source zero-based budgeting app for iPhone. It works like EveryDollar, but everything stays private.

- **Plan every dollar.** Each month gets its own plan. You list your income, then give every dollar a job across groups like Housing, Food and Savings until "left to budget" reaches $0.00. The engraved plate at the top fills in as you go.
- **Assign transactions yourself.** New transactions wait in a tray at the bottom of the budget. Drag one onto a budget item, or tap it to pick an item or split it across several. A "Last time" hint suggests where that merchant went before, but nothing is ever assigned automatically. Transactions sit in New, Tracked or Deleted, and deleted ones can be restored.
- **Funds roll over.** Mark an item as a fund (sinking fund or savings goal) and its balance carries from month to month. Add a goal and a target date, and BetterDollar tells you how much to plan each month.
- **Bring your own Plaid.** Connect banks with your own free Plaid account. The app calls Plaid directly from your iPhone, so there is no BetterDollar server. You can also import CSV exports or enter transactions by hand.
- **An on-device coach.** Ask about your budget, your funds or where the money went. Answers come from Apple Intelligence or an open model you download (Qwen 3.5, Gemma 4, Llama 3.2, LFM2.5), running on the iPhone. Your numbers never go to a cloud AI.
- **Private by default.**
  - Data lives in an on-device SwiftData store.
  - Secrets stay in this device's Keychain and never sync.
  - Face ID lock is optional, and the app is hidden in the app switcher.
  - Backups use AES-256 with a passphrase you choose. Save them anywhere, including iCloud Drive.
  - No analytics, ads or account.

## Bank sync with Plaid (free)

Plaid's **Trial plan** is free for new teams in the US and Canada created on or after April 15, 2026.
- It allows **10 Production Items**. An Item is one bank login, and it can include several accounts.
- It includes Transactions and Balance.
- It covers OAuth banks such as Chase, Bank of America, Wells Fargo, Capital One and Citi.
- Removing an Item does not give the slot back.

To connect:
1. Sign up at [dashboard.plaid.com](https://dashboard.plaid.com/signup), then open **Developers → Keys**.
2. In BetterDollar, go to **Settings → Set up bank sync with Plaid** and paste your client ID and a secret.
   - Start with **Sandbox**. Its test banks accept username `user_good` and password `pass_good`.
   - Switch to **Production** for your real accounts.
3. Tap **Connect a bank**. Linking opens in a private browser sheet using [Plaid Hosted Link](https://plaid.com/docs/link/hosted-link/), so OAuth banks work without a universal link or a server.
4. New transactions land in the tray. Pull to refresh on Transactions to sync again.
   - Syncing uses `/transactions/sync` with a stored cursor.
   - When a pending charge posts, it keeps the assignment you gave it.

Your keys and each bank's access token are stored in the iPhone's Keychain (`ThisDeviceOnly`). They're included in a backup only if you turn that on, and the backup is always encrypted.

## On-device coach

| Engine | Size | Notes |
|---|---|---|
| Apple Intelligence | built in | Foundation Models; reads your budget through tool calls; needs an Apple Intelligence iPhone |
| Qwen 3.5 4B (recommended) | 3.1 GB | Most accurate with real numbers in our tests; Apache 2.0 |
| Qwen 3.5 2B | 1.8 GB | Faster; mixes up figures more often; Apache 2.0 |
| Gemma 4 E2B | 3.6 GB | Accurate, friendly; Gemma terms |
| Llama 3.2 3B | 1.8 GB | Steady but slower; Llama 3.2 license |
| LFM2.5 1.2B | 0.7 GB | Fastest, for older iPhones; LFM Open License |

Local models run through [mlx-swift-lm](https://github.com/ml-explore/mlx-swift-lm) 3.32.3. They download once from Hugging Face at a pinned revision, each file is checked by size and SHA-256, and they're stored in Application Support, excluded from backups. See [docs/RESEARCH.md](docs/RESEARCH.md) for how they were chosen and the smoke-test results.

## Build

Requirements:
- Xcode 26.6 or later with the Metal Toolchain installed.
- [XcodeGen](https://github.com/yonaskolb/XcodeGen).
- iOS 26 or later.

```sh
scripts/dev.sh build          # generate the project and build for the simulator
scripts/dev.sh run -BDDemo    # run with a sample household (in memory)
scripts/dev.sh test-core      # budget engine, Plaid client, backups, CSV (swift test)
scripts/dev.sh test-coach     # coach prompts, catalog, history trimming (macOS)
scripts/dev.sh test-ui        # end-to-end journeys in the simulator
```

App builds pass `-skipPackagePluginValidation -skipMacroValidation`, which MLX's build plugin needs.

To install on your own iPhone with a free Apple ID:
1. Open `BetterDollar.xcodeproj` and pick your Personal Team under Signing.
2. Run it on the device.

Free provisioning expires after 7 days, so reinstall to refresh. Your data survives the reinstall.

Launch arguments for development:
- `-BDDemo`: sample data in an in-memory store.
- `-BDEmpty`: an empty in-memory store.
- `-BDTab budget|transactions|insights|coach|settings`: open on that tab.

## Layout

```
BetterDollar/                 SwiftUI app (Budget, Transactions, Insights, Coach, Settings)
Packages/BetterDollarCore     SwiftData models, budget math, Plaid client + sync, CSV, encrypted backups
Packages/BetterDollarCoach    Apple Foundation Models + MLX engines, model catalog and downloader
BetterDollarUITests           Journeys: plan from template, drag to assign, tap to assign, split, add, coach
tools/render-icon.swift       Draws the guilloche app icon
```

The SwiftData schema already follows CloudKit's rules: every property has a default and every relationship is optional. Turning on iCloud sync later needs a paid Apple Developer account, the CloudKit entitlement, and a `cloudKitDatabase` setting in `BetterDollarSchema`.

## License

MIT. See [LICENSE](LICENSE). Downloaded models have their own licenses, which are listed in the app.
