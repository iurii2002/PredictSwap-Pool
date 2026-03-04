// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/token/ERC20/ERC20.sol";

/**
 * @title LPToken
 * @notice ERC-20 LP token representing a user's share of a specific SwapPool.
 *         One LPToken contract is deployed per pool by PoolFactory.
 *         Only the associated SwapPool can mint or burn.
 *
 * ─── Two-step pool assignment ─────────────────────────────────────────────────
 *
 * To avoid the CREATE2 chicken-and-egg problem (SwapPool needs LP address,
 * LPToken needs SwapPool address), the factory is set as a temporary authority
 * at deploy time. After SwapPool is deployed, the factory calls setPool() once
 * to wire the LP token to its pool. setPool() can never be called again.
 *
 * ─── Exchange rate ────────────────────────────────────────────────────────────
 *
 *   rate = SwapPool.totalShares() / lpToken.totalSupply()
 *
 * Rate starts at 1.0 for the first depositor and increases as LP fees
 * auto-compound in the pool.
 */
contract LPToken is ERC20 {
    address public pool;
    address public immutable factory;
    bool    private poolSet;

    error OnlyPool();
    error OnlyFactory();
    error PoolAlreadySet();
    error ZeroAddress();

    modifier onlyPool() {
        if (msg.sender != pool) revert OnlyPool();
        _;
    }

    constructor(
        string memory name_,
        string memory symbol_,
        address factory_
    ) ERC20(name_, symbol_) {
        if (factory_ == address(0)) revert ZeroAddress();
        factory = factory_;
    }

    /**
     * @notice One-time assignment of the associated SwapPool address.
     *         Called by PoolFactory immediately after deploying the SwapPool.
     *         Cannot be called again once set.
     */
    function setPool(address pool_) external {
        if (msg.sender != factory)  revert OnlyFactory();
        if (poolSet)                revert PoolAlreadySet();
        if (pool_ == address(0))    revert ZeroAddress();
        pool    = pool_;
        poolSet = true;
    }

    function mint(address to, uint256 amount) external onlyPool {
        _mint(to, amount);
    }

    function burn(address from, uint256 amount) external onlyPool {
        _burn(from, amount);
    }
}
