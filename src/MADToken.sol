// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {ERC20Permit} from "@openzeppelin/contracts/token/ERC20/extensions/ERC20Permit.sol";

/// @title Mutually Assured Destruction (MAD)
/// @notice A fixed-supply ERC-20. The whole supply of 1,000,000,000 MAD (18 decimals) is minted once,
/// in the constructor, to the deployer. There is no owner, no minter, no pause, no blocklist and no
/// fee on transfer: every transfer moves exactly what it says, and nothing can ever create more MAD.
/// @dev The only way the supply changes after deployment is down: a holder may `burn` their own tokens.
/// Nothing can burn or move a balance its holder did not authorise with an ERC-20 allowance or an
/// EIP-2612 permit signature. The contract has no constructor arguments, so it deploys the same way
/// on any chain and never calls another contract while deploying.
contract MADToken is ERC20, ERC20Permit {
    /// @notice The token name returned by `name()`.
    string public constant TOKEN_NAME = "Mutually Assured Destruction";

    /// @notice The token symbol returned by `symbol()`.
    string public constant TOKEN_SYMBOL = "MAD";

    /// @notice The number of decimals, as `decimals()` reports it.
    uint8 public constant DECIMALS = 18;

    /// @notice The whole supply in minor units: 1,000,000,000 MAD with 18 decimals.
    uint256 public constant TOTAL_SUPPLY = 1_000_000_000 * 10 ** uint256(DECIMALS);

    /// @notice Emitted once, from the constructor, with the address that received the whole supply.
    event SupplyMinted(address indexed recipient, uint256 amount);

    /// @notice Emitted when a holder burns their own tokens.
    event Burned(address indexed holder, uint256 amount);

    /// @notice Burning zero tokens is a mistake, not a burn.
    error ZeroBurn();

    /// @notice Mints the entire supply to the deployer. There is no other mint path.
    constructor() ERC20(TOKEN_NAME, TOKEN_SYMBOL) ERC20Permit(TOKEN_NAME) {
        _mint(msg.sender, TOTAL_SUPPLY);
        emit SupplyMinted(msg.sender, TOTAL_SUPPLY);
    }

    /// @notice Destroys `amount` of the caller's own tokens, reducing the total supply.
    /// @dev Only the caller's balance can be burned here. There is no `burnFrom`: an allowance lets a
    /// spender move tokens, never destroy them on the holder's behalf.
    /// @param amount The amount to burn, in minor units. Must be greater than zero.
    function burn(uint256 amount) external {
        if (amount == 0) revert ZeroBurn();
        _burn(msg.sender, amount);
        emit Burned(msg.sender, amount);
    }
}
