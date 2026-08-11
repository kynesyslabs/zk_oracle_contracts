# Deployments

## Sepolia (chainId 11155111) — 2026-08-11

| Contract | Address |
|---|---|
| `ZKIdentityRegistry` | `0x99802D4413ed256050464C6aB3e4aCa7a00c1c2f` |
| `Groth16Verifier` (identity_with_merkle) | `0x07F4dABF1D9671A3b9eAacD4013bD2557aA0da7A` |

- **Owner / initial oracle:** `0x288DFc0fF2560C885e3d2C1Fa6904750BeC8380d`
- **Circuit:** `identity_with_merkle` (Groth16, BN254). Proving key + wasm are served
  from `https://files.demos.sh/zk-circuits/v1/`; the verifier's verification key matches
  that zkey (checked with `snarkjs zkey export verificationkey`).
- **Public signals (order):** `[nullifier, merkleRoot, context]`.

## Trust model

- **Root finalisation — trusted committee.** Whitelisted oracles vote a Poseidon merkle
  root; once `threshold` agree, it's finalised. Add operators + raise the threshold to
  decentralise without redeploying. `pause` / `adminSetLatestRoot` / `maxBlockAdvance`
  provide recovery.
- **Inclusion — trustless.** `verifyIdentity(a, b, c, [nullifier, merkleRoot, context])`
  verifies a Groth16 proof of membership against a *finalised* root and burns the
  nullifier (replay-proof). `checkIdentity(...)` is the non-mutating view. So a claim
  stands without trusting the caller: the committee vouches for the root, the proof
  proves membership.

## Consuming inclusion verification

Generate a proof client-side with the SDK `ProofGenerator` (against the current merkle
root from the node's `/zk/merkle-root`), then call `verifyIdentity` / `checkIdentity`.
Format the calldata with `snarkjs zkey export soliditycalldata` — note snarkjs emits the
`B` point with its coordinate pair swapped for the Solidity verifier's expected order.

## Deploy

```bash
INITIAL_ORACLE=0x... EVM_RPC_URL=https://... \
  forge script script/DeployZKIdentity.s.sol --rpc-url "$EVM_RPC_URL" --private-key "$PK" --broadcast
```
