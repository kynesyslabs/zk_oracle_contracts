// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/**
 * @title ZKOracleRegistry
 * @notice Stores verified ZK merkle roots from the Demos network on Base Sepolia.
 *
 * Scalable oracle model:
 *   - Starts as single-oracle (threshold=1, one oracle address) — no multisig overhead.
 *   - Owner can add oracle addresses and raise the threshold at any time without redeploying.
 *   - Each oracle calls submitVote(); once `threshold` unique oracles agree on the same
 *     (rootHash, demosBlockNumber, leafCount), the root is finalised on-chain.
 */
contract ZKOracleRegistry {
    address public owner;
    uint256 public threshold;

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

    // voteKey = keccak256(rootHash, demosBlockNumber, leafCount)
    mapping(bytes32 => mapping(address => bool)) private _voted;
    mapping(bytes32 => uint256) public voteCount;

    event RootUpdated(
        bytes32 indexed rootHash,
        uint256 demosBlockNumber,
        uint256 leafCount,
        uint256 timestamp
    );
    event VoteCast(
        address indexed oracle,
        bytes32 indexed voteKey,
        uint256 currentCount,
        uint256 threshold
    );
    event OracleAdded(address indexed oracle);
    event OracleRemoved(address indexed oracle);
    event ThresholdChanged(uint256 previousThreshold, uint256 newThreshold);
    event OwnershipTransferred(address indexed previousOwner, address indexed newOwner);

    error NotOwner();
    error NotOracle();
    error AlreadyVoted();
    error StaleRoot(uint256 submitted, uint256 latest);
    error InvalidThreshold();
    error OracleAlreadyExists();
    error OracleNotFound();

    modifier onlyOwner() {
        if (msg.sender != owner) revert NotOwner();
        _;
    }

    modifier onlyOracle() {
        if (!isOracle[msg.sender]) revert NotOracle();
        _;
    }

    /**
     * @param initialOracle  Address of the first oracle (single-oracle mode out of the box).
     */
    constructor(address initialOracle) {
        owner = msg.sender;
        threshold = 1;
        _addOracle(initialOracle);
    }

    // ─── Voting ───────────────────────────────────────────────────────────────

    /**
     * @notice Submit a vote for a new ZK merkle root.
     *         When `threshold` unique oracles cast the same vote, the root is finalised.
     *
     * @param rootHash         Poseidon merkle root hash from Demos.
     * @param demosBlockNumber Demos block number at which this root was observed.
     * @param leafCount        Number of commitments in the tree at that block.
     */
    function submitVote(
        bytes32 rootHash,
        uint256 demosBlockNumber,
        uint256 leafCount
    ) external onlyOracle {
        if (demosBlockNumber <= latestRoot.demosBlockNumber) {
            revert StaleRoot(demosBlockNumber, latestRoot.demosBlockNumber);
        }

        bytes32 voteKey = keccak256(abi.encode(rootHash, demosBlockNumber, leafCount));

        if (_voted[voteKey][msg.sender]) revert AlreadyVoted();
        _voted[voteKey][msg.sender] = true;

        uint256 count = voteCount[voteKey] + 1;
        voteCount[voteKey] = count;

        emit VoteCast(msg.sender, voteKey, count, threshold);

        if (count >= threshold) {
            _finaliseRoot(rootHash, demosBlockNumber, leafCount);
        }
    }

    // ─── Owner: oracle management ─────────────────────────────────────────────

    function addOracle(address oracle) external onlyOwner {
        _addOracle(oracle);
    }

    function removeOracle(address oracle) external onlyOwner {
        if (!isOracle[oracle]) revert OracleNotFound();
        isOracle[oracle] = false;

        // Remove from list (swap with last element)
        for (uint256 i = 0; i < oracleList.length; i++) {
            if (oracleList[i] == oracle) {
                oracleList[i] = oracleList[oracleList.length - 1];
                oracleList.pop();
                break;
            }
        }

        // Threshold must not exceed remaining oracle count
        if (threshold > oracleList.length && oracleList.length > 0) {
            uint256 previous = threshold;
            threshold = oracleList.length;
            emit ThresholdChanged(previous, threshold);
        }

        emit OracleRemoved(oracle);
    }

    /**
     * @notice Set the number of agreeing oracle votes required to finalise a root.
     *         Must be between 1 and the current oracle count.
     */
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

    function getVoteCount(
        bytes32 rootHash,
        uint256 demosBlockNumber,
        uint256 leafCount
    ) external view returns (uint256) {
        return voteCount[keccak256(abi.encode(rootHash, demosBlockNumber, leafCount))];
    }

    function hasVoted(
        address oracle,
        bytes32 rootHash,
        uint256 demosBlockNumber,
        uint256 leafCount
    ) external view returns (bool) {
        return _voted[keccak256(abi.encode(rootHash, demosBlockNumber, leafCount))][oracle];
    }

    // ─── Internal ─────────────────────────────────────────────────────────────

    function _addOracle(address oracle) internal {
        if (isOracle[oracle]) revert OracleAlreadyExists();
        isOracle[oracle] = true;
        oracleList.push(oracle);
        emit OracleAdded(oracle);
    }

    function _finaliseRoot(
        bytes32 rootHash,
        uint256 demosBlockNumber,
        uint256 leafCount
    ) internal {
        RootEntry memory entry = RootEntry({
            rootHash: rootHash,
            demosBlockNumber: demosBlockNumber,
            leafCount: leafCount,
            updatedAt: block.timestamp
        });
        latestRoot = entry;
        rootByBlock[demosBlockNumber] = entry;
        emit RootUpdated(rootHash, demosBlockNumber, leafCount, block.timestamp);
    }
}
