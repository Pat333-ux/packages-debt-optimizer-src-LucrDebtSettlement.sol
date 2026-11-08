// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

interface IERC20 {
    function transferFrom(address from, address to, uint256 value) external returns (bool);
    function transfer(address to, uint256 value) external returns (bool);
}

/**
 * @title LucrDebtSettlement
 * @notice Locks LUCR tokens for targeted credit tradeline paydowns and releases them
 *         to the treasury operator once off-ramp ACH/Fedwire settlement is confirmed.
 */
contract LucrDebtSettlement {
    IERC20 public immutable lucrToken;
    address public treasuryOperator;

    struct DebtEscrow {
        address member;
        string accountId;
        uint256 lockedLucr;
        uint256 usdCentsTarget;
        bool settled;
        bool refunded;
    }

    mapping(bytes32 => DebtEscrow) public escrows;

    event DebtPaydownLocked(
        bytes32 indexed settlementId,
        address indexed member,
        string accountId,
        uint256 lucrAmount,
        uint256 usdCents
    );
    event DebtPaydownSettled(bytes32 indexed settlementId, string achTraceId);
    event DebtPaydownRefunded(bytes32 indexed settlementId, address indexed member, uint256 lucrAmount);

    modifier onlyOperator() {
        require(msg.sender == treasuryOperator, "Unauthorized treasury operator");
        _;
    }

    constructor(address _lucrToken, address _treasuryOperator) {
        require(_lucrToken != address(0) && _treasuryOperator != address(0), "Zero address");
        lucrToken = IERC20(_lucrToken);
        treasuryOperator = _treasuryOperator;
    }

    /**
     * @notice Locks LUCR tokens from a member or treasury sponsor for a specific tradeline paydown.
     */
    function lockLucrForDebtPaydown(
        bytes32 settlementId,
        address member,
        string calldata accountId,
        uint256 lucrAmount,
        uint256 usdCents
    ) external {
        require(escrows[settlementId].lockedLucr == 0, "Settlement ID already exists");
        require(lucrAmount > 0 && usdCents > 0, "Invalid amount");
        require(lucrToken.transferFrom(msg.sender, address(this), lucrAmount), "LUCR transferFrom failed");

        escrows[settlementId] = DebtEscrow({
            member: member,
            accountId: accountId,
            lockedLucr: lucrAmount,
            usdCentsTarget: usdCents,
            settled: false,
            refunded: false
        });

        emit DebtPaydownLocked(settlementId, member, accountId, lucrAmount, usdCents);
    }

    /**
     * @notice Called by the backend bridge after the fiat ACH payment clears with the creditor.
     */
    function confirmAchSettlement(bytes32 settlementId, string calldata achTraceId) external onlyOperator {
        DebtEscrow storage item = escrows[settlementId];
        require(item.lockedLucr > 0 && !item.settled && !item.refunded, "Invalid escrow state");

        item.settled = true;
        require(lucrToken.transfer(treasuryOperator, item.lockedLucr), "Treasury sweep failed");

        emit DebtPaydownSettled(settlementId, achTraceId);
    }

    /**
     * @notice Refunds locked LUCR back to the member if a creditor rejects the ACH disbursement.
     */
    function refundFailedPaydown(bytes32 settlementId) external onlyOperator {
        DebtEscrow storage item = escrows[settlementId];
        require(item.lockedLucr > 0 && !item.settled && !item.refunded, "Invalid escrow state");

        item.refunded = true;
        require(lucrToken.transfer(item.member, item.lockedLucr), "Refund transfer failed");

        emit DebtPaydownRefunded(settlementId, item.member, item.lockedLucr);
    }
}
