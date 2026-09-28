// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.24;

import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "./TimbSwapPair.sol";
// ─── Intercfaces ───────────────────────────────────────────────────────────────

interface ITimbSwapPair {
    function token0() external view returns (address);
    function token1() external view returns (address);
}

// ─── Contract ─────────────────────────────────────────────────────────────────

/**
 * @title TimbSwapFactory
 * @notice Creates and indexes TimbSwap AMM pairs.
 *         createPair() deploys real TimbSwapPair bytecode atomically —
 *         no placeholder addresses, no phantom mappings.
 */
contract TimbSwapFactory is Ownable, ReentrancyGuard {

    // ─── Constants ───────────────────────────────────────────────────────────

    uint256 public constant TOTAL_FEE_BPS    = 30;
    uint256 public constant LP_FEE_BPS       = 25;
    uint256 public constant PROTOCOL_FEE_BPS = 5;

    // ─── State ───────────────────────────────────────────────────────────────

    address public feeTo;
    address public router;
    address public timbsToken;
    bool    public paused;

    mapping(address => mapping(address => address)) public getPair;
    address[] public allPairs;
    mapping(address => bool) public emissionsWhitelist;
    mapping(address => bool) public isPartnerPool;
    mapping(address => address) public partnerDestination;

    // ─── Events ──────────────────────────────────────────────────────────────

    event PairCreated(address indexed token0, address indexed token1, address pair, uint256 index);
    event FeeToUpdated(address indexed oldFeeTo, address indexed newFeeTo);
    event RouterSet(address indexed router);
    event TimbsTokenSet(address indexed timbsToken);
    event EmissionsWhitelistUpdated(address indexed pair, bool whitelisted);
    event PartnerPoolSet(address indexed pair, address indexed destination, bool active);
    event Paused(address indexed by);
    event Unpaused(address indexed by);

    // ─── Errors ──────────────────────────────────────────────────────────────

    error ZeroAddress();
    error IdenticalAddresses();
    error PairExists(address pair);
    error PairCreationPaused();
    error NotRouter();

    // ─── Modifiers ───────────────────────────────────────────────────────────

    modifier whenNotPaused() {
        if (paused) revert PairCreationPaused();
        _;
    }

    // ─── Constructor ─────────────────────────────────────────────────────────

    constructor(address _feeTo) Ownable(msg.sender) {
        if (_feeTo == address(0)) revert ZeroAddress();
        feeTo = _feeTo;
        emit FeeToUpdated(address(0), _feeTo);
    }

    // ─── Owner Config ─────────────────────────────────────────────────────────

    function setFeeTo(address _feeTo) external onlyOwner {
        if (_feeTo == address(0)) revert ZeroAddress();
        emit FeeToUpdated(feeTo, _feeTo);
        feeTo = _feeTo;
    }

    function setRouter(address _router) external onlyOwner {
        if (_router == address(0)) revert ZeroAddress();
        router = _router;
        emit RouterSet(_router);
    }

    function setTimbsToken(address _timbsToken) external onlyOwner {
        if (_timbsToken == address(0)) revert ZeroAddress();
        timbsToken = _timbsToken;
        emit TimbsTokenSet(_timbsToken);
    }

    function setEmissionsWhitelist(address pair, bool whitelisted) external onlyOwner {
        if (pair == address(0)) revert ZeroAddress();
        emissionsWhitelist[pair] = whitelisted;
        emit EmissionsWhitelistUpdated(pair, whitelisted);
    }

    function setPartnerPool(address pair, address destination, bool active) external onlyOwner {
        if (pair == address(0)) revert ZeroAddress();
        if (active && destination == address(0)) revert ZeroAddress();
        isPartnerPool[pair] = active;
        partnerDestination[pair] = active ? destination : address(0);
        emit PartnerPoolSet(pair, destination, active);
    }

    function pause()   external onlyOwner { paused = true;  emit Paused(msg.sender); }
    function unpause() external onlyOwner { paused = false; emit Unpaused(msg.sender); }

    // ─── View Helpers ─────────────────────────────────────────────────────────

    function allPairsLength() external view returns (uint256) {
        return allPairs.length;
    }

    function getPairAddress(address tokenA, address tokenB)
        external view returns (address)
    {
        (address t0, address t1) = tokenA < tokenB
            ? (tokenA, tokenB)
            : (tokenB, tokenA);
        return getPair[t0][t1];
    }

    function isPairEmissionsEligible(address pair) external view returns (bool) {
        return emissionsWhitelist[pair];
    }

    function getPartnerConfig(address pair)
        external view returns (bool active, address destination)
    {
        return (isPartnerPool[pair], partnerDestination[pair]);
    }

    function getFeeConfig()
        external pure returns (uint256, uint256, uint256, uint256)
    {
        return (TOTAL_FEE_BPS, LP_FEE_BPS, PROTOCOL_FEE_BPS, 10_000);
    }

    // ─── Pair Creation ────────────────────────────────────────────────────────

    /**
     * @notice Deploy a new TimbSwapPair and register it atomically.
     * @dev Uses `new TimbSwapPair{salt: salt}` — real bytecode deployed
     *      in the same tx as the mapping update. No placeholder addresses.
     *      Tokens sorted so token0 < token1 (canonical ordering).
     */
    function createPair(address tokenA, address tokenB)
        external
        nonReentrant
        whenNotPaused
        returns (address pair)
    {
        if (tokenA == tokenB)                revert IdenticalAddresses();
        if (tokenA == address(0))            revert ZeroAddress();
        if (tokenB == address(0))            revert ZeroAddress();

        (address token0, address token1) = tokenA < tokenB
            ? (tokenA, tokenB)
            : (tokenB, tokenA);

        if (getPair[token0][token1] != address(0))
            revert PairExists(getPair[token0][token1]);

        bytes32 salt = keccak256(abi.encodePacked(token0, token1));

        // Deploy real bytecode — atomic with mapping update below
        pair = address(new TimbSwapPair{salt: salt}(token0, token1));

        // Store atomically
        getPair[token0][token1] = pair;
        getPair[token1][token0] = pair;
        allPairs.push(pair);

        emit PairCreated(token0, token1, pair, allPairs.length - 1);
    }
}
