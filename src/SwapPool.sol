// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/token/ERC1155/IERC1155.sol";
import "@openzeppelin/contracts/token/ERC1155/utils/ERC1155Holder.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "./LPToken.sol";
import "./FeeCollector.sol";
import "./PoolFactory.sol";

/**
 * @title SwapPool
 * @notice Holds Polymarket ERC-1155 shares and WrappedOpinion ERC-1155 shares
 *         for ONE specific event-outcome pair. Both sides represent the same
 *         real-world outcome and are treated as 1:1 equivalent in value.
 *
 *         Token contract addresses are read from PoolFactory (single source of truth).
 *         Only token IDs differ per pool.
 *
 *         Deployed by PoolFactory. One pool per matched market pair.
 *
 * ─── Pool Mechanics ───────────────────────────────────────────────────────────
 *
 *   rate        = totalShares / lpToken.totalSupply()
 *   lpToMint    = depositAmount * lpSupply / totalShares   (or 1:1 if first)
 *   toRelease   = lpBurned * totalShares / lpSupply
 *
 *   Swap fee:   0.40% total
 *     0.30% LP fee  → stays in pool (auto-compounds, no new LP minted)
 *     0.10% protocol → transferred to FeeCollector
 *
 * ─── Side Enum ────────────────────────────────────────────────────────────────
 *
 *   Side.POLYMARKET  = native Polymarket ERC-1155 shares
 *   Side.OPINION     = WrappedOpinion ERC-1155 shares (bridged from BSC)
 */
contract SwapPool is ERC1155Holder, ReentrancyGuard {
    // ─── Constants ────────────────────────────────────────────────────────────
    // Fees are read from factory at swap time (configurable by owner)

    // ─── Immutable config ─────────────────────────────────────────────────────

    /// @notice Factory that deployed this pool — source of token contract addresses
    PoolFactory public immutable factory;

    /// @notice Polymarket ERC-1155 token ID for this pool's event-outcome
    uint256 public immutable polymarketTokenId;
    /// @notice WrappedOpinion ERC-1155 token ID for this pool's event-outcome
    uint256 public immutable opinionTokenId;

    /// @notice Associated LP token (ERC-20)
    LPToken public immutable lpToken;
    /// @notice Protocol fee recipient
    FeeCollector public immutable feeCollector;

    // ─── Pool state ───────────────────────────────────────────────────────────

    /// @notice Polymarket shares held in this pool
    uint256 public polymarketBalance;
    /// @notice WrappedOpinion shares held in this pool
    uint256 public opinionBalance;

    bool public depositsPaused;
    bool public swapsPaused;

    // ─── Types ────────────────────────────────────────────────────────────────

    enum Side {
        POLYMARKET,
        OPINION
    }

    // ─── Events ───────────────────────────────────────────────────────────────

    event DepositsPausedSet(bool paused);
    event SwapsPausedSet(bool paused);

    event Deposited(address indexed user, Side side, uint256 sharesIn, uint256 lpMinted);
    event Withdrawn(address indexed user, Side sideReceived, uint256 lpBurned, uint256 sharesOut);
    event WithdrawnSplit(
        address indexed user,
        uint256 lpBurned,
        uint256 preferredOut,
        Side preferredSide,
        uint256 fallbackOut,
        Side fallbackSide
    );
    event Swapped(
        address indexed user, Side fromSide, uint256 amountIn, uint256 amountOut, uint256 lpFee, uint256 protocolFee
    );

    // ─── Errors ───────────────────────────────────────────────────────────────

    error DepositsPaused();
    error SwapsPaused();

    error ZeroAmount();
    error ZeroAddress();
    error InvalidTokenID();
    error DepositTooSmall();
    error Unauthorized();
    error InsufficientLiquidity(uint256 available, uint256 required);

    // ─── Constructor ──────────────────────────────────────────────────────────

    constructor(
        address factory_,
        uint256 polymarketTokenId_,
        uint256 opinionTokenId_,
        address lpToken_,
        address feeCollector_
    ) {
        if (factory_ == address(0) || lpToken_ == address(0) || feeCollector_ == address(0)) {
            revert ZeroAddress();
        }

        if (polymarketTokenId_ == 0 || opinionTokenId_ == 0) revert InvalidTokenID();

        factory = PoolFactory(factory_);
        polymarketTokenId = polymarketTokenId_;
        opinionTokenId = opinionTokenId_;
        lpToken = LPToken(lpToken_);
        feeCollector = FeeCollector(feeCollector_);
    }

    // ─── View helpers ─────────────────────────────────────────────────────────

    /// @notice Total shares across both sides
    function totalShares() public view returns (uint256) {
        return polymarketBalance + opinionBalance;
    }

    /**
     * @notice Current LP exchange rate scaled by 1e18.
     *         rate = totalShares / lpSupply
     *         Returns 1e18 when pool is empty (first deposit rate).
     */
    function exchangeRate() public view returns (uint256) {
        uint256 supply = lpToken.totalSupply();
        if (supply == 0) return 1e18;
        return (totalShares() * 1e18) / supply;
    }

    // ─── Deposit ──────────────────────────────────────────────────────────────

    /**
     * @notice Deposit shares into the pool and receive LP tokens.
     *         Single-sided: deposit only Polymarket OR only WrappedOpinion.
     *
     * @param side    Which token to deposit (POLYMARKET or OPINION)
     * @param amount  Number of ERC-1155 shares to deposit
     */
    function deposit(Side side, uint256 amount) external nonReentrant returns (uint256 lpMinted) {
        if (depositsPaused) revert DepositsPaused();
        if (amount == 0) revert ZeroAmount();

        _pullTokens(side, msg.sender, amount);

        uint256 supply = lpToken.totalSupply();
        if (supply == 0) {
            // First depositor: 1 share = 1 LP token
            lpMinted = amount;
        } else {
            // Calculated before _updateBalance so totalShares() is pre-deposit
            lpMinted = (amount * supply) / totalShares();
        }

        // Ensure user receives at least 1 LP token
        if (lpMinted == 0) revert DepositTooSmall();

        _updateBalance(side, amount, true);
        lpToken.mint(msg.sender, lpMinted);

        emit Deposited(msg.sender, side, amount, lpMinted);
    }

    // ─── Withdraw ─────────────────────────────────────────────────────────────

    /**
     * @notice Burn LP tokens and receive underlying shares.
     *         User specifies a preferred side. Pool pays from preferred side
     *         if available, otherwise falls back or splits across both sides.
     *
     * @param lpAmount       LP tokens to burn
     * @param preferredSide  Preferred side to receive (POLYMARKET or OPINION)
     */
    function withdraw(uint256 lpAmount, Side preferredSide) external nonReentrant returns (uint256 sharesOut) {
        if (lpAmount == 0) revert ZeroAmount();

        sharesOut = (lpAmount * totalShares()) / lpToken.totalSupply();

        // Burn LP first (CEI pattern)
        lpToken.burn(msg.sender, lpAmount);

        (uint256 preferredAvail, uint256 fallbackAvail, Side fallbackSide) = _sideBalances(preferredSide);

        if (sharesOut <= preferredAvail) {
            // Preferred side has enough
            _updateBalance(preferredSide, sharesOut, false);
            _pushTokens(preferredSide, msg.sender, sharesOut);
            emit Withdrawn(msg.sender, preferredSide, lpAmount, sharesOut);
        } else if (preferredAvail == 0) {
            // Preferred side empty — use fallback entirely
            if (sharesOut > fallbackAvail) revert InsufficientLiquidity(fallbackAvail, sharesOut);
            _updateBalance(fallbackSide, sharesOut, false);
            _pushTokens(fallbackSide, msg.sender, sharesOut);
            emit Withdrawn(msg.sender, fallbackSide, lpAmount, sharesOut);
        } else {
            // Split: drain preferred side, take remainder from fallback
            uint256 remainder = sharesOut - preferredAvail;
            if (remainder > fallbackAvail) revert InsufficientLiquidity(preferredAvail + fallbackAvail, sharesOut);

            _updateBalance(preferredSide, preferredAvail, false);
            _updateBalance(fallbackSide, remainder, false);
            _pushTokens(preferredSide, msg.sender, preferredAvail);
            _pushTokens(fallbackSide, msg.sender, remainder);

            emit WithdrawnSplit(msg.sender, lpAmount, preferredAvail, preferredSide, remainder, fallbackSide);
        }
    }

    // ─── Swap ─────────────────────────────────────────────────────────────────

    /**
     * @notice Swap shares from one side to the other.
     *         User deposits `fromSide` shares, receives equivalent `toSide`
     *         shares minus 0.40% total fee.
     *
     *         Fee split:
     *           0.30% LP fee     → stays in pool as extra shares (auto-compounds)
     *           0.10% protocol   → transferred to FeeCollector
     *
     * @param fromSide  Side being deposited
     * @param amountIn  Number of shares deposited
     */
    function swap(Side fromSide, uint256 amountIn) external nonReentrant returns (uint256 amountOut) {
        if (swapsPaused) revert SwapsPaused();
        if (amountIn == 0) revert ZeroAmount();

        Side toSide = _oppositeSide(fromSide);

        uint256 lpFee = (amountIn * factory.lpFeeBps()) / factory.FEE_DENOMINATOR();
        uint256 protocolFee = (amountIn * factory.protocolFeeBps()) / factory.FEE_DENOMINATOR();
        amountOut = amountIn - lpFee - protocolFee;

        uint256 toBalance = _getBalance(toSide);
        if (amountOut > toBalance) revert InsufficientLiquidity(toBalance, amountOut);

        _pullTokens(fromSide, msg.sender, amountIn);

        // Protocol fee out to FeeCollector (skip if zero — e.g. zero-fee config or tiny amount)
        if (protocolFee > 0) {
            _pushTokens(fromSide, address(feeCollector), protocolFee);
            feeCollector.recordFee(_tokenAddress(fromSide), _tokenId(fromSide), protocolFee);
        }

        // Output to user
        _pushTokens(toSide, msg.sender, amountOut);

        // LP fee stays in pool on fromSide (auto-compounds)
        _updateBalance(fromSide, amountIn - protocolFee, true);
        _updateBalance(toSide, amountOut, false);

        emit Swapped(msg.sender, fromSide, amountIn, amountOut, lpFee, protocolFee);
    }

    // ─── Admin ────────────────────────────────────────────────────────────────

    function setDepositsPaused(bool paused_) external {
        if (msg.sender != address(factory)) revert Unauthorized();
        depositsPaused = paused_;
        emit DepositsPausedSet(paused_);
    }

    function setSwapsPaused(bool paused_) external {
        if (msg.sender != address(factory)) revert Unauthorized();
        swapsPaused = paused_;
        emit SwapsPausedSet(paused_);
    }

    // ─── Internal helpers ─────────────────────────────────────────────────────

    function _pullTokens(Side side, address from, uint256 amount) internal {
        IERC1155(_tokenAddress(side)).safeTransferFrom(from, address(this), _tokenId(side), amount, "");
    }

    function _pushTokens(Side side, address to, uint256 amount) internal {
        IERC1155(_tokenAddress(side)).safeTransferFrom(address(this), to, _tokenId(side), amount, "");
    }

    function _updateBalance(Side side, uint256 amount, bool add) internal {
        if (side == Side.POLYMARKET) {
            polymarketBalance = add ? polymarketBalance + amount : polymarketBalance - amount;
        } else {
            opinionBalance = add ? opinionBalance + amount : opinionBalance - amount;
        }
    }

    function _getBalance(Side side) internal view returns (uint256) {
        return side == Side.POLYMARKET ? polymarketBalance : opinionBalance;
    }

    function _oppositeSide(Side side) internal pure returns (Side) {
        return side == Side.POLYMARKET ? Side.OPINION : Side.POLYMARKET;
    }

    function _sideBalances(Side preferred)
        internal
        view
        returns (uint256 preferredAvail, uint256 fallbackAvail, Side fallbackSide)
    {
        if (preferred == Side.POLYMARKET) {
            return (polymarketBalance, opinionBalance, Side.OPINION);
        } else {
            return (opinionBalance, polymarketBalance, Side.POLYMARKET);
        }
    }

    /// @notice Token contract address — read from factory (single source of truth)
    function _tokenAddress(Side side) internal view returns (address) {
        return side == Side.POLYMARKET ? factory.polymarketToken() : factory.opinionToken();
    }

    function _tokenId(Side side) internal view returns (uint256) {
        return side == Side.POLYMARKET ? polymarketTokenId : opinionTokenId;
    }
}
