// SPDX-License-Identifier: MIT
pragma solidity ^0.6.12;

/*
*
* MIT License
* ===========
*
* Copyright (c) 2021 DotFinance
*
* Permission is hereby granted, free of charge, to any person obtaining a copy
* of this software and associated documentation files (the "Software"), to deal
* in the Software without restriction, including without limitation the rights
* to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
* copies of the Software, and to permit persons to whom the Software is
* furnished to do so, subject to the following conditions:
*
* The above copyright notice and this permission notice shall be included in all
* copies or substantial portions of the Software.
*
* THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
* IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
* FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
* AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
* LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
* OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
*/

import "@pancakeswap/pancake-swap-lib/contracts/token/BEP20/BEP20.sol";
import "@pancakeswap/pancake-swap-lib/contracts/token/BEP20/SafeBEP20.sol";
import "@pancakeswap/pancake-swap-lib/contracts/math/SafeMath.sol";

import "../interfaces/IPinkMinterV1.sol";
import "../interfaces/IStakingRewards.sol";
import "../dashboard/calculator/PriceCalculatorBSC.sol";
import "../zap/ZapBSC.sol";

contract PinkMinterV1 is IPinkMinterV1, OwnableUpgradeable {
    using SafeMath for uint;
    using SafeBEP20 for IBEP20;

    /* ========== CONSTANTS ============= */

    address public constant WBNB = 0xbb4CdB9CBd36B01bD1cBaEBF2De08d9173bc095c;
    address private constant DEAD = 0x000000000000000000000000000000000000dEaD;

    uint public constant FEE_MAX = 10000;

    IPancakeRouter02 private constant routerV1 = IPancakeRouter02(0x05fF2B0DB69458A0750badebc4f9e13aDd608C7F);
    IPancakeRouter02 private constant routerV2 = IPancakeRouter02(0x10ED43C718714eb63d5aA57B78B54704E256024E);

    /* ========== STATE VARIABLES ========== */

    address public pinkChef;
    address public pinkToken;
    address public pinkPool;
    address public pinkBNBPair;
    address public deployer;
    address public timelock;
    ZapBSC public zapBSC;
    PriceCalculatorBSC public priceCalculator;
    mapping(address => bool) private _minters;

    uint public PERFORMANCE_FEE;
    uint public override WITHDRAWAL_FEE_FREE_PERIOD;
    uint public override WITHDRAWAL_FEE;

    uint public override pinkPerProfitBNB;
    uint public pinkPerPinkBNBFlip;   // will be deprecated

    /* ========== MODIFIERS ========== */

    modifier onlyMinter {
        require(isMinter(msg.sender) == true, "PinkMinterV1: caller is not the minter");
        _;
    }

    modifier onlyPinkChef {
        require(msg.sender == pinkChef, "PinkMinterV1: caller not the pink chef");
        _;
    }

    receive() external payable {}

    /* ========== INITIALIZER ========== */

    function initialize(
        address _token,
        address _pool,
        address _pinkBNBPair,
        address _deployer,
        address _timelock,
        address payable _zapBSC,
        address _priceCalculator
    )
        external
        initializer
    {
        require(_token != address(0), "token must be set");
        pinkToken = _token;
        require(_pool != address(0), "pool must be set");
        pinkPool = _pool;
        require(_pinkBNBPair != address(0), "pair must be set");
        pinkBNBPair = _pinkBNBPair;
        require(_deployer != address(0), "deployer must be set");
        deployer = _deployer;
        require(_timelock != address(0), "timelock must be set");
        timelock = _timelock;
        require(_zapBSC != address(0), "zapBSC must be set");
        zapBSC = ZapBSC(_zapBSC);
        require(_priceCalculator != address(0), "priceCalculator must be set");
        priceCalculator = PriceCalculatorBSC(_priceCalculator);
        WITHDRAWAL_FEE_FREE_PERIOD = 3 days;
        WITHDRAWAL_FEE = 50;
        PERFORMANCE_FEE = 3000;

        pinkPerProfitBNB = 6500e18;
        pinkPerPinkBNBFlip = 6e18;

        IBEP20(pinkToken).approve(pinkPool, uint(-1));

        __Ownable_init();
    }

    /* ========== RESTRICTED FUNCTIONS ========== */

    function transferPinkOwner(address _owner) external onlyOwner {
        Ownable(pinkToken).transferOwnership(_owner);
    }

    function setWithdrawalFee(uint _fee) external onlyOwner {
        require(_fee < 500, "wrong fee");
        // less 5%
        WITHDRAWAL_FEE = _fee;
    }

    function setPerformanceFee(uint _fee) external onlyOwner {
        require(_fee < 5000, "wrong fee");
        PERFORMANCE_FEE = _fee;
    }

    function setWithdrawalFeeFreePeriod(uint _period) external onlyOwner {
        WITHDRAWAL_FEE_FREE_PERIOD = _period;
    }

    function setMinter(address minter, bool canMint) external override onlyOwner {
        if (canMint) {
            _minters[minter] = canMint;
        } else {
            delete _minters[minter];
        }
    }

    function setPinkPerProfitBNB(uint _ratio) external onlyOwner {
        pinkPerProfitBNB = _ratio;
    }

    function setPinkPerPinkBNBFlip(uint _pinkPerPinkBNBFlip) external onlyOwner {
        pinkPerPinkBNBFlip = _pinkPerPinkBNBFlip;
    }

    function setPinkChef(address _pinkChef) external onlyOwner {
        require(pinkChef == address(0), "PinkMinterV1: setPinkChef only once");
        pinkChef = _pinkChef;
    }

    /* ========== VIEWS ========== */

    function isMinter(address account) public view override returns (bool) {
        if (IBEP20(pinkToken).getOwner() != address(this)) {
            return false;
        }
        return _minters[account];
    }

    function amountPinkToMint(uint bnbProfit) public view override returns (uint) {
        return bnbProfit.mul(pinkPerProfitBNB).div(1e18);
    }

    function amountPinkToMintForPinkBNB(uint amount, uint duration) public view override returns (uint) {
        return amount.mul(pinkPerPinkBNBFlip).mul(duration).div(365 days).div(1e18);
    }

    function withdrawalFee(uint amount, uint depositedAt) external view override returns (uint) {
        if (depositedAt.add(WITHDRAWAL_FEE_FREE_PERIOD) > block.timestamp) {
            return amount.mul(WITHDRAWAL_FEE).div(FEE_MAX);
        }
        return 0;
    }

    function performanceFee(uint profit) external view override returns (uint) {
        return profit.mul(PERFORMANCE_FEE).div(FEE_MAX);
    }

    /* ========== V1 FUNCTIONS ========== */

    function mintFor(address asset, uint _withdrawalFee, uint _performanceFee, address to, uint) external payable override onlyMinter {
        uint feeSum = _performanceFee.add(_withdrawalFee);
        _transferAsset(asset, feeSum);

        if (asset == pinkToken) {
            IBEP20(pinkToken).safeTransfer(DEAD, feeSum);
            return;
        }

        uint pinkBNBAmount = _zapAssetsToPinkBNB(asset, feeSum, false);
        if (pinkBNBAmount == 0) return;

        IBEP20(pinkBNBPair).safeTransfer(pinkPool, pinkBNBAmount);
        IStakingRewards(pinkPool).notifyRewardAmount(pinkBNBAmount);

        (uint valueInBNB,) = priceCalculator.valueOfAsset(pinkBNBPair, pinkBNBAmount);
        uint contribution = valueInBNB.mul(_performanceFee).div(feeSum);
        uint mintPink = amountPinkToMint(contribution);
        if (mintPink == 0) return;
        _mint(mintPink, to);
    }

    /* ========== PancakeSwap V2 FUNCTIONS ========== */
    // TODO only single mintFor
    function mintForV2(address asset, uint _withdrawalFee, uint _performanceFee, address to, uint) external payable override onlyMinter {
        uint feeSum = _performanceFee.add(_withdrawalFee);
        _transferAsset(asset, feeSum);

        if (asset == pinkToken) {
            IBEP20(pinkToken).safeTransfer(DEAD, feeSum);
            return;
        }

        uint pinkBNBAmount = _zapAssetsToPinkBNB(asset, feeSum, true);
        if (pinkBNBAmount == 0) return;

        IBEP20(pinkBNBPair).safeTransfer(pinkPool, pinkBNBAmount);
        IStakingRewards(pinkPool).notifyRewardAmount(pinkBNBAmount);

        (uint valueInBNB,) = priceCalculator.valueOfAsset(pinkBNBPair, pinkBNBAmount);
        uint contribution = valueInBNB.mul(_performanceFee).div(feeSum);
        uint mintPink = amountPinkToMint(contribution);
        if (mintPink == 0) return;
        _mint(mintPink, to);
    }

    /* ========== PinkChef FUNCTIONS ========== */

    function mint(uint amount) external override onlyPinkChef {
        if (amount == 0) return;
        _mint(amount, address(this));
    }

    function safePinkTransfer(address _to, uint _amount) external override onlyPinkChef {
        if (_amount == 0) return;

        uint bal = IBEP20(pinkToken).balanceOf(address(this));
        if (_amount <= bal) {
            IBEP20(pinkToken).safeTransfer(_to, _amount);
        } else {
            IBEP20(pinkToken).safeTransfer(_to, bal);
        }
    }

    // @dev should be called when determining mint in governance. Pink is transferred to the timelock contract.
    function mintGov(uint amount) external override onlyOwner {
        if (amount == 0) return;
        _mint(amount, timelock);
    }

    /* ========== PRIVATE FUNCTIONS ========== */

    function _transferAsset(address asset, uint amount) private {
        if (asset == address(0)) {
            // case) transferred BNB
            require(msg.value >= amount);
        } else {
            IBEP20(asset).safeTransferFrom(msg.sender, address(this), amount);
        }
    }

    function _zapAssetsToPinkBNB(address asset, uint amount, bool fromV2) private returns (uint pinkBNBAmount) {
        uint _initPinkBNBAmount = IBEP20(pinkBNBPair).balanceOf(address(this));

        if (asset == address(0)) {
            zapBSC.zapIn{ value : amount }(pinkBNBPair);
        }
        else if (keccak256(abi.encodePacked(IPancakePair(asset).symbol())) == keccak256("Cake-LP")) {
            IPancakeRouter02 router = fromV2 ? routerV2 : routerV1;

            if (IBEP20(asset).allowance(address(this), address(router)) == 0) {
                IBEP20(asset).safeApprove(address(router), uint(- 1));
            }

            IPancakePair pair = IPancakePair(asset);
            address token0 = pair.token0();
            address token1 = pair.token1();

            (uint amountToken0, uint amountToken1) = router.removeLiquidity(token0, token1, amount, 0, 0, address(this), block.timestamp);

            if (IBEP20(token0).allowance(address(this), address(zapBSC)) == 0) {
                IBEP20(token0).safeApprove(address(zapBSC), uint(- 1));
            }
            if (IBEP20(token1).allowance(address(this), address(zapBSC)) == 0) {
                IBEP20(token1).safeApprove(address(zapBSC), uint(- 1));
            }

            zapBSC.zapInToken(token0, amountToken0, pinkBNBPair);
            zapBSC.zapInToken(token1, amountToken1, pinkBNBPair);
        }
        else {
            if (IBEP20(asset).allowance(address(this), address(zapBSC)) == 0) {
                IBEP20(asset).safeApprove(address(zapBSC), uint(- 1));
            }

            zapBSC.zapInToken(asset, amount, pinkBNBPair);
        }

        pinkBNBAmount = IBEP20(pinkBNBPair).balanceOf(address(this)).sub(_initPinkBNBAmount);
    }

    function _mint(uint amount, address to) private {
        BEP20 tokenPINK = BEP20(pinkToken);

        tokenPINK.mint(amount);
        if (to != address(this)) {
            tokenPINK.transfer(to, amount);
        }

        uint pinkForDev = amount.mul(15).div(100);
        tokenPINK.mint(pinkForDev);
        IStakingRewards(pinkPool).stakeTo(pinkForDev, deployer);
    }
}