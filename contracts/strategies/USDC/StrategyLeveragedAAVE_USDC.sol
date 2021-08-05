pragma solidity >=0.6.0 <0.7.0;
pragma experimental ABIEncoderV2;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import "@openzeppelin/contracts/token/ERC20/SafeERC20.sol";
import "@openzeppelin/contracts/math/SafeMath.sol";
import "@aave/contracts/interfaces/ILendingPool.sol";
import "@aave/contracts/interfaces/ILendingPoolAddressesProvider.sol";
import "@aave/contracts/protocol/libraries/types/DataTypes.sol";
import "@aave/contracts/interfaces/IPriceOracle.sol";
import "../../BaseStrategy.sol";
import "../../interfaces/IQuickSwapRouter.sol";
import "../../interfaces/IAaveIncentivesControllerExtended.sol";

contract StrategyLeveragedAAVE_USDC is BaseStrategy {
    using SafeERC20 for IERC20;
    using Address for address;
    using SafeMath for uint256;

    ILendingPoolAddressesProvider public constant ADDRESS_PROVIDER =
        ILendingPoolAddressesProvider(0xd05e3E715d945B59290df0ae8eF85c1BdB684744);

    IERC20 public immutable aToken;
    IERC20 public immutable vToken;
    ILendingPool public immutable LENDING_POOL;

    uint256 public immutable DECIMALS; // For toMATIC conversion

    // Hardhcoded from the Liquidity Mining docs: https://docs.aave.com/developers/guides/liquidity-mining
    IAaveIncentivesControllerExtended public constant INCENTIVES_CONTROLLER =
        IAaveIncentivesControllerExtended(0x357D51124f59836DeD84c8a1730D72B749d8BC23);

    // For Swapping
    IQuickSwapRouter public constant ROUTER =
        IQuickSwapRouter(0xa5E0829CaCEd8fFDD4De3c43696c57F7D7A678ff);

    IERC20 public constant WMATIC_TOKEN =
        IERC20(0x0d500B1d8E8eF31E21C99d1Db9A6444d3ADf1270);

    uint256 public minWMATICToWantPrice = 8000; // 80% // Seems like Oracle is slightly off

    // Should we harvest before prepareMigration
    bool public harvestBeforeMigrate = true;

    // Should we ensure the swap will be within slippage params before performing it during normal harvest?
    bool public checkSlippageOnHarvest = true;

    // Leverage
    uint256 public constant MAX_BPS = 10000;
    uint256 public minHealth = 1080000000000000000; // 1.08 with 18 decimals this is slighly above 70% tvl
    uint256 public minRebalanceAmount = 10000000; // 10$, should be changed based on decimals (usdc has 6)

    constructor(address _vault) public BaseStrategy(_vault) {
        // You can set these parameters on deployment to whatever you want
        maxReportDelay = 6300;
        profitFactor = 100;
        debtThreshold = 0;

        // Get lending Pool
        ILendingPool lendingPool =
            ILendingPool(ADDRESS_PROVIDER.getLendingPool());

        // Set lending pool as immutable
        LENDING_POOL = lendingPool;

        // Get Tokens Addresses
        DataTypes.ReserveData memory data =
            lendingPool.getReserveData(address(want));

        // Get aToken
        aToken = IERC20(data.aTokenAddress);

        // Get vToken
        vToken = IERC20(data.variableDebtTokenAddress);

        // Get Decimals
        DECIMALS = ERC20(address(want)).decimals();

        want.safeApprove(address(lendingPool), type(uint256).max);
        WMATIC_TOKEN.safeApprove(address(ROUTER), type(uint256).max);
    }

    function setMinHealth(uint256 newMinHealth) external onlyKeepers {
        require(newMinHealth >= 1000000000000000000, "Need higher health");
        minHealth = newMinHealth;
    }

    function setMinRebalanceAmount(uint256 newMinRebalanceAmount) external onlyKeepers {
        minRebalanceAmount = newMinRebalanceAmount;
    }

    function setHarvestBeforeMigrate(bool newHarvestBeforeMigrate)
    external
    onlyKeepers
    {
        harvestBeforeMigrate = newHarvestBeforeMigrate;
    }

    function setCheckSlippageOnHarvest(bool newCheckSlippageOnHarvest)
    external
    onlyKeepers
    {
        checkSlippageOnHarvest = newCheckSlippageOnHarvest;
    }

    function setMinPrice(uint256 newMinWMATICToWantPrice) external onlyKeepers {
        require(newMinWMATICToWantPrice >= 0 && newMinWMATICToWantPrice <= MAX_BPS);
        minWMATICToWantPrice = newMinWMATICToWantPrice;
    }

    // ******** OVERRIDE THESE METHODS FROM BASE CONTRACT ************

    function name() external view override returns (string memory) {
        // Add your own name here, suggestion e.g. "StrategyCreamYFI"
        return "Strategy-Levered-AAVE-USDC";
    }

    function estimatedTotalAssets() public view override returns (uint256) {
        // Balance of want + balance in AAVE
        uint256 liquidBalance =
        want.balanceOf(address(this)).add(deposited()).sub(borrowed());

        // Return balance + reward
        return liquidBalance.add(valueOfRewards());
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
        // NOTE: This means that if we are paying back we just deleverage
        // While if we are not paying back, we are harvesting rewards
        if (_debtOutstanding > 0) {
            // Withdraw and Repay
            uint256 toWithdraw = _debtOutstanding;

            // Get it all out
            _divestFromAAVE();

            // Get rewards
            _claimRewardsAndGetMoreWant();

            // Repay debt
            uint256 maxRepay = want.balanceOf(address(this));
            if (_debtOutstanding > maxRepay) {
                // we can't pay all, means we lost some
                _loss = _debtOutstanding.sub(maxRepay);
                _debtPayment = maxRepay;
            } else {
                // We can pay all, let's do it
                _debtPayment = toWithdraw;
            }
        } else {
            // Do normal Harvest
            _debtPayment = 0;

            // Get current amount of want // used to estimate profit
            uint256 beforeBalance = want.balanceOf(address(this));

            // Claim WMATIC -> swap into want
            _claimRewardsAndGetMoreWant();

            (uint256 earned, uint256 lost) = _repayAAVEBorrow(beforeBalance);

            _profit = earned;
            _loss = lost;
        }
    }

    function _repayAAVEBorrow(uint256 beforeBalance)
    internal
    returns (uint256 _profit, uint256 _loss)
    {
        uint256 afterSwapBalance = want.balanceOf(address(this));
        uint256 wantFromSwap = afterSwapBalance.sub(beforeBalance);

        // Calculate Gain from AAVE interest // NOTE: This should never happen as we take more debt than we earn
        uint256 currentWantInAave = deposited().sub(borrowed());
        uint256 initialDeposit = vault.strategies(address(this)).totalDebt;
        if (currentWantInAave > initialDeposit) {
            uint256 interestProfit = currentWantInAave.sub(initialDeposit);
            LENDING_POOL.withdraw(address(want), interestProfit, address(this));
            // Withdraw interest of aToken so that now we have exactly the same amount
        }

        uint256 afterBalance = want.balanceOf(address(this));
        uint256 wantEarned = afterBalance.sub(beforeBalance); // Earned before repaying debt

        // Pay off any debt
        // Debt is equal to negative of canBorrow
        uint256 toRepay = debtBelowHealth();
        if (toRepay > wantEarned) {
            // We lost some money

            // Repay all we can, rest is loss
            LENDING_POOL.repay(address(want), wantEarned, 2, address(this));

            _loss = toRepay.sub(wantEarned);

            // Notice that once the strats starts loosing funds here, you should probably retire it as it's not profitable
        } else {
            // We made money or are even

            // Let's repay the debtBelowHealth
            uint256 repaid = toRepay;

            _profit = wantEarned.sub(repaid);

            if (repaid > 0) {
                LENDING_POOL.repay(address(want), repaid, 2, address(this));
            }
        }
    }

    function adjustPosition(uint256 _debtOutstanding) internal override {
        // TODO: Do something to invest excess `want` tokens (from the Vault) into your positions
        // NOTE: Try to adjust positions so that `_debtOutstanding` can be freed up on *next* harvest (not immediately)
        uint256 wantAvailable = want.balanceOf(address(this));
        if (wantAvailable > _debtOutstanding) {
            uint256 toDeposit = wantAvailable.sub(_debtOutstanding);
            LENDING_POOL.deposit(address(want), toDeposit, address(this), 0);

            // Lever up
            _invest();
        }
    }

    function balanceOfRewards() public view returns (uint256) {
        // Get rewards
        address[] memory assets = new address[](2);
        assets[0] = address(aToken);
        assets[1] = address(vToken);

        uint256 totalRewards =
            INCENTIVES_CONTROLLER.getRewardsBalance(assets, address(this));
        return totalRewards;
    }

    function valueOfRewards() public view returns (uint256) {
        return maticToWant(balanceOfRewards());
    }

    // Get WMATIC
    function _claimRewards() internal {
        // Get rewards
        address[] memory assets = new address[](2);
        assets[0] = address(aToken);
        assets[1] = address(vToken);

        // Get Rewards, withdraw all
        INCENTIVES_CONTROLLER.claimRewards(
            assets,
            type(uint256).max,
            address(this)
        );
    }

    function _fromMATICToWant(uint256 amountIn, uint256 minOut) internal {
        address[] memory path = new address[](2);
        path[0] = address(WMATIC_TOKEN);
        path[1] = address(want);

        ROUTER.swapExactTokensForTokens(
            amountIn,
            minOut,
            path,
            address(this),
            now
        );
    }

    function _claimRewardsAndGetMoreWant() internal {
        _claimRewards();

        uint256 rewardsAmount = WMATIC_TOKEN.balanceOf(address(this));

        if (rewardsAmount == 0) {
            return;
        }

        // Specify a min out
        uint256 minWMATICOut = rewardsAmount.mul(minWMATICToWantPrice).div(MAX_BPS);

        uint256 maticToSwap = WMATIC_TOKEN.balanceOf(address(this));

        uint256 minWantOut = 0;
        if (checkSlippageOnHarvest) {
            minWantOut = maticToWant(maticToSwap)
            .mul(minWMATICToWantPrice)
            .div(MAX_BPS);
        }

        _fromMATICToWant(maticToSwap, minWantOut);
    }

    function liquidatePosition(uint256 _amountNeeded)
    internal
    override
    returns (uint256 _liquidatedAmount, uint256 _loss)
    {
        // TODO: Do stuff here to free up to `_amountNeeded` from all positions back into `want`
        // NOTE: Maintain invariant `want.balanceOf(this) >= _liquidatedAmount`
        // NOTE: Maintain invariant `_liquidatedAmount + _loss <= _amountNeeded`

        // Lever Down
        _divestFromAAVE();

        uint256 totalAssets = want.balanceOf(address(this));
        if (_amountNeeded > totalAssets) {
            _liquidatedAmount = totalAssets;
            _loss = _amountNeeded.sub(totalAssets);
        } else {
            _liquidatedAmount = _amountNeeded;
        }
    }

    // Withdraw all from AAVE Pool
    function liquidateAllPositions() internal override returns (uint256) {
        // Repay all debt and divest
        _divestFromAAVE();

        // Get rewards before leaving
        _claimRewardsAndGetMoreWant();

        // Return amount freed
        return want.balanceOf(address(this));
    }

    // NOTE: Can override `tendTrigger` and `harvestTrigger` if necessary

    function prepareMigration(address _newStrategy) internal override {
        // TODO: Transfer any non-`want` tokens to the new strategy
        // NOTE: `migrate` will automatically forward all `want` in this strategy to the new one
        // This is gone if we use upgradeable

        //Divest all
        _divestFromAAVE();

        if (harvestBeforeMigrate) {
            // Harvest rewards one last time
            _claimRewardsAndGetMoreWant();
        }

        // Just in case we don't fully liquidate to want
        if (aToken.balanceOf(address(this)) > 0) {
            aToken.safeTransfer(_newStrategy, aToken.balanceOf(address(this)));
        }

        if (WMATIC_TOKEN.balanceOf(address(this)) > 0) {
            WMATIC_TOKEN.safeTransfer(_newStrategy, WMATIC_TOKEN.balanceOf(address(this)));
        }
    }

    // Override this to add all tokens/tokenized positions this contract manages
    // on a *persistent* basis (e.g. not just for swapping back to want ephemerally)
    // NOTE: Do *not* include `want`, already included in `sweep` below
    //
    // Example:
    //
    //    function protectedTokens() internal override view returns (address[] memory) {
    //      address[] memory protected = new address[](3);
    //      protected[0] = tokenA;
    //      protected[1] = tokenB;
    //      protected[2] = tokenC;
    //      return protected;
    //    }
    function protectedTokens()
    internal
    view
    override
    returns (address[] memory)
    {
        address[] memory protected = new address[](2);
        protected[0] = address(aToken);
        protected[1] = address(WMATIC_TOKEN);
        return protected;
    }

    /**
     * @notice
     *  Provide an accurate conversion from `_amtInWei` (denominated in wei)
     *  to `want` (using the native decimal characteristics of `want`).
     * @dev
     *  Care must be taken when working with decimals to assure that the conversion
     *  is compatible. As an example:
     *
     *      given 1e17 wei (0.1 MATIC) as input, and want is USDC (6 decimals),
     *      with USDC/MATIC = 1800, this should give back 1800000000 (180 USDC)
     *
     * @param _amtInWei The amount (in wei/1e-18 ETH) to convert to `want`
     * @return The amount in `want` of `_amtInEth` converted to `want`
     **/
    function maticToWant(uint256 _amtInWei)
    public
    view
    virtual
    override
    returns (uint256)
    {
        address priceOracle = ADDRESS_PROVIDER.getPriceOracle();
        uint256 priceInMATIC =
            IPriceOracle(priceOracle).getAssetPrice(address(want));

        // Opposite of priceInMATIC
        // Multiply first to keep rounding
        uint256 priceInWant = _amtInWei.mul(10**DECIMALS).div(priceInMATIC);

        return priceInWant;
    }

    /* Leverage functions */
    function deposited() public view returns (uint256) {
        return aToken.balanceOf(address(this));
    }

    function borrowed() public view returns (uint256) {
        return vToken.balanceOf(address(this));
    }

    // What should we repay?
    function debtBelowHealth() public view returns (uint256) {
        (
        uint256 totalCollateralETH,
        uint256 totalDebtETH,
        uint256 availableBorrowsETH,
        uint256 currentLiquidationThreshold,
        uint256 ltv,
        uint256 healthFactor
        ) = LENDING_POOL.getUserAccountData(address(this));

        // How much did we go off of minHealth? //NOTE: We always borrow as much as we can
        uint256 maxBorrow = deposited().mul(ltv).div(MAX_BPS);

        if (healthFactor < minHealth && borrowed() > maxBorrow) {
            uint256 maxValue = borrowed().sub(maxBorrow);

            return maxValue;
        }

        return 0;
    }

    // NOTE: We always borrow max, no fucks given
    function canBorrow() public view returns (uint256) {
        (
        uint256 totalCollateralETH,
        uint256 totalDebtETH,
        uint256 availableBorrowsETH,
        uint256 currentLiquidationThreshold,
        uint256 ltv,
        uint256 healthFactor
        ) = LENDING_POOL.getUserAccountData(address(this));

        if (healthFactor > minHealth) {
            // Amount = deposited * ltv - borrowed
            // Div MAX_BPS because because ltv / maxbps is the percent
            uint256 maxValue =
                deposited().mul(ltv).div(MAX_BPS).sub(borrowed());

            // Don't borrow if it's dust, save gas
            if (maxValue < minRebalanceAmount) {
                return 0;
            }

            return maxValue;
        }

        return 0;
    }

    function _invest() internal {
        // Loop on it until it's properly done
        uint256 max_iterations = 5;
        for (uint256 i = 0; i < max_iterations; i++) {
            uint256 toBorrow = canBorrow();
            if (toBorrow > 0) {
                LENDING_POOL.borrow(
                    address(want),
                    toBorrow,
                    2,
                    0,
                    address(this)
                );

                LENDING_POOL.deposit(address(want), toBorrow, address(this), 0);
            } else {
                break;
            }
        }
    }

    // Divest all from AAVE, awful gas, but hey, it works
    function _divestFromAAVE() internal {
        uint256 repayAmount = canRepay(); // The "unsafe" (below target health) you can withdraw

        // Loop to withdraw until you have the amount you need
        while (repayAmount != uint256(-1)) {
            _withdrawStepFromAAVE(repayAmount);
            repayAmount = canRepay();
        }
        if (deposited() > 0) {
            // Withdraw the rest here
            LENDING_POOL.withdraw(
                address(want),
                type(uint256).max,
                address(this)
            );
        }
    }

    // Withdraw and Repay AAVE Debt
    function _withdrawStepFromAAVE(uint256 canRepay) internal {
        if (canRepay > 0) {
            //Repay this step
            LENDING_POOL.withdraw(address(want), canRepay, address(this));
            LENDING_POOL.repay(address(want), canRepay, 2, address(this));
        }
    }

    // returns 95% of the collateral we can withdraw from aave, used to loop and repay debts
    function canRepay() public view returns (uint256) {
        (
        uint256 totalCollateralETH,
        uint256 totalDebtETH,
        uint256 availableBorrowsETH,
        uint256 currentLiquidationThreshold,
        uint256 ltv,
        uint256 healthFactor
        ) = LENDING_POOL.getUserAccountData(address(this));

        uint256 aBalance = deposited();
        uint256 vBalance = borrowed();

        if (vBalance == 0) {
            return uint256(-1); //You have repaid all
        }

        uint256 diff =
        aBalance.sub(vBalance.mul(10000).div(currentLiquidationThreshold));
        uint256 inWant = diff.mul(95).div(100); // Take 95% just to be safe

        return inWant;
    }

    /** Manual Functions */

    /** Leverage Manual Functions */
    // Emergency function to immediately deleverage to 0
    function manualDivestFromAAVE() public onlyVaultManagers {
        _divestFromAAVE();
    }

    // Manually perform 5 loops to lever up
    // Safe because it's capped by canBorrow
    function manualLeverUp() public onlyVaultManagers {
        _invest();
    }

    // Emergency function that we can use to deleverage manually if something is broken
    // If something goes wrong, just try smaller and smaller can repay amounts
    function manualWithdrawStepFromAAVE(uint256 toRepay)
    public
    onlyVaultManagers
    {
        _withdrawStepFromAAVE(toRepay);
    }

    // Take some funds from manager and use them to repay
    // Useful if you ever go below 1 HF and somehow you didn't get liquidated
    function manualRepayFromManager(uint256 toRepay) public onlyVaultManagers {
        want.safeTransferFrom(msg.sender, address(this), toRepay);
        LENDING_POOL.repay(address(want), toRepay, 2, address(this));
    }

    /** DCA Manual Functions */

    // Get the rewards
    function manualClaimRewards() public onlyVaultManagers {
        _claimRewards();
    }

    // Swap from AAVE to Want
    ///@param amountToSwap Amount of AAVE to Swap, NOTE: You have to calculate the amount!!
    ///@param multiplierInWei pricePerToken including slippage, will be divided by 10 ** 18
    function manualSwapFromMATICToWant(
        uint256 amountToSwap,
        uint256 multiplierInWei
    ) public onlyVaultManagers {
        uint256 amountOutMinimum =
        amountToSwap.mul(multiplierInWei).div(10**18);

        _fromMATICToWant(amountToSwap, amountOutMinimum);
    }
}
