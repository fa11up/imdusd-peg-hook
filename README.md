# imdusd-peg-hook

`PegFeeHook`: a Uniswap v4 hook for the imdUSD/USDC pool. Every swap pays the pool's LP fee, 0.01%. A swap
that pushes the price away from $1 and ends outside ±0.25% also pays a surcharge priced from where it **ends**,
rising in a straight line to 4.99% at $0.98 / $1.02 (5% in total with the LP fee) and flat beyond. The surcharge
is held as PoolManager claims, and anyone can `sweep(currency)` it to the imdUSD Treasury; no swap ever depends on
that transfer. Swaps that move the price back towards $1 pay only the LP fee.

The hook has no owner and no settings, and attaches to exactly one pool: (imdUSD, USDC), fee 0.01%, tick spacing 1,
opened at exactly $1. It reads both tokens' decimals itself.

**Restorer's cashback (branch `cashback-rebate`, PROTOTYPE: unaudited, not for launch).** The surcharge is reserved
in a pot for the side of $1 its swap ended on. A swap that moves the price back towards $1 releases the share of that
side's pot matching the distance it covered, measured between the ±2% cap and the ±0.25% band. Half of what is released
goes to the recipient the swapper names in `hookData` (`abi.encode(address)`), the rest is sweepable to the Treasury;
with no recipient, or on a swap that is itself surcharged, all of it is. Back inside the band, a side's pot is empty.
Payouts can never exceed half of surcharges already paid; pushing the price away to grow a pot pays 100% in for at
most 50% back; a restore split into steps is paid what one swap would be. Questions for the audit: (1) restoring
through one's own just-added liquidity, where others provide little in [band, cap], earns the cashback for a cheap
move; (2) a recipient the token refuses reverts that swap (the swapper's own choice); (3) REBATE_BPS = 50% is a
policy number. It adds the BEFORE_SWAP flag, so it is a different hook address and a different pool from `main`.

`script/DeployPegHook.s.sol` checks the tokens, that the Treasury belongs to imdUSD's vault and that USDC has not
blacklisted it, mines the CREATE2 salt (the address must carry exactly the hook's flag bits, `PEG_HOOK_FLAGS`), deploys
through the canonical CREATE2 deployer, and initializes the pool at $1 unless it is already open.

Adding liquidity: an empty pool's price can be moved for free, so a deposit carries its own bounds. Mint through
PositionManager with `amount0Max` / `amount1Max` from the script's `depositMaxes()`, which computes what the position
holds at exactly $1 plus a tolerance; at a moved price one side exceeds its maximum and the mint reverts.

Audit history: [`audits/AUDIT-2026-10-10.md`](audits/AUDIT-2026-10-10.md) (three rounds).

```
forge build
forge test                             # the fee arithmetic, offline
forge test --fork-url <mainnet RPC>    # everything, against the live v4 PoolManager
```
