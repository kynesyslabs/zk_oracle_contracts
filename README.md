# zk-oracle-contracts

`ZKIdentityRegistry`: publishes Demos ZK identity merkle roots on an EVM chain
(committee of oracles) and verifies Groth16 inclusion proofs against them
(trustless). `Verifier.sol` is the Groth16 verifier of the Demos
`identity_with_merkle` circuit.

## Requirements

- [Foundry](https://book.getfoundry.sh/getting-started/installation)
- `forge-std` in `lib/` (`git clone --depth 1 https://github.com/foundry-rs/forge-std lib/forge-std`)

## Build and test

```bash
forge build
forge test
```

## Circuit and verification key

- Circuit: `identity_with_merkle` (Groth16, BN254, depth 20), from the Demos node
  (`src/features/zk/circuits/identity_with_merkle.circom`).
- Public signals, in order: **`[nullifier, context, merkleRoot]`**. Circom emits the
  output first, then the public inputs in the order of
  `main {public [context, merkle_root]}`. The registry reads the root from
  position 2; the context is chosen freely by the prover and is never a root.
- Verification key: the ceremony-final key (19 contributions in
  `kynesyslabs/zk_ceremony` plus the drand mainnet round 6629366 beacon), the same
  file the node verifies with (`src/features/zk/keys/verification_key_merkle.json`).
  A copy is in `keys/verification_key_merkle.json`:

  | File | sha256 |
  |---|---|
  | `keys/verification_key_merkle.json` | `e02d5858493ffe323d2eb78c67ea02dd1d0f80662f68f702fa8cdda356af41fd` |
  | `identity_with_merkle_final.zkey` (ceremony `final/`) | `591c50c67cb669c09874b0a9cb544c678594b0fd4fee612539c86fb0a97bec56` |

- `contracts/Verifier.sol` is regenerated from the ceremony-final zkey:

  ```bash
  snarkjs zkey export solidityverifier identity_with_merkle_final.zkey contracts/Verifier.sol
  snarkjs zkey export verificationkey  identity_with_merkle_final.zkey keys/verification_key_merkle.json
  ```

  `test/Verifier.t.sol` fails if any constant in `Verifier.sol` differs from
  `keys/verification_key_merkle.json`, and verifies a real proof made with the
  ceremony zkey (`test/fixtures/identity_proof.json`) through the verifier and the
  registry. After any key change, regenerate the fixture too.

## Chain epochs

A Demos chain can be reset (beta runs on its own chain and is wiped again at TGE),
and block numbers restart. Every root is bound to an epoch, identified by the
chain's block-0 hash (`getChainIdentity` → `genesisHash` on the node):

- `submitVote(genesisHash, root, block, leafCount)` reverts with `WrongEpoch` unless
  `genesisHash` is the current epoch's.
- `startEpoch(genesisHash)` (owner) opens a new epoch: clears the latest root so
  block numbers start from 1 again, retires all roots of earlier epochs from
  `verifyIdentity` / `checkIdentity`, and orphans their pending votes.
- Nullifiers are kept across epochs. An application that wants one claim per chain
  should put the chain into its proof context.

## Consuming inclusion proofs

- Call `verifyIdentity` from your own contract, not from an EOA, and derive the
  proof context from your contract's address (plus any per-use salt). Nullifiers
  are spent per caller (`nullifierUsed(caller, nullifier)`): someone replaying a
  user's proof first burns it only for their own address, and two applications
  never collide.
- A proof is not bound to its submitter. `IdentityVerified.caller` is whoever
  called, which proves nothing about who generated the proof; tie the claim to an
  account inside your own contract.
- `checkIdentity` answers for `msg.sender`: false once that caller spent the
  nullifier.
- `revokeRoot` is permanent: a revoked root never verifies again, cannot be voted
  or set back, and clears the latest root when it is the latest.

## Contract interface

| Function | Access | Description |
|---|---|---|
| `submitVote(genesisHash, rootHash, blockNumber, leafCount)` | oracle | Vote for a root of the current epoch |
| `verifyIdentity(a, b, c, [nullifier, context, root])` | anyone | Verify a proof against a current-epoch root, burn the nullifier for the caller |
| `checkIdentity(a, b, c, [nullifier, context, root])` | view | Same check without burning (false if the caller spent it) |
| `nullifierUsed(caller, nullifier)`, `revokedRoot(root)` | view | Spent nullifiers per caller, revoked roots |
| `isFinalisedRoot(root)` | view | Root finalised in the current epoch |
| `getLatestRoot()` / `latestRoot()` | view | Latest root `(root, block, leafCount, updatedAt, epochId)` |
| `currentEpoch()` | view | `(epochId, genesisHash)` |
| `rootByBlock(block)` / `rootByEpochBlock(epoch, block)` | view | Historical roots |
| `currentVoteKey`, `getVoteCount`, `hasVoted` | view | Pending votes of the current epoch and oracle set |
| `addOracle`, `removeOracle`, `setThreshold` | owner | Committee management (events on every change) |
| `startEpoch(genesisHash)` | owner | Track a new or reset Demos chain |
| `pause`, `unpause` | owner | Halt voting and inclusion checks (`verifyIdentity` reverts, `checkIdentity` returns false) |
| `adminSetLatestRoot`, `revokeRoot` | owner | Recover from a bad finalisation |
| `transferOwnership(newOwner)`, `acceptOwnership()` | owner / pending owner | Two-step ownership transfer |

`removeOracle` bumps `oracleSetVersion`, which is part of the vote key, so a
removed oracle's pending votes stop counting. It refuses to drop the set below
`threshold`; lower the threshold first.

## Deploy

```bash
cp .env.example .env   # fill in, then: set -a; . ./.env; set +a
forge script script/DeployZKIdentity.s.sol \
  --rpc-url "$EVM_RPC_URL" --account <deployer> --broadcast
```

The script deploys `Groth16Verifier` and `ZKIdentityRegistry(ORACLES, THRESHOLD,
verifier, DEMOS_GENESIS_HASH)` and, when `OWNER` is set, starts the ownership
transfer to it; the new owner must call `acceptOwnership()`.

## Production deployment

Required before the registry backs anything of value:

- **Owner = a Safe multisig behind a timelock.** The owner can add oracles, lower
  the threshold, set the latest root and start epochs, so a single key owning the
  registry is a single point of compromise. Transfer ownership to the timelock,
  administered by the Safe, and accept it from there.
- **At least 3 oracles from independent operators, threshold ≥ 2.** Each oracle
  reads several Demos nodes and only votes on a quorum of identical answers.
  The committee and its threshold are constructor arguments, so the registry is
  never live with a smaller committee while ownership is being handed over.
- **Oracle keys are separate from the owner key**, one key per oracle, held only by
  that oracle's operator.
- Record every deployment in `DEPLOYMENTS.md`, including the epoch genesis hash.

## License

MIT, see [LICENSE](LICENSE). One exception: `contracts/Verifier.sol` is generated by
[snarkJS](https://github.com/iden3/snarkjs) from its Groth16 verifier template and
keeps that template's GPL-3.0 header.
