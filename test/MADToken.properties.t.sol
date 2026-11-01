// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {IERC20Errors} from "@openzeppelin/contracts/interfaces/draft-IERC6093.sol";
import {MADToken} from "src/MADToken.sol";

contract MADTokenDeploymentProbe {
    function deploy() external returns (MADToken) {
        return new MADToken();
    }
}

/// @notice Edge cases and algebraic properties supplement the original behavioral tests.
/// forge-config: default.fuzz.runs = 1000
contract MADTokenPropertiesTest is Test {
    uint256 private constant SUPPLY = 1_000_000_000 ether;
    MADToken private token;
    address private alice;
    address private bob;
    address private carol;

    event Transfer(address indexed from, address indexed to, uint256 value);
    event Burned(address indexed holder, uint256 amount);
    event Approval(address indexed owner, address indexed spender, uint256 value);

    function setUp() public {
        token = new MADToken();
        alice = makeAddr("MAD properties alice");
        bob = makeAddr("MAD properties bob");
        carol = makeAddr("MAD properties carol");
    }

    function test_constructorMintsToCallingContractRatherThanTransactionOrigin() public {
        MADTokenDeploymentProbe factory = new MADTokenDeploymentProbe();
        vm.prank(alice, alice);
        MADToken deployed = factory.deploy();
        assertEq(deployed.balanceOf(address(factory)), SUPPLY);
        assertEq(deployed.balanceOf(alice), 0);
        assertEq(deployed.balanceOf(address(this)), 0);
        assertEq(deployed.totalSupply(), SUPPLY);
    }

    function test_zeroTransfersFromEmptyAccountsEmitEventsWithoutChangingState() public {
        vm.expectEmit(true, true, false, true, address(token));
        emit Transfer(alice, bob, 0);
        vm.prank(alice);
        assertTrue(token.transfer(bob, 0));

        vm.expectEmit(true, true, false, true, address(token));
        emit Transfer(alice, bob, 0);
        vm.prank(carol);
        assertTrue(token.transferFrom(alice, bob, 0));
        assertEq(token.allowance(alice, carol), 0);
        assertEq(token.balanceOf(alice), 0);
        assertEq(token.balanceOf(bob), 0);
        assertEq(token.balanceOf(carol), 0);
        assertEq(token.totalSupply(), SUPPLY);
    }

    function test_zeroTransferToZeroAddressStillReverts() public {
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InvalidReceiver.selector, address(0)));
        token.transfer(address(0), 0);
        vm.prank(bob);
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InvalidReceiver.selector, address(0)));
        token.transferFrom(alice, address(0), 0);
        assertEq(token.balanceOf(address(0)), 0);
        assertEq(token.totalSupply(), SUPPLY);
    }

    function test_entireSupplyRoundTripThenBurnLastWei() public {
        assertTrue(token.transfer(alice, SUPPLY));
        vm.prank(alice);
        assertTrue(token.transfer(bob, SUPPLY));
        vm.prank(bob);
        assertTrue(token.transfer(address(this), SUPPLY));
        assertEq(token.totalSupply(), SUPPLY);
        assertEq(token.balanceOf(address(this)), SUPPLY);
        assertEq(token.balanceOf(alice), 0);
        assertEq(token.balanceOf(bob), 0);

        token.burn(SUPPLY - 1);
        assertEq(token.totalSupply(), 1);
        assertEq(token.balanceOf(address(this)), 1);
        vm.expectEmit(true, true, false, true, address(token));
        emit Transfer(address(this), address(0), 1);
        vm.expectEmit(true, false, false, true, address(token));
        emit Burned(address(this), 1);
        token.burn(1);
        assertEq(token.totalSupply(), 0);
        assertEq(token.balanceOf(address(this)), 0);
        assertEq(token.balanceOf(address(0)), 0);
        assertEq(token.TOTAL_SUPPLY(), SUPPLY, "the initial supply constant must not track burns");

        assertTrue(token.approve(bob, type(uint256).max));
        assertTrue(token.transfer(alice, 0));
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InsufficientBalance.selector, address(this), 0, 1));
        token.transfer(alice, 1);
        vm.prank(bob);
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InsufficientBalance.selector, address(this), 0, 1));
        token.transferFrom(address(this), bob, 1);
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InsufficientBalance.selector, address(this), 0, 1));
        token.burn(1);
        assertEq(token.totalSupply(), 0);
    }

    function test_selfTransferStillRequiresEnoughBalance() public {
        token.transfer(alice, 7);
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InsufficientBalance.selector, alice, 7, 8));
        token.transfer(alice, 8);
        assertEq(token.balanceOf(alice), 7);
        assertEq(token.totalSupply(), SUPPLY);
    }

    function test_delegatedSelfTransferConsumesFiniteAllowance() public {
        token.transfer(alice, 10);
        vm.prank(alice);
        token.approve(bob, 7);
        vm.expectEmit(true, true, false, true, address(token));
        emit Transfer(alice, alice, 7);
        vm.prank(bob);
        assertTrue(token.transferFrom(alice, alice, 7));
        assertEq(token.balanceOf(alice), 10);
        assertEq(token.balanceOf(bob), 0);
        assertEq(token.allowance(alice, bob), 0);
        vm.prank(bob);
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InsufficientAllowance.selector, bob, 0, 1));
        token.transferFrom(alice, alice, 1);
    }

    function test_transferFromByOwnerRequiresSelfApproval() public {
        token.transfer(alice, 10);
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InsufficientAllowance.selector, alice, 0, 1));
        token.transferFrom(alice, bob, 1);
        vm.prank(alice);
        token.approve(alice, 1);
        vm.prank(alice);
        assertTrue(token.transferFrom(alice, bob, 1));
        assertEq(token.balanceOf(alice), 9);
        assertEq(token.balanceOf(bob), 1);
        assertEq(token.allowance(alice, alice), 0);
    }

    function test_replacingAndRevokingApprovalImmediatelyLimitsSpending() public {
        token.transfer(alice, 100);
        vm.prank(alice);
        token.approve(bob, 100);
        vm.prank(bob);
        token.transferFrom(alice, bob, 60);

        vm.prank(alice);
        token.approve(bob, 5);
        assertEq(token.allowance(alice, bob), 5, "approval must replace the unspent allowance");
        vm.prank(bob);
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InsufficientAllowance.selector, bob, 5, 6));
        token.transferFrom(alice, bob, 6);

        vm.expectEmit(true, true, false, true, address(token));
        emit Approval(alice, bob, 0);
        vm.prank(alice);
        token.approve(bob, 0);
        vm.prank(bob);
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InsufficientAllowance.selector, bob, 0, 1));
        token.transferFrom(alice, bob, 1);
        assertEq(token.balanceOf(alice), 40);
        assertEq(token.balanceOf(bob), 60);
        assertEq(token.allowance(alice, bob), 0);
    }

    function test_infiniteApprovalCanBeRevokedAndMaxMinusOneIsFinite() public {
        token.transfer(alice, 10);
        vm.prank(alice);
        token.approve(bob, type(uint256).max);
        vm.prank(bob);
        token.transferFrom(alice, bob, 1);
        assertEq(token.allowance(alice, bob), type(uint256).max);
        vm.prank(alice);
        token.approve(bob, 0);
        vm.prank(bob);
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InsufficientAllowance.selector, bob, 0, 1));
        token.transferFrom(alice, bob, 1);
        vm.prank(alice);
        token.approve(bob, type(uint256).max - 1);
        vm.prank(bob);
        token.transferFrom(alice, bob, 1);
        assertEq(token.allowance(alice, bob), type(uint256).max - 2);
        assertEq(token.balanceOf(alice), 8);
        assertEq(token.balanceOf(bob), 2);
    }

    function test_burningDoesNotChangeAllowancesOrLetSpendersUseDestroyedTokens() public {
        token.transfer(alice, 100);
        vm.prank(alice);
        token.approve(bob, 100);
        vm.prank(alice);
        token.burn(60);
        assertEq(token.allowance(alice, bob), 100);
        vm.prank(bob);
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InsufficientBalance.selector, alice, 40, 41));
        token.transferFrom(alice, bob, 41);
        assertEq(token.allowance(alice, bob), 100, "failed spend consumed allowance");
        vm.prank(bob);
        token.transferFrom(alice, bob, 40);
        assertEq(token.allowance(alice, bob), 60);

        token.transfer(alice, 10);
        vm.prank(bob);
        token.transferFrom(alice, bob, 10);
        assertEq(token.balanceOf(alice), 0);
        assertEq(token.balanceOf(bob), 50);
        assertEq(token.allowance(alice, bob), 50);
        assertEq(token.totalSupply(), SUPPLY - 60);
    }

    function test_maximumAmountCannotTransferOrBurnEvenWithInfiniteAllowance() public {
        token.approve(bob, type(uint256).max);
        bytes memory insufficient = abi.encodeWithSelector(
            IERC20Errors.ERC20InsufficientBalance.selector, address(this), SUPPLY, type(uint256).max
        );
        vm.expectRevert(insufficient);
        token.transfer(alice, type(uint256).max);
        vm.expectRevert(insufficient);
        token.burn(type(uint256).max);
        vm.prank(bob);
        vm.expectRevert(insufficient);
        token.transferFrom(address(this), alice, type(uint256).max);
        assertEq(token.allowance(address(this), bob), type(uint256).max);
        assertEq(token.balanceOf(address(this)), SUPPLY);
        assertEq(token.balanceOf(alice), 0);
        assertEq(token.totalSupply(), SUPPLY);
    }

    function testFuzz_failedTransferFromOverBalanceRollsBackAllowance(uint256 held, uint256 amount, bool infinite)
        public
    {
        held = bound(held, 0, SUPPLY);
        amount = bound(amount, held + 1, type(uint256).max - 1);
        uint256 allowed = infinite ? type(uint256).max : amount;
        token.transfer(alice, held);
        vm.prank(alice);
        token.approve(bob, allowed);
        vm.prank(bob);
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InsufficientBalance.selector, alice, held, amount));
        token.transferFrom(alice, carol, amount);
        _assertFailedSpendUnchanged(held, allowed);
    }

    function testFuzz_failedTransferFromOverAllowancePreservesState(uint256 held, uint256 allowed, uint256 amount)
        public
    {
        held = bound(held, 1, SUPPLY);
        allowed = bound(allowed, 0, held - 1);
        amount = bound(amount, allowed + 1, held);
        token.transfer(alice, held);
        vm.prank(alice);
        token.approve(bob, allowed);
        vm.prank(bob);
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InsufficientAllowance.selector, bob, allowed, amount));
        token.transferFrom(alice, carol, amount);
        _assertFailedSpendUnchanged(held, allowed);
    }

    function testFuzz_failedTransferFromToZeroRestoresAllowance(uint256 held, uint256 amount) public {
        held = bound(held, 1, SUPPLY);
        amount = bound(amount, 1, held);
        token.transfer(alice, held);
        vm.prank(alice);
        token.approve(bob, amount);
        vm.prank(bob);
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InvalidReceiver.selector, address(0)));
        token.transferFrom(alice, address(0), amount);
        _assertFailedSpendUnchanged(held, amount);

        // The same allowance can still be used by a subsequent valid transaction.
        vm.prank(bob);
        assertTrue(token.transferFrom(alice, carol, amount));
        assertEq(token.allowance(alice, bob), 0);
        assertEq(token.balanceOf(alice), held - amount);
        assertEq(token.balanceOf(carol), amount);
    }

    function testFuzz_transferRoundTripRestoresBalances(uint256 held, uint256 amount) public {
        held = bound(held, 0, SUPPLY);
        amount = bound(amount, 0, held);
        token.transfer(alice, held);
        vm.prank(alice);
        assertTrue(token.transfer(bob, amount));
        assertEq(token.balanceOf(bob), amount, "outbound transfer was short");
        vm.prank(bob);
        assertTrue(token.transfer(alice, amount));
        assertEq(token.balanceOf(alice), held);
        assertEq(token.balanceOf(bob), 0);
        assertEq(token.balanceOf(address(this)), SUPPLY - held);
        assertEq(token.totalSupply(), SUPPLY);
    }

    function testFuzz_splittingBurnsHasTheSameEffectAsOneBurn(uint256 held, uint256 first, uint256 second) public {
        held = bound(held, 2, SUPPLY);
        first = bound(first, 1, held - 1);
        second = bound(second, 1, held - first);
        MADToken oneBurn = new MADToken();
        token.transfer(alice, held);
        oneBurn.transfer(alice, held);
        vm.startPrank(alice);
        token.burn(first);
        token.burn(second);
        oneBurn.burn(first + second);
        vm.stopPrank();
        assertEq(token.balanceOf(alice), oneBurn.balanceOf(alice));
        assertEq(token.totalSupply(), oneBurn.totalSupply());
        assertEq(token.totalSupply(), SUPPLY - first - second);
        assertEq(token.balanceOf(address(this)), SUPPLY - held);
        assertEq(token.balanceOf(address(0)), 0);
    }

    function testFuzz_approvalIsIdempotentAndCannotAffectOtherSpenders(uint256 original, uint256 replacement) public {
        vm.startPrank(alice);
        token.approve(bob, original);
        token.approve(carol, original);
        token.approve(bob, replacement);
        token.approve(bob, replacement);
        vm.stopPrank();
        assertEq(token.allowance(alice, bob), replacement);
        assertEq(token.allowance(alice, carol), original);
        assertEq(token.allowance(bob, alice), 0);
        assertEq(token.nonces(alice), 0);
        assertEq(token.balanceOf(alice), 0);
        assertEq(token.balanceOf(address(this)), SUPPLY);
        assertEq(token.totalSupply(), SUPPLY);
    }

    function _assertFailedSpendUnchanged(uint256 held, uint256 allowed) private view {
        assertEq(token.allowance(alice, bob), allowed, "failed call spent allowance");
        assertEq(token.balanceOf(alice), held, "failed call debited holder");
        assertEq(token.balanceOf(bob), 0, "failed call credited spender");
        assertEq(token.balanceOf(carol), 0, "failed call credited receiver");
        assertEq(token.balanceOf(address(this)), SUPPLY - held);
        assertEq(token.totalSupply(), SUPPLY);
    }
}
