# TimbSwap

**An exchange with a prize game built in — and one incentive engine underneath both.**

TimbSwap is a decentralized exchange whose swap fees and idle-capital yield fund a recurring,
on-chain prize game. The swap, the staking, the farming, and the game are not separate products
— they are modules of a single self-funding loop. What the protocol earns is swept back to the
people who generate it, on a fixed cadence, under hard solvency limits. Rewards are funded by
real inflow, never printed.

It is **source-available, permissionless, and non-custodial**: the protocol is a set of **Solidity
smart contracts** on Arbitrum, verified on Sourcify, that anyone can call directly — settlement
and payouts need no privileged operator, and you always hold your own keys.

**Live:** [timbswap.xyz](https://timbswap.xyz/)  
**Start here:** [timbswap.xyz/start](https://timbswap.xyz/start/) — first round in 2 minutes, no extension needed  
**Network:** Arbitrum Sepolia (Chain ID: 421614)  
**GitHub:** [github.com/0xTimberZx/TimbSwap](https://github.com/0xTimberZx/TimbSwap) · **Source, served from the site:** [timbswap.xyz/source](https://timbswap.xyz/source/)  
**Faucet:** [timbswap.xyz/faucet](https://timbswap.xyz/faucet/) — testnet TIMBS for wallets holding an Active ticket  
**Litepaper:** [timbswap.xyz/litepaper](https://timbswap.xyz/litepaper/)  
**Changelog:** [CHANGELOG.md](./CHANGELOG.md)

> **Status (Sept 2026):** live on Arbitrum **Sepolia testnet** — all tokens are test assets with no
> monetary value. Unaudited; an independent audit is a gating condition for any mainnet launch.
> The prize game runs on its **gen-3** contracts; the **faucet** is live (TIMBS-only on testnet);
> **email sign-in** (an embedded wallet with optional authenticator / passkey MFA and key export) is
> live next to extension wallets; the mainnet-TIMB **airdrop** leg is deployed on Arbitrum One but
> **paused until the public announcement**. See [Roadmap](./ROADMAP.md) and the
> [Risks](https://timbswap.xyz/docs/#risks) section.

---

## The incentive engine

One inflow drives every module. Value moves in one direction, on a fixed cadence:

```
        ┌──────────────────────── the loop repeats every 6 rounds ───────────────────────┐
        │                                                                                 │
   ①  TRADE ───▶  ②  COLLECT ───▶  ③  REWARD ───────────────▶  ④  RETURN ────────────────┘
   swaps pay a     fees + yield      the epoch sweep refills, in fixed order:               players & LPs
   0.30% fee       on pooled         pot → farm → staking → boost                           come back;
   (0.25% LP /     capital feed      (each capped; boost gets only the remainder)           deeper pools,
    0.05% treas.)  the treasury      accrual halts at 99% of obligations                    more volume
```

- **Funded, never printed.** Emissions retarget to what the treasury actually collected; a
  **solvency stop** freezes accrual at 99% of outstanding obligations. The system cannot promise
  tokens it does not hold.
- **Fixed supply.** 100,000,000 TIMBS, hard-capped. No mint beyond it.
- **Prize-linked, not extractive.** The pot is paid from *yield on deposited capital* (the
  `TimbYieldVault`), so a player's principal stays theirs and refundable — closer to a
  prize-linked savings account than a lottery.

The "modules" below (swap, farm, staking, game, treasury, governance) are the parts of this one
machine — read them as gears, not a product menu.

---

## Contracts

| Contract | Address |
|----------|---------|
| TIMBSToken | `0x2Aaa61E2c08Ff61c93E960EcCd5Dd7fedF0bfaAa` |
| TimbSwapFactory | `0xCCd6d3f0A86042d2B7056eDd381d367126628AF5` |
| TimbSwapRouter v8 | `0x40C7Caf90817C9891D278Ec1400B9deb180911f1` |
| EligibleTokenRegistry | `0xbFF59a3408B2574AcE948F130f0fA2f2CB149F04` |
| GameRegistry (gen-3, keeper-driven activation) | `0x11C240577Cc522BE3e0f4b1ac61f916e35cfDD65` |
| TimbPrize (gen-3) | `0x6027a196b553cC016b2CA8fC4477B681a2Ca86AF` |
| Prize VRFEntropy (Chainlink VRF v2.5) | `0xa2AC62BF0FdD1D1ED148ea1c0555eEcD8829A393` |
| GasFaucet (TIMBS-only on testnet) | `0x0a59b7d61a4db317fad8697c3e3e1e6df4c7a04b` |
| TimbYieldVault | `0x43D833e828e2AF951527C2b573Eb70c358FfEB0B` |
| PrizeEscrow | `0x865C50d933e63BbE388EEAFa017AE634B0A6fB6D` |
| TimbStaking | `0xe776c7b700B190ED8248741F9b518B08d8733C8F` |
| TimbFarm | `0xE319E2206F71A5cD8dd2c411C6F29712935f9011` |
| TimbBoostFarm | `0x551D919D517aBa40D2b3A57a91973ad5Ad3CBd35` |
| TimbLockVault | `0x0157086E7670D1eFb15DC6b5158eE78279927a41` |
| TimbTreasury v4 | `0xd3F40042aFA8074EA68C9f61dE6aDADD539F0D5c` |
| TimbGovernance | not deployed on testnet (governance is off) |
| TIMBS/ETH Pair | `0x5a911CBfD2808Ad5214E842a0E8ae34d8199BB95` |
| WETH (Arb Sepolia) | `0x980B62Da83eFf3D4576C647993b0c1D7faf17c73` |
| USDC (Circle canonical, 6 dec) | `0x75faf114eafb1BDbe2F0316DF893fd58CE46AA4d` |
| LINK (Chainlink canonical) | `0xb1D4538B4571d411F07960EF2838Ce337FE1E80E` |

All TimbSwap contracts verified on [Sourcify](https://repo.sourcify.dev/421614/). WETH and USDC are the canonical Arbitrum Sepolia testnet tokens. `config.js` is the source of truth for addresses; the settler and keepers read it directly. Prior-generation game contracts are listed in [SPECS.md](./SPECS.md) — old tickets remain reclaimable there.

**Arbitrum One (mainnet):** `TimbAirdropDistributor` `0x955e5800245164EC4DCd1da9062115bBdA132c83` — the sink for the testnet-claim → mainnet-TIMB airdrop (1 TIMB per eligible claim, 10,000 TIMB cap, owner = Safe). **Paused until the public announcement.**

---

## Testnet Faucets

Everything runs on **Arbitrum Sepolia (Chain ID 421614)**. Grab gas and stables before you swap, farm, or play.

**TIMBS — [timbswap.xyz/faucet](https://timbswap.xyz/faucet/)** — for live players: hold an **Active** ticket in the prize game and claim **1 TIMBS every 24 h**. Cloudflare Turnstile on claim; eligibility and cooldown are enforced on-chain by `GasFaucet` as well as by the gatekeeper.

**Gas — Arbitrum Sepolia ETH** *(pick up to 3; each has its own daily limit)*

- [Alchemy Faucet](https://www.alchemy.com/faucets/arbitrum-sepolia) — drips directly on Arbitrum Sepolia
- [QuickNode Faucet](https://faucet.quicknode.com/arbitrum/sepolia) — Arbitrum Sepolia ETH
- [Chainlink Faucet](https://faucets.chain.link/arbitrum-sepolia) — Arbitrum Sepolia (also bridges from Sepolia)

**Stablecoins** *(up to 2)*

- [Circle USDC Faucet](https://faucet.circle.com/) — select **Arbitrum Sepolia**; mints the exact canonical USDC (`0x75faf114…46AA4d`) TimbSwap trades
- [Aave Testnet Faucet](https://app.aave.com/faucet/) — switch to **Arbitrum Sepolia** for test USDC / DAI / USDT balances to experiment with

> Tip: if a faucet is dry, get Sepolia ETH first (e.g. the Chainlink or Alchemy Sepolia faucet) and bridge to Arbitrum Sepolia via the [Arbitrum Bridge](https://bridge.arbitrum.io/).

---

## Connecting — extension or email

Every page connects through one flow in `config.js`. **Connect Wallet** offers two ways in:

- **Extension / in-app wallet** — MetaMask, Rabby, Brave, or a mobile wallet browser. Unchanged.
- **Continue with email** — a one-time code creates an embedded wallet ([Privy](https://www.privy.io/)),
  a plain `0x…` EOA, so a phone with no extension can still mint a ticket and claim from the faucet.
  Nothing on-chain changes — every contract keys on `msg.sender` as before. The key is split
  between Privy and the user's browser; TimbSwap never sees it and only receives the address.

Email wallets get the safety rails an extension would normally provide, all in `assets/email-login.js`:

- **Confirmation sheet** before every send / sign — the call decoded from a human-readable ABI
  (ticket, swap "you pay / receive ≥ min", claims), fee estimate, advanced gas / nonce, errors in place.
- **Wallet security** (wallet menu, email sessions only) — **authenticator-app MFA** (TOTP, QR enrol)
  and/or **passkey MFA** (Face ID / fingerprint / device PIN); once enrolled, Privy asks for a check
  before signing, at most once every 15 minutes. Either method can be removed again from the same sheet.
- **Export private key** — a warnings + disclaimer gate, then an emailed code and the MFA check,
  then the key masked on-page with a copy button (Privy's hosted copy button until client-side
  export is switched on for the app). For moving the wallet into MetaMask; treat the key as burned if
  it is ever pasted anywhere else.
- **Idle timeout** — any session (email or extension) older than 360 minutes idle is torn down and
  the page hard-refreshes to the gated view.

`PRIVY_APP_ID = ""` in `config.js` is the kill switch: the option disappears and every page behaves
exactly as before. Design notes, dashboard setup and the test checklist: [`dev-docs/EMAIL_LOGIN.md`](./dev-docs/EMAIL_LOGIN.md).

---

## The modules

Each is a gear in the engine above, not a standalone feature.

**AMM Swap** — Uniswap v2-style. 0.3% pool fee split 0.25% to LPs / 0.05% to the protocol. Testnet adds a 0.05% router fee (0.35% all-in); mainnet is 0.30% all-in, with half the protocol share sent to the prize pot. Supports `addLiquidity`, `addLiquidityETH`, `removeLiquidity`, `removeLiquidityETH`.

**Prize Game** — Perpetual round-based game. Each round = 6 segments of 60 min (59 min 45 s open + 15 s settlement). Players hold a **ticket** — a 6-character string (A–Z, 0–9, no repeats) that plays the next round. Every eligible swap nudges the active segment's digit upward on a continuous meter; when a segment closes its digit locks and the next becomes active. After all 6 lock, an exact match wins the pot. Segments settle **permissionlessly** once the open window elapses (anyone can call `settleSegment`). Entry can be paid in ETH or TIMBS; **extra rounds** cost `entryCostTIMBS` each (up to 12, non-refundable). Ticket principal stays refundable for **4 rounds** after the ticket's last eligible round (and if you win near the end, the refund window starts *after* your claim window closes — up to LER+6) and, while active, earns yield via the **TimbYieldVault** that grows the pot. Winners claim their prize on a separate, shorter clock — **2 rounds from the match** — and a lapsed prize recycles into the pot without touching the winner's principal window. At each segment close the locked letter is the nudge counter **jittered with the settling block's hash**, so swaps influence the outcome but nobody can aim it. The registry is keyed by a **game generation**: when a new TimbPrize is deployed and `startGame` runs, the generation bumps and every prior-game ticket goes inert — its principal is recoverable any time via **Reclaim principal** on the compete page — so a redeploy never contaminates the new game and never needs a fresh registry again.

**SwapTables** — Pari-mutuel roulette on TIMBS play-chips, run live on stream. A table seats up
to 12 wallets; each loads six chips, one per segment, and places them across seven pools (six
segment pools plus the round-wide **Repeats a Digit**). The six characters lock one at a time —
the drumroll — and each pool pays its winners pro-rata as it locks. Rake is graduated: **0% on an
uncontested pool**, ~4.87% at two wallets, easing toward 1.75% as more join — so the house earns most exactly when
tables are busy. Thin winning pools are topped up from the **UnderwriteReserve** toward
`stake × fair × 0.90`, funded by dead pots and half the rake — the rule being that more players
must never make any player's outcome worse. Unclaimed Repeats-a-Digit money rolls into a
cross-generation **DDJackpot** that pays a metered slice, stake-capped so a 5-chip bet cannot
drain what 1,000-chip bets built. Boards are immutable and redeployed per generation; the
SeedRegistry and DDJackpot span every generation; SegmentCrank batches locks for generations 4-7 only. **Generation 9** is live — each
character comes from its own Chainlink VRF draw (closing the selection edge the commit-reveal
fallback gave whoever opened the table), and the 100-TIMBS table seed is routed whole to the
UnderwriteReserve rather than split across pools, closing a two-wallet seed farm.

**LP Farming** — Stake TIMBS/ETH LP tokens to earn TIMBS emissions.

**Single-Asset Staking** — Stake TIMBS to earn distributions from protocol buybacks.

**Lock Vault** — Lock any whitelisted ERC-20 for 24–320 hours. Public registry.

**Governance** — TIMBS holders deposit voting power to vote on protocol proposals. Hybrid on-chain voting, owner execution.

---

## Hosting (since 2026-09-25)

> GitHub disabled Actions and Pages on this account on 2026-09-25 (an
> automated abuse flag on runner minutes; a support ticket is open). Nothing
> in the protocol changed. What moved:
>
> | Was | Now |
> |---|---|
> | Site on GitHub Pages | Cloudflare Worker with static assets; the bundle is built by `scripts/build-site.sh` and uploaded in the dashboard |
> | Keepers as GitHub Actions cron | Railway, one service per keeper under `scripts/keeper-loop.js`; see `scripts/RAILWAY.md` |
> | Bug reports via GitHub private advisory | **devhub@timbswap.xyz**; the advisory is accepted again whenever the repo is reachable |
> | Source browsed on GitHub | [timbswap.xyz/source](https://timbswap.xyz/source/), each contract cross-linked to Arbiscan and Sourcify |
>
> The workflows below are kept and gated on the repo variable
> `KEEPERS_HOST`; they run only when it is set to `actions`. Sections that
> describe GitHub Pages or Actions are left as written for when the account
> is restored.

---

## Repo Structure

```
TimbSwap/                ← served at the site root (Cloudflare Worker; GitHub Pages before 2026-09-25)
├── contracts/           ← 13 Solidity contracts (0.8.24, viaIR)
├── index.html           ← Landing page (site root: timbswap.xyz/)
├── style.css            ← global design system (all pages)
├── config.js            ← addresses + ethers helpers + connect flow (extension or email) + autoReconnect + idle timeout (all pages)
├── landing.js           ← landing-page script
├── waitlist.js / .css   ← mainnet waitlist form on the landing page (Supabase `waitlist` function + Resend)
├── assets/
│   └── email-login.js   ← "Continue with email": Privy bridge, confirm sheet, MFA, Wallet security, key export (loaded on demand)
├── vendor/              ← esbuild bundles: privy-core.js, webauthn.js, hpke.js, qrcode.js (see scripts/build-vendor.mjs)
├── start/               ← "First round in 2 minutes" onboarding   → /start/
├── swap/                ← Swap + Add/Remove Liquidity      → /swap/
├── compete/             ← Prize entry + claimWinnings       → /compete/
├── farm/                ← LP farm + TIMBS staking           → /farm/
├── lock/                ← Lock vault + public registry      → /lock/
├── gov/                 ← Governance proposals + voting     → /gov/
├── analytics/           ← Live metrics + event history      → /analytics/
├── explore/             ← V2 Pools explorer                 → /explore/
├── faucet/              ← Active-ticket TIMBS faucet        → /faucet/
├── quests/              ← Quests & points leaderboard       → /quests/
├── campaigns/           ← Competitions (dates, prizes)      → /campaigns/
├── bounty/              ← Bug bounty scope + rules          → /bounty/
├── litepaper/           ← One-document overview             → /litepaper/
├── docs/                ← User-facing documentation page    → /docs/
├── tables/              ← SwapTables: console, felt, watch, lobby → /tables/
│   ├── index.html       ←   operator console (open / arm / reveal / retire)
│   ├── play.html        ←   the felt — sit, load, place
│   ├── live.html        ←   the stream page (spectate, no wallet)
│   └── games.html       ←   every running table, read-only
├── CNAME                ← Custom domain (timbswap.xyz) for GitHub Pages (unused while hosted on Cloudflare)
├── dev-docs/            ← Internal design specs (not the /docs/ web page); EMAIL_LOGIN.md covers the email wallet
├── scripts/
│   ├── settler.js       ← Automated segment settler
│   ├── epoch.js         ← Reward-sweep distributor (every 6 rounds)
│   ├── faucet-worker.js ← Faucet keeper (drains reserved claims → dispense())
│   ├── fleet-heartbeat.js ← Liveness witness over the Actions API (alerts, never acts)
│   ├── settler-liveness.js ← Game-clock witness: is the prize segment past its grid mark, and why? (alerts, never settles)
│   ├── epoch-recon.js   ← Epoch witness: recomputes each keeper settlement from chain events and compares (alerts, never grants)
│   ├── faucet-recon.js  ← Faucet witness: pairs Supabase rows, Dispensed events and the contract clock (alerts, never dispenses)
│   ├── points-recon.js  ← Points witness: shadow ledger from the same events, compared to the board (alerts, never scores)
│   ├── dead-man.js      ← Pings an outside dead-man switch while the heartbeat is alive (the one call that leaves Actions)
│   ├── lib/             ← Shared keeper plumbing: config.js readers, chunked log scans, state files, Telegram
│   ├── seed-pools.js    ← Mainnet: seed blue-chip pools at Chainlink ratios (dry run by default)
│   ├── vault-to-pot.js  ← Admin: top up the live pot with ETH from the deployer wallet or the yield vault's free reserve (dry run by default)
│   ├── build-vendor.mjs ← Rebuilds vendor/*.js from pinned npm packages (esbuild)
│   ├── Deploy*.s.sol    ← Foundry deploy scripts (gen-3 migration has a pre-flight guard)
│   └── package.json
├── supabase/
│   ├── functions/       ← faucet-claim (gatekeeper), airdrop-dispatch (mainnet sender), waitlist, quests, rpc
│   └── migrations/      ← faucet_claims, airdrop_outbox + service_role-only RPCs
├── workers/             ← Cloudflare Worker: same-origin /api/rpc + /api/faucet-claim relay
├── .github/workflows/
│   ├── settler.yml      ← GitHub Actions cron (10 min + daily health) + self-chaining
│   ├── epoch.yml        ← Reward sweep
│   ├── faucet.yml       ← Faucet keeper (10 min)
│   ├── admin-fund-rewards.yml ← Manual owner grant to farm / staking when the waterfall has nothing to pour
│   ├── admin-vault-to-pot.yml ← Manual pot top-up from the deployer wallet or the yield-vault reserve (self-test gated on PRs)
│   ├── faucet-invariants.yml ← Read-only monitor: does the faucet claim record fit what the cooldown permits?
│   ├── fleet-heartbeat.yml ← Read-only witness: is every scheduled keeper still running? (dev-docs/KEEPER_FLEET.md)
│   ├── settler-liveness.yml ← Read-only witness: is the prize game where its clock says it should be?
│   ├── epoch-recon.yml  ← Read-only witness: did the epoch keeper grant what the chain says it should have?
│   ├── faucet-recon.yml ← Read-only witness: do the faucet's three records agree about who was paid?
│   ├── points-recon.yml ← Read-only witness: does the leaderboard say what the chain says?
│   ├── dead-man.yml     ← The external switch: no ping when Actions or the heartbeat stops
│   └── slither.yml      ← Static-analysis gate on the contracts
├── abi/                 ← hand-kept contract ABIs (for integrators)
├── CHANGELOG.md         ← Operator-facing log of live-deployment changes
├── SPECS.md             ← Full technical specs + addresses
├── ROADMAP.md           ← Shipped / next / vision + the mainnet graduation gate
├── CLAUDE.md            ← Agent rules for Claude Code
└── foundry.toml
```

---

## Settler

*Runs on Railway since 2026-09-25 (`scripts/RAILWAY.md`); the Actions description below applies when `KEEPERS_HOST=actions`.*

Segments settle automatically via GitHub Actions every 10 minutes (each run lingers across segment boundaries and dispatches the next, with the cron as backstop — the "cancelled" scheduled ticks in Actions are the concurrency group dropping redundant backstops, not failures). Health check fires daily at noon UTC. Telegram: an **ops** stream to a private chat and a **community** stream (round rollovers only) to the public group.

**Required secrets** (repo → Settings → Secrets → Actions):

| Secret | Value |
|--------|-------|
| `ARB_SEPOLIA_RPC` | Arbitrum Sepolia RPC URL |
| `SETTLER_PRIVATE_KEY` | Deployer wallet private key |
| `TELEGRAM_BOT_TOKEN` | Telegram bot token |
| `TELEGRAM_CHAT_ID` | Your Telegram chat ID |
| `TELEGRAM_CHAT_ID_PUBLIC` | (Optional) Community group chat ID — receives only confirmed round-rollover announcements |
| `X_API_KEY` / `X_API_SECRET` | (Optional) X app consumer keys — enables auto-posting settled rounds to @timbswap |
| `X_ACCESS_TOKEN` / `X_ACCESS_TOKEN_SECRET` | (Optional) X account tokens (must be Read and Write) |

Manual trigger: Actions → TimbSwap Settler → Run workflow → choose `settle` or `health`.

Notification volume and X posting (repo **Variables**, not secrets — these are public):

| Variable | Value |
|----------|-------|
| `TELEGRAM_OPS_MODE` | `all` (default: every arm/lock/settle beat to the ops chat), `errors` (only ❌ ⚠️ 💥 ♻️ alerts), or `off`. Never affects the community stream |
| `X_POST_MODE` | `all` (default), `winners` (only rounds that paid out), or `off` |
| `X_HASHTAGS` | (Optional) trailing hashtag line, e.g. `TimbSwap Arbitrum DeFi Markets DApp Testnet`. Space/comma separated (`#` added if missing); several `\|`-separated groups rotate by round number so posts aren't identical. Trimmed to fit X's 280-char limit. Unset ⇒ no hashtags |
| `X_HASHTAGS_WINNER` | (Optional) hashtag line for winner posts only; falls back to `X_HASHTAGS` when unset |

---

## Development

```bash
# Install
forge install OpenZeppelin/openzeppelin-contracts
forge install foundry-rs/forge-std

# Build
forge build

# Test
forge test -vvvv

# Deploy
cp env.example .env   # fill in values
forge script scripts/Deploy.s.sol \
  --rpc-url $ARB_SEPOLIA_RPC \
  --broadcast --verify --verifier sourcify
```

**Compiler:** Solidity 0.8.24, viaIR, optimizer 200 runs, EVM cancun.  
**Remix:** Enable viaIR in Advanced Configurations before compiling Router or TimbPrize.

---

## Tokenomics

- **Hard cap:** 100,000,000 TIMBS
- **Effective supply:** ~99,500,000 TIMBS *(500k at unreachable phantom pair address — permanent burn)*
- **Entry cost:** paid in ETH (`entryCostETH`) or TIMBS (`entryCostTIMBS`), both governance-adjustable
- **Extra rounds:** `entryCostTIMBS` each, up to 12 per ticket, non-refundable
- **Buyback:** 5% burned, 20% to reserve, 75% into the reward waterfall
- **Protocol fee:** 0.05% of swap volume (mainnet: half → prize pot, half → TimbTreasury)

---

## Ecosystem

Part of the 0xTimberZx ecosystem alongside BlockpotDAO, MessageBoard, and 0xFaucet.  
Frontend diagnostics are **local-only** during the capped beta (no telemetry leaves the browser); see the note in `config.js`.

---

## Contact

| Address | For |
|---------|-----|
| `devhub@timbswap.xyz` | Bug reports outside GitHub, bounty payout coordination, integration questions, abuse reports. See [SECURITY.md](./SECURITY.md) for the disclosure process. |
| `marketing@timbswap.xyz` | Partnerships, listings, press, and sponsorship. |
| `hello@timbswap.xyz` | Player support and anything else. |

Public channels: [@timbswap](https://x.com/timbswap) on X and [t.me/timbswapann](https://t.me/timbswapann) on Telegram.

---

## License

TimbSwap is **source-available** under the [Business Source License 1.1](./LICENSE).
You may read, audit, fork, and use the code for **non-production** purposes
(development, testing, research, security review). Production and commercial use
is not granted until the **Change Date (2029-07-25)**, on which the license
automatically converts to **MIT**.

The **TimbSwap** name, logo, and branding are trademarks of the project and are
**not** licensed — you may fork the code, but may not present a deployment as
"TimbSwap".
