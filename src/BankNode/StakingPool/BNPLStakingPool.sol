// contracts/ExampleBankNode.sol
// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/ERC20.sol";

import "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import "@openzeppelin/contracts-upgradeable/access/AccessControlEnumerableUpgradeable.sol";

import "../../Management/IBankNodeManager.sol";
import "../IBNPLBankNode.sol";
import "../../ERC20/IMintableBurnableTokenUpgradeable.sol";
import "../../Utils/TransferHelper.sol";
import "../../SwapMarket/IBNPLSwapMarket.sol";
import "../../Aave/IAaveLendingPool.sol";
import "../../Utils/Math/PRBMathUD60x18.sol";
import "./UserTokenLockup.sol";
import "@openzeppelin/contracts-upgradeable/security/ReentrancyGuardUpgradeable.sol";

contract BNPLStakingPool is
    Initializable,
    ReentrancyGuardUpgradeable,
    AccessControlEnumerableUpgradeable,
    UserTokenLockup,
    IBNPLNodeStakingPool
{
    /**
     * @dev Emitted when user `user` is stakes `bnplStakeAmount` of BNPL tokens while receiving `poolTokensMinted` of pool tokens
     */
    event Stake(address indexed user, uint256 bnplStakeAmount, uint256 poolTokensMinted);

    /**
     * @dev Emitted when user `user` is unstakes `unstakeAmount` of liquidity while receiving `bnplTokensReturned` of BNPL tokens
     */
    event Unstake(address indexed user, uint256 bnplUnstakeAmount, uint256 poolTokensBurned);

    /*
     * @dev Emitted when user `user` donates `donationAmount` of base liquidity tokens to the pool
     */
    event Donation(address indexed user, uint256 donationAmount);

    /**
     * @dev Emitted when user `user` bonds `bondAmount` of base liquidity tokens to the pool
     */
    event Bond(address indexed user, uint256 bondAmount);

    /**
     * @dev Emitted when user `user` unbonds `unbondAmount` of base liquidity tokens to the pool
     */
    event Unbond(address indexed user, uint256 unbondAmount);

    /**
     * @dev Emitted when user `user` donates `donationAmount` of base liquidity tokens to the pool
     */
    event Slash(address indexed recipient, uint256 slashAmount);

    uint32 public constant BNPL_STAKER_NEEDS_KYC = 1 << 3;

    bytes32 public constant SLASHER_ROLE = keccak256("SLASHER_ROLE");
    bytes32 public constant NODE_REWARDS_MANAGER_ROLE = keccak256("NODE_REWARDS_MANAGER_ROLE");
    //bytes32 public constant SLASHER_ADMIN_ROLE = keccak256("SLASHER_ADMIN_ROLE");

    IERC20 public BASE_LIQUIDITY_TOKEN; // = IERC20(0x1d1781B0017CCBb3f0341420E5952aAfD9d8C083);
    IMintableBurnableTokenUpgradeable public POOL_LIQUIDITY_TOKEN; // = IMintableToken(0x517D01e738F8E1fB473f905BCC736aaa41226761);
    IBNPLBankNode public bankNode;
    IBankNodeManager public bankNodeManager;

    uint256 public baseTokenBalance;
    uint256 public tokensBondedAllTime;
    uint256 public poolTokenEffectiveSupply;
    uint256 public virtualPoolTokensCount;
    uint256 public totalDonatedAllTime;
    uint256 public totalSlashedAllTime;
    BNPLKYCStore public bnplKYCStore;
    uint32 public kycDomainId;

    function initialize(
        address bnplToken,
        address poolBNPLToken,
        address bankNodeContract,
        address bankNodeManagerContract,
        address tokenBonder,
        uint256 tokensToBond,
        BNPLKYCStore bnplKYCStore_,
        uint32 kycDomainId_
    ) external override initializer nonReentrant {
        require(bnplToken != address(0), "bnplToken cannot be 0");
        require(poolBNPLToken != address(0), "poolBNPLToken cannot be 0");
        require(bankNodeContract != address(0), "slasherAdmin cannot be 0");
        require(tokenBonder != address(0), "tokenBonder cannot be 0");
        require(tokensToBond > 0, "tokensToBond cannot be 0");

        __ReentrancyGuard_init_unchained();
        __Context_init_unchained();
        __ERC165_init_unchained();
        __AccessControl_init_unchained();
        __AccessControlEnumerable_init_unchained();
        _UserTokenLockup_init_unchained();

        BASE_LIQUIDITY_TOKEN = IERC20(bnplToken);
        POOL_LIQUIDITY_TOKEN = IMintableBurnableTokenUpgradeable(poolBNPLToken);

        bankNode = IBNPLBankNode(bankNodeContract);
        bankNodeManager = IBankNodeManager(bankNodeManagerContract);

        //_setupRole(SLASHER_ADMIN_ROLE, slasherAdmin);
        _setupRole(SLASHER_ROLE, bankNodeContract);
        _setupRole(NODE_REWARDS_MANAGER_ROLE, tokenBonder);
        //_setRoleAdmin(SLASHER_ROLE, SLASHER_ADMIN_ROLE);

        require(BASE_LIQUIDITY_TOKEN.balanceOf(address(this)) >= tokensToBond, "tokens to bond not sent");
        baseTokenBalance = tokensToBond;
        tokensBondedAllTime = tokensToBond;
        poolTokenEffectiveSupply = tokensToBond;
        virtualPoolTokensCount = tokensToBond;
        bnplKYCStore = bnplKYCStore_;
        kycDomainId = kycDomainId_;
        POOL_LIQUIDITY_TOKEN.mint(address(this), tokensToBond);
        emit Bond(tokenBonder, tokensToBond);
    }

    function poolTokensCirculating() external view returns (uint256) {
        return poolTokenEffectiveSupply - POOL_LIQUIDITY_TOKEN.balanceOf(address(this));
    }

    function getUnstakeLockupPeriod() public pure returns (uint256) {
        return 7 days;
    }

    function getPoolTotalAssetsValue() public view override returns (uint256) {
        return baseTokenBalance;
    }

    function isApproveLoanAvailable() public view override returns (bool) {
        return
            getPoolWithdrawConversion(POOL_LIQUIDITY_TOKEN.balanceOf(address(this))) >=
            ((bankNodeManager.minimumBankNodeBondedAmount() * 75) / 100);
    }

    function getPoolDepositConversion(uint256 depositAmount) public view returns (uint256) {
        return (depositAmount * poolTokenEffectiveSupply) / getPoolTotalAssetsValue();
    }

    function getPoolWithdrawConversion(uint256 withdrawAmount) public view returns (uint256) {
        return (withdrawAmount * getPoolTotalAssetsValue()) / poolTokenEffectiveSupply;
    }

    function _issueUnlockedTokensToUser(address user, uint256 amount) internal override returns (uint256) {
        require(
            amount != 0 && amount <= poolTokenEffectiveSupply,
            "poolTokenAmount cannot be 0 or more than circulating"
        );

        require(poolTokenEffectiveSupply != 0, "poolTokenEffectiveSupply must not be 0");
        require(getPoolTotalAssetsValue() != 0, "total asset value must not be 0");

        uint256 baseTokensOut = getPoolWithdrawConversion(amount);
        poolTokenEffectiveSupply -= amount;
        require(baseTokenBalance >= baseTokensOut, "base tokens balance must be >= out");
        baseTokenBalance -= baseTokensOut;
        TransferHelper.safeTransfer(address(BASE_LIQUIDITY_TOKEN), user, baseTokensOut);
        emit Unstake(user, baseTokensOut, amount);
        return baseTokensOut;
    }

    function _removeLiquidityAndLock(
        address user,
        uint256 poolTokensToConsume,
        uint256 unstakeLockupPeriod
    ) internal returns (uint256) {
        require(unstakeLockupPeriod != 0, "lockup period cannot be 0");
        require(user != address(this), "user cannot be self");
        require(user != address(0), "user cannot be null");

        require(
            poolTokensToConsume > 0 && poolTokensToConsume <= poolTokenEffectiveSupply,
            "poolTokenAmount cannot be 0 or more than circulating"
        );

        require(poolTokenEffectiveSupply != 0, "poolTokenEffectiveSupply must not be 0");
        POOL_LIQUIDITY_TOKEN.burnFrom(user, poolTokensToConsume);
        _createTokenLockup(user, poolTokensToConsume, uint64(block.timestamp + unstakeLockupPeriod), true);
        return 0;
    }

    function _mintPoolTokensForUser(address user, uint256 mintAmount) private {
        //require(user != address(this), "user cannot be self");
        require(user != address(0), "user cannot be null");
        require(mintAmount != 0, "mint amount cannot be 0");
        uint256 newMintTokensCirculating = poolTokenEffectiveSupply + mintAmount;
        poolTokenEffectiveSupply = newMintTokensCirculating;
        POOL_LIQUIDITY_TOKEN.mint(user, mintAmount);
        require(poolTokenEffectiveSupply == newMintTokensCirculating);
    }

    function _processDonation(address sender, uint256 depositAmount) private {
        require(sender != address(this), "sender cannot be self");
        require(sender != address(0), "sender cannot be null");
        require(depositAmount != 0, "depositAmount cannot be 0");

        require(poolTokenEffectiveSupply != 0, "poolTokenEffectiveSupply must not be 0");
        TransferHelper.safeTransferFrom(address(BASE_LIQUIDITY_TOKEN), sender, address(this), depositAmount);
        baseTokenBalance += depositAmount;
        totalDonatedAllTime += depositAmount;
        emit Donation(sender, depositAmount);
    }

    function _processBondTokens(address sender, uint256 depositAmount) private {
        require(sender != address(this), "sender cannot be self");
        require(sender != address(0), "sender cannot be null");
        require(depositAmount != 0, "depositAmount cannot be 0");

        require(poolTokenEffectiveSupply != 0, "poolTokenEffectiveSupply must not be 0");
        TransferHelper.safeTransferFrom(address(BASE_LIQUIDITY_TOKEN), sender, address(this), depositAmount);
        uint256 selfMint = getPoolDepositConversion(depositAmount);
        _mintPoolTokensForUser(address(this), selfMint);
        virtualPoolTokensCount += selfMint;
        baseTokenBalance += depositAmount;
        tokensBondedAllTime += depositAmount;
        emit Bond(sender, depositAmount);
    }

    function _processUnbondTokens(address sender, uint256 unbondAmount) private {
        require(sender != address(this), "sender cannot be self");
        require(sender != address(0), "sender cannot be null");
        require(unbondAmount != 0, "unbondAmount cannot be 0");

        require(bankNode.onGoingLoanCount() == 0, "Cannot unbond, there are ongoing loans");
        uint256 bondedAmount = getPoolDepositConversion(unbondAmount);
        require(unbondAmount <= bondedAmount, "The unbondAmount must be <= the bondedAmount");
        require(
            getPoolWithdrawConversion(POOL_LIQUIDITY_TOKEN.balanceOf(address(this))) >= unbondAmount,
            "Insufficient bonded amount"
        );

        TransferHelper.safeTransfer(address(BASE_LIQUIDITY_TOKEN), sender, unbondAmount);
        POOL_LIQUIDITY_TOKEN.burn(bondedAmount);

        poolTokenEffectiveSupply -= bondedAmount;
        virtualPoolTokensCount -= bondedAmount;
        baseTokenBalance -= unbondAmount;

        emit Unbond(sender, unbondAmount);
    }

    function _setupLiquidityFirst(address user, uint256 depositAmount) private returns (uint256) {
        require(user != address(this), "user cannot be self");
        require(user != address(0), "user cannot be null");
        require(depositAmount != 0, "depositAmount cannot be 0");

        require(poolTokenEffectiveSupply == 0, "poolTokenEffectiveSupply must be 0");
        uint256 totalAssetValue = getPoolTotalAssetsValue();

        TransferHelper.safeTransferFrom(address(BASE_LIQUIDITY_TOKEN), user, address(this), depositAmount);

        require(poolTokenEffectiveSupply == 0, "poolTokenEffectiveSupply must be 0");
        require(getPoolTotalAssetsValue() == totalAssetValue, "total asset value must not change");

        baseTokenBalance += depositAmount;
        uint256 newTotalAssetValue = getPoolTotalAssetsValue();
        require(newTotalAssetValue != 0 && newTotalAssetValue >= depositAmount);
        uint256 poolTokensOut = newTotalAssetValue;
        _mintPoolTokensForUser(user, poolTokensOut);
        emit Stake(user, depositAmount, poolTokensOut);
        //_processMigrateUnusedFundsToLendingPool();
        return poolTokensOut;
    }

    function _addLiquidityNormal(address user, uint256 depositAmount) private returns (uint256) {
        require(user != address(this), "user cannot be self");
        require(user != address(0), "user cannot be null");
        require(depositAmount != 0, "depositAmount cannot be 0");

        require(poolTokenEffectiveSupply != 0, "poolTokenEffectiveSupply must not be 0");
        require(getPoolTotalAssetsValue() != 0, "total asset value must not be 0");

        TransferHelper.safeTransferFrom(address(BASE_LIQUIDITY_TOKEN), user, address(this), depositAmount);
        require(poolTokenEffectiveSupply != 0, "poolTokenEffectiveSupply cannot be 0");

        uint256 totalAssetValue = getPoolTotalAssetsValue();
        require(totalAssetValue != 0, "total asset value cannot be 0");
        uint256 poolTokensOut = getPoolDepositConversion(depositAmount);

        baseTokenBalance += depositAmount;
        _mintPoolTokensForUser(user, poolTokensOut);
        emit Stake(user, depositAmount, poolTokensOut);
        //_processMigrateUnusedFundsToLendingPool();
        return poolTokensOut;
    }

    function _addLiquidity(address user, uint256 depositAmount) private returns (uint256) {
        require(user != address(this), "user cannot be self");
        require(user != address(0), "user cannot be null");

        require(depositAmount != 0, "depositAmount cannot be 0");
        if (poolTokenEffectiveSupply == 0) {
            return _setupLiquidityFirst(user, depositAmount);
        } else {
            return _addLiquidityNormal(user, depositAmount);
        }
    }

    function _removeLiquidityNoLockup(address user, uint256 poolTokensToConsume) private returns (uint256) {
        require(user != address(this), "user cannot be self");
        require(user != address(0), "user cannot be null");

        require(
            poolTokensToConsume != 0 && poolTokensToConsume <= poolTokenEffectiveSupply,
            "poolTokenAmount cannot be 0 or more than circulating"
        );

        require(poolTokenEffectiveSupply != 0, "poolTokenEffectiveSupply must not be 0");
        require(getPoolTotalAssetsValue() != 0, "total asset value must not be 0");

        uint256 baseTokensOut = getPoolWithdrawConversion(poolTokensToConsume);
        poolTokenEffectiveSupply -= poolTokensToConsume;
        //_ensureBaseBalance(baseTokensOut);
        require(baseTokenBalance >= baseTokensOut, "base tokens balance must be >= out");
        TransferHelper.safeTransferFrom(address(POOL_LIQUIDITY_TOKEN), user, address(this), poolTokensToConsume);
        require(baseTokenBalance >= baseTokensOut, "base tokens balance must be >= out");
        baseTokenBalance -= baseTokensOut;
        TransferHelper.safeTransfer(address(BASE_LIQUIDITY_TOKEN), user, baseTokensOut);
        emit Unstake(user, baseTokensOut, poolTokensToConsume);
        return baseTokensOut;
    }

    function _removeLiquidity(address user, uint256 poolTokensToConsume) internal returns (uint256) {
        require(poolTokensToConsume != 0, "poolTokensToConsume cannot be 0");
        uint256 unstakeLockupPeriod = getUnstakeLockupPeriod();
        if (unstakeLockupPeriod == 0) {
            return _removeLiquidityNoLockup(user, poolTokensToConsume);
        } else {
            return _removeLiquidityAndLock(user, poolTokensToConsume, unstakeLockupPeriod);
        }
    }

    /// @notice Allows a user to donate `donateAmount` of BNPL to the pool (user must first approve)
    function donate(uint256 donateAmount) external override nonReentrant {
        require(donateAmount != 0, "donateAmount cannot be 0");
        _processDonation(msg.sender, donateAmount);
    }

    /// @notice Allows a user to bond `bondAmount` of BNPL to the pool (user must first approve)
    function bondTokens(uint256 bondAmount) external override nonReentrant onlyRole(NODE_REWARDS_MANAGER_ROLE) {
        require(bondAmount != 0, "bondAmount cannot be 0");
        _processBondTokens(msg.sender, bondAmount);
    }

    /// @notice Allows a user to unbond `unbondAmount` of BNPL from the pool
    function unbondTokens(uint256 unbondAmount) external override nonReentrant onlyRole(NODE_REWARDS_MANAGER_ROLE) {
        require(unbondAmount != 0, "unbondAmount cannot be 0");
        _processUnbondTokens(msg.sender, unbondAmount);
    }

    /// @notice Allows a user to stake `unstakeAmount` of BNPL to the pool (user must first approve)
    function stakeTokens(uint256 stakeAmount) external override nonReentrant {
        require(
            bnplKYCStore.checkUserBasicBitwiseMode(kycDomainId, msg.sender, BNPL_STAKER_NEEDS_KYC) == 1,
            "borrower needs kyc"
        );
        require(stakeAmount != 0, "stakeAmount cannot be 0");
        _addLiquidity(msg.sender, stakeAmount);
    }

    /// @notice Allows a user to unstake `unstakeAmount` of BNPL from the pool (puts it into a lock up for a 7 day cool down period)
    function unstakeTokens(uint256 unstakeAmount) external override nonReentrant {
        require(unstakeAmount != 0, "unstakeAmount cannot be 0");
        _removeLiquidity(msg.sender, unstakeAmount);
    }

    function _slash(uint256 slashAmount, address recipient) private {
        require(slashAmount < getPoolTotalAssetsValue(), "cannot slash more than the pool balance");
        baseTokenBalance -= slashAmount;
        totalSlashedAllTime += slashAmount;
        TransferHelper.safeTransfer(address(BASE_LIQUIDITY_TOKEN), recipient, slashAmount);
        emit Slash(recipient, slashAmount);
    }

    /// @notice Allows an authenticated contract/user (in this case, only BNPLBankNode) to slash `slashAmount` of BNPL from the pool
    function slash(uint256 slashAmount) external override onlyRole(SLASHER_ROLE) nonReentrant {
        _slash(slashAmount, msg.sender);
    }

    function getNodeOwnerPoolTokenRewards() public view returns (uint256) {
        uint256 equivalentPoolTokens = getPoolDepositConversion(tokensBondedAllTime);
        uint256 ownerPoolTokens = POOL_LIQUIDITY_TOKEN.balanceOf(address(this));
        if (ownerPoolTokens > equivalentPoolTokens) {
            return ownerPoolTokens - equivalentPoolTokens;
        }
        return 0;
    }

    function getNodeOwnerBNPLRewards() external view returns (uint256) {
        uint256 rewardsAmount = getNodeOwnerPoolTokenRewards();
        if (rewardsAmount != 0) {
            return getPoolWithdrawConversion(rewardsAmount);
        }
        return 0;
    }

    function claimNodeOwnerPoolTokenRewards(address to)
        external
        override
        onlyRole(NODE_REWARDS_MANAGER_ROLE)
        nonReentrant
    {
        uint256 poolTokenRewards = getNodeOwnerPoolTokenRewards();
        require(poolTokenRewards > 0, "cannot claim 0 rewards");
        virtualPoolTokensCount -= poolTokenRewards;
        POOL_LIQUIDITY_TOKEN.transfer(to, poolTokenRewards);
    }

    /// @notice Calculates the amount of BNPL to slash from the pool given a Bank Node loss of `nodeLoss` with a previous balance of `prevNodeBalance` and the current pool balance containing `poolBalance` BNPL
    function calculateSlashAmount(
        uint256 prevNodeBalance,
        uint256 nodeLoss,
        uint256 poolBalance
    ) external pure returns (uint256) {
        uint256 slashRatio = PRBMathUD60x18.div(
            nodeLoss * PRBMathUD60x18.scale(),
            prevNodeBalance * PRBMathUD60x18.scale()
        );
        return (poolBalance * slashRatio) / PRBMathUD60x18.scale();
    }

    /// @notice Allows user `user` to claim the next token lockup vault they have locked up in the contract
    function claimTokenLockup(address user) external nonReentrant returns (uint256) {
        return _claimNextTokenLockup(user);
    }

    /// @notice Allows user `user` to claim the next `maxNumberOfClaims` token lockup vaults they have locked up in the contract
    function claimTokenNextNLockups(address user, uint32 maxNumberOfClaims) external nonReentrant returns (uint256) {
        return _claimUpToNextNTokenLockups(user, maxNumberOfClaims);
    }
}
