// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {IERC20Errors} from "@openzeppelin/contracts/interfaces/draft-IERC6093.sol";
import {ERC20Permit} from "@openzeppelin/contracts/token/ERC20/extensions/ERC20Permit.sol";
import {ECDSA} from "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";
import {MADToken} from "src/MADToken.sol";

/// @notice Signatures use an independently constructed domain, so an incorrect
/// name, version, chain ID or verifying contract cannot make the test agree with the token.
/// forge-config: default.fuzz.runs = 1000
contract MADTokenPermitTest is Test {
    uint256 private constant SUPPLY = 1_000_000_000 ether;
    uint256 private constant HELD = 100 ether;
    uint256 private constant OLD_ALLOWANCE = 17;
    uint256 private constant CURVE_ORDER = 0xFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFEBAAEDCE6AF48A03BBFD25E8CD0364141;
    bytes32 private constant PERMIT_TYPEHASH =
        keccak256("Permit(address owner,address spender,uint256 value,uint256 nonce,uint256 deadline)");

    struct Signature {
        uint8 v;
        bytes32 r;
        bytes32 s;
    }

    MADToken private token;
    address private owner;
    uint256 private ownerKey;
    address private spender;
    address private relayer;
    address private other;
    uint256 private deploymentChainId;

    event Approval(address indexed owner, address indexed spender, uint256 value);

    function setUp() public {
        vm.warp(1_000_000);
        deploymentChainId = block.chainid;
        token = new MADToken();
        (owner, ownerKey) = makeAddrAndKey("MAD permit owner");
        spender = makeAddr("MAD permit spender");
        relayer = makeAddr("MAD permit relayer");
        other = makeAddr("MAD permit other");
        token.transfer(owner, HELD);
        vm.prank(owner);
        token.approve(spender, OLD_ALLOWANCE);
    }

    function test_domainAndIntrospectionMatchTheSpecifiedToken() public view {
        assertEq(token.DOMAIN_SEPARATOR(), _domain(address(token), block.chainid));
        (
            bytes1 fields,
            string memory name,
            string memory version,
            uint256 chainId,
            address verifyingContract,
            bytes32 salt,
            uint256[] memory extensions
        ) = token.eip712Domain();
        assertEq(fields, hex"0f");
        assertEq(name, "Mutually Assured Destruction");
        assertEq(version, "1");
        assertEq(chainId, block.chainid);
        assertEq(verifyingContract, address(token));
        assertEq(salt, bytes32(0));
        assertEq(extensions.length, 0);
    }

    function test_permitAcceptsDeadlineEqualityAndEmitsApproval() public {
        uint256 deadline = block.timestamp;
        Signature memory sig = _sign(5 ether, 0, deadline);
        vm.expectEmit(true, true, false, true, address(token));
        emit Approval(owner, spender, 5 ether);
        vm.prank(relayer);
        _submit(5 ether, deadline, sig);
        _assertPermitState(1, 5 ether);
    }

    function test_permitExpiresOneSecondAfterDeadline() public {
        uint256 deadline = vm.getBlockTimestamp();
        Signature memory sig = _sign(5 ether, 0, deadline);
        vm.warp(deadline + 1);
        vm.expectRevert(abi.encodeWithSelector(ERC20Permit.ERC2612ExpiredSignature.selector, deadline));
        _submit(5 ether, deadline, sig);
        _assertPermitState(0, OLD_ALLOWANCE);
    }

    function test_zeroSpenderRollsBackNonceAfterValidSignatureRecovery() public {
        uint256 deadline = block.timestamp;
        Signature memory sig =
            _signature(_digest(_domain(address(token), block.chainid), owner, address(0), 1, 0, deadline));
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InvalidSpender.selector, address(0)));
        token.permit(owner, address(0), 1, deadline, sig.v, sig.r, sig.s);
        _assertPermitState(0, OLD_ALLOWANCE);
        assertEq(token.allowance(owner, address(0)), 0);

        // A valid signature with the same nonce must still work after the failed call.
        sig = _sign(1, 0, deadline);
        _submit(1, deadline, sig);
        _assertPermitState(1, 1);
    }

    function test_zeroOwnerAndEmptySignatureCannotAuthorizeAnything() public {
        vm.expectRevert(ECDSA.ECDSAInvalidSignature.selector);
        token.permit(address(0), spender, type(uint256).max, block.timestamp, 27, bytes32(0), bytes32(0));
        assertEq(token.nonces(address(0)), 0);
        assertEq(token.allowance(address(0), spender), 0);
        _assertPermitState(0, OLD_ALLOWANCE);
    }

    function test_emptySignatureForFundedOwnerPreservesExistingAllowance() public {
        vm.expectRevert(ECDSA.ECDSAInvalidSignature.selector);
        token.permit(owner, spender, type(uint256).max, block.timestamp, 27, bytes32(0), bytes32(0));
        _assertPermitState(0, OLD_ALLOWANCE);
    }

    function test_malleableHighSSignatureIsRejectedWithoutConsumingNonce() public {
        uint256 deadline = block.timestamp;
        Signature memory sig = _sign(5 ether, 0, deadline);
        sig.s = bytes32(CURVE_ORDER - uint256(sig.s));
        sig.v = sig.v == 27 ? 28 : 27;
        bytes32 digest = _digest(_domain(address(token), block.chainid), owner, spender, 5 ether, 0, deadline);
        assertEq(ecrecover(digest, sig.v, sig.r, sig.s), owner, "fixture must be the equivalent high-s signature");
        vm.expectRevert(abi.encodeWithSelector(ECDSA.ECDSAInvalidSignatureS.selector, sig.s));
        _submit(5 ether, deadline, sig);
        _assertPermitState(0, OLD_ALLOWANCE);
    }

    function test_signatureCannotBeUsedOnAnotherToken() public {
        MADToken another = new MADToken();
        uint256 deadline = block.timestamp;
        Signature memory sig = _sign(5 ether, 0, deadline);
        bytes32 actualDigest = _digest(_domain(address(another), block.chainid), owner, spender, 5 ether, 0, deadline);
        _expectInvalidSigner(actualDigest, owner, sig);
        another.permit(owner, spender, 5 ether, deadline, sig.v, sig.r, sig.s);
        assertEq(another.nonces(owner), 0);
        assertEq(another.allowance(owner, spender), 0);
        assertEq(another.totalSupply(), SUPPLY);
        _assertPermitState(0, OLD_ALLOWANCE);

        _submit(5 ether, deadline, sig);
        _assertPermitState(1, 5 ether);
    }

    function test_chainChangeInvalidatesOldDomainAndAcceptsNewDomain() public {
        uint256 originalChain = deploymentChainId;
        uint256 deadline = block.timestamp;
        Signature memory sig = _sign(5 ether, 0, deadline);
        bytes32 originalDomain = _domain(address(token), originalChain);
        vm.chainId(originalChain + 1);
        bytes32 changedDomain = _domain(address(token), originalChain + 1);
        assertEq(token.DOMAIN_SEPARATOR(), changedDomain);
        assertNotEq(changedDomain, originalDomain);
        _expectInvalidSigner(_digest(changedDomain, owner, spender, 5 ether, 0, deadline), owner, sig);
        _submit(5 ether, deadline, sig);
        _assertPermitState(0, OLD_ALLOWANCE);

        sig = _signature(_digest(changedDomain, owner, spender, 5 ether, 0, deadline));
        _submit(5 ether, deadline, sig);
        _assertPermitState(1, 5 ether);
        vm.chainId(originalChain);
        assertEq(token.DOMAIN_SEPARATOR(), originalDomain, "cached domain was not restored");
    }

    function test_replayCannotRestoreASpentAndRevokedAllowance() public {
        uint256 deadline = block.timestamp;
        Signature memory sig = _sign(20 ether, 0, deadline);
        _submit(20 ether, deadline, sig);
        vm.prank(spender);
        token.transferFrom(owner, spender, 5 ether);
        vm.prank(owner);
        token.approve(spender, 0);
        bytes32 replayDigest = _digest(_domain(address(token), block.chainid), owner, spender, 20 ether, 1, deadline);
        _expectInvalidSigner(replayDigest, owner, sig);
        _submit(20 ether, deadline, sig);
        assertEq(token.nonces(owner), 1);
        assertEq(token.allowance(owner, spender), 0);
        assertEq(token.balanceOf(owner), HELD - 5 ether);
        assertEq(token.balanceOf(spender), 5 ether);
        assertEq(token.totalSupply(), SUPPLY);
    }

    function test_nonceIsSharedAcrossSpenders() public {
        uint256 deadline = block.timestamp;
        Signature memory first = _sign(5 ether, 0, deadline);
        bytes32 domain = _domain(address(token), block.chainid);
        Signature memory second = _signature(_digest(domain, owner, other, 9 ether, 0, deadline));
        _submit(5 ether, deadline, first);
        _expectInvalidSigner(_digest(domain, owner, other, 9 ether, 1, deadline), owner, second);
        token.permit(owner, other, 9 ether, deadline, second.v, second.r, second.s);
        _assertPermitState(1, 5 ether);
        assertEq(token.allowance(owner, other), 0);
        assertEq(token.nonces(other), 0);
    }

    function test_maximumPermitCanBeSpentRepeatedlyThenRevokedWithZeroPermit() public {
        uint256 deadline = type(uint256).max;
        Signature memory sig = _sign(type(uint256).max, 0, deadline);
        _submit(type(uint256).max, deadline, sig);
        _assertPermitState(1, type(uint256).max);
        vm.startPrank(spender);
        assertTrue(token.transferFrom(owner, spender, 1));
        assertTrue(token.transferFrom(owner, spender, 2));
        vm.stopPrank();
        assertEq(token.allowance(owner, spender), type(uint256).max);
        assertEq(token.nonces(owner), 1, "spending must not change permit nonces");

        sig = _sign(0, 1, deadline);
        _submit(0, deadline, sig);
        assertEq(token.nonces(owner), 2);
        assertEq(token.allowance(owner, spender), 0);
        vm.prank(spender);
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InsufficientAllowance.selector, spender, 0, 1));
        token.transferFrom(owner, spender, 1);
        assertEq(token.balanceOf(owner), HELD - 3);
        assertEq(token.balanceOf(spender), 3);
        assertEq(token.totalSupply(), SUPPLY);
    }

    function testFuzz_permitBindsOwnerSpenderValueAndDeadline(uint256 value, uint8 field) public {
        uint256 deadline = block.timestamp + 1 days;
        Signature memory sig = _sign(value, 0, deadline);
        address claimedOwner = owner;
        address claimedSpender = spender;
        uint256 claimedValue = value;
        uint256 claimedDeadline = deadline;
        uint256 kind = field % 4;
        if (kind == 0) claimedOwner = other;
        else if (kind == 1) claimedSpender = other;
        else if (kind == 2) claimedValue = value ^ 1;
        else claimedDeadline = deadline + 1;

        bytes32 actualDigest = _digest(
            _domain(address(token), block.chainid), claimedOwner, claimedSpender, claimedValue, 0, claimedDeadline
        );
        _expectInvalidSigner(actualDigest, claimedOwner, sig);
        token.permit(claimedOwner, claimedSpender, claimedValue, claimedDeadline, sig.v, sig.r, sig.s);
        _assertPermitState(0, OLD_ALLOWANCE);
        assertEq(token.nonces(other), 0);
        assertEq(token.allowance(owner, other), 0);
        assertEq(token.allowance(other, spender), 0);
    }

    function testFuzz_futureNonceCannotSkipAuthorization(uint256 nonce) public {
        nonce = bound(nonce, 1, type(uint256).max);
        uint256 deadline = block.timestamp;
        Signature memory sig = _sign(5 ether, nonce, deadline);
        bytes32 actualDigest = _digest(_domain(address(token), block.chainid), owner, spender, 5 ether, 0, deadline);
        _expectInvalidSigner(actualDigest, owner, sig);
        _submit(5 ether, deadline, sig);
        _assertPermitState(0, OLD_ALLOWANCE);
    }

    function testFuzz_expiredPermitCannotReplaceExistingAllowance(uint256 deadline) public {
        deadline = bound(deadline, 0, block.timestamp - 1);
        Signature memory sig = _sign(type(uint256).max, 0, deadline);
        vm.expectRevert(abi.encodeWithSelector(ERC20Permit.ERC2612ExpiredSignature.selector, deadline));
        _submit(type(uint256).max, deadline, sig);
        _assertPermitState(0, OLD_ALLOWANCE);
    }

    function testFuzz_invalidVPreservesNonceAndAllowance(uint8 vSeed) public {
        uint8 invalidV = uint8(bound(vSeed, 0, 253));
        if (invalidV >= 27) invalidV += 2; // Generate every v except 27 and 28, without rejected inputs.
        uint256 deadline = block.timestamp;
        Signature memory sig = _sign(5 ether, 0, deadline);
        sig.v = invalidV;
        vm.expectRevert(ECDSA.ECDSAInvalidSignature.selector);
        _submit(5 ether, deadline, sig);
        _assertPermitState(0, OLD_ALLOWANCE);
    }

    function testFuzz_validPermitAuthorizesExactlyTheSignedAmount(uint256 allowed, uint256 spent) public {
        spent = bound(spent, 0, allowed < HELD ? allowed : HELD);
        uint256 deadline = block.timestamp + 1 days;
        Signature memory sig = _sign(allowed, 0, deadline);
        vm.prank(relayer);
        _submit(allowed, deadline, sig);
        _assertPermitState(1, allowed);
        vm.prank(spender);
        assertTrue(token.transferFrom(owner, spender, spent));
        assertEq(token.allowance(owner, spender), allowed == type(uint256).max ? allowed : allowed - spent);
        assertEq(token.balanceOf(owner), HELD - spent);
        assertEq(token.balanceOf(spender), spent);
        assertEq(token.balanceOf(relayer), 0);
        assertEq(token.nonces(owner), 1);
        assertEq(token.totalSupply(), SUPPLY);
    }

    function _domain(address verifyingContract, uint256 chainId) private pure returns (bytes32) {
        return keccak256(
            abi.encode(
                keccak256("EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)"),
                keccak256(bytes("Mutually Assured Destruction")),
                keccak256(bytes("1")),
                chainId,
                verifyingContract
            )
        );
    }

    function _digest(
        bytes32 domain,
        address signedOwner,
        address signedSpender,
        uint256 value,
        uint256 nonce,
        uint256 deadline
    ) private pure returns (bytes32) {
        bytes32 structHash = keccak256(abi.encode(PERMIT_TYPEHASH, signedOwner, signedSpender, value, nonce, deadline));
        return keccak256(abi.encodePacked("\x19\x01", domain, structHash));
    }

    function _signature(bytes32 digest) private view returns (Signature memory sig) {
        (sig.v, sig.r, sig.s) = vm.sign(ownerKey, digest);
    }

    function _sign(uint256 value, uint256 nonce, uint256 deadline) private view returns (Signature memory) {
        return _signature(_digest(_domain(address(token), deploymentChainId), owner, spender, value, nonce, deadline));
    }

    function _submit(uint256 value, uint256 deadline, Signature memory sig) private {
        token.permit(owner, spender, value, deadline, sig.v, sig.r, sig.s);
    }

    function _expectInvalidSigner(bytes32 digest, address claimedOwner, Signature memory sig) private {
        address recovered = ecrecover(digest, sig.v, sig.r, sig.s);
        assertNotEq(recovered, claimedOwner, "fixture did not change the signed message");
        vm.expectRevert(abi.encodeWithSelector(ERC20Permit.ERC2612InvalidSigner.selector, recovered, claimedOwner));
    }

    function _assertPermitState(uint256 nonce, uint256 allowed) private view {
        assertEq(token.nonces(owner), nonce, "incorrect permit nonce");
        assertEq(token.allowance(owner, spender), allowed, "incorrect allowance");
        assertEq(token.balanceOf(owner), HELD, "permit moved holder tokens");
        assertEq(token.balanceOf(spender), 0, "permit credited spender");
        assertEq(token.balanceOf(relayer), 0, "permit credited relayer");
        assertEq(token.balanceOf(address(this)), SUPPLY - HELD);
        assertEq(token.totalSupply(), SUPPLY, "permit changed supply");
    }
}
