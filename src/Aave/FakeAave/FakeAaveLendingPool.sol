// contracts/FakeAaveLendingPool.sol
// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import "../IAaveLendingPool.sol";
import "./IFakeAaveToken.sol";
import "../../Utils/TransferHelper.sol";

contract FakeAaveLendingPool is IAaveLendingPool {
    mapping(address => IFakeAaveToken) public depositAssetToAaveAsset;
    mapping(address => IERC20) public aaveAssetToDepositAsset;

    function _addAssetPair(address depositAsset, address aaveAsset) private {
        require(
            address(depositAssetToAaveAsset[depositAsset]) == address(0),
            "this deposit asset is already registered"
        );
        require(address(aaveAssetToDepositAsset[aaveAsset]) == address(0), "this aave asset is already registered");
        depositAssetToAaveAsset[depositAsset] = IFakeAaveToken(aaveAsset);
        aaveAssetToDepositAsset[aaveAsset] = IERC20(aaveAsset);
    }

    function addAssetPair(address depositAsset, address aaveAsset) public {
        _addAssetPair(depositAsset, aaveAsset);
    }

    function deposit(
        address asset,
        uint256 amount,
        address onBehalfOf,
        uint16 /*referralCode*/
    ) public override {
        require(asset != address(0), "cannot be asset == 0");
        IFakeAaveToken aaveToken = depositAssetToAaveAsset[asset];

        require(address(aaveToken) != address(0), "deposit asset not supported");
        require(amount != 0, "amount cannot be 0");
        require(onBehalfOf != address(0), "cannot be onBehalfOf == 0");
        TransferHelper.safeTransferFrom(asset, msg.sender, address(this), amount);
        aaveToken.internalAaveMintFor(onBehalfOf, amount);
    }

    function withdraw(
        address asset,
        uint256 amount,
        address to
    ) public override {
        require(asset != address(0), "cannot be asset == 0");
        IERC20 depositAsset = aaveAssetToDepositAsset[asset];

        require(address(depositAsset) != address(0), "aave asset not supported");
        require(amount != 0, "amount cannot be 0");
        require(to != address(0), "cannot be asset == 0");
        IFakeAaveToken(asset).internalAaveBurnFor(msg.sender, amount);
        TransferHelper.safeTransfer(asset, to, amount);
    }
}