// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @notice Groth16 verifier generated from the Demos `identity_with_merkle` circuit
///         (snarkjs `zkey export solidityverifier`). Public signals, in order:
///         [nullifier, context, merkleRoot]: circom emits outputs first, then the
///         public inputs in the order of `main {public [context, merkle_root]}`.
interface IZKVerifier {
    function verifyProof(
        uint[2] calldata a,
        uint[2][2] calldata b,
        uint[2] calldata c,
        uint[3] calldata input
    ) external view returns (bool);
}

/**
 * @title ZKIdentityRegistry
 * @notice Demos ZK identity anchor. Two layers with different trust models:
 *
 *   1. Root finalisation (trusted committee): whitelisted oracles vote a Poseidon
 *      merkle root from the Demos network on-chain; once `threshold` independent
 *      oracles agree, the root is finalised. Roots are bound to a chain epoch (the
 *      Demos block-0 hash), so a chain reset retires every root of the old chain.
 *
 *   2. Inclusion (trustless): `verifyIdentity` accepts a Groth16 proof that a
 *      commitment is included in a root finalised in the current epoch, verifies
 *      it on-chain against the circuit's verifier, and burns the nullifier for
 *      the calling address so a proof can't be replayed against that caller.
 *
 *   Consumers call `verifyIdentity` from their own contract and derive the proof
 *   context from that contract's address. Nullifiers are spent per caller, so a
 *   third party replaying a user's proof first burns it only for itself, and two
 *   applications never share a nullifier space. The proof carries no binding to
 *   who submits it: `IdentityVerified.caller` says who called, not who proved.
 */
contract ZKIdentityRegistry {
    /// @dev Positions in the circuit's public signals.
    uint256 internal constant SIGNAL_NULLIFIER = 0;
    uint256 internal constant SIGNAL_CONTEXT = 1;
    uint256 internal constant SIGNAL_MERKLE_ROOT = 2;

    address public owner;
    address public pendingOwner;
    uint256 public threshold;
    bool public paused;

    /// @notice The Groth16 verifier for the `identity_with_merkle` circuit.
    IZKVerifier public immutable verifier;

    mapping(address => bool) public isOracle;
    address[] public oracleList;

    /// @notice Bumped whenever an oracle is removed. It is part of the vote key,
    ///         so a removed oracle's pending votes stop counting.
    uint256 public oracleSetVersion;

    /// @notice Current chain epoch. The id counts up on every `startEpoch`, so a
    ///         genesis hash seen before still opens a fresh epoch with no roots.
    uint256 public epochId;
    bytes32 public epochGenesisHash;
    mapping(uint256 => bytes32) public genesisHashOfEpoch;

    struct RootEntry {
        bytes32 rootHash;
        uint256 demosBlockNumber;
        uint256 leafCount;
        uint256 updatedAt;
        uint256 epochId;
    }

    RootEntry public latestRoot;
    mapping(uint256 => mapping(uint256 => RootEntry)) public rootByEpochBlock;

    /// @notice Epoch a root was last finalised in. Inclusion is monotonic within
    ///         a chain, so any root of the current epoch is accepted; roots of an
    ///         older epoch describe a chain that no longer exists.
    mapping(bytes32 => uint256) public rootEpoch;

    /// @notice Spent nullifiers per caller, so a given (identity, context) proof
    ///         verifies once for each consumer. Kept across epochs: a consumer that
    ///         wants a fresh claim per chain must use a per-chain context.
    mapping(address => mapping(uint256 => bool)) public nullifierUsed;

    /// @notice Roots the owner revoked. Permanent, so a revoked root cannot come
    ///         back through a later vote or an admin correction.
    mapping(bytes32 => bool) public revokedRoot;

    mapping(bytes32 => mapping(address => bool)) private _voted;
    mapping(bytes32 => uint256) public voteCount;

    event RootUpdated(
        uint256 indexed epochId, bytes32 indexed rootHash, uint256 demosBlockNumber, uint256 leafCount, uint256 timestamp
    );
    event VoteCast(address indexed oracle, bytes32 indexed voteKey, uint256 currentCount, uint256 threshold);
    event OracleAdded(address indexed oracle);
    event OracleRemoved(address indexed oracle, uint256 oracleSetVersion);
    event ThresholdChanged(uint256 previousThreshold, uint256 newThreshold);
    event OwnershipTransferStarted(address indexed previousOwner, address indexed newOwner);
    event OwnershipTransferred(address indexed previousOwner, address indexed newOwner);
    event Paused(address indexed by);
    event Unpaused(address indexed by);
    event EpochStarted(uint256 indexed epochId, bytes32 indexed genesisHash, bytes32 previousGenesisHash);
    event RootCorrected(
        uint256 indexed epochId, bytes32 indexed rootHash, uint256 demosBlockNumber, uint256 leafCount, uint256 timestamp
    );
    event RootRevoked(uint256 indexed epochId, bytes32 indexed rootHash);
    event IdentityVerified(uint256 indexed nullifier, bytes32 indexed merkleRoot, uint256 context, address indexed caller);

    error NotOwner();
    error NotPendingOwner();
    error NotOracle();
    error AlreadyVoted();
    error StaleRoot(uint256 submitted, uint256 latest);
    error WrongEpoch(bytes32 submitted, bytes32 current);
    error SameEpoch(bytes32 genesisHash);
    error InvalidThreshold();
    error OracleAlreadyExists();
    error OracleNotFound();
    error IsPaused();
    error NotPaused();
    error RootNotFinalised(bytes32 root);
    error NullifierAlreadyUsed(uint256 nullifier);
    error RootIsRevoked(bytes32 root);
    error InvalidProof();
    error ZeroAddress();
    error ZeroValue();

    modifier onlyOwner() {
        if (msg.sender != owner) revert NotOwner();
        _;
    }

    modifier onlyOracle() {
        if (!isOracle[msg.sender]) revert NotOracle();
        _;
    }

    modifier whenNotPaused() {
        if (paused) revert IsPaused();
        _;
    }

    /**
     * @param initialOracles The whole oracle committee. It is set here, with its
     *                       threshold, so the registry never accepts votes from a
     *                       smaller committee than the one it is meant to run with.
     * @param threshold_     Votes needed to finalise a root, 1..initialOracles.length.
     * @param verifier_      Deployed Groth16 verifier for the identity_with_merkle circuit.
     * @param genesisHash    Block-0 hash of the Demos chain the first epoch tracks.
     */
    constructor(address[] memory initialOracles, uint256 threshold_, address verifier_, bytes32 genesisHash) {
        if (verifier_ == address(0)) revert ZeroAddress();
        owner = msg.sender;
        emit OwnershipTransferred(address(0), msg.sender);
        verifier = IZKVerifier(verifier_);
        for (uint256 i = 0; i < initialOracles.length; i++) {
            _addOracle(initialOracles[i]);
        }
        if (threshold_ == 0 || threshold_ > initialOracles.length) revert InvalidThreshold();
        threshold = threshold_;
        emit ThresholdChanged(0, threshold_);
        _startEpoch(genesisHash);
    }

    // ─── Layer 1: committee root finalisation ──────────────────────────────────

    /**
     * @notice Vote for the merkle root a Demos chain reports at `demosBlockNumber`.
     * @param genesisHash Block-0 hash of the chain the oracle read; must be the
     *                    current epoch, so a vote read from a reset (or a different)
     *                    chain can never finalise.
     */
    function submitVote(bytes32 genesisHash, bytes32 rootHash, uint256 demosBlockNumber, uint256 leafCount)
        external
        onlyOracle
        whenNotPaused
    {
        if (genesisHash != epochGenesisHash) revert WrongEpoch(genesisHash, epochGenesisHash);
        if (rootHash == bytes32(0)) revert ZeroValue();
        if (revokedRoot[rootHash]) revert RootIsRevoked(rootHash);

        // Only monotonic, with no upper bound on the gap: the tree changes only
        // on registrations, so a long quiet spell is a legitimately large jump.
        // A bad height is kept out by the oracles' multi-node quorum and the
        // committee threshold, and undone with adminSetLatestRoot / startEpoch.
        uint256 latest = latestRoot.demosBlockNumber;
        if (demosBlockNumber <= latest) revert StaleRoot(demosBlockNumber, latest);

        bytes32 voteKey = currentVoteKey(rootHash, demosBlockNumber, leafCount);
        if (_voted[voteKey][msg.sender]) revert AlreadyVoted();
        _voted[voteKey][msg.sender] = true;

        uint256 count = voteCount[voteKey] + 1;
        voteCount[voteKey] = count;
        emit VoteCast(msg.sender, voteKey, count, threshold);

        if (count >= threshold) _finaliseRoot(rootHash, demosBlockNumber, leafCount);
    }

    // ─── Layer 2: trustless inclusion verification ─────────────────────────────

    /**
     * @notice Verify a Groth16 proof that a commitment is included in a merkle
     *         root finalised in the current epoch, and burn its nullifier for
     *         msg.sender. Public signals are [nullifier, context, merkleRoot].
     *         Reverts while the registry is paused: pause is the stop for a
     *         broken verifier key or circuit, not only for voting.
     * @return true on success (reverts otherwise).
     */
    function verifyIdentity(uint[2] calldata a, uint[2][2] calldata b, uint[2] calldata c, uint[3] calldata pubSignals)
        external
        whenNotPaused
        returns (bool)
    {
        uint256 nullifier = pubSignals[SIGNAL_NULLIFIER];
        bytes32 root = bytes32(pubSignals[SIGNAL_MERKLE_ROOT]);

        if (!isFinalisedRoot(root)) revert RootNotFinalised(root);
        if (nullifierUsed[msg.sender][nullifier]) revert NullifierAlreadyUsed(nullifier);
        if (!verifier.verifyProof(a, b, c, pubSignals)) revert InvalidProof();

        nullifierUsed[msg.sender][nullifier] = true;
        emit IdentityVerified(nullifier, root, pubSignals[SIGNAL_CONTEXT], msg.sender);
        return true;
    }

    /// @notice Non-mutating check (no nullifier burn): true when `verifyIdentity`
    ///         called by msg.sender with this proof would succeed now.
    function checkIdentity(uint[2] calldata a, uint[2][2] calldata b, uint[2] calldata c, uint[3] calldata pubSignals)
        external
        view
        returns (bool)
    {
        if (paused) return false;
        if (!isFinalisedRoot(bytes32(pubSignals[SIGNAL_MERKLE_ROOT]))) return false;
        if (nullifierUsed[msg.sender][pubSignals[SIGNAL_NULLIFIER]]) return false;
        return verifier.verifyProof(a, b, c, pubSignals);
    }

    // ─── Owner: oracle management ─────────────────────────────────────────────

    function addOracle(address oracle) external onlyOwner {
        _addOracle(oracle);
    }

    /// @notice Refuses to drop the set below `threshold`; lower the threshold
    ///         first, so a weaker quorum is always an explicit, logged decision.
    function removeOracle(address oracle) external onlyOwner {
        if (!isOracle[oracle]) revert OracleNotFound();
        if (oracleList.length - 1 < threshold) revert InvalidThreshold();
        isOracle[oracle] = false;
        for (uint256 i = 0; i < oracleList.length; i++) {
            if (oracleList[i] == oracle) {
                oracleList[i] = oracleList[oracleList.length - 1];
                oracleList.pop();
                break;
            }
        }
        oracleSetVersion += 1;
        emit OracleRemoved(oracle, oracleSetVersion);
    }

    function setThreshold(uint256 _threshold) external onlyOwner {
        if (_threshold == 0 || _threshold > oracleList.length) revert InvalidThreshold();
        uint256 previous = threshold;
        threshold = _threshold;
        emit ThresholdChanged(previous, _threshold);
    }

    // ─── Owner: two-step ownership ────────────────────────────────────────────

    /// @notice Two steps so a mistyped address can't take the registry: the new
    ///         owner must call `acceptOwnership` from that address.
    function transferOwnership(address newOwner) external onlyOwner {
        if (newOwner == address(0)) revert ZeroAddress();
        pendingOwner = newOwner;
        emit OwnershipTransferStarted(owner, newOwner);
    }

    function acceptOwnership() external {
        if (msg.sender != pendingOwner) revert NotPendingOwner();
        address previous = owner;
        owner = msg.sender;
        pendingOwner = address(0);
        emit OwnershipTransferred(previous, msg.sender);
    }

    // ─── Owner: chain epochs, recovery & safety ───────────────────────────────

    /**
     * @notice Track a new Demos chain (a reset or the launch of a new network).
     *         Clears the latest root so block numbers can start from 1 again,
     *         retires every root of earlier epochs from inclusion checks, and
     *         orphans their pending votes.
     */
    function startEpoch(bytes32 genesisHash) external onlyOwner {
        if (genesisHash == epochGenesisHash) revert SameEpoch(genesisHash);
        _startEpoch(genesisHash);
    }

    function pause() external onlyOwner {
        if (paused) revert IsPaused();
        paused = true;
        emit Paused(msg.sender);
    }

    function unpause() external onlyOwner {
        if (!paused) revert NotPaused();
        paused = false;
        emit Unpaused(msg.sender);
    }

    /// @notice Overwrite `latestRoot` in the current epoch to recover from a bad
    ///         finalisation. The root layer is committee-asserted, so this is a
    ///         trusted escape hatch (it emits `RootCorrected` for audit). It does
    ///         NOT weaken layer 2: inclusion is always proven, never asserted.
    function adminSetLatestRoot(bytes32 rootHash, uint256 demosBlockNumber, uint256 leafCount) external onlyOwner {
        if (rootHash == bytes32(0)) revert ZeroValue();
        _finaliseRoot(rootHash, demosBlockNumber, leafCount);
        emit RootCorrected(epochId, rootHash, demosBlockNumber, leafCount, block.timestamp);
    }

    /// @notice Stop accepting proofs against a root finalised by mistake. Needed
    ///         besides adminSetLatestRoot: a wrong root stays usable for
    ///         inclusion until revoked, even after the latest root moves on.
    ///         When it is the latest root, the latest root is cleared too, so the
    ///         next honest vote is not refused as stale against a bad height.
    function revokeRoot(bytes32 rootHash) external onlyOwner {
        if (rootHash == bytes32(0)) revert ZeroValue();
        if (revokedRoot[rootHash]) revert RootIsRevoked(rootHash);
        revokedRoot[rootHash] = true;
        rootEpoch[rootHash] = 0;
        if (latestRoot.rootHash == rootHash) delete latestRoot;
        emit RootRevoked(epochId, rootHash);
    }

    // ─── Views ────────────────────────────────────────────────────────────────

    /// @notice True when `root` was finalised in the current epoch.
    function isFinalisedRoot(bytes32 root) public view returns (bool) {
        return root != bytes32(0) && rootEpoch[root] == epochId;
    }

    function currentEpoch() external view returns (uint256 id, bytes32 genesisHash) {
        return (epochId, epochGenesisHash);
    }

    function getLatestRoot()
        external
        view
        returns (bytes32 rootHash, uint256 demosBlockNumber, uint256 leafCount, uint256 updatedAt, uint256 epoch)
    {
        RootEntry memory r = latestRoot;
        return (r.rootHash, r.demosBlockNumber, r.leafCount, r.updatedAt, r.epochId);
    }

    /// @notice Root finalised at `demosBlockNumber` in the current epoch.
    function rootByBlock(uint256 demosBlockNumber) external view returns (RootEntry memory) {
        return rootByEpochBlock[epochId][demosBlockNumber];
    }

    function oracleCount() external view returns (uint256) {
        return oracleList.length;
    }

    /// @notice The key votes for this root are counted under right now.
    function currentVoteKey(bytes32 rootHash, uint256 demosBlockNumber, uint256 leafCount)
        public
        view
        returns (bytes32)
    {
        return keccak256(abi.encode(epochId, oracleSetVersion, rootHash, demosBlockNumber, leafCount));
    }

    function getVoteCount(bytes32 rootHash, uint256 demosBlockNumber, uint256 leafCount)
        external
        view
        returns (uint256)
    {
        return voteCount[currentVoteKey(rootHash, demosBlockNumber, leafCount)];
    }

    function hasVoted(address oracle, bytes32 rootHash, uint256 demosBlockNumber, uint256 leafCount)
        external
        view
        returns (bool)
    {
        return _voted[currentVoteKey(rootHash, demosBlockNumber, leafCount)][oracle];
    }

    // ─── Internal ─────────────────────────────────────────────────────────────

    function _addOracle(address oracle) internal {
        if (oracle == address(0)) revert ZeroAddress();
        if (isOracle[oracle]) revert OracleAlreadyExists();
        isOracle[oracle] = true;
        oracleList.push(oracle);
        emit OracleAdded(oracle);
    }

    function _startEpoch(bytes32 genesisHash) internal {
        if (genesisHash == bytes32(0)) revert ZeroValue();
        bytes32 previous = epochGenesisHash;
        uint256 id = epochId + 1;
        epochId = id;
        epochGenesisHash = genesisHash;
        genesisHashOfEpoch[id] = genesisHash;
        delete latestRoot;
        emit EpochStarted(id, genesisHash, previous);
    }

    function _finaliseRoot(bytes32 rootHash, uint256 demosBlockNumber, uint256 leafCount) internal {
        if (revokedRoot[rootHash]) revert RootIsRevoked(rootHash);
        uint256 id = epochId;
        RootEntry memory entry = RootEntry({
            rootHash: rootHash,
            demosBlockNumber: demosBlockNumber,
            leafCount: leafCount,
            updatedAt: block.timestamp,
            epochId: id
        });
        latestRoot = entry;
        rootByEpochBlock[id][demosBlockNumber] = entry;
        rootEpoch[rootHash] = id;
        emit RootUpdated(id, rootHash, demosBlockNumber, leafCount, block.timestamp);
    }
}
