# imdusd-peg-hook

`PegFeeHook`: a Uniswap v4 hook giving the imdUSD/USDC pool a dynamic LP fee. Near $1, and for any trade
that moves the price back towards $1, the fee is 0.01%. A trade that pushes the price further from $1 pays
more, rising in a straight line from the ±0.25% band's edge to 5% at $0.98 / $1.02. The hook has no owner,
no settings and no storage, and attaches to exactly one pool: (imdUSD, USDC), dynamic fee, tick spacing 1,
opened at exactly $1.

`script/DeployPegHook.s.sol` mines the CREATE2 salt (the address must carry exactly the BEFORE_INITIALIZE
and BEFORE_SWAP flag bits), deploys through the canonical CREATE2 deployer, and initializes the pool at $1.

```
forge build
forge test --fork-url <mainnet RPC>    # the tests run against the live v4 PoolManager
```
