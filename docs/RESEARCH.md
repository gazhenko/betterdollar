# Research notes (October 2026)

## Plaid: what's free

- **Trial plan.** Free for new Plaid teams in the US and Canada created on or after April 15, 2026.
  - It allows **10 Production Items**. An Item is one login at one institution, and it may hold several accounts.
  - Products: Auth, Balance, Identity, Assets, Liabilities, Investments, Statements, and Transactions (including Refresh).
  - It includes immediate OAuth access to Bank of America, Chase, Wells Fargo, Capital One, Citi, Navy Federal, PNC, U.S. Bank, American Express and Merrill.
  - There's no business registration or security questionnaire.
  - Calling `/item/remove` does **not** free a slot.
  - Sources: [Plaid billing docs](https://plaid.com/docs/account/billing/) and the Plaid support article "What is the Plaid Trial plan?"
- **Limited Production.** The older free tier, closed to new US/CA signups after April 15, 2026.
- **Sandbox.** Free and unlimited, with fake institutions (`user_good` / `pass_good`).

### Why Hosted Link instead of the LinkKit SDK
- On iOS, LinkKit OAuth needs a `redirect_uri` that is a **universal link**.
  - Universal links need an Apple Developer team and an `apple-app-site-association` file on a domain the developer controls.
  - That doesn't work for a bring-your-own-keys open-source app built with free provisioning.
- [Hosted Link](https://plaid.com/docs/link/hosted-link/) gives a Plaid-hosted URL instead.
  - BetterDollar opens it in `ASWebAuthenticationSession` (ephemeral) with `completion_redirect_uri = betterdollar://plaid/complete`. A custom scheme is allowed, and nothing needs registering in the dashboard.
  - It then reads the public token from `/link/token/get` (`link_sessions[].results.item_add_results[]`) and exchanges it. No webhook or server is needed.
- `is_mobile_app` is left off, so OAuth banks finish inside the browser sheet rather than bouncing through a universal link.
- Not yet verified against live Sandbox keys. The client is unit-tested against recorded response shapes, and Plaid's real error format (`INVALID_API_KEYS`) was checked against the decoder.

## Apple cloud

- CloudKit and iCloud Documents need the paid Apple Developer Program. Personal (free) teams can't add the iCloud capability.
- The owner chose **local only for now**. Encrypted backups can still be saved to iCloud Drive manually through Files.
- The SwiftData schema already follows CloudKit's rules, so sync can be added later.

## On-device models

- **Apple Foundation Models**
  - A ~3B on-device model with a 4K-token context, guided generation and the `Tool` protocol.
  - It is free and offline, but only on Apple Intelligence devices.
  - BetterDollar gives it a short overview and three tools: budget item, transaction search, and a finance section (budget, funds, accounts, history).
  - Verified in the iOS 26.5 Simulator: it answered "How am I doing this month?" from the sample household.
- **MLX via mlx-swift-lm 3.32.3**
  - Supports Qwen 3.5, Gemma 4, Llama, LFM2 and many more.
  - The `FoundationModelsIntegration` trait is disabled because it needs the 27 SDKs.
  - Weights download straight from Hugging Face at pinned revisions; the tokenizer comes from swift-transformers 1.3.4.

Smoke test on this Mac: each model downloaded, loaded and answered a budget question from a sample `FinanceData`.

| Model | Download | Load | Speed | Answer |
|---|---|---|---|---|
| LFM2.5 1.2B (0.68 GB) | 10 s | 0.9 s | 48–60 tok/s | some wrong arithmetic |
| Qwen 3.5 2B (1.76 GB) | 54 s | 6.1 s | 39 tok/s | invented a "paid off debt" |
| Llama 3.2 3B (1.83 GB) | 25 s | 3.3 s | 15.5 tok/s | mostly right; confused received with left to budget |
| Qwen 3.5 4B (3.07 GB) | 36 s | 3.1 s | 33 tok/s | accurate, concrete next steps |
| Gemma 4 E2B (3.59 GB) | 41 s | 6.0 s | 27 tok/s | accurate |

What the results changed:
- Qwen 3.5 4B is the recommended model. It is known to run on an iPhone 17 Pro.
- Prompts now quote precomputed figures, such as cash flow and left to budget, instead of asking small models to do arithmetic.
- Funds are listed separately in prompts.
- The persona forbids naming items that aren't in the data.

Mac speeds are not iPhone speeds. Expect roughly a third to half on an iPhone 17 Pro.
