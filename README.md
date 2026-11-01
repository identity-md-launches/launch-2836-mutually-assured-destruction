# Mutually Assured Destruction (MAD)

A fixed-supply ERC-20 token for Ethereum mainnet, built with Foundry and OpenZeppelin Contracts v5.4.0.

| Parameter | Value |
|---|---|
| Token name | `Mutually Assured Destruction` |
| Symbol | `MAD` |
| Decimals | 18 |
| Total supply | 1,000,000,000 MAD = `1000000000000000000000000000` minor units |
| Solidity contract | `MADToken` (`src/MADToken.sol`) |
| Constructor arguments | none |
| Owner / admin | none |
| Compiler | solc 0.8.26, optimizer on (200 runs), `bytecode_hash = "none"`, no CBOR metadata |

## Behaviour

- **One mint, ever.** The constructor mints the whole supply to `msg.sender`, the deployer. At launch
  the deployer is the ProjectFactory, which then pays the supply out (swarm share, pool seed,
  remainder). There is no `mint`, no minter role and no owner. The supply can never grow.
- **Plain transfers.** `transfer`, `transferFrom`, `approve` and `allowance` are OpenZeppelin's
  unmodified ERC-20. No fee, tax, reflection, cooldown, max-wallet or blocklist. Every launch flow
  (factory to distributor, distributor to claimant, pool seed, swaps in both directions) moves
  exactly the stated amount.
- **Holder-only burn.** `burn(uint256 amount)` destroys the caller's own tokens and lowers
  `totalSupply`. Burning zero reverts with `ZeroBurn()`. There is deliberately no `burnFrom`: an
  allowance lets a spender move tokens, never destroy them for the holder.
- **EIP-2612 permit.** `permit` grants an allowance from a signed message, so holders can approve
  without paying gas themselves. Standard OpenZeppelin `ERC20Permit`, EIP-712 domain
  `Mutually Assured Destruction` version `1`.
- **No privileged hand.** No pause, freeze, blacklist, seize, upgrade or `selfdestruct`. Nothing can
  move or lock a holder's balance except the holder, through an ERC-20 allowance or a permit they
  signed.
- **No ether.** The contract has no `receive` or `fallback`; sending ETH to it reverts.

## Assumptions

- The brief asks for a token with the stated name, symbol and supply and nothing else. No tax,
  vesting, governance or reflection mechanics were requested, so none were added.
- The deployer is whoever calls the constructor. On the IdentityMD launch that is the factory, which
  the launch floor checks holds the whole supply after deployment.
- `burn` and `permit` are the only additions to the ERC-20 standard. Both are conventional, both are
  OpenZeppelin code paths, and neither gives anyone power over another holder's balance.
- Burned tokens are gone for good. There is no way to re-mint them.

## Deployment parameters

- Chain: Ethereum mainnet (chain id 1).
- Contract: `MADToken`, no constructor arguments, so the creation code is the compiled bytecode as
  built with the pinned `foundry.toml`.
- `token.totalSupply` for the manifest: `1000000000000000000000000000`. `token.decimals`: `18`.
- The launch's pool pair, fee, tick spacing, economics and remainder address are the launch's own
  and are written by the manifest step, not by this repository.
- The constructor calls no other contract and reads no chain state, so it deploys identically on an
  empty chain and on mainnet.

## After launch

There is nothing to configure. The token has no owner and no settable value. Operational
responsibilities are limited to:

- **Holders** keep their own keys. A permit signature is as powerful as an `approve`; sign only for
  spenders you trust and use a short deadline.
- **Integrators** should treat MAD as a standard 18-decimal ERC-20 that returns `true` on success and
  reverts on failure. `totalSupply` only decreases, through `burn`.
- **Source verification** on the block explorer is the network deployer's step after launch, with
  the pinned compiler settings in `foundry.toml` (0.8.26, optimizer 200 runs, cancun,
  `bytecode_hash = none`, `cbor_metadata = false`).

## Layout

```
foundry.toml                 compiler pins and build settings
remappings.txt               forge-std and @openzeppelin/contracts
src/MADToken.sol             the token
test/MADToken.t.sol          behavioural and fuzz tests
lib/forge-std                vendored forge-std v1.9.7 (plain files, no submodule)
lib/openzeppelin-contracts   vendored OpenZeppelin Contracts v5.4.0 (contracts/ only, plain files)
```

## Verification

```
forge build
forge test
forge fmt --check
```

The tests cover: metadata; the single mint to the deployer and its events; exact transfer amounts and
conservation of supply; transfer failures (insufficient balance, zero receiver); allowances, infinite
allowance, and `transferFrom` failures; `burn` success and failure (zero, over balance, other
holders untouched); the absence of `burnFrom`; `permit` success, expiry, wrong signer and replay; that
no mint, owner, pause, freeze, blacklist, seize or upgrade selector exists for anyone; the launch
flow from factory to distributor to claimant arriving whole; and a scan of the reachable runtime code
for `DELEGATECALL`, `CALLCODE` and `SELFDESTRUCT`. Fuzz tests check supply conservation, burn
accounting and allowance accounting across random amounts.

Tests passing do not constitute a security audit. The token is two OpenZeppelin base contracts plus a
twelve-line `burn`, but an independent review before release is still the right call for anything that
will hold value.
