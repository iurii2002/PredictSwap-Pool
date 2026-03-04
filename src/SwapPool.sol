// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/token/ERC1155/IERC1155.sol";
import "@openzeppelin/contracts/token/ERC1155/utils/ERC1155Holder.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "./LPToken.sol";
import "./FeeCollector.sol";

/**
 * @title SwapPool
 * @notice Holds Polymarket ERC-1155 shares and WrappedOpinion ERC-1155 shares
 *         for ONE specific event-outcome pair. Both sides represent the same
 *         real-world outcome and are treated as 1:1 equivalent in value.
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

    uint256 public constant FEE_DENOMINATOR  = 10_000;
    uint256 public constant LP_FEE_BPS       = 30;   // 0.30%
    uint256 public constant PROTOCOL_FEE_BPS = 10;   // 0.10%
    uint256 public constant TOTAL_FEE_BPS    = 40;   // 0.40%

    // ─── Immutable config ─────────────────────────────────────────────────────

    /// @notice Polymarket ERC-1155 contract address
    address public immutable polymarketToken;
    /// @notice Polymarket ERC-1155 token ID for this pool's event-outcome
    uint256 public immutable polymarketTokenId;

    /// @notice WrappedOpinion ERC-1155 contract address
    address public immutable opinionToken;
    /// @notice WrappedOpinion ERC-1155 token ID for this pool's event-outcome
    uint256 public immutable opinionTokenId;

    /// @notice Associated LP token (ERC-20)
    LPToken  public immutable lpToken;
    /// @notice Protocol fee recipient
    FeeCollector public immutable feeCollector;

    // ─── Pool state ───────────────────────────────────────────────────────────

    /// @notice Polymarket shares held in this pool
    uint256 public polymarketBalance;
    /// @notice WrappedOpinion shares held in this pool
    uint256 public opinionBalance;

    // ─── Types ────────────────────────────────────────────────────────────────

    enum Side { POLYMARKET, OPINION }

    // ─── Events ───────────────────────────────────────────────────────────────

    event Deposited(
        address indexed user,
        Side side,
        uint256 sharesIn,
        uint256 lpMinted
    );
    event Withdrawn(
        address indexed user,
        Side sideReceived,
        uint256 lpBurned,
        uint256 sharesOut
    );
    event Swapped(
        address indexed user,
        Side fromSide,
        uint256 amountIn,
        uint256 amountOut,
        uint256 lpFee,
        uint256 protocolFee
    );

    // ─── Errors ───────────────────────────────────────────────────────────────

    error ZeroAmount();
    error InsufficientLiquidity(uint256 available, uint256 required);
    error InvalidSide();

    // ─── Constructor ──────────────────────────────────────────────────────────

    constructor(
        address polymarketToken_,
        uint256 polymarketTokenId_,
        address opinionToken_,
        uint256 opinionTokenId_,
        address lpToken_,
        address feeCollector_
    ) {
        polymarketToken   = polymarketToken_;
        polymarketTokenId = polymarketTokenId_;
        opinionToken      = opinionToken_;
        opinionTokenId    = opinionTokenId_;
        lpToken           = LPToken(lpToken_);
        feeCollector      = FeeCollector(feeCollector_);
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
     * @param side      Which token to deposit (POLYMARKET or OPINION)
     * @param amount    Number of ERC-1155 shares to deposit
     *
     * Emits Deposited.
     */
    function deposit(Side side, uint256 amount) external nonReentrant returns (uint256 lpMinted) {
        if (amount == 0) revert ZeroAmount();

        // Pull tokens in
        _pullTokens(side, msg.sender, amount);

        // Calculate LP to mint
        uint256 supply = lpToken.totalSupply();
        if (supply == 0) {
            // First depositor: 1 share = 1 LP token
            lpMinted = amount;
        } else {
            // lpToMint = amount * supply / totalShares (before adding amount)
            // totalShares() still reflects pre-deposit state here because
            // _updateBalance is called after this calculation
            lpMinted = (amount * supply) / totalShares();
        }

        // Update internal balance tracking
        _updateBalance(side, amount, true);

        // Mint LP tokens to user
        lpToken.mint(msg.sender, lpMinted);

        emit Deposited(msg.sender, side, amount, lpMinted);
    }

    // ─── Withdraw ─────────────────────────────────────────────────────────────

    /**
     * @notice Burn LP tokens and receive underlying shares.
     *         User specifies a preferred side. If that side has sufficient
     *         liquidity, all shares come from there. Otherwise falls back
     *         to the other side (or splits if neither has enough alone).
     *
     * @param lpAmount       LP tokens to burn
     * @param preferredSide  Preferred side to receive (POLYMARKET or OPINION)
     *
     * Emits Withdrawn. May emit two Withdrawn events if split across sides.
     */
    function withdraw(
        uint256 lpAmount,
        Side preferredSide
    ) external nonReentrant returns (uint256 sharesOut) {
        if (lpAmount == 0) revert ZeroAmount();

        uint256 supply = lpToken.totalSupply();
        // sharesToRelease = lpBurned * totalShares / supply
        sharesOut = (lpAmount * totalShares()) / supply;

        // Burn LP first (CEI pattern)
        lpToken.burn(msg.sender, lpAmount);

        // Determine which side(s) to pay from
        (uint256 preferredAvail, uint256 fallbackAvail, Side fallbackSide) =
            _sideBalances(preferredSide);

        if (sharesOut <= preferredAvail) {
            // Preferred side has enough
            _updateBalance(preferredSide, sharesOut, false);
            _pushTokens(preferredSide, msg.sender, sharesOut);
            emit Withdrawn(msg.sender, preferredSide, lpAmount, sharesOut);
        } else if (preferredAvail == 0) {
            // Preferred side empty, use fallback entirely
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

            // Emit two events to clearly show the split
            emit Withdrawn(msg.sender, preferredSide, 0, preferredAvail);
            emit Withdrawn(msg.sender, fallbackSide, lpAmount, remainder);
        }
    }

    // ─── Swap ─────────────────────────────────────────────────────────────────

    /**
     * @notice Swap shares from one side to the other.
     *         User deposits `fromSide` shares, receives equivalent `toSide`
     *         shares minus 0.40% total fee.
     *
     *         Fee split:
     *           - 0.30% LP fee: stays in pool as extra shares (no new LP minted)
     *           - 0.10% protocol fee: transferred to FeeCollector
     *
     * @param fromSide   Side being deposited
     * @param amountIn   Number of shares deposited
     *
     * @return amountOut Shares received by user (amountIn - 0.40%)
     *
     * Emits Swapped.
     */
    function swap(
        Side fromSide,
        uint256 amountIn
    ) external nonReentrant returns (uint256 amountOut) {
        if (amountIn == 0) revert ZeroAmount();

        Side toSide = _oppositeSide(fromSide);

        // Calculate fees
        uint256 lpFee       = (amountIn * LP_FEE_BPS) / FEE_DENOMINATOR;
        uint256 protocolFee = (amountIn * PROTOCOL_FEE_BPS) / FEE_DENOMINATOR;
        amountOut           = amountIn - lpFee - protocolFee;

        // Check destination liquidity
        uint256 toBalance = _getBalance(toSide);
        if (amountOut > toBalance) revert InsufficientLiquidity(toBalance, amountOut);

        // Pull input tokens from user
        _pullTokens(fromSide, msg.sender, amountIn);

        // Push protocol fee to FeeCollector
        _pushTokens(fromSide, address(feeCollector), protocolFee);
        feeCollector.recordFee(_tokenAddress(fromSide), _tokenId(fromSide), protocolFee);

        // Push output tokens to user
        _pushTokens(toSide, msg.sender, amountOut);

        // Update balances:
        //   fromSide: +amountIn, then -protocolFee (net: +amountIn - protocolFee = +amountOut + lpFee)
        //   toSide:   -amountOut
        // LP fee (lpFee) remains in pool on fromSide — this is the auto-compounding mechanism.
        _updateBalance(fromSide, amountIn - protocolFee, true);  // net add to pool
        _updateBalance(toSide, amountOut, false);

        emit Swapped(msg.sender, fromSide, amountIn, amountOut, lpFee, protocolFee);
    }

    // ─── Internal helpers ─────────────────────────────────────────────────────

    function _pullTokens(Side side, address from, uint256 amount) internal {
        IERC1155(_tokenAddress(side)).safeTransferFrom(
            from, address(this), _tokenId(side), amount, ""
        );
    }

    function _pushTokens(Side side, address to, uint256 amount) internal {
        IERC1155(_tokenAddress(side)).safeTransferFrom(
            address(this), to, _tokenId(side), amount, ""
        );
    }

    function _updateBalance(Side side, uint256 amount, bool add) internal {
        if (side == Side.POLYMARKET) {
            polymarketBalance = add
                ? polymarketBalance + amount
                : polymarketBalance - amount;
        } else {
            opinionBalance = add
                ? opinionBalance + amount
                : opinionBalance - amount;
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
        returns (uint256 preferredAvail, uint256 fallbackAvail, Side fallback)
    {
        if (preferred == Side.POLYMARKET) {
            return (polymarketBalance, opinionBalance, Side.OPINION);
        } else {
            return (opinionBalance, polymarketBalance, Side.POLYMARKET);
        }
    }

    function _tokenAddress(Side side) internal view returns (address) {
        return side == Side.POLYMARKET ? polymarketToken : opinionToken;
    }

    function _tokenId(Side side) internal view returns (uint256) {
        return side == Side.POLYMARKET ? polymarketTokenId : opinionTokenId;
    }
}
