# Security Policy & Bug Bounty (testnet phase)

TimbSwap is live on **Arbitrum Sepolia** as a capped, unaudited testnet. Every
token is a test asset with no monetary value, and the bug bounty runs **now**,
before the independent audit and any mainnet launch, so vulnerabilities are
found and fixed while nothing real is at stake. Rewards are real: **USDT on
Arbitrum One**, paid from a public bounty wallet.

> **Report privately — do not open a public issue.**
> Primary channel: **devhub@timbswap.xyz** (security-only inbox; put the
> contract name in the subject). A GitHub private advisory on this repo
> (Security → "Report a vulnerability") is also accepted whenever the repo is
> reachable; email is the channel that is always open.

The full program terms, the reward tiers, and the live pool balance are on the
[Protocol page](https://timbswap.xyz/gov/#bounty). This file is the short form.

`devhub@timbswap.xyz` is for security reports only. Player support goes to
`hello@timbswap.xyz`, partnerships and press to `marketing@timbswap.xyz`.

---

## How to report

1. Email the report to devhub@timbswap.xyz with: affected contract(s) +
   address, a description, impact, and a **proof of concept** (a Foundry test
   or a fork script is ideal).
2. Acknowledgement within **72 hours**, triage by severity, updates through
   the fix.
3. Give up to **90 days** (or until a fix ships, whichever is sooner) before
   any public disclosure. Coordinated disclosure only.

## Scope

**In:** the deployed Arbitrum Sepolia contracts listed in the
[Docs address table](https://timbswap.xyz/docs/) and their source in
`contracts/` (also served at [timbswap.xyz/source](https://timbswap.xyz/source/)): DEX core, prize game, token and incentives, governance.

**Out:** the frontend and static site (except a display bug that could mislead
a user into a losing on-chain action, which is T1), off-chain keepers and
telemetry, **SwapTables** (`SegmentBoard*`, `SeedRegistry`, `PoolLedger`:
testnet-only and not part of the mainnet deployment), third-party code and infra (Chainlink VRF, OpenZeppelin, the
Arbitrum sequencer, RPC providers, wallets), already-documented behavior,
gas-optimisation notes, and scanner output without a working PoC.

## Known issues

The testnet contracts are an **earlier build** than the mainnet source in the
[TimbSwap repository](https://github.com/0xTimberZx/TimbSwap/tree/main/contracts).
A finding that is already fixed, or already configurable, in that mainnet
source is **known** and earns nothing, even though the testnet build still
shows it. The testnet will not be redeployed to fix it. Check a finding against
the mainnet source before you submit. Reports about the items below are also
closed as known. This list covers reports received after it was published.

**Different by design on mainnet:**

- **Winning-string repeats.** Handled in the mainnet `TimbPrize`: the winning
  string follows the same `GameRegistry.allowRepeatedChars` rule as tickets.
- **Randomness source.** Testnet jitters with the settling block's hash;
  mainnet draws from `VRFEntropy` (Chainlink VRF).
- **Ownership and privileged roles.** Testnet contracts are owned by a single
  key. On mainnet, ownership sits behind a timelock + multisig, so owner-power
  and centralisation findings against the testnet key are out.
- **Governance.** No governance module is live on testnet and on-chain voting
  is switched off. Findings against a testnet governance address or the
  `/gov/` voting flow are out.
- **Testnet wiring and configuration.** Addresses, whitelists and parameters
  that the owner can reset in one transaction on testnet are set separately
  for mainnet. A testnet misconfiguration pays only if the same mistake is in
  the mainnet deploy script.
- **Permissionless pair swaps.** `TimbSwapPair.swap()` is open to any caller,
  as in Uniswap V2; the constant-product invariant is enforced after fees. The
  router's extra protocol fee and the prize-game nudge apply only to swaps
  routed through the router, so a direct swap skips both (and gives up its own
  nudge). Earlier testnet builds carried an "only factory-registered router"
  comment; the mainnet source documents the permissionless design.

**Accepted risks on mainnet (known, bounded, not bugs):**

- **Oracle discretion on VRF re-requests.** When a VRF request stalls past
  `REREQUEST_DELAY`, `rerequest` fires a replacement, and whichever word lands
  first is used. Players and the protocol cannot predict either word, but the
  Chainlink node that fulfils them can compute both before submitting. A node
  operator could in principle withhold one fulfilment and deliver the other.
  This is the standard Chainlink VRF trust assumption. It is bounded by the
  per-segment re-request cap (`MAX_PUBLIC_REREQUESTS`, see TS-005), and every
  re-request is alerted by the settler. Reports that restate it are closed as
  known. A way to force or exceed extra draws beyond the cap is still in scope:
  **T2** if it only burns extra draws and subscription balance, **T5** if it
  lets anyone choose among outcomes.
- **Arbitrum node disagreement.** Arbitrum has a single canonical ordering set
  by the sequencer, every node replays it deterministically, and faulty state
  is resolved by the rollup's dispute protocol on Ethereum. The VRF word is
  proof-checked by the coordinator and written once per segment
  (`rawFulfillRandomWords` ignores late arrivals). Node disagreement cannot
  produce two outcomes for a segment. A sequencer reorg can drop a request or
  fulfilment, which the settler recovers by re-arming. Reports built on
  node-level disagreement or reorg splitting the outcome are out of scope.

**Already reported (duplicates earn nothing):**

| Ref | Area | Issue |
|---|---|---|
| TS-001 | Frontend config | Governance address pointed at a retired router |
| TS-002 | `TimbBoostFarm` | Rate retarget after `periodFinish` accrues across the dead window |
| TS-003 | `TIMBSToken` | Transfer-cap whitelist misses `TimbFarm` / `TimbBoostFarm`; `farmPool` mis-set |
| TS-004 | `TimbPrize` | Winning string can repeat characters (handled in mainnet source) |
| TS-005 | `VRFEntropy` | Permissionless `rerequest` has no per-salt retry cap; each call spends the VRF subscription |
| TS-006 | `TimbTreasury` | `distributeToPot` deposits into `PrizeEscrow` without crediting `TimbPrize.currentAccumulatedRewards`, so the ETH never reaches a winner |
| TS-007 | Frontend | Prize headline (landing "Up for Grabs", compete banner) showed the PrizeEscrow balance instead of the winnable pot |
| TS-008 | `GameRegistry` / `TimbPrize` | Settlement counted only Active tickets, so selectively activating one's own ticket could exclude matching Pending winners |
| TS-009 | `TimbSwapRouter` | Swap nudges had no minimum input, so dust swaps drove the meter for gas alone and bypassed the free-nudge cap |
| TS-010 | `TimbSwapRouter` | Exact-output swaps checked only the swap input against `amountInMax`, so the protocol fee was charged beyond the caller's limit |
| TS-011 | `TimbStaking` / `TimbFarm` | `emergencyWithdraw` forfeited pending rewards without releasing them from `rewardReserve`, so `recoverERC20` could never reclaim them |
| TS-012 | Frontend | Token `symbol()`/`name()` from permissionless pairs were rendered via `innerHTML` unescaped (stored XSS on Explore and Swap) |
| TS-013 | `TimbSwapRouter` | An `advanceScroll` batch that settled the segment carried its remaining nudges into the next segment uncharged, bypassing the free-nudge cap |

## Severity & rewards

Severity is **impact-based**: what the bug would do with real funds, guided by
the [Immunefi severity classification](https://immunefi.com/immunefi-vulnerability-severity-classification-system-v2-3/).
Rewards settle **pari-mutuel**: each tier holds a share of the pool, split
among all accepted reports in that tier. The bands below are what a report
pays when it is the only accepted report in its tier. **No single payout
exceeds $500** in this pre-mainnet phase. First valid reporter of a unique
issue is eligible; duplicates earn nothing.

| Tier | Class | What lands here | Reward (tier share, if unshared) |
|---|---|---|---|
| **T1** | UI / display | A display or labelling bug that could mislead a user into a losing on-chain action. | **credit + up to $50** |
| **T2** | Operational / fallback | Keeper or automation failures, VRF stall or re-request griefing, recoverable settlement or liveness DoS. Value stuck, not lost. A stall must be one someone can cause, or one the protocol cannot recover from; slow fulfilment by Chainlink or Arbitrum infrastructure is not a finding. | **$50 – $100** |
| **T3** | Misrouting / contractual | Value routed to the wrong place or mis-split: buyback, lapse, pot / escrow / refund accounting. Off-chain-signalling governance manipulation. | **$100 – $250** |
| **T4** | Token & DEX structural | TIMBS mint / inflate / cap bypass, whitelist bypass, DEX k-invariant break, reward-solvency break, LP theft. | **$250 – $450** |
| **T5** | Deep exploit / drain | Full drain of `PrizeEscrow` / `TimbYieldVault` / `TimbTreasury` / the pair; prize-outcome manipulation; owner or privilege escalation; chained exploit. | **up to $500** (cap) |

Reentrancy that bypasses the `nonReentrant` guards is priced by its impact.
Final severity and reward are at the maintainers' discretion.

## Rules of engagement

- Prefer your own local fork. Do not grief, spam, or DoS the shared Arbitrum
  Sepolia deployment, the faucet, or the keepers other players rely on.
- No social engineering, phishing, physical attacks, or targeting of team
  members or third parties.
- One report per unique root cause.

## Safe harbor

For research conducted in good faith and within these rules, TimbSwap will not
pursue or support legal action against you, and considers your activity
authorized. This is not authorization to violate any law or to access accounts
or data that are not yours. If in doubt, ask first via the private channel.

## Eligibility

- Not open to current or former TimbSwap contributors, or their immediate
  family.
- You must comply with applicable sanctions and AML law. KYC may be required
  before payout.

---

*The mainnet program, with larger bands and real value at risk, is described in
the [TimbSwap repository's SECURITY.md](https://github.com/0xTimberZx/TimbSwap/blob/main/SECURITY.md)
and takes over after the independent audit.*
