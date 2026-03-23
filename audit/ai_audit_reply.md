# Audit conserns

audit was made by ai tool - https://aiaudit.hashlock.com/audit/655d210f-1877-41db-b45f-5ff2101b404e

## Responses

1. Exchange Rate Manipulation Through Donation Attack
Irrelevant. Contracts does not use balanceOf that might be manipulated by direct donation

2. Permanent Freezing of Existing Pools When FeeCollector is Changed
Does not affect LPs of users. In case of lost of FeeCollector account might set protocolFeeBps to 0 to bypass it

3. Centralized Control Allows Instant Protocol Takeover
Pause all pools — legitimate admin function, not an attack vector. This is standard and expected for a protocol at this stage. Any serious incident requires instant response; a timelock on pause would be an anti-feature.

4. Precision Loss in Fee Calculations for Small Amounts
Protocol would not lost found, but simple wont receive fees. 
However, it will require users to swap amounts lower than transaction fees. Does not make any particular sence for such type of attack.

5. Reentrancy Through Malicious ERC-1155 Token Contracts
Irrelevant as ERC1155 token are immutable in contracts

6. Anyone Can Emit Fake Fee Events in FeeCollector
Made by design. For indexing have to use msg.sender to filter pools

7. Withdrawal Griefing Through Balance Manipulation
The attack has no economic payload.
Both sides are 1:1 equivalent by design — that's the entire premise of the protocol. Forcing a user to receive Opinion tokens instead of Polymarket tokens delivers the same value. There's nothing to grief because the "unwanted tokens" are worth exactly the same as the preferred ones.
The attacker also pays 0.40% swap fee to drain the preferred side and gains nothing from it. It's a self-funded nuisance with no upside.

8. First Depositor Can Manipulate LP Token Price
totalShares() reads polymarketBalance + opinionBalance — internal accounting variables, not balanceOf. Direct token transfers to the pool don't move those variables. The donation step of this attack does nothing.

9. Missing Validation of Token Contract Addresses
The risk is real in a narrow sense — passing a wrong address at deployment would brick the factory. But this is a one-time owner-controlled deployment with no adversarial input. The "attacker" is the deployer making a typo.

10. Pool Balances Not Synced with Actual Token Balances
Internal variables are the source of truth by design, balanceOf is never read. 
If user sends tokens to pool by mistake without calling deposit() function they gonna be lost forever, like on any other typical contract address

11. Gas Optimization: Redundant Balance Checks in Withdrawal
Not applicable



audit was made by ai tool - audit_agent_report_4_f7fbb87c-3cb8-4f9b-b044-9380deb5a580.pdf

## Responses


1. Independent ceiling-rounding of LP and protocol fees can overcharge by 100% or revert small swaps and cross-side withdrawals
Function _computeFees updated to correct according to finding

``` bash
function _computeFees(uint256 amount) internal view returns (uint256 lpFee, uint256 protocolFee) {
    uint256 denom    = factory.FEE_DENOMINATOR();
    uint256 lbps     = factory.lpFeeBps();
    uint256 pbps     = factory.protocolFeeBps();
    uint256 totalBps = lbps + pbps;

    if (totalBps == 0) return (0, 0);

    // Single ceiling rounding on the combined fee — one rounding event, not two
    uint256 totalFee = (amount * totalBps + denom - 1) / denom;

    // Split proportionally: protocolFee gets floor, lpFee absorbs the remainder
    protocolFee = pbps > 0 ? (totalFee * pbps) / totalBps : 0;
    lpFee       = totalFee - protocolFee;
}
```

2. Non-Specific Solidity Pragma Version
Acknowladge and took into account while deployment

3. PUSH0 Opcode Compatibility Issue
Not applicable to your deployment targets. Both Polygon and BSC have activated Shanghai, so PUSH0 is supported on both chains. No action needed.

4. Loop contains require / revert statements
The finding is technically correct but the severity is negligible in this context — withdrawBatch is onlyOwner, so the caller controls the input array entirely. 

5. Unoptimized Numeric Literal Format
Acknowladge but prefer to stick with more readable format