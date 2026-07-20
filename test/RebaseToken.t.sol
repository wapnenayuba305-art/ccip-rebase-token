// SPDX-License-Identifier: MIT

pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {RebaseToken} from "../src/RebaseToken.sol";
import {Vault} from "../src/Vault.sol";
import {IRebaseToken} from "../src/interfaces/IRebaseToken.sol";

contract RebaseTokenTest is Test {
    RebaseToken private rebaseToken;
    Vault private vault;

    address public owner = makeAddr("owner");
    address public user = makeAddr("user");
    address public user2 = makeAddr("user2");

    function _sendEth(address target, uint256 amount) internal {
        (bool success, ) = payable(target).call{value: amount}("");
        require(success, "ETH transfer failed");
    }

    function setUp() public {
        vm.startPrank(owner);

        rebaseToken = new RebaseToken();
        vault = new Vault(IRebaseToken(address(rebaseToken)));

        rebaseToken.grantMintAndBurnRole(address(vault));

        vm.deal(owner, 1 ether);
        _sendEth(address(vault), 1 ether);

        vm.stopPrank();
    }

    // ─────────────────────────────────────────────
    // Deposit Tests
    // ─────────────────────────────────────────────

    /// @notice A deposit mints the correct amount of RebaseTokens.
    /// @dev Balance is checked in the same block as deposit (no interest yet).
    function testDepositMintsTokens() public {
        uint256 amount = 1 ether;

        vm.deal(user, amount);
        vm.startPrank(user);
        vault.deposit{value: amount}();

        // Check balance immediately — no time has passed, so no interest yet
        uint256 balance = rebaseToken.balanceOf(user);
        vm.stopPrank();

        assertEq(balance, amount, "Token balance should equal deposited ETH");
    }

    /// @notice Depositing zero ETH should revert.
    function testDepositZeroReverts() public {
        vm.startPrank(user);
        vm.expectRevert();
        vault.deposit{value: 0}();
        vm.stopPrank();
    }

    /// @notice Fuzz test — deposit any practical amount and verify 1:1 minting.
    /// @dev Balance read in same transaction context to avoid interest accrual skew.
    function testDepositFuzz(uint256 amount) public {
        // Cap at uint96 max to avoid overflow in interest calculations
        amount = bound(amount, 1e5, type(uint96).max);

        vm.deal(user, amount);
        vm.startPrank(user);
        vault.deposit{value: amount}();

        // Read balance immediately after deposit in the same block
        uint256 balance = rebaseToken.balanceOf(user);
        vm.stopPrank();

        // Allow up to 1 wei tolerance for rounding in interest calculation
        assertApproxEqAbs(balance, amount, 1, "Token balance should match deposited amount");
    }

    // ─────────────────────────────────────────────
    // Linear Interest Accrual Tests
    // ─────────────────────────────────────────────

    /// @notice Interest accrues linearly — equal time periods produce equal interest.
    /// @notice Interest accrues linearly — equal time periods produce equal interest.
    function testDepositLinear(uint256 amount) public {
        amount = bound(amount, 1e5, type(uint96).max);

        vm.deal(user, amount);
        vm.startPrank(user);
        vault.deposit{value: amount}();
        vm.stopPrank();

        uint256 initialBalance = rebaseToken.balanceOf(user);

        uint256 timeDelta = 1 days;

        vm.warp(block.timestamp + timeDelta);
        uint256 balanceAfterFirstWarp = rebaseToken.balanceOf(user);
        uint256 interestFirstPeriod = balanceAfterFirstWarp - initialBalance;

        vm.warp(block.timestamp + timeDelta);
        uint256 balanceAfterSecondWarp = rebaseToken.balanceOf(user);
        uint256 interestSecondPeriod =
            balanceAfterSecondWarp - balanceAfterFirstWarp;

        // Allow a 1 wei difference due to integer division rounding
        assertApproxEqAbs(
            interestFirstPeriod,
            interestSecondPeriod,
            1,
            "Interest accrual is not linear"
        );
    }

    /// @notice Balance increases over time after a deposit (interest accrues).
    function testBalanceIncreasesOverTime() public {
        uint256 amount = 1 ether;

        vm.deal(user, amount);
        vm.startPrank(user);
        vault.deposit{value: amount}();
        vm.stopPrank();

        uint256 balanceBefore = rebaseToken.balanceOf(user);

        // Warp far enough that interest is more than 1 wei
        vm.warp(block.timestamp + 365 days);

        uint256 balanceAfter = rebaseToken.balanceOf(user);

        assertGt(balanceAfter, balanceBefore, "Balance should grow over time");
    }

    // ─────────────────────────────────────────────
    // Redeem Tests
    // ─────────────────────────────────────────────

    /// @notice A full redeem burns all tokens and returns ETH.
    function testRedeemFullAmount() public {
        uint256 amount = 0.5 ether;

        vm.deal(user, amount);
        vm.startPrank(user);
        vault.deposit{value: amount}();

        // Read balance immediately — redeem exact amount we have right now
        uint256 tokenBalance = rebaseToken.balanceOf(user);
        uint256 ethBefore = user.balance;

        vault.redeem(tokenBalance);
        vm.stopPrank();

        assertEq(rebaseToken.balanceOf(user), 0, "Token balance should be zero after full redeem");
        assertGt(user.balance, ethBefore, "User should have received ETH");
    }

    /// @notice A partial redeem burns only the specified tokens and returns proportional ETH.
    function testRedeemPartialAmount() public {
        uint256 amount = 1 ether;

        vm.deal(user, amount);
        vm.startPrank(user);
        vault.deposit{value: amount}();

        // Read actual balance to account for any interest already accrued
        uint256 actualBalance = rebaseToken.balanceOf(user);
        uint256 redeemAmount = actualBalance / 2; // redeem exactly half of what we have

        vault.redeem(redeemAmount);
        uint256 remainingBalance = rebaseToken.balanceOf(user);
        vm.stopPrank();

        // Allow 1 wei tolerance for rounding
        assertApproxEqAbs(remainingBalance, actualBalance - redeemAmount, 1, "Remaining token balance incorrect");
    }

    /// @notice Fuzz test — deposit then redeem the full amount.
    function testRedeemFuzz(uint256 amount) public {
        amount = bound(amount, 1e5, 0.5 ether);

        vm.deal(user, amount);
        vm.startPrank(user);
        vault.deposit{value: amount}();

        // Read actual balance and redeem it — avoids off-by-one from interest
        uint256 tokenBalance = rebaseToken.balanceOf(user);
        vault.redeem(tokenBalance);
        vm.stopPrank();

        assertEq(rebaseToken.balanceOf(user), 0, "All tokens should be burned after redeem");
    }

    // ─────────────────────────────────────────────
    // Vault Tests
    // ─────────────────────────────────────────────

    /// @notice The vault correctly reports the RebaseToken address.
    function testGetRebaseTokenAddress() public view {
        assertEq(
            vault.getRebaseTokenAddress(),
            address(rebaseToken),
            "Vault should return correct token address"
        );
    }

    /// @notice The vault accepts direct ETH transfers (rewards top-up).
    function testVaultReceivesEth() public {
        uint256 balanceBefore = address(vault).balance;

        vm.deal(user, 1 ether);
        vm.prank(user);
        _sendEth(address(vault), 1 ether);

        assertEq(address(vault).balance, balanceBefore + 1 ether, "Vault balance should increase");
    }

    // ─────────────────────────────────────────────
    // Multi-user Tests
    // ─────────────────────────────────────────────

    /// @notice Two users deposit independently and have separate balances.
    function testMultipleUsersDeposit() public {
        uint256 amount1 = 0.3 ether;
        uint256 amount2 = 0.2 ether;

        vm.deal(user, amount1);
        vm.startPrank(user);
        vault.deposit{value: amount1}();
        // Read immediately after deposit before any interest accrues
        uint256 balance1 = rebaseToken.balanceOf(user);
        vm.stopPrank();

        vm.deal(user2, amount2);
        vm.startPrank(user2);
        vault.deposit{value: amount2}();
        uint256 balance2 = rebaseToken.balanceOf(user2);
        vm.stopPrank();

        assertApproxEqAbs(balance1, amount1, 1, "User1 balance incorrect");
        assertApproxEqAbs(balance2, amount2, 1, "User2 balance incorrect");
    }

    /// @notice Two users accrue interest independently over the same period.
    function testMultipleUsersInterestAccrual() public {
        uint256 amount1 = 0.3 ether;
        uint256 amount2 = 0.2 ether;

        vm.deal(user, amount1);
        vm.prank(user);
        vault.deposit{value: amount1}();

        vm.deal(user2, amount2);
        vm.prank(user2);
        vault.deposit{value: amount2}();

        uint256 balanceBefore1 = rebaseToken.balanceOf(user);
        uint256 balanceBefore2 = rebaseToken.balanceOf(user2);

        vm.warp(block.timestamp + 365 days);

        assertGt(rebaseToken.balanceOf(user), balanceBefore1, "User1 should have accrued interest");
        assertGt(rebaseToken.balanceOf(user2), balanceBefore2, "User2 should have accrued interest");
    }
}