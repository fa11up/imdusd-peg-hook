# imdusd-peg-hook

`PegFeeHook`: a Uniswap v4 hook for the imdUSD/USDC pool. Every swap pays the pool's LP fee, 0.01%. A swap
that pushes the price away from $1 and ends outside ±0.25% also pays a surcharge priced from where it **ends**,
rising in a straight line to 4.99% at $0.98 / $1.02 (5% in total with the LP fee) and flat beyond. The surcharge
goes to the imdUSD Treasury. Swaps that move the price back towards $1 pay only the LP fee.

The hook has no owner, no settings and no storage, and attaches to exactly one pool: (imdUSD, USDC), fee 0.01%,
tick spacing 1, opened at exactly $1. It reads both tokens' decimals itself.

`script/DeployPegHook.s.sol` checks the tokens and that the Treasury belongs to imdUSD's vault, mines the CREATE2
salt (the address must carry exactly the BEFORE_INITIALIZE, AFTER_SWAP and AFTER_SWAP_RETURNS_DELTA bits), deploys
through the canonical CREATE2 deployer, and initializes the pool at $1 unless it is already open. Run its
`checkPrice()` right before adding liquidity.

Audit history: [`audits/AUDIT-2026-10-10.md`](audits/AUDIT-2026-10-10.md).

```
forge build
forge test --fork-url <mainnet RPC>    # the tests run against the live v4 PoolManager
```
