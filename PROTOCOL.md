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
| **WOOD transfer tax** | Buy/sell tax on transfers into/out of a registered pair only; full WOOD skim → TaxCollector; convert() sells WOOD→USDG and splits stables | `taxBps = 0` (disabled); wallet-to-wallet, staking, mint/burn never taxed |
| **POL fees** (later) | Own WOOD/USDG LP NFT | 100% to Treasury |

### Transfer tax (WOOD only)

`WOOD.setTax(taxBps, platformFeeBps, platformWallet, treasuryWallet, lock)` (governor-only)
applies a tax to transfers where **either side is a registered `isTaxedPair`** — i.e. buys and
sells against a listed market — and nowhere else: plain wallet-to-wallet transfers, `Camp`
stake/unstake, and every protocol mint or burn (both have one side at `address(0)`) skip it
unconditionally, by construction. Addresses on the governor `isTaxExempt` list also skip tax
(immediate toggle, no delay queue) so the TaxCollector can sell WOOD into a taxed pair without
re-skimming itself.

`taxBps` is capped at `MAX_TAX_BPS = 2000` (20%) as a hard ceiling — a seatbelt against a
confiscatory rate, not a target. A non-zero `taxBps` requires a real `treasuryWallet`. Default
`taxBps = 0`: no tax anywhere.

**Routing (NET-style collector):** the full WOOD tax amount is sent to `treasuryWallet` only —
production points that address at `TaxCollector`. `platformFeeBps` / `platformWallet` remain on
`setTax` as a lockable config snapshot / event surface; they do **not** receive raw WOOD.
`TransferTaxed(from, to, tax, platformAmount=0, treasuryAmount=tax)` is emitted on every skim.

**TaxCollector.convert(woodAmount, minUsdgOut)** (permissionless once configured):

1. Sells WOOD for USDG via a governor-set Uniswap V2-style `router` (and optional `pool` address
   for ops; no live WOOD market yet, so both are settable not constructor-fixed).
2. Enforces an **on-chain oracle floor** so a sandwich against `convert(0, 0)` cannot dump
   accumulated WOOD into a manipulated pool. `woodOracle` (WOOD/USD, same `IPriceOracle`
   surface as Treasury) and `maxSlippageBps` are governor-set; effective
   `amountOutMin = max(caller minUsdgOut, minUsdgFromOracle(amountIn))`. Callers may only
   tighten the floor — a zero or low `minUsdgOut` is ignored in favor of the oracle value.
3. Splits the resulting USDG by `treasuryBps` / `teamBps` (must sum to 10_000) to
   `treasuryWallet` / `platformWallet` on the collector.
4. Emits `Converted(caller, woodIn, usdgOut, treasuryAmount, teamAmount)`.

Setup order (governor): deploy TaxCollector → `WOOD.setTaxExempt(collector, true)` →
`WOOD.setTax(..., treasuryWallet=collector, ...)` → `setTaxedPair(pool, true)` →
collector `setRouter` / `setRecipients` / `setSplit` / `setWoodOracle` / optional
`setMaxSlippageBps`.

**Locking:** passing `lock = true` freezes `taxBps`/`platformFeeBps`/both wallets permanently —
`setTax` reverts on every call after that, forever, with no unlock path. `setTaxedPair` and
`setTaxExempt` are intentionally *not* covered by the lock — new markets can still be listed and
the collector can stay exempt after the rate is frozen.

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

Two complementary mechanisms; only the bid half is permissionless.

### Redeem (permissionless floor — InverseBond shape)

`Redeem.sol` is a standing right for anyone to burn WOOD for USDG from the Treasury at a
governor-set discount to `treasury.backingPerWood()` (default `spreadBps = 150`, i.e. 1.5%
below RFV). No market oracle, no DEX, no keeper:

1. Caller approves WOOD → `redeem(woodAmount, minUsdgOut)`.
2. Contract `transferFrom`s WOOD to itself, then `burn`s **only its own balance** (needs
   `WOOD_MINTER` solely for that scoped burn — never burns an arbitrary address).
3. Pays USDG via `treasury.withdraw` (needs `RESERVE_SPENDER`), scaled to USDG's native
   decimals (production USDG is 6-dec; the contract reads `decimals()` once at deploy).
4. Rate-limited per Camp-aligned 8h epoch: at epoch open, cap = `capBps` of then-current
   `excessReserves()` (default 10%), frozen for the epoch and depleted as redemptions land.

If market price drops below this payout, buying WOOD and redeeming here is free money — that
buy pressure is the floor defense. Premium to RFV remains market opinion; RFV is the contract
fact.

### RangeBound (guardian ask side — unchanged)

- Band around `backingPerWood`: default 95%–105%, spot from `woodSpotOracle`
- `executeAsk` (sell into strength above the upper band) stays **guardian-operated** exactly
  as today — there is no NET-style equivalent for the ask, so it is not automated here
- `executeBid` remains as a skeleton for discretionary guardian ops; day-to-day floor defense
  is now Redeem, not a deferred DEX bid

## Roles (`Authority`)

| Role | Used by |
| --- | --- |
| `GOVERNOR` | Asset registry, rates, markets, band, Redeem spread/cap/pause |
| `GUARDIAN` | RangeBound ops, emergency posture later |
| `RESERVE_DEPOSITOR` | Privileged treasury deposits |
| `RESERVE_SPENDER` | Vault, RangeBound, **Redeem** (USDG outflows) |
| `REWARD_MANAGER` | Camp (and bootstrap minter) |
| `BOND_MANAGER` | Heist |
| `WOOD_MINTER` | Treasury (mint path) and **Redeem** (burn-only of WOOD it already holds) |

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
