// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {IERC20Errors} from "@openzeppelin/contracts/interfaces/draft-IERC6093.sol";
import {ERC20Permit} from "@openzeppelin/contracts/token/ERC20/extensions/ERC20Permit.sol";
import {MADToken} from "src/MADToken.sol";

/// @dev Closed actor set: every recipient is tracked, and only this handler is targeted.
/// Ghost accounting starts from the specified mint and is updated from requested amounts,
/// never from the token's reported balances, allowances, supply, or nonces.
contract MADTokenHandler is Test {
    uint256 public constant INITIAL_SUPPLY = 1_000_000_000 ether;
    uint256 public constant ACTOR_COUNT = 4;
    bytes32 private constant PERMIT_TYPEHASH =
        keccak256("Permit(address owner,address spender,uint256 value,uint256 nonce,uint256 deadline)");

    MADToken public immutable token;
    bytes32 private immutable domain;
    address[4] public actors;
    uint256[4] private keys;
    mapping(address => uint256) public ghostBalance;
    mapping(address => mapping(address => uint256)) public ghostAllowance;
    mapping(address => uint256) public ghostNonce;
    uint256 public burned;
    uint256 public transfers;
    uint256 public delegatedTransfers;
    uint256 public burns;
    uint256 public permits;
    uint256 public rejectedCalls;

    constructor() {
        token = new MADToken();
        actors[0] = address(this); // The real deploying contract remains an actor.
        for (uint256 i = 1; i < ACTOR_COUNT; ++i) {
            (actors[i], keys[i]) = makeAddrAndKey(string.concat("MAD invariant holder ", vm.toString(i)));
        }
        ghostBalance[address(this)] = INITIAL_SUPPLY;
        domain = keccak256(
            abi.encode(
                keccak256("EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)"),
                keccak256(bytes("Mutually Assured Destruction")),
                keccak256(bytes("1")),
                block.chainid,
                address(token)
            )
        );
        // Fund all actors through real transfers, without writing token storage.
        for (uint256 i = 1; i < ACTOR_COUNT; ++i) {
            _transfer(actors[0], actors[i], INITIAL_SUPPLY / ACTOR_COUNT);
            _approve(actors[i - 1], actors[i], INITIAL_SUPPLY / 8);
        }
        _approve(actors[3], actors[0], INITIAL_SUPPLY / 8);
    }

    function transfer(uint256 fromSeed, uint256 toSeed, uint256 amountSeed) external {
        address from = _actor(fromSeed);
        address to = _actor(toSeed);
        _transfer(from, to, _amount(amountSeed, ghostBalance[from]));
    }

    function approve(uint256 ownerSeed, uint256 spenderSeed, uint256 valueSeed) external {
        _approve(_actor(ownerSeed), _actor(spenderSeed), _approval(valueSeed));
    }

    function transferFrom(uint256 ownerSeed, uint256 spenderSeed, uint256 toSeed, uint256 amountSeed) external {
        address owner = _actor(ownerSeed);
        address spender = _actor(spenderSeed);
        address to = _actor(toSeed);
        uint256 allowed = ghostAllowance[owner][spender];
        uint256 limit = ghostBalance[owner] < allowed ? ghostBalance[owner] : allowed;
        uint256 amount = _amount(amountSeed, limit);

        vm.prank(spender);
        assertTrue(token.transferFrom(owner, to, amount), "valid delegated transfer failed");
        ghostBalance[owner] -= amount;
        ghostBalance[to] += amount;
        if (allowed != type(uint256).max) ghostAllowance[owner][spender] -= amount;
        ++delegatedTransfers;
    }

    function burn(uint256 ownerSeed, uint256 amountSeed) external {
        address owner = _actor(ownerSeed);
        uint256 amount = _amount(amountSeed, ghostBalance[owner]);
        if (amount == 0) {
            vm.prank(owner);
            vm.expectRevert(MADToken.ZeroBurn.selector);
            token.burn(0);
            ++rejectedCalls;
        } else {
            vm.prank(owner);
            token.burn(amount);
            ghostBalance[owner] -= amount;
            burned += amount;
            ++burns;
        }
    }

    function permit(uint256 ownerSeed, uint256 spenderSeed, uint256 valueSeed) external {
        uint256 index = 1 + ownerSeed % (ACTOR_COUNT - 1);
        address owner = actors[index];
        address spender = _actor(spenderSeed);
        uint256 value = _approval(valueSeed);
        // The deadline itself is valid, including at exact equality with the timestamp.
        uint256 deadline = block.timestamp;
        (uint8 v, bytes32 r, bytes32 s) =
            vm.sign(keys[index], _digest(owner, spender, value, ghostNonce[owner], deadline));
        token.permit(owner, spender, value, deadline, v, r, s);
        ghostAllowance[owner][spender] = value;
        ++ghostNonce[owner];
        ++permits;
    }

    function rejectTransferOverBalance(uint256 ownerSeed, uint256 toSeed, bool maximum) external {
        address owner = _actor(ownerSeed);
        uint256 held = ghostBalance[owner];
        uint256 amount = maximum ? type(uint256).max : held + 1;
        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InsufficientBalance.selector, owner, held, amount));
        token.transfer(_actor(toSeed), amount);
        ++rejectedCalls;
    }

    function rejectBurnOverBalance(uint256 ownerSeed, bool maximum) external {
        address owner = _actor(ownerSeed);
        uint256 held = ghostBalance[owner];
        uint256 amount = maximum ? type(uint256).max : held + 1;
        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InsufficientBalance.selector, owner, held, amount));
        token.burn(amount);
        ++rejectedCalls;
    }

    /// @dev Valid approval followed by an invalid spend probes allowance rollback as well
    /// as balance rollback. A revoked allowance probes unauthorized spends, even by the deployer.
    function rejectTransferFrom(uint256 ownerSeed, uint256 spenderSeed, uint256 mode) external {
        address owner = _actor(ownerSeed);
        address spender = _actor(spenderSeed);
        uint256 kind = mode % 3;
        uint256 amount = kind == 0 ? ghostBalance[owner] + 1 : 1;
        uint256 allowed = kind == 1 ? 0 : (mode % 2 == 0 ? amount : type(uint256).max);
        _approve(owner, spender, allowed);

        bytes memory reason;
        if (kind == 0) {
            reason = abi.encodeWithSelector(
                IERC20Errors.ERC20InsufficientBalance.selector, owner, ghostBalance[owner], amount
            );
        } else if (kind == 1) {
            reason = abi.encodeWithSelector(IERC20Errors.ERC20InsufficientAllowance.selector, spender, 0, amount);
        } else {
            reason = abi.encodeWithSelector(IERC20Errors.ERC20InvalidReceiver.selector, address(0));
        }
        vm.prank(spender);
        vm.expectRevert(reason);
        token.transferFrom(owner, kind == 2 ? address(0) : spender, amount);
        ++rejectedCalls;
    }

    /// @dev Failed signatures must not consume a nonce or replace an existing allowance.
    function rejectPermit(uint256 ownerSeed, uint256 spenderSeed, uint256 valueSeed, bool expired) external {
        uint256 index = 1 + ownerSeed % (ACTOR_COUNT - 1);
        address owner = actors[index];
        address spender = _actor(spenderSeed);
        uint256 value = _approval(valueSeed);
        uint256 deadline = expired ? block.timestamp - 1 : block.timestamp;
        uint256 nonce = ghostNonce[owner];
        bytes32 signedDigest = _digest(owner, spender, value, expired ? nonce : nonce + 1, deadline);
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(keys[index], signedDigest);
        bytes memory reason;
        if (expired) {
            reason = abi.encodeWithSelector(ERC20Permit.ERC2612ExpiredSignature.selector, deadline);
        } else {
            address recovered = ecrecover(_digest(owner, spender, value, nonce, deadline), v, r, s);
            reason = abi.encodeWithSelector(ERC20Permit.ERC2612InvalidSigner.selector, recovered, owner);
        }
        vm.expectRevert(reason);
        token.permit(owner, spender, value, deadline, v, r, s);
        ++rejectedCalls;
    }

    function rejectPrivilegedCall(uint256 callerSeed, uint256 holderSeed, uint256 operation) external {
        address holder = _actor(holderSeed);
        bytes memory data;
        uint256 kind = operation % 6;
        if (kind == 0) data = abi.encodeWithSignature("mint(address,uint256)", holder, 1);
        else if (kind == 1) data = abi.encodeWithSignature("burnFrom(address,uint256)", holder, 1);
        else if (kind == 2) data = abi.encodeWithSignature("pause()");
        else if (kind == 3) data = abi.encodeWithSignature("blacklist(address)", holder);
        else if (kind == 4) data = abi.encodeWithSignature("initialize(address)", holder);
        else data = abi.encodeWithSignature("seize(address)", holder);
        vm.prank(_actor(callerSeed));
        (bool ok,) = address(token).call(data);
        assertFalse(ok, "unexpected privileged entry point");
        ++rejectedCalls;
    }

    /// @dev Called only after a campaign, not randomly: every remaining holder must be
    /// able to move their entire balance. Also exercises zero transfers from empty holders.
    function consolidate() external {
        for (uint256 i = 1; i < ACTOR_COUNT; ++i) {
            _transfer(actors[i], actors[0], ghostBalance[actors[i]]);
        }
    }

    function _transfer(address from, address to, uint256 amount) private {
        vm.prank(from);
        assertTrue(token.transfer(to, amount), "valid transfer failed");
        ghostBalance[from] -= amount;
        ghostBalance[to] += amount;
        ++transfers;
    }

    function _approve(address owner, address spender, uint256 value) private {
        vm.prank(owner);
        assertTrue(token.approve(spender, value), "valid approval failed");
        ghostAllowance[owner][spender] = value;
    }

    function _actor(uint256 seed) private view returns (address) {
        return actors[seed % ACTOR_COUNT];
    }

    // Bias toward the boundaries without filtering or silently skipping calls.
    function _amount(uint256 seed, uint256 limit) private pure returns (uint256) {
        uint256 kind = seed % 8;
        if (kind == 0 || limit == 0) return 0;
        if (kind == 1) return 1;
        if (kind == 2) return limit;
        if (kind == 3) return limit - 1;
        return seed % (limit + 1);
    }

    function _approval(uint256 seed) private pure returns (uint256) {
        uint256 kind = seed % 4;
        if (kind == 0) return 0;
        if (kind == 1) return type(uint256).max;
        if (kind == 2) return seed % (INITIAL_SUPPLY + 1);
        return seed;
    }

    function _digest(address owner, address spender, uint256 value, uint256 nonce, uint256 deadline)
        private
        view
        returns (bytes32)
    {
        bytes32 structHash = keccak256(abi.encode(PERMIT_TYPEHASH, owner, spender, value, nonce, deadline));
        return keccak256(abi.encodePacked("\x19\x01", domain, structHash));
    }
}

/// forge-config: default.invariant.runs = 256
/// forge-config: default.invariant.depth = 128
/// forge-config: default.invariant.fail-on-revert = true
contract MADTokenInvariantTest is Test {
    uint256 private constant INITIAL_SUPPLY = 1_000_000_000 ether;
    MADTokenHandler private handler;
    MADToken private token;

    function setUp() public {
        vm.warp(1_000_000);
        handler = new MADTokenHandler();
        token = handler.token();

        bytes4[] memory selectors = new bytes4[](10);
        selectors[0] = MADTokenHandler.transfer.selector;
        selectors[1] = MADTokenHandler.approve.selector;
        selectors[2] = MADTokenHandler.transferFrom.selector;
        selectors[3] = MADTokenHandler.burn.selector;
        selectors[4] = MADTokenHandler.permit.selector;
        selectors[5] = MADTokenHandler.rejectTransferOverBalance.selector;
        selectors[6] = MADTokenHandler.rejectBurnOverBalance.selector;
        selectors[7] = MADTokenHandler.rejectTransferFrom.selector;
        selectors[8] = MADTokenHandler.rejectPermit.selector;
        selectors[9] = MADTokenHandler.rejectPrivilegedCall.selector;
        targetContract(address(handler));
        targetSelector(FuzzSelector({addr: address(handler), selectors: selectors}));
    }

    function invariant_supplyEqualsBalancesAndOnlyBurnsReduceIt() public view {
        uint256 sum;
        for (uint256 i; i < 4; ++i) {
            sum += token.balanceOf(handler.actors(i));
        }
        assertEq(token.totalSupply(), sum, "supply differs from all tracked balances");
        assertEq(token.totalSupply() + handler.burned(), INITIAL_SUPPLY, "unexpected mint, burn, or transfer tax");
        assertEq(token.balanceOf(address(0)), 0, "burn credited the zero address");
    }

    function invariant_balancesMatchAuthorizedActions() public view {
        for (uint256 i; i < 4; ++i) {
            address actor = handler.actors(i);
            assertEq(token.balanceOf(actor), handler.ghostBalance(actor), "unauthorized balance change");
        }
    }

    function invariant_allowancesAndNoncesMatchAuthorizations() public view {
        for (uint256 i; i < 4; ++i) {
            address owner = handler.actors(i);
            assertEq(token.nonces(owner), handler.ghostNonce(owner), "nonce changed without a successful permit");
            for (uint256 j; j < 4; ++j) {
                address spender = handler.actors(j);
                assertEq(
                    token.allowance(owner, spender),
                    handler.ghostAllowance(owner, spender),
                    "allowance changed without authorization or a successful spend"
                );
            }
        }
    }

    function afterInvariant() public {
        handler.consolidate();
        invariant_supplyEqualsBalancesAndOnlyBurnsReduceIt();
        invariant_balancesMatchAuthorizedActions();
        invariant_allowancesAndNoncesMatchAuthorizations();
        assertEq(token.balanceOf(handler.actors(0)), token.totalSupply(), "remaining tokens could not be moved");
    }

    /// @dev A deterministic sequence proves the harness can perform positive transfers,
    /// burns, signed authorizations and rejected actions, including terminal zero supply.
    function test_handlerExercisesMixedSequenceAndCompleteBurn() public {
        handler.approve(1, 2, 101); // Infinite approval.
        handler.transferFrom(1, 2, 3, 1);
        handler.permit(0, 2, 42);
        handler.transferFrom(1, 2, 3, 1);
        handler.burn(3, 1);
        handler.rejectTransferOverBalance(1, 2, false);
        handler.rejectBurnOverBalance(1, true);
        for (uint256 mode; mode < 3; ++mode) {
            handler.rejectTransferFrom(1, 2, mode);
        }
        handler.rejectPermit(0, 2, 42, false);
        handler.rejectPermit(0, 2, 42, true);
        for (uint256 mode; mode < 6; ++mode) {
            handler.rejectPrivilegedCall(0, 1, mode);
        }
        afterInvariant();
        handler.burn(0, 2); // Full balance, now the entire remaining supply.
        handler.burn(1, 0); // Zero burn is rejected even after extinction.
        handler.rejectTransferOverBalance(0, 1, false);
        invariant_supplyEqualsBalancesAndOnlyBurnsReduceIt();
        invariant_balancesMatchAuthorizedActions();
        invariant_allowancesAndNoncesMatchAuthorizations();
        assertEq(token.totalSupply(), 0);
        assertGt(handler.transfers(), 0);
        assertGt(handler.delegatedTransfers(), 0);
        assertGt(handler.burns(), 0);
        assertGt(handler.permits(), 0);
        assertGt(handler.rejectedCalls(), 0);
    }
}
