# zk-oracle-contracts

Solidity smart contract for publishing verified ZK merkle roots on-chain.
Deployed once — then any number of oracle servers can vote to finalise new roots.

## Requirements

- [Foundry](https://book.getfoundry.sh/getting-started/installation)
- [Bun](https://bun.sh)

## Setup

```bash
bun install
cp .env.example .env
```

## Build

```bash
forge build
```

## Deploy

```bash
NETWORK=base-sepolia bun run scripts/deploy.ts
```

Available network presets:

| `NETWORK`          | Chain            |
|--------------------|------------------|
| `base-sepolia`     | Base Sepolia     |
| `base-mainnet`     | Base Mainnet     |
| `eth-mainnet`      | Ethereum Mainnet |
| `eth-sepolia`      | Ethereum Sepolia |
| `polygon-mainnet`  | Polygon Mainnet  |
| `arbitrum-mainnet` | Arbitrum One     |
| `local`            | localhost:8545   |

For a custom RPC use `EVM_RPC_URL` instead of `NETWORK`:

```bash
EVM_RPC_URL=https://your-rpc ORACLE_PRIVATE_KEY=0x... bun run scripts/deploy.ts
```

After deployment the script prints `CONTRACT_ADDRESS=0x...` — copy it into the oracle server's `.env`.

## Environment variables

| Variable             | Required | Description                                            |
|----------------------|----------|--------------------------------------------------------|
| `NETWORK`            | one of   | Network preset (see table above)                       |
| `EVM_RPC_URL`        | one of   | Custom RPC URL (overrides `NETWORK`)                   |
| `ORACLE_PRIVATE_KEY` | yes      | Deployer wallet key — becomes initial oracle address   |
| `ORACLE_ADDRESS`     | no       | Override oracle address (defaults to deployer)         |

## Contract interface

| Function | Access | Description |
|---|---|---|
| `submitVote(rootHash, blockNumber, leafCount)` | oracle | Cast a vote for a new root |
| `latestRoot()` | public | Latest finalised root |
| `rootByBlock(blockNumber)` | public | Historical root by Demos block number |
| `getVoteCount(rootHash, blockNumber, leafCount)` | public | Pending vote count |
| `addOracle(address)` | owner | Add an oracle |
| `removeOracle(address)` | owner | Remove an oracle |
| `setThreshold(n)` | owner | Change vote threshold |
| `transferOwnership(address)` | owner | Transfer ownership |
