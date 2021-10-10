// SPDX-License-Identifier: GNU Affero
// Feel free to change the license, but this is what we use

// Feel free to change this version of Solidity. We support >=0.6.0 <0.7.0;
pragma solidity >=0.6.0 <0.7.0;
pragma experimental ABIEncoderV2;

// These are the core Yearn libraries
import {BaseStrategyInitializable} from "../BaseStrategy.sol";

import {SafeERC20, SafeMath, IERC20, Address} from "@openzeppelin/contracts/token/ERC20/SafeERC20.sol";

import "@openzeppelin/contracts/math/Math.sol";

import {IUniLikeSwapRouter} from "../interfaces/IUniLikeSwapRouter.sol";

import "../interfaces/aave/IProtocolDataProvider.sol";
import "../interfaces/aave/IAaveIncentivesController.sol";
import "../interfaces/aave/IAToken.sol";
import "../interfaces/aave/IVariableDebtToken.sol";
import "../interfaces/aave/ILendingPool.sol";

contract StrategyGenLevAAVE is BaseStrategyInitializable {
    using SafeERC20 for IERC20;
    using Address for address;
    using SafeMath for uint256;

    // AAVE protocol address
    IProtocolDataProvider private constant protocolDataProvider = IProtocolDataProvider(0x7551b5D2763519d4e37e8B81929D336De671d46d);
    IAaveIncentivesController private constant incentivesController = IAaveIncentivesController(0x357D51124f59836DeD84c8a1730D72B749d8BC23);
    ILendingPool private constant lendingPool = ILendingPool(0x8dFf5E27EA6b7AC08EbFdf9eB090F32ee9a30fcf);

    address private constant rewardToken = 0x0d500B1d8E8eF31E21C99d1Db9A6444d3ADf1270;
    address private constant wrappedNative = 0x0d500B1d8E8eF31E21C99d1Db9A6444d3ADf1270;

    // Supply and borrow tokens
    IAToken public aToken;
    IVariableDebtToken public debtToken;

    // SWAP routers
    IUniLikeSwapRouter private PRIMARY_ROUTER = IUniLikeSwapRouter(0xa5E0829CaCEd8fFDD4De3c43696c57F7D7A678ff);
    IUniLikeSwapRouter private SECONDARY_ROUTER = IUniLikeSwapRouter(0x1b02dA8Cb0d097eB8D57A175b88c7D8b47997506);

    // OPS State Variables
    uint256 private constant DEFAULT_COLLAT_TARGET_MARGIN = 0.02 ether;
    uint256 private constant DEFAULT_COLLAT_MAX_MARGIN = 0.005 ether;
    uint256 private constant LIQUIDATION_WARNING_THRESHOLD = 0.01 ether;

    uint256 public maxBorrowCollatRatio; // The maximum the aave protocol will let us borrow
    uint256 public targetCollatRatio; // The LTV we are levering up to
    uint256 public maxCollatRatio; // Closest to liquidation we'll risk

    uint8 public maxIterations;

    uint256 public minWant = 100;
    uint256 public minRatio = 0.005 ether;
    uint256 public minRewardToSell = 1e15;

    enum SwapRouter {Primary, Secondary}
    SwapRouter public swapRouter = SwapRouter.Primary;

    bool private alreadyAdjusted = false; // Signal whether a position adjust was done in prepareReturn

    uint16 private referral = 0;

    uint256 private constant MAX_BPS = 1e4;
    uint256 private constant BPS_WAD_RATIO = 1e14;
    uint256 private constant COLLATERAL_RATIO_PRECISION = 1 ether;
    uint256 private constant PESSIMISM_FACTOR = 1000;
    uint256 private DECIMALS;

    constructor(address _vault) public BaseStrategyInitializable(_vault) {
        _initializeThis();
    }

    function initialize(
        address _vault,
        address _strategist,
        address _rewards,
        address _keeper
    ) external override {
        _initialize(_vault, _strategist, _rewards, _keeper);
        _initializeThis();
    }

    function _initializeThis() internal {
        require(address(aToken) == address(0));

        // initialize operational state
        maxIterations = 16;

        // mins
        minWant = 100;
        minRatio = 0.005 ether;
        minRewardToSell = 1e15;

        // reward params
        swapRouter = SwapRouter.Primary;

        // Set aave tokens
        (address _aToken, , address _debtToken) = protocolDataProvider.getReserveTokensAddresses(address(want));
        aToken = IAToken(_aToken);
        debtToken = IVariableDebtToken(_debtToken);

        // Let collateral targets
        (uint256 ltv, uint256 liquidationThreshold) = getProtocolCollatRatios();
        targetCollatRatio = liquidationThreshold.sub(DEFAULT_COLLAT_TARGET_MARGIN);
        maxCollatRatio = liquidationThreshold.sub(DEFAULT_COLLAT_MAX_MARGIN);
        maxBorrowCollatRatio = ltv.sub(DEFAULT_COLLAT_MAX_MARGIN);

        DECIMALS = 10**vault.decimals();

        // approve spend aave spend
        approveMaxSpend(address(want), address(lendingPool));
        approveMaxSpend(address(aToken), address(lendingPool));

        // approve flashloan spend
        approveMaxSpend(rewardToken, address(lendingPool));

        // approve swap router spend
        approveMaxSpend(rewardToken, address(PRIMARY_ROUTER));
        if (address(SECONDARY_ROUTER) != address(0)) {
            approveMaxSpend(rewardToken, address(SECONDARY_ROUTER));
        }
    }

    function setReferralCode(uint16 _referral) external onlyVaultManagers {
        referral = _referral;
    }

    function setRouters(address _primaryRouter, address _secondaryRouter) external onlyVaultManagers {
        PRIMARY_ROUTER = IUniLikeSwapRouter(_primaryRouter);
        SECONDARY_ROUTER = IUniLikeSwapRouter(_secondaryRouter);
    }

    // SETTERS
    function setCollateralTargets(
        uint256 _targetCollatRatio,
        uint256 _maxCollatRatio,
        uint256 _maxBorrowCollatRatio
    ) external onlyVaultManagers {
        (uint256 ltv, uint256 liquidationThreshold) = getProtocolCollatRatios();

        require(_targetCollatRatio < liquidationThreshold);
        require(_maxCollatRatio < liquidationThreshold);
        require(_targetCollatRatio < _maxCollatRatio);
        require(_maxBorrowCollatRatio < ltv);

        targetCollatRatio = _targetCollatRatio;
        maxCollatRatio = _maxCollatRatio;
        maxBorrowCollatRatio = _maxBorrowCollatRatio;
    }

    function setMinsAndMaxs(
        uint256 _minWant,
        uint256 _minRatio,
        uint8 _maxIterations
    ) external onlyVaultManagers {
        require(_minRatio < maxBorrowCollatRatio);
        require(_maxIterations > 0 && _maxIterations < 16);
        minWant = _minWant;
        minRatio = _minRatio;
        maxIterations = _maxIterations;
    }

    function setRewardBehavior(SwapRouter _swapRouter, uint256 _minRewardToSell) external onlyVaultManagers {
        require(_swapRouter == SwapRouter.Primary || _swapRouter == SwapRouter.Secondary);
        if (_swapRouter == SwapRouter.Secondary) {
            require(address(SECONDARY_ROUTER) != address(0));
        }
        swapRouter = _swapRouter;
        minRewardToSell = _minRewardToSell;
    }

    function name() external view override returns (string memory) {
        return "StrategyGenLevAAVE";
    }

    function estimatedTotalAssets() public view override returns (uint256) {
        uint256 balanceExcludingRewards = balanceOfWant().add(getCurrentSupply());

        // if we don't have a position, don't worry about rewards
        if (balanceExcludingRewards < minWant) {
            return balanceExcludingRewards;
        }

        uint256 rewards = estimatedRewardsInWant().mul(MAX_BPS.sub(PESSIMISM_FACTOR)).div(MAX_BPS);

        return balanceExcludingRewards.add(rewards);
    }

    function estimatedRewardsInWant() public view returns (uint256) {
        uint256 rewardTokenBalance = balanceOfRewardToken();

        uint256 pendingRewards = incentivesController.getRewardsBalance(getAaveAssets(), address(this));

        if (rewardToken == address(want)) {
            return pendingRewards;
        } else {
            return tokenToWant(rewardToken, rewardTokenBalance.add(pendingRewards));
        }
    }

    function prepareReturn(uint256 _debtOutstanding)
        internal
        override
        returns (
            uint256 _profit,
            uint256 _loss,
            uint256 _debtPayment
        )
    {
        // claim & sell rewards
        _claimAndSellRewards();

        // account for profit / losses
        uint256 totalDebt = vault.strategies(address(this)).totalDebt;

        // Assets immediately convertable to want only
        uint256 supply = getCurrentSupply();
        uint256 totalAssets = balanceOfWant().add(supply);

        if (totalDebt > totalAssets) {
            // we have losses
            _loss = totalDebt.sub(totalAssets);
        } else {
            // we have profit
            _profit = totalAssets.sub(totalDebt);
        }

        // free funds to repay debt + profit to the strategy
        uint256 amountAvailable = balanceOfWant();
        uint256 amountRequired = _debtOutstanding.add(_profit);

        if (amountRequired > amountAvailable) {
            // we need to free funds
            // we dismiss losses here, they cannot be generated from withdrawal
            // but it is possible for the strategy to unwind full position
            (amountAvailable, ) = liquidatePosition(amountRequired);

            // Don't do a redundant adjustment in adjustPosition
            alreadyAdjusted = true;

            if (amountAvailable >= amountRequired) {
                _debtPayment = _debtOutstanding;
                // profit remains unchanged unless there is not enough to pay it
                if (amountRequired.sub(_debtPayment) < _profit) {
                    _profit = amountRequired.sub(_debtPayment);
                }
            } else {
                // we were not able to free enough funds
                if (amountAvailable < _debtOutstanding) {
                    // available funds are lower than the repayment that we need to do
                    _profit = 0;
                    _debtPayment = amountAvailable;
                    // we dont report losses here as the strategy might not be able to return in this harvest
                    // but it will still be there for the next harvest
                } else {
                    // NOTE: amountRequired is always equal or greater than _debtOutstanding
                    // important to use amountRequired just in case amountAvailable is > amountAvailable
                    _debtPayment = _debtOutstanding;
                    _profit = amountAvailable.sub(_debtPayment);
                }
            }
        } else {
            _debtPayment = _debtOutstanding;
            // profit remains unchanged unless there is not enough to pay it
            if (amountRequired.sub(_debtPayment) < _profit) {
                _profit = amountRequired.sub(_debtPayment);
            }
        }
    }

    function adjustPosition(uint256 _debtOutstanding) internal override {
        if (alreadyAdjusted) {
            alreadyAdjusted = false; // reset for next time
            return;
        }

        uint256 wantBalance = balanceOfWant();
        // deposit available want as collateral
        if (wantBalance > _debtOutstanding && wantBalance.sub(_debtOutstanding) > minWant) {
            _depositCollateral(wantBalance.sub(_debtOutstanding));
            // we update the value
            wantBalance = balanceOfWant();
        }
        // check current position
        uint256 currentCollatRatio = getCurrentCollatRatio();

        // Either we need to free some funds OR we want to be max levered
        if (_debtOutstanding > wantBalance) {
            // we should free funds
            uint256 amountRequired = _debtOutstanding.sub(wantBalance);

            // NOTE: vault will take free funds during the next harvest
            _freeFunds(amountRequired);
        } else if (currentCollatRatio < targetCollatRatio) {
            // we should lever up
            if (targetCollatRatio.sub(currentCollatRatio) > minRatio) {
                // we only act on relevant differences
                _leverMax();
            }
        } else if (currentCollatRatio > targetCollatRatio) {
            if (currentCollatRatio.sub(targetCollatRatio) > minRatio) {
                (uint256 deposits, uint256 borrows) = getCurrentPosition();
                uint256 newBorrow = getBorrowFromSupply(deposits.sub(borrows), targetCollatRatio);
                _leverDownTo(newBorrow, borrows);
            }
        }
    }

    function liquidatePosition(uint256 _amountNeeded) internal override returns (uint256 _liquidatedAmount, uint256 _loss) {
        // NOTE: Maintain invariant `want.balanceOf(this) >= _liquidatedAmount`
        // NOTE: Maintain invariant `_liquidatedAmount + _loss <= _amountNeeded`
        uint256 wantBalance = balanceOfWant();
        if (wantBalance > _amountNeeded) {
            // if there is enough free want, let's use it
            return (_amountNeeded, 0);
        }

        // we need to free funds
        uint256 amountRequired = _amountNeeded.sub(wantBalance);
        _freeFunds(amountRequired);

        uint256 freeAssets = balanceOfWant();
        if (_amountNeeded > freeAssets) {
            _liquidatedAmount = freeAssets;
            _loss = _amountNeeded.sub(freeAssets);
        } else {
            _liquidatedAmount = _amountNeeded;
        }
    }

    function tendTrigger(uint256 gasCost) public view override returns (bool) {
        if (harvestTrigger(gasCost)) {
            //harvest takes priority
            return false;
        }
        // pull the liquidation liquidationThreshold from aave to be extra safu
        (, uint256 liquidationThreshold) = getProtocolCollatRatios();

        uint256 currentCollatRatio = getCurrentCollatRatio();

        if (currentCollatRatio >= liquidationThreshold) {
            return true;
        }

        return (liquidationThreshold.sub(currentCollatRatio) <= LIQUIDATION_WARNING_THRESHOLD);
    }

    function liquidateAllPositions() internal override returns (uint256 _amountFreed) {
        (_amountFreed, ) = liquidatePosition(type(uint256).max);
    }

    function prepareMigration(address _newStrategy) internal override {
        require(getCurrentSupply() < minWant);
    }

    function protectedTokens() internal view override returns (address[] memory) {}

    //emergency function that we can use to deleverage manually if something is broken
    function manualDeleverage(uint256 amount) external onlyVaultManagers {
        _withdrawCollateral(amount);
        _repayWant(amount);
    }

    //emergency function that we can use to deleverage manually if something is broken
    function manualReleaseWant(uint256 amount) external onlyVaultManagers {
        _withdrawCollateral(amount);
    }

    // emergency function that we can use to sell rewards if something is broken
    function manualClaimAndSellRewards() external onlyVaultManagers {
        _claimAndSellRewards();
    }

    // INTERNAL ACTIONS

    function _claimAndSellRewards() internal {
        // claim the rewards
        incentivesController.claimRewards(getAaveAssets(), type(uint256).max, address(this));

        if (rewardToken != address(want)) {
            uint256 rewardTokenBalance = balanceOfRewardToken();
            if (rewardTokenBalance >= minRewardToSell) {
                _sellRewardTokenForWant(rewardTokenBalance, 0);
            }
        }

        return;
    }

    function _freeFunds(uint256 amountToFree) internal returns (uint256) {
        if (amountToFree == 0) return 0;

        (uint256 deposits, uint256 borrows) = getCurrentPosition();

        uint256 realAssets = deposits.sub(borrows);
        uint256 amountRequired = Math.min(amountToFree, realAssets);
        uint256 newSupply = realAssets.sub(amountRequired);
        uint256 newBorrow = getBorrowFromSupply(newSupply, targetCollatRatio);

        // repay required amount
        _leverDownTo(newBorrow, borrows);

        return balanceOfWant();
    }

    function _leverMax() internal {
        (uint256 deposits, uint256 borrows) = getCurrentPosition();

        // NOTE: decimals should cancel out
        uint256 realSupply = deposits.sub(borrows);
        uint256 newBorrow = getBorrowFromSupply(realSupply, targetCollatRatio);
        uint256 totalAmountToBorrow = newBorrow.sub(borrows);

        for (uint8 i = 0; i < maxIterations && totalAmountToBorrow > minWant; i++) {
            totalAmountToBorrow = totalAmountToBorrow.sub(_leverUpStep(totalAmountToBorrow));
        }
    }

    function _leverUpStep(uint256 amount) internal returns (uint256) {
        if (amount == 0) {
            return 0;
        }

        uint256 wantBalance = balanceOfWant();

        // calculate how much borrow can I take
        (uint256 deposits, uint256 borrows) = getCurrentPosition();
        uint256 canBorrow = getBorrowFromDeposit(deposits.add(wantBalance), maxBorrowCollatRatio);

        if (canBorrow <= borrows) {
            return 0;
        }
        canBorrow = canBorrow.sub(borrows);

        if (canBorrow < amount) {
            amount = canBorrow;
        }

        // deposit available want as collateral
        _depositCollateral(wantBalance);

        // borrow available amount
        _borrowWant(amount);

        return amount;
    }

    function _leverDownTo(uint256 newAmountBorrowed, uint256 currentBorrowed) internal {
        if (newAmountBorrowed >= currentBorrowed) {
            // we don't need to repay
            return;
        }

        uint256 totalRepayAmount = currentBorrowed.sub(newAmountBorrowed);

        for (uint8 i = 0; i < maxIterations && totalRepayAmount > minWant; i++) {
            uint256 toRepay = totalRepayAmount;
            uint256 wantBalance = balanceOfWant();
            if (toRepay > wantBalance) {
                toRepay = wantBalance;
            }
            uint256 repaid = _repayWant(toRepay);
            totalRepayAmount = totalRepayAmount.sub(repaid);
            // withdraw collateral
            _withdrawExcessCollateral();
        }

        // deposit back to get targetCollatRatio (we always need to leave this in this ratio)
        (uint256 deposits, uint256 borrows) = getCurrentPosition();
        uint256 targetDeposit = getDepositFromBorrow(borrows, targetCollatRatio);
        if (targetDeposit > deposits) {
            uint256 toDeposit = targetDeposit.sub(deposits);
            if (toDeposit > minWant) {
                _depositCollateral(Math.min(toDeposit, balanceOfWant()));
            }
        }

        return;
    }

    function _withdrawExcessCollateral() internal returns (uint256 amount) {
        (uint256 deposits, uint256 borrows) = getCurrentPosition();
        uint256 theoDeposits = getDepositFromBorrow(borrows, maxCollatRatio);
        if (deposits > theoDeposits) {
            uint256 toWithdraw = deposits.sub(theoDeposits);
            return _withdrawCollateral(toWithdraw);
        }
    }

    function _depositCollateral(uint256 amount) internal returns (uint256) {
        if (amount == 0) return 0;
        lendingPool.deposit(address(want), amount, address(this), referral);
        return amount;
    }

    function _withdrawCollateral(uint256 amount) internal returns (uint256) {
        if (amount == 0) return 0;
        lendingPool.withdraw(address(want), amount, address(this));
        return amount;
    }

    function _repayWant(uint256 amount) internal returns (uint256) {
        if (amount == 0) return 0;
        return lendingPool.repay(address(want), amount, 2, address(this));
    }

    function _borrowWant(uint256 amount) internal returns (uint256) {
        if (amount == 0) return 0;
        lendingPool.borrow(address(want), amount, 2, referral, address(this));
        return amount;
    }

    // INTERNAL VIEWS
    function balanceOfWant() internal view returns (uint256) {
        return want.balanceOf(address(this));
    }

    function balanceOfAToken() internal view returns (uint256) {
        return aToken.balanceOf(address(this));
    }

    function balanceOfDebtToken() internal view returns (uint256) {
        return debtToken.balanceOf(address(this));
    }

    function balanceOfRewardToken() internal view returns (uint256) {
        return IERC20(rewardToken).balanceOf(address(this));
    }

    function getCurrentPosition() public view returns (uint256 deposits, uint256 borrows) {
        deposits = balanceOfAToken();
        borrows = balanceOfDebtToken();
    }

    function getCurrentCollatRatio() public view returns (uint256 currentCollatRatio) {
        (uint256 deposits, uint256 borrows) = getCurrentPosition();

        if (deposits > 0) {
            currentCollatRatio = borrows.mul(COLLATERAL_RATIO_PRECISION).div(deposits);
        }
    }

    function getCurrentSupply() public view returns (uint256) {
        (uint256 deposits, uint256 borrows) = getCurrentPosition();
        return deposits.sub(borrows);
    }

    // conversions
    function tokenToWant(address token, uint256 amount) internal view returns (uint256) {
        if (amount == 0 || address(want) == token) {
            return amount;
        }

        // KISS: just use a v2 router for quotes which aren't used in critical logic
        IUniLikeSwapRouter router = swapRouter == SwapRouter.Primary ? PRIMARY_ROUTER : SECONDARY_ROUTER;

        uint256[] memory amounts = router.getAmountsOut(amount, getTokenOutPathV2(token, address(want)));

        return amounts[amounts.length - 1];
    }

    function nativeToWant(uint256 _amtInWei) public view override returns (uint256) {
        return tokenToWant(wrappedNative, _amtInWei);
    }

    function getTokenOutPathV2(address _token_in, address _token_out) internal pure returns (address[] memory _path) {
        bool is_wrapped_native = _token_in == address(wrappedNative) || _token_out == address(wrappedNative);

        _path = new address[](is_wrapped_native ? 2 : 3);
        _path[0] = _token_in;

        if (is_wrapped_native) {
            _path[1] = _token_out;
        } else {
            _path[1] = address(wrappedNative);
            _path[2] = _token_out;
        }
    }

    function _sellRewardTokenForWant(uint256 amountIn, uint256 minOut) internal {
        if (amountIn == 0) {
            return;
        }

        IUniLikeSwapRouter router = swapRouter == SwapRouter.Primary ? PRIMARY_ROUTER : SECONDARY_ROUTER;

        router.swapExactTokensForTokens(amountIn, minOut, getTokenOutPathV2(address(rewardToken), address(want)), address(this), now);
    }

    function getAaveAssets() internal view returns (address[] memory assets) {
        assets = new address[](2);
        assets[0] = address(aToken);
        assets[1] = address(debtToken);
    }

    function getProtocolCollatRatios() internal view returns (uint256 ltv, uint256 liquidationThreshold) {
        (, ltv, liquidationThreshold, , , , , , , ) = protocolDataProvider.getReserveConfigurationData(address(want));
        // convert bps to wad
        ltv = ltv.mul(BPS_WAD_RATIO);
        liquidationThreshold = liquidationThreshold.mul(BPS_WAD_RATIO);
    }

    function getBorrowFromDeposit(uint256 deposit, uint256 collatRatio) internal pure returns (uint256) {
        return deposit.mul(collatRatio).div(COLLATERAL_RATIO_PRECISION);
    }

    function getDepositFromBorrow(uint256 borrow, uint256 collatRatio) internal pure returns (uint256) {
        return borrow.mul(COLLATERAL_RATIO_PRECISION).div(collatRatio);
    }

    function getBorrowFromSupply(uint256 supply, uint256 collatRatio) internal pure returns (uint256) {
        return supply.mul(collatRatio).div(COLLATERAL_RATIO_PRECISION.sub(collatRatio));
    }

    function approveMaxSpend(address token, address spender) internal {
        IERC20(token).safeApprove(spender, type(uint256).max);
    }
}
