// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @notice Groth16 verifier generated from the Demos `identity_with_merkle` circuit
///         (snarkjs `zkey export solidityverifier`). Public signals, in order:
///         [nullifier, merkleRoot, context].
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
 *   1. Root finalisation (trusted committee) — whitelisted oracles vote a Poseidon
 *      merkle root from the Demos network on-chain; once `threshold` independent
 *      oracles agree, the root is finalised. Raise the threshold and add operators
 *      to decentralise this layer without redeploying. Pause + admin correction +
 *      a block-jump guard keep a bad read from wedging it.
 *
 *   2. Inclusion (trustless) — `verifyIdentity` accepts a Groth16 proof that a
 *      commitment is included in a *finalised* root, verifies it on-chain against
 *      the circuit's verifier, and burns the nullifier so a proof can't be
 *      replayed. This is the piece that lets a claim stand without trusting the
 *      submitter: the committee vouches for the root, the proof proves membership.
 */
contract ZKIdentityRegistry {
    address public owner;
    uint256 public threshold;
    bool public paused;

    /// @notice Reject a submitted Demos block that jumps more than this far past
    ///         the latest finalised one (0 disables the check).
    uint256 public maxBlockAdvance;

    /// @notice The Groth16 verifier for the `identity_with_merkle` circuit.
    IZKVerifier public immutable verifier;

    mapping(address => bool) public isOracle;
    address[] public oracleList;

    struct RootEntry {
        bytes32 rootHash;
        uint256 demosBlockNumber;
        uint256 leafCount;
        uint256 updatedAt;
    }

    RootEntry public latestRoot;
    mapping(uint256 => RootEntry) public rootByBlock;

    /// @notice Every root ever finalised. `verifyIdentity` accepts a proof against
    ///         any of them — inclusion is monotonic, so a member at an older root
    ///         stays a member.
    mapping(bytes32 => bool) public isFinalisedRoot;

    /// @notice Spent nullifiers, so a given (identity, context) proof verifies once.
    mapping(uint256 => bool) public nullifierUsed;

    mapping(bytes32 => mapping(address => bool)) private _voted;
    mapping(bytes32 => uint256) public voteCount;

    event RootUpdated(bytes32 indexed rootHash, uint256 demosBlockNumber, uint256 leafCount, uint256 timestamp);
    event VoteCast(address indexed oracle, bytes32 indexed voteKey, uint256 currentCount, uint256 threshold);
    event OracleAdded(address indexed oracle);
    event OracleRemoved(address indexed oracle);
    event ThresholdChanged(uint256 previousThreshold, uint256 newThreshold);
    event OwnershipTransferred(address indexed previousOwner, address indexed newOwner);
    event Paused(address indexed by);
    event Unpaused(address indexed by);
    event MaxBlockAdvanceChanged(uint256 previous, uint256 next);
    event RootCorrected(bytes32 indexed rootHash, uint256 demosBlockNumber, uint256 leafCount, uint256 timestamp);
    event IdentityVerified(uint256 indexed nullifier, bytes32 indexed merkleRoot, uint256 context, address indexed caller);

    error NotOwner();
    error NotOracle();
    error AlreadyVoted();
    error StaleRoot(uint256 submitted, uint256 latest);
    error InvalidThreshold();
    error OracleAlreadyExists();
    error OracleNotFound();
    error IsPaused();
    error NotPaused();
    error BlockJumpTooLarge(uint256 submitted, uint256 latest, uint256 maxAdvance);
    error RootNotFinalised(bytes32 root);
    error NullifierAlreadyUsed(uint256 nullifier);
    error InvalidProof();
    error ZeroVerifier();

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
     * @param initialOracle Address of the first oracle (single-oracle mode out of the box).
     * @param verifier_      Deployed Groth16 verifier for the identity_with_merkle circuit.
     */
    constructor(address initialOracle, address verifier_) {
        if (verifier_ == address(0)) revert ZeroVerifier();
        owner = msg.sender;
        threshold = 1;
        verifier = IZKVerifier(verifier_);
        _addOracle(initialOracle);
    }

    // ─── Layer 1: committee root finalisation ──────────────────────────────────

    function submitVote(bytes32 rootHash, uint256 demosBlockNumber, uint256 leafCount)
        external
        onlyOracle
        whenNotPaused
    {
        uint256 latest = latestRoot.demosBlockNumber;
        if (demosBlockNumber <= latest) revert StaleRoot(demosBlockNumber, latest);
        if (maxBlockAdvance != 0 && latest != 0 && demosBlockNumber - latest > maxBlockAdvance) {
            revert BlockJumpTooLarge(demosBlockNumber, latest, maxBlockAdvance);
        }

        bytes32 voteKey = keccak256(abi.encode(rootHash, demosBlockNumber, leafCount));
        if (_voted[voteKey][msg.sender]) revert AlreadyVoted();
        _voted[voteKey][msg.sender] = true;

        uint256 count = voteCount[voteKey] + 1;
        voteCount[voteKey] = count;
        emit VoteCast(msg.sender, voteKey, count, threshold);

        if (count >= threshold) _finaliseRoot(rootHash, demosBlockNumber, leafCount);
    }

    // ─── Layer 2: trustless inclusion verification ─────────────────────────────

    /**
     * @notice Verify a Groth16 proof that a commitment is included in a finalised
     *         merkle root, and burn its nullifier. Public signals are
     *         [nullifier, merkleRoot, context] as produced by the SDK ProofGenerator.
     * @return true on success (reverts otherwise).
     */
    function verifyIdentity(
        uint[2] calldata a,
        uint[2][2] calldata b,
        uint[2] calldata c,
        uint[3] calldata pubSignals
    ) external returns (bool) {
        uint256 nullifier = pubSignals[0];
        bytes32 root = bytes32(pubSignals[1]);
        uint256 context = pubSignals[2];

        if (!isFinalisedRoot[root]) revert RootNotFinalised(root);
        if (nullifierUsed[nullifier]) revert NullifierAlreadyUsed(nullifier);
        if (!verifier.verifyProof(a, b, c, pubSignals)) revert InvalidProof();

        nullifierUsed[nullifier] = true;
        emit IdentityVerified(nullifier, root, context, msg.sender);
        return true;
    }

    /// @notice Non-mutating check (no nullifier burn) — for a caller that just
    ///         wants to know a proof is valid against a finalised root.
    function checkIdentity(
        uint[2] calldata a,
        uint[2][2] calldata b,
        uint[2] calldata c,
        uint[3] calldata pubSignals
    ) external view returns (bool) {
        if (!isFinalisedRoot[bytes32(pubSignals[1])]) return false;
        return verifier.verifyProof(a, b, c, pubSignals);
    }

    // ─── Owner: oracle management ─────────────────────────────────────────────

    function addOracle(address oracle) external onlyOwner {
        _addOracle(oracle);
    }

    function removeOracle(address oracle) external onlyOwner {
        if (!isOracle[oracle]) revert OracleNotFound();
        isOracle[oracle] = false;
        for (uint256 i = 0; i < oracleList.length; i++) {
            if (oracleList[i] == oracle) {
                oracleList[i] = oracleList[oracleList.length - 1];
                oracleList.pop();
                break;
            }
        }
        if (threshold > oracleList.length && oracleList.length > 0) {
            uint256 previous = threshold;
            threshold = oracleList.length;
            emit ThresholdChanged(previous, threshold);
        }
        emit OracleRemoved(oracle);
    }

    function setThreshold(uint256 _threshold) external onlyOwner {
        if (_threshold == 0 || _threshold > oracleList.length) revert InvalidThreshold();
        uint256 previous = threshold;
        threshold = _threshold;
        emit ThresholdChanged(previous, _threshold);
    }

    function transferOwnership(address newOwner) external onlyOwner {
        address previous = owner;
        owner = newOwner;
        emit OwnershipTransferred(previous, newOwner);
    }

    // ─── Owner: recovery & safety ─────────────────────────────────────────────

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

    function setMaxBlockAdvance(uint256 newMax) external onlyOwner {
        uint256 previous = maxBlockAdvance;
        maxBlockAdvance = newMax;
        emit MaxBlockAdvanceChanged(previous, newMax);
    }

    /// @notice Overwrite `latestRoot` to recover from a bad finalisation. The root
    ///         layer is committee-asserted, so this is a trusted escape hatch (it
    ///         emits `RootCorrected` for audit). It does NOT weaken layer 2: a
    ///         corrected root is still only usable once finalised, and inclusion is
    ///         always proven, never asserted.
    function adminSetLatestRoot(bytes32 rootHash, uint256 demosBlockNumber, uint256 leafCount)
        external
        onlyOwner
    {
        _finaliseRoot(rootHash, demosBlockNumber, leafCount);
        emit RootCorrected(rootHash, demosBlockNumber, leafCount, block.timestamp);
    }

    // ─── Views ────────────────────────────────────────────────────────────────

    function getLatestRoot()
        external
        view
        returns (bytes32 rootHash, uint256 demosBlockNumber, uint256 leafCount, uint256 updatedAt)
    {
        RootEntry memory r = latestRoot;
        return (r.rootHash, r.demosBlockNumber, r.leafCount, r.updatedAt);
    }

    function oracleCount() external view returns (uint256) {
        return oracleList.length;
    }

    function getVoteCount(bytes32 rootHash, uint256 demosBlockNumber, uint256 leafCount)
        external
        view
        returns (uint256)
    {
        return voteCount[keccak256(abi.encode(rootHash, demosBlockNumber, leafCount))];
    }

    function hasVoted(address oracle, bytes32 rootHash, uint256 demosBlockNumber, uint256 leafCount)
        external
        view
        returns (bool)
    {
        return _voted[keccak256(abi.encode(rootHash, demosBlockNumber, leafCount))][oracle];
    }

    // ─── Internal ─────────────────────────────────────────────────────────────

    function _addOracle(address oracle) internal {
        if (isOracle[oracle]) revert OracleAlreadyExists();
        isOracle[oracle] = true;
        oracleList.push(oracle);
        emit OracleAdded(oracle);
    }

    function _finaliseRoot(bytes32 rootHash, uint256 demosBlockNumber, uint256 leafCount) internal {
        RootEntry memory entry = RootEntry({
            rootHash: rootHash,
            demosBlockNumber: demosBlockNumber,
            leafCount: leafCount,
            updatedAt: block.timestamp
        });
        latestRoot = entry;
        rootByBlock[demosBlockNumber] = entry;
        isFinalisedRoot[rootHash] = true;
        emit RootUpdated(rootHash, demosBlockNumber, leafCount, block.timestamp);
    }
}
