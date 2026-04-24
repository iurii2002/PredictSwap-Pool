// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.24;

import "@openzeppelin/contracts/token/ERC1155/IERC1155.sol";
import "@openzeppelin/contracts/token/ERC1155/utils/ERC1155Holder.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "./LPToken.sol";
import "./FeeCollector.sol";
import "./PoolFactory.sol";

/**
 * @title SwapPool v3 — Simplified Value Accounting
 * @notice Holds two ERC-1155 prediction-market shares for ONE specific event-outcome
 *         pair (marketA + marketB). Both sides are treated as 1:1 in value.
 *
 *         Value accounting (replaces the v2 four-partition matrix):
 *           aSideValue — total normalized value owed to marketA-side LP holders
 *           bSideValue — total normalized value owed to marketB-side LP holders
 *
 *         All values are stored in 18-decimal normalized units.
 *         Transfers use raw native-decimal amounts via _toNorm / _fromNorm.
 *
 *         Per-side rates:
 *           marketARate = aSideValue * 1e18 / marketALpSupply
 *           marketBRate = bSideValue * 1e18 / marketBLpSupply
 *
 *         Swaps credit the LP fee to the drained side's value.
 *         Physical token composition is not tracked per-side — only total value.
 *
 * ─── Withdrawal rules ─────────────────────────────────────────────────────────
 *
 *   swaps active + not resolved  → withdrawal(): choose side, 0.4% fee if cross-side
 *   swaps active + resolved      → withdrawal(): choose side, no fee
 *   swaps paused + not resolved  → withdrawProRata(): proportional split, no fee
 *   swaps paused + resolved      → withdrawProRata(): proportional split, no fee
 *
 *   Governing rule: swapsPaused determines which function is available.
 *                   resolved determines whether cross-side fees apply.
 */
contract SwapPool is ERC1155Holder, ReentrancyGuard {

    using SafeERC20 for IERC20;

    // ─── Constants ────────────────────────────────────────────────────────────

    uint256 private constant RATE_PRECISION   = 1e18;
    uint256 public  constant FEE_DENOMINATOR  = 10_000;
    uint256 public  constant MAX_LP_FEE       = 100; // 1.00% hard cap
    uint256 public  constant MAX_PROTOCOL_FEE = 50;  // 0.50% hard cap

    // ─── Immutable config ─────────────────────────────────────────────────────

    PoolFactory public immutable factory;

    uint256 public immutable marketATokenId;
    uint8   public immutable marketADecimals;

    uint256 public immutable marketBTokenId;
    uint8   public immutable marketBDecimals;

    FeeCollector public immutable feeCollector;

    // ─── LP tokenIds (set once via initialize) ────────────────────────────────

    uint256 public marketALpTokenId;
    uint256 public marketBLpTokenId;
    bool    private _initialized;

    // ─── Fee config (mutable, owner-gated via factory) ────────────────────────

    uint256 public lpFeeBps;
    uint256 public protocolFeeBps;

    // ─── Value accounting (all values normalized to 18 decimals) ──────────────

    /// @notice Accounted balance of marketA-side LP holders (normalized 18-dec).
    ///         Increases on deposits and swap fees; decreases on withdrawals.
    ///         Dividing by LP supply gives the marketA-side exchange rate.
    uint256 public aSideValue;

    /// @notice Accounted balance of marketB-side LP holders (normalized 18-dec).
    ///         Increases on deposits and swap fees; decreases on withdrawals.
    ///         Dividing by LP supply gives the marketB-side exchange rate.
    uint256 public bSideValue;

    // ─── Admin flags ──────────────────────────────────────────────────────────

    bool public resolved;
    bool public depositsPaused;
    bool public swapsPaused;

    // ─── Types ────────────────────────────────────────────────────────────────

    enum Side {
        MARKET_A,
        MARKET_B
    }

    // ─── Events ───────────────────────────────────────────────────────────────

    event Initialized(uint256 marketALpTokenId, uint256 marketBLpTokenId);
    event DepositsPausedSet(bool isPaused);
    event SwapsPausedSet(bool isPaused);
    event Resolved(bool isResolved);
    event FeesUpdated(uint256 lpFeeBps, uint256 protocolFeeBps);

    event Deposited(address indexed user, Side side, uint256 sharesIn, uint256 lpMinted);

    event Withdrawn(
        address indexed user,
        Side lpSide,
        Side receiveSide,
        uint256 lpBurned,
        uint256 received,
        uint256 lpFee,
        uint256 protocolFee
    );

    event WithdrawnProRata(
        address indexed user,
        Side lpSide,
        uint256 lpBurned,
        uint256 nativeOut,
        uint256 crossOut
    );

    event Swapped(
        address indexed user,
        Side fromSide,
        uint256 amountIn,
        uint256 amountOut,
        uint256 lpFee,
        uint256 protocolFee
    );

    event TokensRescued(Side side, uint256 amount, address indexed to);
    event ERC1155Rescued(address indexed contractAddr, uint256 tokenId, uint256 amount, address indexed to);
    event ERC20Rescued(address indexed token, uint256 amount, address indexed to);
    event ETHRescued(uint256 amount, address indexed to);

    // ─── Errors ───────────────────────────────────────────────────────────────

    error DepositsPaused();
    error MarketResolved();
    error SwapsPaused();
    error SwapsNotPaused();
    error ZeroAmount();
    error ZeroAddress();
    error InvalidTokenID();
    error InvalidDecimals();
    error FeeTooHigh();
    error DepositTooSmall();
    error SwapTooSmall();
    error Unauthorized();
    error NothingToRescue();
    error CannotRescuePoolTokens();
    error AlreadyInitialized();
    error NotInitialized();
    error InsufficientLiquidity(uint256 available, uint256 required);

    // ─── Constructor ──────────────────────────────────────────────────────────

    constructor(
        address factory_,
        PoolFactory.MarketConfig memory marketA_,
        PoolFactory.MarketConfig memory marketB_,
        uint256 lpFeeBps_,
        uint256 protocolFeeBps_,
        address feeCollector_
    ) {
        if (factory_ == address(0) || feeCollector_ == address(0)) revert ZeroAddress();
        if (marketA_.tokenId == 0 || marketB_.tokenId == 0) revert InvalidTokenID();
        if (marketA_.decimals > 18 || marketB_.decimals > 18) revert InvalidDecimals();
        if (lpFeeBps_ > MAX_LP_FEE) revert FeeTooHigh();
        if (protocolFeeBps_ > MAX_PROTOCOL_FEE) revert FeeTooHigh();

        factory = PoolFactory(factory_);

        marketATokenId  = marketA_.tokenId;
        marketADecimals = marketA_.decimals;
        marketBTokenId  = marketB_.tokenId;
        marketBDecimals = marketB_.decimals;

        lpFeeBps       = lpFeeBps_;
        protocolFeeBps = protocolFeeBps_;

        feeCollector = FeeCollector(feeCollector_);
    }

    /// @notice One-time wiring of LP tokenIds. Called by factory immediately after
    ///         registering the two LP positions on the shared LP token.
    function initialize(uint256 marketALpTokenId_, uint256 marketBLpTokenId_) external {
        if (msg.sender != address(factory)) revert Unauthorized();
        if (_initialized) revert AlreadyInitialized();
        if (marketALpTokenId_ == 0 || marketBLpTokenId_ == 0) revert InvalidTokenID();
        _initialized = true;
        marketALpTokenId = marketALpTokenId_;
        marketBLpTokenId = marketBLpTokenId_;
        emit Initialized(marketALpTokenId_, marketBLpTokenId_);
    }

    modifier whenInitialized() {
        if (!_initialized) revert NotInitialized();
        _;
    }

    // ─── View helpers ─────────────────────────────────────────────────────────

    /// @notice Current marketA-side LP rate, scaled by 1e18. Starts at 1e18.
    function marketARate() public view returns (uint256) {
        uint256 supply = factory.marketALpToken().totalSupply(marketALpTokenId);
        if (supply == 0) return RATE_PRECISION;
        return (aSideValue * RATE_PRECISION) / supply;
    }

    /// @notice Current marketB-side LP rate, scaled by 1e18. Starts at 1e18.
    function marketBRate() public view returns (uint256) {
        uint256 supply = factory.marketBLpToken().totalSupply(marketBLpTokenId);
        if (supply == 0) return RATE_PRECISION;
        return (bSideValue * RATE_PRECISION) / supply;
    }

    function totalFeeBps() public view returns (uint256) {
        return lpFeeBps + protocolFeeBps;
    }

    /// @notice Physical balance of a side's token held by this pool (normalized 18-dec).
    function physicalBalanceNorm(Side side) public view returns (uint256) {
        uint256 raw = IERC1155(_marketContract(side)).balanceOf(address(this), _tokenId(side));
        return _toNorm(side, raw);
    }

    // ─── Fee helper ───────────────────────────────────────────────────────────

    function _computeFees(uint256 normAmount) internal view returns (uint256 lpFee, uint256 protocolFee) {
        uint256 totalBps = lpFeeBps + protocolFeeBps;
        if (totalBps == 0 || normAmount == 0) return (0, 0);

        uint256 totalFee = (normAmount * totalBps + FEE_DENOMINATOR - 1) / FEE_DENOMINATOR;
        protocolFee = protocolFeeBps > 0 ? (totalFee * protocolFeeBps) / totalBps : 0;
        lpFee       = totalFee - protocolFee;
    }

    // ─── Deposit ──────────────────────────────────────────────────────────────

    /**
     * @notice Deposit shares and receive the matching LP token.
     *         First deposit on a side mints LP 1:1 with the normalized amount.
     */
    function deposit(Side side, uint256 amount)
        external
        nonReentrant
        whenInitialized
        returns (uint256 lpMinted)
    {
        if (depositsPaused) revert DepositsPaused();
        if (resolved) revert MarketResolved();
        if (amount == 0) revert ZeroAmount();

        _pullTokens(side, msg.sender, amount);
        uint256 normAmount = _toNorm(side, amount);

        uint256 supply = _lpToken(side).totalSupply(_lpTokenId(side));
        uint256 sideValue = _sideValue(side);

        lpMinted = (supply == 0)
            ? normAmount
            : (normAmount * supply) / sideValue;
        if (lpMinted == 0) revert DepositTooSmall();

        _addSideValue(side, normAmount);
        _mintLp(side, msg.sender, lpMinted);

        emit Deposited(msg.sender, side, amount, lpMinted);
    }

    // ─── Swap ─────────────────────────────────────────────────────────────────

    /**
     * @notice Swap shares 1:1 (minus fees). LP fee accrues to the drained side's value.
     */
    function swap(Side fromSide, uint256 sharesIn)
        external
        nonReentrant
        whenInitialized
        returns (uint256 sharesOut)
    {
        if (swapsPaused) revert SwapsPaused();
        if (resolved) revert MarketResolved();
        if (sharesIn == 0) revert ZeroAmount();

        Side toSide = _oppositeSide(fromSide);

        uint256 normIn = _toNorm(fromSide, sharesIn);
        (uint256 lpFee, uint256 protocolFee) = _computeFees(normIn);
        uint256 normOut = normIn - lpFee - protocolFee;

        // Check physical liquidity on the output side
        uint256 availableOut = physicalBalanceNorm(toSide);
        if (normOut > availableOut) revert InsufficientLiquidity(availableOut, normOut);

        // Pull input tokens
        _pullTokens(fromSide, msg.sender, sharesIn);

        // Protocol fee (paid in input-side tokens)
        uint256 rawProtocol = _fromNorm(fromSide, protocolFee);
        if (rawProtocol > 0) {
            _pushTokens(fromSide, address(feeCollector), rawProtocol);
            feeCollector.recordFee(_marketContract(fromSide), _tokenId(fromSide), rawProtocol);
        }

        // Output tokens to swapper
        uint256 rawOut = _fromNorm(toSide, normOut);
        if (rawOut == 0) revert SwapTooSmall(); // or a new ZeroOutput error
        _pushTokens(toSide, msg.sender, rawOut);

        // LP fee split: drained-side LPs get fee proportional to their
        // value; any drain beyond their value used the other side's overflow.
        _distributeLpFee(toSide, fromSide, lpFee, normOut);

        sharesOut = rawOut;
        emit Swapped(msg.sender, fromSide, sharesIn, rawOut, lpFee, protocolFee);
    }

    // ─── Withdrawal (swaps must be active) ────────────────────────────────────

    /**
     * @notice Withdraw LP position. User chooses which side to receive payout in.
     *
     *         Same-side:  no fee (except JIT fee on fresh LP portion when not resolved).
     *         Cross-side: full fee on claim when not resolved, free when resolved.
     *
     *         Reverts if the pool doesn't have enough physical tokens on the chosen side.
     *         When insufficient, user should try the other side or wait for resolution.
     */
    function withdrawal(Side receiveSide, uint256 lpAmount, Side lpSide)
        external
        nonReentrant
        whenInitialized
        returns (uint256 received)
    {   
        if (swapsPaused) revert SwapsPaused(); // should use withdrawProRata
        if (lpAmount == 0) revert ZeroAmount();

        uint256 shares = _lpToShares(lpSide, lpAmount);

        uint256 lpFee;
        uint256 protocolFee;

        if (receiveSide == lpSide) {
            // Same-side: JIT fee on fresh portion only
            uint256 freshBurned = _freshConsumedForBurn(lpSide, lpAmount);
            if (!resolved && freshBurned > 0) {
                // feeBase is a part of LP that was not on wallet long enough
                uint256 feeBase = (shares * freshBurned) / lpAmount; 
                (lpFee, protocolFee) = _computeFees(feeBase);
            }
        } else {
            // Cross-side: fee on full claim when not resolved
            if (!resolved) {
                (lpFee, protocolFee) = _computeFees(shares);
            }
        }

        uint256 payoutNorm = shares - lpFee - protocolFee;

        // Check physical liquidity on the receive side
        uint256 available = physicalBalanceNorm(receiveSide);
        uint256 totalOutflow = payoutNorm + protocolFee; // both leave the pool in receiveSide tokens
        if (totalOutflow > available) revert InsufficientLiquidity(available, totalOutflow);

        uint256 supplyBefore = _lpToken(lpSide).totalSupply(_lpTokenId(lpSide));
        bool isLastLp = (supplyBefore == lpAmount);
        // Update value: LP fee moves to other side is cross-side
        if (receiveSide == lpSide) {            
            if (isLastLp && lpFee > 0) {
                // No remaining same-side LPs to benefit from the fee.
                // Credit it to the other side (they now effectively own the residual).
                _subSideValue(lpSide, shares);
                _addSideValue(_oppositeSide(lpSide), lpFee);
            } else {
                _subSideValue(lpSide, shares - lpFee);
            }
        } else {
            _subSideValue(lpSide, shares);
            if (isLastLp) {
                // Last LP on this side — no one left to claim fee remainder.
                _addSideValue(receiveSide, lpFee);
            } else {
                _distributeLpFee(receiveSide, lpSide, lpFee, totalOutflow);
            }
        }

        // Burn LP tokens (triggers LPToken's fresh bucket bookkeeping)
        _burnLp(lpSide, msg.sender, lpAmount);

        // Transfer payout
        uint256 rawPayout = _fromNorm(receiveSide, payoutNorm);
        if (rawPayout == 0) revert ZeroAmount();
        _pushTokens(receiveSide, msg.sender, rawPayout);

        // Transfer protocol fee
        uint256 rawProto = _fromNorm(receiveSide, protocolFee);
        if (rawProto > 0) {
            _pushTokens(receiveSide, address(feeCollector), rawProto);
            feeCollector.recordFee(_marketContract(receiveSide), _tokenId(receiveSide), rawProto);
        }

        received = rawPayout;
        _flushResidualIfEmpty();
        emit Withdrawn(msg.sender, lpSide, receiveSide, lpAmount, rawPayout, lpFee, protocolFee);
    }

    // ─── Withdrawal Pro-Rata (swaps must be paused) ───────────────────────────

    /**
     * @notice Withdraw LP position with proportional split of native and cross tokens.
     *         Only available when swaps are paused (to prevent one side draining
     *         the other). Never charges fees.
     *
     *         Native share = (lpAmount / totalSideSupply) × physicalNative,
     *         capped at the user's full claim. Remainder paid in cross-side tokens.
     *          
     */
    function withdrawProRata(uint256 lpAmount, Side lpSide)
        external
        nonReentrant
        whenInitialized
        returns (uint256 nativeOut, uint256 crossOut)
    {
        if (!swapsPaused) revert SwapsNotPaused(); // should use withdraw
        if (lpAmount == 0) revert ZeroAmount();

        uint256 shares = _lpToShares(lpSide, lpAmount);

        Side nativeSide = lpSide;
        Side crossSide  = _oppositeSide(lpSide);

        // Proportional share of native reserves (prevents draining)
        uint256 totalSupply = _lpToken(lpSide).totalSupply(_lpTokenId(lpSide));
        uint256 availableNative = physicalBalanceNorm(nativeSide);
        uint256 nativeShare = (lpAmount * availableNative) / totalSupply;

        // Cap at claim — if no shortage, user gets everything in native
        if (nativeShare > shares) nativeShare = shares;
        uint256 crossShare = shares - nativeShare;

        // Check cross-side liquidity for the remainder. It shoul never be the case
        if (crossShare > 0) {
            uint256 availableCross = physicalBalanceNorm(crossSide);
            if (crossShare > availableCross) revert InsufficientLiquidity(availableCross, crossShare);
        }

        // Update value
        _subSideValue(lpSide, shares);

        // Burn LP tokens
        _burnLp(lpSide, msg.sender, lpAmount);

        uint256 rawNative = _fromNorm(nativeSide, nativeShare);
        uint256 rawCross = _fromNorm(crossSide, crossShare);

        if (rawNative == 0 && rawCross == 0) revert ZeroAmount();

        // Transfer native portion
        if (rawNative > 0) _pushTokens(nativeSide, msg.sender, rawNative);
        // Transfer cross portion
        if (rawCross  > 0) _pushTokens(crossSide, msg.sender, rawCross);

        nativeOut = rawNative;
        crossOut  = rawCross;
        _flushResidualIfEmpty();
        emit WithdrawnProRata(msg.sender, lpSide, lpAmount, rawNative, rawCross);
    }

    // ─── Flush residual ───────────────────────────────────────────────────────

    /// @dev When all LP tokens are burned, sweep any rounding dust to the fee collector.
    function _flushResidualIfEmpty() internal {
        uint256 aSupply = factory.marketALpToken().totalSupply(marketALpTokenId);
        uint256 bSupply = factory.marketBLpToken().totalSupply(marketBLpTokenId);
        if (aSupply + bSupply > 0) return;

        aSideValue = 0;
        bSideValue = 0;

        uint256 rawA = IERC1155(_marketContract(Side.MARKET_A))
            .balanceOf(address(this), marketATokenId);
        uint256 rawB = IERC1155(_marketContract(Side.MARKET_B))
            .balanceOf(address(this), marketBTokenId);

        if (rawA > 0) {
            _pushTokens(Side.MARKET_A, address(feeCollector), rawA);
            feeCollector.recordFee(_marketContract(Side.MARKET_A), marketATokenId, rawA);
        }
        if (rawB > 0) {
            _pushTokens(Side.MARKET_B, address(feeCollector), rawB);
            feeCollector.recordFee(_marketContract(Side.MARKET_B), marketBTokenId, rawB);
        }
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

    function setResolved(bool resolved_) external {
        if (msg.sender != address(factory)) revert Unauthorized();
        resolved = resolved_;
        emit Resolved(resolved_);
    }

    function setResolvedAndPaused() external {
        if (msg.sender != address(factory)) revert Unauthorized();
        resolved = true;
        depositsPaused = true;
        swapsPaused = true;
        emit Resolved(true);
        emit DepositsPausedSet(true);
        emit SwapsPausedSet(true);
    }

    function setFees(uint256 lpFeeBps_, uint256 protocolFeeBps_) external {
        if (msg.sender != address(factory)) revert Unauthorized();
        if (lpFeeBps_ > MAX_LP_FEE) revert FeeTooHigh();
        if (protocolFeeBps_ > MAX_PROTOCOL_FEE) revert FeeTooHigh();
        lpFeeBps       = lpFeeBps_;
        protocolFeeBps = protocolFeeBps_;
        emit FeesUpdated(lpFeeBps_, protocolFeeBps_);
    }

    // ─── Rescue ───────────────────────────────────────────────────────────────

    /// @notice Rescue surplus pool tokens (sent accidentally, above tracked value).
    function rescueTokens(Side side, uint256 rawAmount, address to) external {
        if (msg.sender != address(factory)) revert Unauthorized();
        if (to == address(0)) revert ZeroAddress();

        uint256 normAmount = _toNorm(side, rawAmount);
        if (normAmount == 0) revert NothingToRescue();

        // Global surplus: total physical across BOTH sides minus total obligations
        uint256 totalPhysical = physicalBalanceNorm(Side.MARKET_A) + physicalBalanceNorm(Side.MARKET_B);
        uint256 totalTracked  = aSideValue + bSideValue;
        if (totalPhysical <= totalTracked) revert NothingToRescue();

        uint256 surplus = totalPhysical - totalTracked;
        if (normAmount > surplus) revert NothingToRescue();

        _pushTokens(side, to, rawAmount);
        emit TokensRescued(side, normAmount, to);
    }

    function rescueERC1155(address contractAddress_, uint256 tokenId_, uint256 amount, address to) external {
        if (msg.sender != address(factory)) revert Unauthorized();
        if (to == address(0)) revert ZeroAddress();
        address mktA = _marketContract(Side.MARKET_A);
        address mktB = _marketContract(Side.MARKET_B);
        if ((contractAddress_ == mktA && tokenId_ == marketATokenId) 
        || (contractAddress_ == mktB && tokenId_ == marketBTokenId)) revert CannotRescuePoolTokens();
        IERC1155(contractAddress_).safeTransferFrom(address(this), to, tokenId_, amount, "");
        emit ERC1155Rescued(contractAddress_, tokenId_, amount, to);
    }

    function rescueERC20(address token, uint256 amount, address to) external {
        if (msg.sender != address(factory)) revert Unauthorized();
        if (to == address(0)) revert ZeroAddress();
        IERC20(token).safeTransfer(to, amount);
        emit ERC20Rescued(token, amount, to);
    }

    function rescueETH(address payable to) external {
        if (msg.sender != address(factory)) revert Unauthorized();
        if (to == address(0)) revert ZeroAddress();
        uint256 balance = address(this).balance;
        (bool ok,) = to.call{value: balance}("");
        require(ok, "ETH transfer failed");
        emit ETHRescued(balance, to);
    }

    receive() external payable {}

    // ─── Internal helpers ─────────────────────────────────────────────────────

    /// @notice Normalized share amount attributed to the given LP token amount.
    function _lpToShares(Side lpSide, uint256 lpAmount) internal view returns (uint256) {
        uint256 rate = (lpSide == Side.MARKET_A) ? marketARate() : marketBRate();
        return (lpAmount * rate) / RATE_PRECISION;
    }

    /// @notice Portion of `lpAmount` attributable to the caller's fresh (locked) bucket.
    ///         Matured LP is consumed first by the LPToken's outflow hook, so the fee
    ///         base is only the overhang — i.e., max(0, lpAmount − matured).
    function _freshConsumedForBurn(Side lpSide, uint256 lpAmount) internal view returns (uint256) {
        LPToken lp = _lpToken(lpSide);
        uint256 tokenId = _lpTokenId(lpSide);
        uint256 balance = lp.balanceOf(msg.sender, tokenId);
        uint256 locked  = lp.lockedAmount(msg.sender, tokenId);
        uint256 matured = balance > locked ? balance - locked : 0;
        return lpAmount > matured ? lpAmount - matured : 0;
    }

    function _burnLp(Side lpSide, address from, uint256 amount) internal {
        if (lpSide == Side.MARKET_A) {
            factory.marketALpToken().burn(from, marketALpTokenId, amount);
        } else {
            factory.marketBLpToken().burn(from, marketBLpTokenId, amount);
        }
    }

    function _mintLp(Side lpSide, address to, uint256 amount) internal {
        if (lpSide == Side.MARKET_A) {
            factory.marketALpToken().mint(to, marketALpTokenId, amount);
        } else {
            factory.marketBLpToken().mint(to, marketBLpTokenId, amount);
        }
    }

    function _sideValue(Side side) internal view returns (uint256) {
        return side == Side.MARKET_A ? aSideValue : bSideValue;
    }

    function _addSideValue(Side side, uint256 amount) internal {
        if (side == Side.MARKET_A) {
            aSideValue += amount;
        } else {
            bSideValue += amount;
        }
    }

    function _subSideValue(Side side, uint256 amount) internal {
        if (side == Side.MARKET_A) {
            aSideValue -= amount;
        } else {
            bSideValue -= amount;
        }
    }

    /// @notice Split LP fee between drained side and the other side based on
    ///         effective liquidity ownership. If the drain exceeds the drained
    ///         side's LP value, the excess was backed by the other side's overflow.
    ///         Imagine Pool 1005:1000, but LPs are 2000:5. 
    ///         If swap 1000 A to B, all the fees goes to 5 LP, that is incorrect 
    ///         and should be targeted with this function
    function _distributeLpFee(Side drainedSide, Side otherSide, uint256 lpFee, uint256 drain) internal {
        if (lpFee == 0) return;
        uint256 drainedVal = _sideValue(drainedSide);
        if (drainedVal == 0) {
            _addSideValue(otherSide, lpFee);
        } else if (drain <= drainedVal) {
            _addSideValue(drainedSide, lpFee);
        } else {
            uint256 feeToDrained = (lpFee * drainedVal) / drain;
            _addSideValue(drainedSide, feeToDrained);
            _addSideValue(otherSide, lpFee - feeToDrained);
        }
    }

    function _lpToken(Side side) internal view returns (LPToken) {
        return side == Side.MARKET_A ? factory.marketALpToken() : factory.marketBLpToken();
    }

    function _lpTokenId(Side side) internal view returns (uint256) {
        return side == Side.MARKET_A ? marketALpTokenId : marketBLpTokenId;
    }

    function _toNorm(Side side, uint256 raw) internal view returns (uint256) {
        uint8 dec = side == Side.MARKET_A ? marketADecimals : marketBDecimals;
        if (dec == 18) return raw;
        return raw * 10 ** (18 - dec);
    }

    function _fromNorm(Side side, uint256 norm) internal view returns (uint256) {
        uint8 dec = side == Side.MARKET_A ? marketADecimals : marketBDecimals;
        if (dec == 18) return norm;
        return norm / 10 ** (18 - dec);
    }

    function _pullTokens(Side side, address from, uint256 amount) internal {
        IERC1155(_marketContract(side)).safeTransferFrom(from, address(this), _tokenId(side), amount, "");
    }

    function _pushTokens(Side side, address to, uint256 amount) internal {
        IERC1155(_marketContract(side)).safeTransferFrom(address(this), to, _tokenId(side), amount, "");
    }

    function _oppositeSide(Side side) internal pure returns (Side) {
        return side == Side.MARKET_A ? Side.MARKET_B : Side.MARKET_A;
    }

    function _marketContract(Side side) internal view returns (address) {
        return side == Side.MARKET_A ? factory.marketAContract() : factory.marketBContract();
    }

    function _tokenId(Side side) internal view returns (uint256) {
        return side == Side.MARKET_A ? marketATokenId : marketBTokenId;
    }
}