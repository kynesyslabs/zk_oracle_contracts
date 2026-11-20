# Deployments

## Ethereum Sepolia (chainId 11155111), 2026-08-11: RETIRED, do not use

| Contract | Address |
|---|---|
| `ZKIdentityRegistry` | `0x99802D4413ed256050464C6aB3e4aCa7a00c1c2f` |
| `Groth16Verifier` (identity_with_merkle) | `0x07F4dABF1D9671A3b9eAacD4013bD2557aA0da7A` |

- **Owner / initial oracle:** `0x288DFc0fF2560C885e3d2C1Fa6904750BeC8380d`
- Unsafe, superseded by the next deployment of this repository:
  - it read the merkle root from public signal 1, which is the prover-chosen
    context, so a proof against a private tree passed by setting its context to a
    finalised root;
  - its verifier carries the single-party v1 key (`files.demos.sh/zk-circuits/v1/`),
    not the ceremony-final key, so proofs from the SDK and node do not verify;
  - it has no chain epochs, so roots of a reset Demos chain stay valid.
- `pause()` only stops voting. Its `verifyIdentity` / `checkIdentity` have no pause
  check, so the forgeable inclusion path stays live on that address for good. No
  consumer may call it or trust an `IdentityVerified` event from it.

## Trust model

- **Root finalisation, trusted committee.** Whitelisted oracles vote a Poseidon
  merkle root of the current chain epoch; once `threshold` agree, it is finalised.
  `pause` / `adminSetLatestRoot` / `revokeRoot` / `startEpoch` provide recovery.
- **Inclusion, trustless.** `verifyIdentity(a, b, c, [nullifier, context, merkleRoot])`
  verifies a Groth16 proof of membership against a root finalised in the current
  epoch and burns the nullifier for the calling address (replay-proof per
  consumer). `checkIdentity(...)` is the non-mutating view.

## Consuming inclusion verification

Generate a proof client-side with the SDK `ProofGenerator` (against the current
merkle root from the node's `/zk/merkle-root`), then call `verifyIdentity` /
`checkIdentity` from the consumer's own contract (see the README, "Consuming
inclusion proofs"). Format the calldata with `snarkjs zkey export soliditycalldata`;
snarkjs emits the `B` point with its coordinate pair swapped for the Solidity
verifier's expected order. Public signals are `[nullifier, context, merkleRoot]`.

## Deploy

See the README, "Deploy" and "Production deployment".
