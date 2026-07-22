# SherwoodDAO Protocol — Phase 1

**Status:** implementation in progress (Foundry). Nothing is production-deployed.

A treasury-backed reserve currency (`WOOD`) with Olympus-shaped seatbelts from day one: excess-only minting, 8-hour watches, bonds (Heist), backing-floor loans (Vault), and a range-bound stability skeleton.

## Module map

| Module | Contract | Status |
| --- | --- | --- |
| Roles | `Authority` | Live |
| Currency | `WOOD` | Live |
| Staked shares | `sWOOD` (deployed by Camp) | Live |
| Reserves / RFV | `Treasury` | Live |
| Stake + watches | `Camp` | Live |
| Bonds | `Heist` | Live (single market) |
| Borrow vs backing | `Vault` | Live (core math) |
| Band ops | `RangeBound` | Skeleton (band gating + hooks) |
| Oracles | `MockOracle`, `ManualOracle` | Bootstrap |
| Council | — | Deferred |

## Backing formula

All values in 18-decimal USD units (“WAD”).

```
assetValue(token) = balance_normalized_18 * oraclePrice * uiMultiplier / 1e36
totalReserves     = Σ assetValue(token)   for enabled assets
excessReserves    = max(totalReserves − WOOD.totalSupply, 0)
backingPerWood    = totalReserves * 1e18 / totalSupply   (or 1e18 if supply = 0)
```

**Invariant:** Camp rebases and Heist claims may only mint WOOD while `amount ≤ excessReserves`.  
**Target:** 1 WOOD is backed by ≥ $1 of risk-free value (RFV). Premium to RFV is market opinion; RFV is the contract fact.

`uiMultiplier` (≤ 1e18) haircuts non-cash assets (e.g. equities at 0.9e18).

## The Camp (staking + watches)

- Stake WOOD → mint **sWOOD shares** at current index.
- `wood = shares * index / 1e9`.
- Every **8 hours** anyone may call `rebase()`:
  - `reward = stakedWood * rewardRateBps / 10_000` (governor-set; default 10 bps = 0.10%/epoch)
  - Cap reward by `excessReserves`
  - Mint reward WOOD into Camp; raise `index` so all stakers share pro-rata
- sWOOD is **non-rebasing** (standard ERC20). UI should show `Camp.woodBalanceOf(user)`.

## Protocol revenue (Olympus-shaped)

Sherwood does **not** skim revenue to an *undisclosed* platform wallet — every stream below lands
100% in the Treasury unless a governor has explicitly opted into one of two disclosed, on-chain,
off-by-default exceptions: the Heist founder fee, and the WOOD transfer tax. Nothing is hidden:
every split, every recipient, and every resulting mint or skim is public state and a public event.

| Stream | Mechanism | Default |
| --- | --- | --- |
| **Bond RFV profit** | Quote USD in − RFV of (user WOOD + protocol mint) out | Enforced: never sell below `max(backing, $1)` adjusted for protocol share |
| **Bond protocol mint** | Extra WOOD minted on each claim (V1 DAO mint, lite); split between Treasury and an optional disclosed founder fee | `protocolMintBps = 1000` (10% of user payout); `founderFeeBps = 0` (0% of that 10% — i.e. 100% to Treasury) |
| **Vault interest** | Cooler-style borrow APR; repay → Treasury | `interestBps = 50` (0.50% APR), 100% to Treasury, no founder-fee split |
| **Stake / unstake** | — | **0** |
| **WOOD transfer tax** | Buy/sell tax on transfers into/out of a registered pair only; split between Treasury and a platform wallet | `taxBps = 0` (disabled); wallet-to-wallet transfers, staking, and protocol mint/burn are never taxed regardless |
| **POL fees** (later) | Own WOOD/USDG LP NFT | 100% to Treasury |

### Transfer tax (WOOD only)

`WOOD.setTax(taxBps, platformFeeBps, platformWallet, treasuryWallet, lock)` (governor-only)
applies a tax to transfers where **either side is a registered `isTaxedPair`** — i.e. buys and
sells against a listed market — and nowhere else: plain wallet-to-wallet transfers, `Camp`
stake/unstake, and every protocol mint or burn (both have one side at `address(0)`) skip it
unconditionally, by construction, not by exemption list. `taxBps` is capped at `MAX_TAX_BPS =
2000` (20%) as a hard ceiling regardless of what governance sets — a seatbelt against a
confiscatory rate, not a target. `platformFeeBps` is a share **of the tax itself** (10,000 = the
whole tax to platform), and a non-zero `taxBps` requires both `platformWallet` and
`treasuryWallet` to be real addresses in the same call — so a rate can never go live pointed at an
unset address (which would otherwise burn the skim into the zero address unnoticed). Default
`taxBps = 0`: no tax anywhere, matching the shipped "no platform wallet" behavior exactly. Every
taxed transfer emits `TransferTaxed(from, to, tax, platformAmount, treasuryAmount)` alongside the
ordinary `Transfer` events — the split is always independently verifiable from an explorer.

**Locking:** passing `lock = true` freezes `taxBps`/`platformFeeBps`/both wallets permanently —
`setTax` reverts on every call after that, forever, with no unlock path. This is deliberately
stricter than the founder fee (which stays governor-adjustable indefinitely): it matches a
comparable live token's actual on-chain shape, where the rate has no setter at all after genesis
and is fixed forever. `setTaxedPair` is intentionally *not* covered by the lock — new markets can
always be listed even after the rate itself is frozen, matching that same reference token's
accepted, disclosed behavior (its guardian can still extend the tax to newly listed pairs
indefinitely). Until locked, `setTax` can be called repeatedly — useful for iterating during
testnet rollout before committing to a final rate on mainnet.

`setTaxedPair` has no live-pool validation (unlike Heist's bond quote check) — Sherwood has no
deployed WOOD market yet, so there's nothing on-chain to validate a pair address against. The
governor registers the real pair once one exists.

### Founder fee (Heist only)

`Heist.setFounderFee(recipient, bps)` (governor-only) splits the *existing* bond protocol mint —
it does not add a new one. `bps` is a share **of the protocol mint itself** (0–10,000), so it
stays valid at any `protocolMintBps` value: `founderAmount = protocolShare * founderFeeBps /
10_000`, `treasuryAmount = protocolShare − founderAmount`. Total protocol-side dilution
(`protocolMintBps` of user payout) is identical whether this is enabled or not — only the
destination of that fixed share changes. `bps = 0` (the shipped default) sends 100% to Treasury,
matching pre-founder-fee behavior exactly. A non-zero `bps` requires a real `recipient`; setting
both back to zero disables it. Every claim emits `BondClaimed(user, userAmount, treasuryAmount,
founderAmount)` — the split is always independently verifiable from an explorer, not just trusted
from a dashboard.

### Bond pricing (Heist)

```
floor          = max(backingPerWood, $1)
minBondPrice   = floor * (1 + protocolMintBps / 10_000)
controlVariable ≥ minBondPrice   // USD per WOOD, 18-dec
userPayout     = quoteUSD / controlVariable
protocolShare  = userPayout * protocolMintBps / 10_000
require (userPayout + protocolShare) * floor ≤ quoteUSD
```

Higher `controlVariable` → fewer WOOD per USD → larger RFV gap (protocol profit).  
**No discount bonds** (controlVariable may not sit below the RFV floor).

On `claim`: mint `userPayout` to bonder and `protocolShare` to **Treasury** (held WOOD = protocol-owned inventory).

## The Heist (bonds)

Single market in Phase 1:

- Pay quote asset (e.g. USDG) → quote lands in **Treasury** (raises reserves)
- Vest user WOOD over `vestingTerm`; mint from excess **on claim**
- See protocol revenue table above for pricing + protocol mint

## The Vault

- Collateral: sWOOD shares  
- Debt asset: USDG (from Treasury reserves; Vault holds `RESERVE_SPENDER`)  
- Max LTV: **95% of RFV** (`backingPerWood * woodValue`), **not** spot  
- Interest: **0.50% APR** fixed, continuous on touch; **interest repaid first**, 100% to Treasury  
- Metrics: `totalInterestAccrued` / `totalInterestRepaid`  
- No price liquidations in Phase 1 (guardian/owner operational path only)

## Range-bound stability

- Band around `backingPerWood`: default 95%–105%  
- Spot from `woodSpotOracle`  
- `executeBid` / `executeAsk` guardian-gated; real DEX routing deferred  

## Roles (`Authority`)

| Role | Used by |
| --- | --- |
| `GOVERNOR` | Asset registry, rates, markets, band |
| `GUARDIAN` | RangeBound ops, emergency posture later |
| `RESERVE_DEPOSITOR` | Privileged treasury deposits |
| `RESERVE_SPENDER` | Vault, RangeBound withdrawals |
| `REWARD_MANAGER` | Camp (and bootstrap minter) |
| `BOND_MANAGER` | Heist |
| `WOOD_MINTER` | Treasury (only path that mints WOOD) |

Owner of Authority is the bootstrap admin; later transfer to Council (`Authority` is
`Ownable2Step`, so transfer requires the new owner to `acceptOwnership()`).

**The owner implicitly holds every role** (`Authority.hasRole` returns `true` for the owner
regardless of the role checked), including `RESERVE_SPENDER` — so the owner can currently call
`Treasury.withdraw(token, to, amount)` directly, with no excess-reserves check, no cap, no
timelock, no multisig. This is a standard trusted-admin pattern for a Phase-1 protocol with no
external depositors, and it's how the owner would realistically extract value pre-launch — but
it is in direct tension with "protocol-owned, not owner-owned" once anyone else has deposited
real reserves. Before that point, this needs to become a timelock and/or multisig, or the
`RESERVE_SPENDER`/`GOVERNOR` roles need to be split off the raw `owner()` bypass in `hasRole`.

## Explicitly deferred

- On-chain Council / sWOOD voting  
- Real Robinhood Chain RWA oracles  
- Multi-market Heist, LP bonds  
- Keeper bots for RBS  
- Upgradeable proxies  
- Frontend wallet wiring  

## Commands

```sh
cd contracts
forge test -vv
forge build --sizes
# local stack
anvil &
forge script script/DeployLocal.s.sol --rpc-url http://127.0.0.1:8545 --broadcast
```
