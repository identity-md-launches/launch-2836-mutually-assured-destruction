// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {IERC20Errors} from "@openzeppelin/contracts/interfaces/draft-IERC6093.sol";
import {ERC20Permit} from "@openzeppelin/contracts/token/ERC20/extensions/ERC20Permit.sol";
import {MADToken} from "../src/MADToken.sol";

/// @notice Behavioural tests for the MAD token: the supply is minted once to the deployer, transfers
/// move exactly what they say, only a holder can burn their own balance, nothing can mint, and no
/// privileged hand exists to move or freeze anyone.
contract MADTokenTest is Test {
    uint256 constant SUPPLY = 1_000_000_000 ether;
    uint256 constant SWARM_BPS = 1_000;

    /// @dev Stands in for the factory that deploys the token at launch and receives the supply.
    address constant FACTORY = address(0xFAC7);
    address constant DISTRIBUTOR = address(0xD157);
    address constant CLAIMANT = address(0xC1A1);
    address constant ALICE = address(0xA11CE);
    address constant BOB = address(0xB0B);
    address constant STRANGER = address(0xBEEF);

    MADToken token;

    event Transfer(address indexed from, address indexed to, uint256 value);
    event Approval(address indexed owner, address indexed spender, uint256 value);
    event SupplyMinted(address indexed recipient, uint256 amount);
    event Burned(address indexed holder, uint256 amount);

    function setUp() public {
        vm.prank(FACTORY);
        token = new MADToken();
    }

    // ---------------------------------------------------------------- metadata and constructor

    function test_metadata() public view {
        assertEq(token.name(), "Mutually Assured Destruction");
        assertEq(token.symbol(), "MAD");
        assertEq(token.decimals(), 18);
        assertEq(token.TOKEN_NAME(), "Mutually Assured Destruction");
        assertEq(token.TOKEN_SYMBOL(), "MAD");
        assertEq(token.DECIMALS(), 18);
    }

    function test_constructorMintsWholeSupplyToDeployer() public view {
        assertEq(token.TOTAL_SUPPLY(), SUPPLY);
        assertEq(token.totalSupply(), SUPPLY);
        assertEq(token.balanceOf(FACTORY), SUPPLY);
        assertEq(token.balanceOf(address(this)), 0, "the test contract is not the deployer");
    }

    function test_constructorEmitsMintEvents() public {
        vm.expectEmit(true, true, false, true);
        emit Transfer(address(0), FACTORY, SUPPLY);
        vm.expectEmit(true, false, false, true);
        emit SupplyMinted(FACTORY, SUPPLY);
        vm.prank(FACTORY);
        new MADToken();
    }

    function test_constructorMintsToWhoeverDeploys() public {
        vm.prank(ALICE);
        MADToken other = new MADToken();
        assertEq(other.balanceOf(ALICE), SUPPLY);
        assertEq(other.balanceOf(FACTORY), 0);
        assertEq(other.totalSupply(), SUPPLY);
    }

    function test_supplyIsExactlyOneBillionWithEighteenDecimals() public view {
        assertEq(token.totalSupply(), 1_000_000_000 * 10 ** 18);
        assertEq(token.totalSupply() / 10 ** uint256(token.decimals()), 1_000_000_000);
    }

    // ---------------------------------------------------------------- transfers

    function test_transferMovesExactAmount() public {
        vm.prank(FACTORY);
        vm.expectEmit(true, true, false, true);
        emit Transfer(FACTORY, ALICE, 1_000 ether);
        assertTrue(token.transfer(ALICE, 1_000 ether));
        assertEq(token.balanceOf(ALICE), 1_000 ether);
        assertEq(token.balanceOf(FACTORY), SUPPLY - 1_000 ether);
        assertEq(token.totalSupply(), SUPPLY, "a transfer changed the supply");
    }

    function test_transferZeroAmountSucceeds() public {
        vm.prank(FACTORY);
        assertTrue(token.transfer(ALICE, 0));
        assertEq(token.balanceOf(ALICE), 0);
    }

    function test_transferToSelfKeepsBalance() public {
        vm.prank(FACTORY);
        assertTrue(token.transfer(FACTORY, 5 ether));
        assertEq(token.balanceOf(FACTORY), SUPPLY);
    }

    function test_transferRevertsOnInsufficientBalance() public {
        vm.prank(FACTORY);
        token.transfer(ALICE, 10 ether);
        vm.prank(ALICE);
        vm.expectRevert(
            abi.encodeWithSelector(IERC20Errors.ERC20InsufficientBalance.selector, ALICE, 10 ether, 11 ether)
        );
        token.transfer(BOB, 11 ether);
        assertEq(token.balanceOf(ALICE), 10 ether);
        assertEq(token.balanceOf(BOB), 0);
    }

    function test_transferRevertsWhenSenderHoldsNothing() public {
        vm.prank(STRANGER);
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InsufficientBalance.selector, STRANGER, 0, 1));
        token.transfer(ALICE, 1);
    }

    function test_transferRevertsToZeroAddress() public {
        vm.prank(FACTORY);
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InvalidReceiver.selector, address(0)));
        token.transfer(address(0), 1 ether);
    }

    // ---------------------------------------------------------------- allowances

    function test_approveAndTransferFrom() public {
        vm.prank(FACTORY);
        token.transfer(ALICE, 100 ether);

        vm.prank(ALICE);
        vm.expectEmit(true, true, false, true);
        emit Approval(ALICE, BOB, 60 ether);
        assertTrue(token.approve(BOB, 60 ether));
        assertEq(token.allowance(ALICE, BOB), 60 ether);

        vm.prank(BOB);
        assertTrue(token.transferFrom(ALICE, STRANGER, 40 ether));
        assertEq(token.balanceOf(ALICE), 60 ether);
        assertEq(token.balanceOf(STRANGER), 40 ether);
        assertEq(token.allowance(ALICE, BOB), 20 ether, "the allowance was not reduced by what was spent");
        assertEq(token.totalSupply(), SUPPLY);
    }

    function test_infiniteAllowanceIsNotReduced() public {
        vm.prank(FACTORY);
        token.transfer(ALICE, 100 ether);
        vm.prank(ALICE);
        token.approve(BOB, type(uint256).max);
        vm.prank(BOB);
        token.transferFrom(ALICE, BOB, 100 ether);
        assertEq(token.allowance(ALICE, BOB), type(uint256).max);
        assertEq(token.balanceOf(BOB), 100 ether);
    }

    function test_transferFromRevertsWithoutAllowance() public {
        vm.prank(FACTORY);
        token.transfer(ALICE, 100 ether);
        vm.prank(STRANGER);
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InsufficientAllowance.selector, STRANGER, 0, 1 ether));
        token.transferFrom(ALICE, STRANGER, 1 ether);
        assertEq(token.balanceOf(ALICE), 100 ether);
    }

    function test_transferFromRevertsBeyondAllowance() public {
        vm.prank(FACTORY);
        token.transfer(ALICE, 100 ether);
        vm.prank(ALICE);
        token.approve(BOB, 10 ether);
        vm.prank(BOB);
        vm.expectRevert(
            abi.encodeWithSelector(IERC20Errors.ERC20InsufficientAllowance.selector, BOB, 10 ether, 11 ether)
        );
        token.transferFrom(ALICE, BOB, 11 ether);
    }

    function test_transferFromRevertsBeyondBalanceEvenWithAllowance() public {
        vm.prank(FACTORY);
        token.transfer(ALICE, 10 ether);
        vm.prank(ALICE);
        token.approve(BOB, 1_000 ether);
        vm.prank(BOB);
        vm.expectRevert(
            abi.encodeWithSelector(IERC20Errors.ERC20InsufficientBalance.selector, ALICE, 10 ether, 11 ether)
        );
        token.transferFrom(ALICE, BOB, 11 ether);
    }

    function test_approveRevertsForZeroSpender() public {
        vm.prank(ALICE);
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InvalidSpender.selector, address(0)));
        token.approve(address(0), 1);
    }

    // ---------------------------------------------------------------- burn

    function test_burnReducesHolderBalanceAndSupply() public {
        vm.prank(FACTORY);
        token.transfer(ALICE, 100 ether);

        vm.prank(ALICE);
        vm.expectEmit(true, true, false, true);
        emit Transfer(ALICE, address(0), 30 ether);
        vm.expectEmit(true, false, false, true);
        emit Burned(ALICE, 30 ether);
        token.burn(30 ether);

        assertEq(token.balanceOf(ALICE), 70 ether);
        assertEq(token.totalSupply(), SUPPLY - 30 ether);
    }

    function test_burnWholeBalance() public {
        vm.prank(FACTORY);
        token.transfer(ALICE, 100 ether);
        vm.prank(ALICE);
        token.burn(100 ether);
        assertEq(token.balanceOf(ALICE), 0);
        assertEq(token.totalSupply(), SUPPLY - 100 ether);
    }

    function test_burnRevertsOnZero() public {
        vm.prank(FACTORY);
        vm.expectRevert(MADToken.ZeroBurn.selector);
        token.burn(0);
        assertEq(token.totalSupply(), SUPPLY);
    }

    function test_burnRevertsBeyondBalance() public {
        vm.prank(FACTORY);
        token.transfer(ALICE, 10 ether);
        vm.prank(ALICE);
        vm.expectRevert(
            abi.encodeWithSelector(IERC20Errors.ERC20InsufficientBalance.selector, ALICE, 10 ether, 11 ether)
        );
        token.burn(11 ether);
        assertEq(token.balanceOf(ALICE), 10 ether);
        assertEq(token.totalSupply(), SUPPLY);
    }

    function test_burnByHolderWithNothingReverts() public {
        vm.prank(STRANGER);
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InsufficientBalance.selector, STRANGER, 0, 1));
        token.burn(1);
    }

    function test_burnOnlyTouchesTheCaller() public {
        vm.prank(FACTORY);
        token.transfer(ALICE, 100 ether);
        vm.prank(FACTORY);
        token.transfer(BOB, 100 ether);
        vm.prank(ALICE);
        token.burn(100 ether);
        assertEq(token.balanceOf(BOB), 100 ether, "another holder's balance changed");
        assertEq(token.balanceOf(FACTORY), SUPPLY - 200 ether);
    }

    /// @dev There is no burnFrom. An allowance lets a spender move tokens, not destroy them.
    function test_noBurnFromExists() public {
        vm.prank(FACTORY);
        token.transfer(ALICE, 100 ether);
        vm.prank(ALICE);
        token.approve(BOB, 100 ether);
        vm.prank(BOB);
        (bool ok,) = address(token).call(abi.encodeWithSignature("burnFrom(address,uint256)", ALICE, 50 ether));
        assertFalse(ok, "burnFrom should not exist");
        assertEq(token.balanceOf(ALICE), 100 ether);
        assertEq(token.totalSupply(), SUPPLY);
    }

    // ---------------------------------------------------------------- permit (EIP-2612)

    function _permitDigest(address owner, address spender, uint256 value, uint256 nonce, uint256 deadline)
        internal
        view
        returns (bytes32)
    {
        bytes32 structHash = keccak256(
            abi.encode(
                keccak256("Permit(address owner,address spender,uint256 value,uint256 nonce,uint256 deadline)"),
                owner,
                spender,
                value,
                nonce,
                deadline
            )
        );
        return keccak256(abi.encodePacked("\x19\x01", token.DOMAIN_SEPARATOR(), structHash));
    }

    function test_permitSetsAllowanceAndConsumesNonce() public {
        uint256 key = 0xA11CE;
        address owner = vm.addr(key);
        uint256 deadline = block.timestamp + 1 hours;
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(key, _permitDigest(owner, BOB, 5 ether, 0, deadline));

        vm.prank(STRANGER);
        token.permit(owner, BOB, 5 ether, deadline, v, r, s);

        assertEq(token.allowance(owner, BOB), 5 ether);
        assertEq(token.nonces(owner), 1);
    }

    function test_permitThenTransferFromMovesTokens() public {
        uint256 key = 0xA11CE;
        address owner = vm.addr(key);
        vm.prank(FACTORY);
        token.transfer(owner, 10 ether);

        uint256 deadline = block.timestamp + 1 hours;
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(key, _permitDigest(owner, BOB, 10 ether, 0, deadline));
        token.permit(owner, BOB, 10 ether, deadline, v, r, s);

        vm.prank(BOB);
        token.transferFrom(owner, BOB, 10 ether);
        assertEq(token.balanceOf(BOB), 10 ether);
        assertEq(token.balanceOf(owner), 0);
    }

    function test_permitRevertsWhenExpired() public {
        uint256 key = 0xA11CE;
        address owner = vm.addr(key);
        uint256 deadline = block.timestamp - 1;
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(key, _permitDigest(owner, BOB, 5 ether, 0, deadline));
        vm.expectRevert(abi.encodeWithSelector(ERC20Permit.ERC2612ExpiredSignature.selector, deadline));
        token.permit(owner, BOB, 5 ether, deadline, v, r, s);
        assertEq(token.allowance(owner, BOB), 0);
    }

    function test_permitRevertsForWrongSigner() public {
        uint256 ownerKey = 0xA11CE;
        uint256 forgerKey = 0xF0E;
        address owner = vm.addr(ownerKey);
        uint256 deadline = block.timestamp + 1 hours;
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(forgerKey, _permitDigest(owner, BOB, 5 ether, 0, deadline));
        vm.expectRevert(abi.encodeWithSelector(ERC20Permit.ERC2612InvalidSigner.selector, vm.addr(forgerKey), owner));
        token.permit(owner, BOB, 5 ether, deadline, v, r, s);
        assertEq(token.allowance(owner, BOB), 0);
    }

    function test_permitCannotBeReplayed() public {
        uint256 key = 0xA11CE;
        address owner = vm.addr(key);
        uint256 deadline = block.timestamp + 1 hours;
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(key, _permitDigest(owner, BOB, 5 ether, 0, deadline));
        token.permit(owner, BOB, 5 ether, deadline, v, r, s);
        vm.expectRevert();
        token.permit(owner, BOB, 5 ether, deadline, v, r, s);
        assertEq(token.nonces(owner), 1);
    }

    // ---------------------------------------------------------------- nothing mints, nothing freezes

    /// @dev Mirrors the launch floor: the same selectors a stranger or the factory might try.
    function test_noCallIncreasesSupply() public {
        string[10] memory signatures = [
            "mint(address,uint256)",
            "mint(uint256)",
            "mint()",
            "issue(uint256)",
            "setOwner(address)",
            "transferOwnership(address)",
            "upgradeTo(address)",
            "initialize(address)",
            "unpause()",
            "setMinter(address)"
        ];
        for (uint256 i = 0; i < signatures.length; i++) {
            bytes memory data = abi.encodeWithSignature(signatures[i], STRANGER, type(uint128).max);
            vm.prank(STRANGER);
            (bool ok,) = address(token).call(data);
            assertFalse(ok, signatures[i]);
            vm.prank(FACTORY);
            (ok,) = address(token).call(data);
            assertFalse(ok, signatures[i]);
            assertEq(token.totalSupply(), SUPPLY, signatures[i]);
            assertEq(token.balanceOf(STRANGER), 0, signatures[i]);
        }
    }

    /// @dev Mirrors the launch floor: no privileged call moves or freezes a holder.
    function test_noPrivilegedCallMovesOrFreezesAHolder() public {
        vm.prank(FACTORY);
        token.transfer(ALICE, SUPPLY / 1_000);
        uint256 held = token.balanceOf(ALICE);
        string[12] memory signatures = [
            "pause()",
            "blacklist(address)",
            "blocklist(address)",
            "freeze(address)",
            "freezeAccount(address)",
            "setBlacklist(address,bool)",
            "setBlocked(address,bool)",
            "lock(address)",
            "disableTransfers()",
            "setTransfersEnabled(bool)",
            "burnFrom(address,uint256)",
            "seize(address)"
        ];
        for (uint256 i = 0; i < signatures.length; i++) {
            vm.prank(FACTORY);
            (bool ok,) = address(token).call(abi.encodeWithSignature(signatures[i], ALICE, true));
            assertFalse(ok, signatures[i]);
        }
        vm.prank(FACTORY);
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InsufficientAllowance.selector, FACTORY, 0, 1));
        token.transferFrom(ALICE, FACTORY, 1);
        assertEq(token.balanceOf(ALICE), held);
        vm.prank(ALICE);
        assertTrue(token.transfer(BOB, held / 2));
        assertEq(token.balanceOf(BOB), held / 2);
    }

    function test_hasNoOwner() public {
        (bool ok,) = address(token).call(abi.encodeWithSignature("owner()"));
        assertFalse(ok, "the token should not expose an owner");
    }

    function test_rejectsEther() public {
        vm.deal(ALICE, 1 ether);
        vm.prank(ALICE);
        (bool ok,) = address(token).call{value: 1 ether}("");
        assertFalse(ok, "the token should not accept ether");
    }

    // ---------------------------------------------------------------- launch flows

    /// @dev The swarm's ten percent leaves the factory whole and is claimable whole.
    function test_launchFlowsArriveWhole() public {
        uint256 swarm = (SUPPLY * SWARM_BPS) / 10_000;
        vm.prank(FACTORY);
        assertTrue(token.transfer(DISTRIBUTOR, swarm));
        assertEq(token.balanceOf(DISTRIBUTOR), swarm);
        vm.prank(DISTRIBUTOR);
        assertTrue(token.transfer(CLAIMANT, swarm));
        assertEq(token.balanceOf(CLAIMANT), swarm);
        assertEq(token.balanceOf(DISTRIBUTOR), 0);
        assertEq(token.totalSupply(), SUPPLY);
    }

    /// @dev Reachable runtime code contains no DELEGATECALL, CALLCODE or SELFDESTRUCT, as the floor reads it.
    function test_runtimeCodeHasNoDelegatecallOrSelfdestruct() public view {
        bytes memory runtime = address(token).code;
        assertGt(runtime.length, 0);
        assertLe(runtime.length, 24_576, "runtime exceeds EIP-170");
        bool reachable = true;
        for (uint256 i = 0; i < runtime.length; i++) {
            uint8 op = uint8(runtime[i]);
            if (op == 0x5B) reachable = true;
            if (op >= 0x60 && op <= 0x7F) {
                i += (op - 0x5F);
                continue;
            }
            if (reachable) {
                assertTrue(op != 0xF4, "DELEGATECALL");
                assertTrue(op != 0xF2, "CALLCODE");
                assertTrue(op != 0xFF, "SELFDESTRUCT");
            }
            if (op == 0x00 || op == 0x56 || op == 0xF3 || op == 0xFD || op == 0xFE || op == 0xFF) reachable = false;
        }
    }

    // ---------------------------------------------------------------- fuzz

    function testFuzz_transferConservesSupply(address to, uint256 amount) public {
        vm.assume(to != address(0) && to != FACTORY);
        amount = bound(amount, 0, SUPPLY);
        vm.prank(FACTORY);
        assertTrue(token.transfer(to, amount));
        assertEq(token.balanceOf(to), amount);
        assertEq(token.balanceOf(FACTORY) + token.balanceOf(to), SUPPLY);
        assertEq(token.totalSupply(), SUPPLY);
    }

    function testFuzz_transferBeyondBalanceReverts(uint256 held, uint256 amount) public {
        held = bound(held, 0, SUPPLY - 1);
        amount = bound(amount, held + 1, SUPPLY);
        vm.prank(FACTORY);
        token.transfer(ALICE, held);
        vm.prank(ALICE);
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InsufficientBalance.selector, ALICE, held, amount));
        token.transfer(BOB, amount);
    }

    function testFuzz_burnReducesSupplyByExactlyTheAmount(uint256 held, uint256 burned) public {
        held = bound(held, 1, SUPPLY);
        burned = bound(burned, 1, held);
        vm.prank(FACTORY);
        token.transfer(ALICE, held);
        vm.prank(ALICE);
        token.burn(burned);
        assertEq(token.balanceOf(ALICE), held - burned);
        assertEq(token.totalSupply(), SUPPLY - burned);
        assertEq(token.balanceOf(FACTORY) + token.balanceOf(ALICE), token.totalSupply());
    }

    function testFuzz_transferFromSpendsExactlyTheAllowance(uint256 allowed, uint256 spent) public {
        allowed = bound(allowed, 1, SUPPLY);
        spent = bound(spent, 1, allowed);
        vm.prank(FACTORY);
        token.approve(BOB, allowed);
        vm.prank(BOB);
        token.transferFrom(FACTORY, ALICE, spent);
        assertEq(token.allowance(FACTORY, BOB), allowed - spent);
        assertEq(token.balanceOf(ALICE), spent);
        assertEq(token.totalSupply(), SUPPLY);
    }
}
