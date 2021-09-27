// contracts/ScrollToken.sol
// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import "@openzeppelin/contracts/access/AccessControl.sol";
import "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import "@openzeppelin/contracts/token/ERC20/extensions/ERC20Burnable.sol";

import "../../ERC20/IMintableToken.sol";
import "./IFakeAaveToken.sol";

contract FakeAaveUSDToken is ERC20, AccessControl, ERC20Burnable, IMintableToken, IFakeAaveToken {
    bytes32 public constant MINTER_ROLE = keccak256("MINTER_ROLE");
    bytes32 public constant MINTER_ADMIN_ROLE = keccak256("MINTER_ADMIN_ROLE");
    uint8 _decimals;

    constructor(
        string memory name_,
        string memory symbol_,
        uint8 decimals_
    ) ERC20(name_, symbol_) {
        _decimals = decimals_;
        // _setupRole(MINTER_ROLE, msg.sender);
        _setupRole(MINTER_ADMIN_ROLE, msg.sender);
        _setRoleAdmin(MINTER_ROLE, MINTER_ADMIN_ROLE);
        // _mint(msg.sender, 100000000*(10**18));
    }

    function internalAaveMintFor(address to, uint256 amount) public override {
        _mint(to, amount);
    }

    function internalAaveBurnFor(address to, uint256 amount) public override {
        _burn(to, amount);
    }

    function mint(address to, uint256 amount) public override onlyRole(MINTER_ROLE) {
        _mint(to, amount);
    }

    function decimals() public view override returns (uint8) {
        return _decimals;
    }
}
