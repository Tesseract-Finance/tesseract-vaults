// SPDX-License-Identifier: GNU Affero

pragma solidity >=0.6.0 <0.7.0;
pragma experimental ABIEncoderV2;

import { BaseStrategy } from "../BaseStrategy.sol";
import { SafeERC20, SafeMath, IERC20, Address } from "@openzeppelin/contracts/token/ERC20/SafeERC20.sol";
import "@openzeppelin/contracts/math/Math.sol";
import "../interfaces/curve/IGauge.sol";
import "../interfaces/curve/IStableSwap.sol";
import { IERC20Metadata } from "../interfaces/IERC.sol";
import {IUniLikeSwapRouter} from "../interfaces/IUniLikeSwapRouter.sol";

abstract contract CurveStable is BaseStrategy {
    using SafeERC20 for IERC20;
    using Address for address;
    using SafeMath for uint256;

    address public constant voter = address(0x710295b5f326c2e47E6dD2E7F6b5b0F7c5AC2F24); // sms

    address public constant crv = address(0x172370d5Cd63279eFa6d502DAB29171933a610AF);
    address public constant dai = address(0x8f3Cf7ad23Cd3CaDbD9735AFf958023239c6A063);
    address public constant usdc = address(0x2791Bca1f2de4661ED88A30C99A7a9449Aa84174);
    address public constant usdt = address(0xc2132D05D31c914a87C6611C10748AEb04B58e8F);
    address public constant wbtc = address(0x1BFD67037B42Cf73acF2047067bd4F2C47D9BfD6);
    address public constant weth = address(0x7ceB23fD6bC0adD59E62ac25578270cFf1b9f619);
    address public constant wmatic = address(0x0d500B1d8E8eF31E21C99d1Db9A6444d3ADf1270);

    address public constant sushiswap = address(0x1b02dA8Cb0d097eB8D57A175b88c7D8b47997506);

    uint256 public constant DENOMINATOR = 10000;

    address[] public dex;
    address public curve;
    address public gauge;
    uint256 public keepCRV;

    constructor(address _vault) public BaseStrategy(_vault) {
        minReportDelay = 6 hours;
        maxReportDelay = 2 days;
        profitFactor = 1;
        debtThreshold = 1e24;
    }

    function _approveBasic() internal virtual {
        want.safeApprove(gauge, 0);
        want.safeApprove(gauge, type(uint256).max);
        IERC20(dai).safeApprove(curve, 0);
        IERC20(dai).safeApprove(curve, type(uint256).max);
        IERC20(usdc).safeApprove(curve, 0);
        IERC20(usdc).safeApprove(curve, type(uint256).max);
        IERC20(usdt).safeApprove(curve, 0);
        IERC20(usdt).safeApprove(curve, type(uint256).max);
        IERC20(wbtc).safeApprove(curve, 0);
        IERC20(wbtc).safeApprove(curve, type(uint256).max);
        IERC20(weth).safeApprove(curve, 0);
        IERC20(weth).safeApprove(curve, type(uint256).max);
    }

    function _approveDex() internal virtual {
        IERC20(crv).approve(dex[0], 0);
        IERC20(crv).approve(dex[0], type(uint256).max);
    }

    function approveAll() external onlyAuthorized {
        _approveBasic();
        _approveDex();
    }

    function setKeepCRV(uint256 _keepCRV) external onlyAuthorized {
        keepCRV = _keepCRV;
    }

    function switchDex(uint256 _id, address _dex) external onlyAuthorized {
        require(_dex == sushiswap, "!dex");
        dex[_id] = _dex;
        _approveDex();
    }

    function name() external view override returns (string memory) {
        return string(abi.encodePacked("Curve", IERC20Metadata(address(want)).symbol()));
    }

    function balanceOfWant() public view returns (uint256) {
        return want.balanceOf(address(this));
    }

    function balanceOfPool() public view returns (uint256) {
        return IGauge(gauge).balanceOf(address(this));
    }

    function estimatedTotalAssets() public view override returns (uint256) {
        return balanceOfWant().add(balanceOfPool());
    }

    function nativeToWant(uint256 _amtInWei) public view override returns (uint256) {
        address[] memory path = new address[](2);
        path[0] = wmatic;
        path[1] = usdc;
        uint256[] memory amounts = IUniLikeSwapRouter(dex[0]).getAmountsOut(_amtInWei, path);
        uint inUSD = amounts[amounts.length - 1].mul(1e12);

        uint wantInUSD = ICurveFi(curve).get_virtual_price();
        return inUSD.mul(1e18).div(wantInUSD);
    }

    function adjustPosition(uint256 _debtOutstanding) internal override {
        uint256 _want = balanceOfWant();
        if (_want > 0) {
            IGauge(gauge).deposit(_want);
        }
    }

    function _withdrawSome(uint256 _amount) internal returns (uint256) {
        _amount = Math.min(_amount, balanceOfPool());
        IGauge(gauge).withdraw(_amount);
        return _amount;
    }

    function liquidatePosition(uint256 _amountNeeded)
    internal
    override
    returns (uint256 _liquidatedAmount, uint256 _loss)
    {
        uint256 _balance = balanceOfWant();
        if (_balance < _amountNeeded) {
            _liquidatedAmount = _withdrawSome(_amountNeeded - _balance);
            _liquidatedAmount = Math.min(_liquidatedAmount.add(_balance), _amountNeeded);
            if (_amountNeeded > _liquidatedAmount) {
                _loss = _amountNeeded - _liquidatedAmount; // this should be 0. o/w there must be an error
            }
        }
        else {
            _liquidatedAmount = _amountNeeded;
        }
    }

    function liquidateAllPositions() internal override returns (uint256 _amountFreed) {
        (_amountFreed, ) = liquidatePosition(vault.strategies(address(this)).totalDebt);
    }

    function prepareMigration(address _newStrategy) internal override {
        uint _balance = IGauge(gauge).balanceOf(address(this));
        IGauge(gauge).withdraw(_balance, true);
        _migrateRewards(_newStrategy);
    }

    function _migrateRewards(address _newStrategy) internal virtual {
        IERC20(crv).safeTransfer(_newStrategy, IERC20(crv).balanceOf(address(this)));
    }

    function _adjustCRV(uint256 _crv) internal returns (uint256) {
        uint256 _keepCRV = _crv.mul(keepCRV).div(DENOMINATOR);
        if (_keepCRV > 0) IERC20(crv).safeTransfer(voter, _keepCRV);
        return _crv.sub(_keepCRV);
    }
}


contract Strategy is CurveStable {
    address[] public pathTarget;
    // address public constant reward = wmatic;

    constructor(address _vault) public CurveStable(_vault) {
        curve = address(0x1d8b86e3D88cDb2d34688e87E72F388Cb541B7C8);
        gauge = address(0x3B6B158A76fd8ccc297538F454ce7B4787778c7C);

        _approveBasic();
        pathTarget = new address[](2);
        _setPathTarget(0, 1); // crv path target
        _setPathTarget(1, 1); // reward path target

        dex = new address[](2);
        dex[0] = sushiswap; // crv
        dex[1] = sushiswap; // reward
        _approveDex();
    }

    // >>> approve other basic usage
    // function _approveBasic() internal override { super._approveBasic(); }

    // >>> approve other rewards on dex
    function _approveDex() internal override {
        super._approveDex();
        IERC20(wmatic).approve(dex[1], 0);
        IERC20(wmatic).approve(dex[1], type(uint256).max);
    }

    // >>> migrate other rewards to newStrategy
    function _migrateRewards(address _newStrategy) internal override {
        super._migrateRewards(_newStrategy);
        IERC20(wmatic).safeTransfer(_newStrategy, IERC20(wmatic).balanceOf(address(this)));
    }

    function _setPathTarget(uint _tokenId, uint _id) internal {
        if (_id == 0) {
            pathTarget[_tokenId] = dai;
        }
        else if (_id == 1) {
            pathTarget[_tokenId] = usdc;
        }
        else {
            pathTarget[_tokenId] = usdt;
        }
    }

    function setPathTarget(uint _tokenId, uint _id) external onlyAuthorized {
        _setPathTarget(_tokenId, _id);
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
        uint before = balanceOfWant();
        IGauge(gauge).claim_rewards();
        uint256 _crv = IERC20(crv).balanceOf(address(this));
        if (_crv > 0) {
            _crv = _adjustCRV(_crv);

            address[] memory path = new address[](3);
            path[0] = crv;
            path[1] = wmatic;
            path[2] = pathTarget[0];

            IUniLikeSwapRouter(dex[0]).swapExactTokensForTokens(_crv, uint256(0), path, address(this), now);
        }
        // >>> claim reward tokens
        // >>> if more than one reward tokens, adding them all here
        // >>> sell all rewards to pathTarget[1]
        uint256 _wmatic = IERC20(wmatic).balanceOf(address(this));
        if (_wmatic > 0) {
            address[] memory path = new address[](2);
            path[0] = wmatic;
            path[1] = pathTarget[1];

            IUniLikeSwapRouter(dex[1]).swapExactTokensForTokens(_wmatic, uint256(0), path, address(this), now);
        }


        uint256 _dai = IERC20(dai).balanceOf(address(this));
        uint256 _usdc = IERC20(usdc).balanceOf(address(this));
        uint256 _usdt = IERC20(usdt).balanceOf(address(this));
        uint256 _wbtc = IERC20(wbtc).balanceOf(address(this));
        uint256 _weth = IERC20(weth).balanceOf(address(this));

        if (_dai > 0 || _usdc > 0 || _usdt > 0 || _wbtc > 0 || _weth > 0) {
            ICurveFi(curve).add_liquidity([_dai, _usdc, _usdt, _wbtc, _weth], 0);
        }


        _profit = balanceOfWant().sub(before);

        uint _total = estimatedTotalAssets();
        uint _debt = vault.strategies(address(this)).totalDebt;
        if(_total < _debt) {
            _loss = _debt - _total;
            _profit = 0;
        }

        if (_debtOutstanding > 0) {
            _withdrawSome(_debtOutstanding);
            _debtPayment = Math.min(_debtOutstanding, balanceOfWant().sub(_profit));
        }
    }

    // NOTE: Can override `tendTrigger` and `harvestTrigger` if necessary

    function protectedTokens()
    internal
    view
    override
    returns (address[] memory)
    {
        address[] memory protected = new address[](2);
        protected[0] = crv;
        protected[1] = wmatic;
        return protected;
    }
}
