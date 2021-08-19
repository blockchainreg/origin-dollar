pragma solidity 0.5.11;

/**
 * @title Curve 3Pool Strategy
 * @notice Investment strategy for investing stablecoins via Curve 3Pool
 * @author Origin Protocol Inc
 */

import { ICurvePool } from "./ICurvePool.sol";
import { ICurveGauge } from "./ICurveGauge.sol";
import { ICRVMinter } from "./ICRVMinter.sol";
import {
    IERC20,
    InitializableAbstractStrategy
} from "../utils/InitializableAbstractStrategy.sol";
import { StableMath } from "../utils/StableMath.sol";
import { Helpers } from "../utils/Helpers.sol";

contract ThreePoolStrategyBase is InitializableAbstractStrategy {
    using StableMath for uint256;

    event RewardTokenCollected(address recipient, uint256 amount);

    address crvGaugeAddress;
    address crvMinterAddress;
    uint256 constant maxSlippage = 1e16; // 1%, same as the Curve UI

    /**
     * @dev Deposit asset into the Curve 3Pool
     * @param _asset Address of asset to deposit
     * @param _amount Amount of asset to deposit
     */
    function deposit(address _asset, uint256 _amount)
        external
        onlyVault
        nonReentrant
    {
        require(_amount > 0, "Must deposit something");
        emit Deposit(_asset, address(platformAddress), _amount);
        // 3Pool requires passing deposit amounts for all 3 assets, set to 0 for
        // all
        uint256[3] memory _amounts;
        uint256 poolCoinIndex = _getPoolCoinIndex(_asset);
        // Set the amount on the asset we want to deposit
        _amounts[poolCoinIndex] = _amount;
        ICurvePool curvePool = ICurvePool(platformAddress);
        uint256 assetDecimals = Helpers.getDecimals(_asset);
        uint256 depositValue = _amount
            .scaleBy(int8(18 - assetDecimals))
            .divPrecisely(curvePool.get_virtual_price());
        uint256 minMintAmount = depositValue.mulTruncate(
            uint256(1e18).sub(maxSlippage)
        );
        // Do the deposit to 3pool
        curvePool.add_liquidity(_amounts, minMintAmount);
        _depositToRewards();
    }

    /**
     * @dev Deposit the entire balance of any supported asset into the Curve 3pool
     */
    function depositAll() external onlyVault nonReentrant {
        uint256[3] memory _amounts = [uint256(0), uint256(0), uint256(0)];
        uint256 depositValue = 0;
        ICurvePool curvePool = ICurvePool(platformAddress);

        for (uint256 i = 0; i < assetsMapped.length; i++) {
            address assetAddress = assetsMapped[i];
            uint256 balance = IERC20(assetAddress).balanceOf(address(this));
            if (balance > 0) {
                uint256 poolCoinIndex = _getPoolCoinIndex(assetAddress);
                // Set the amount on the asset we want to deposit
                _amounts[poolCoinIndex] = balance;
                uint256 assetDecimals = Helpers.getDecimals(assetAddress);
                // Get value of deposit in Curve LP token to later determine
                // the minMintAmount argument for add_liquidity
                depositValue = depositValue.add(
                    balance.scaleBy(int8(18 - assetDecimals)).divPrecisely(
                        curvePool.get_virtual_price()
                    )
                );
                emit Deposit(assetAddress, address(platformAddress), balance);
            }
        }

        uint256 minMintAmount = depositValue.mulTruncate(
            uint256(1e18).sub(maxSlippage)
        );
        // Do the deposit to 3pool
        curvePool.add_liquidity(_amounts, minMintAmount);
        _depositToRewards();
    }

    /**
     * @dev Withdraw asset from Curve 3Pool
     * @param _recipient Address to receive withdrawn asset
     * @param _asset Address of asset to withdraw
     * @param _amount Amount of asset to withdraw
     */
    function withdraw(
        address _recipient,
        address _asset,
        uint256 _amount
    ) external onlyVault nonReentrant {
        require(_recipient != address(0), "Invalid recipient");
        require(_amount > 0, "Invalid amount");

        emit Withdrawal(_asset, address(assetToPToken[_asset]), _amount);

        // Calculate how much of the pool token we need to withdraw
        (uint256 contractPTokens, , uint256 totalPTokens) = _getTotalPTokens();

        require(totalPTokens > 0, "Insufficient 3CRV balance");

        uint256 poolCoinIndex = _getPoolCoinIndex(_asset);
        // Calculate the max amount of the asset we'd get if we withdrew all the
        // platform tokens
        ICurvePool curvePool = ICurvePool(platformAddress);
        uint256 maxAmount = curvePool.calc_withdraw_one_coin(
            totalPTokens,
            int128(poolCoinIndex)
        );

        // Calculate how many platform tokens we need to withdraw the asset amount
        uint256 withdrawPTokens = totalPTokens.mul(_amount).div(maxAmount);
        if (contractPTokens < withdrawPTokens) {
            // Not enough of pool token exists on this contract, some must be
            // staked, unstake difference
            _withdrawFromRewards(withdrawPTokens.sub(contractPTokens));
        }

        // Calculate a minimum withdrawal amount
        uint256 assetDecimals = Helpers.getDecimals(_asset);
        // 3crv is 1e18, subtract slippage percentage and scale to asset
        // decimals
        uint256 minWithdrawAmount = withdrawPTokens
            .mulTruncate(uint256(1e18).sub(maxSlippage))
            .scaleBy(int8(assetDecimals - 18));

        curvePool.remove_liquidity_one_coin(
            withdrawPTokens,
            int128(poolCoinIndex),
            minWithdrawAmount
        );
        IERC20(_asset).safeTransfer(_recipient, _amount);

        // Transfer any leftover dust back to the vault buffer.
        uint256 dust = IERC20(_asset).balanceOf(address(this));
        if (dust > 0) {
            IERC20(_asset).safeTransfer(vaultAddress, dust);
        }
    }

    /**
     * @dev Remove all assets from platform and send them to Vault contract.
     */
    function withdrawAll() external onlyVaultOrGovernor nonReentrant {
        // Withdraw all from Gauge
        (, uint256 gaugePTokens, uint256 totalPTokens) = _getTotalPTokens();
        _withdrawFromRewards(gaugePTokens);
        uint256[3] memory minWithdrawAmounts = [
            uint256(0),
            uint256(0),
            uint256(0)
        ];
        // Calculate min withdrawal amounts for each coin
        for (uint256 i = 0; i < assetsMapped.length; i++) {
            address assetAddress = assetsMapped[i];
            uint256 virtualBalance = checkBalance(assetAddress);
            uint256 poolCoinIndex = _getPoolCoinIndex(assetAddress);
            minWithdrawAmounts[poolCoinIndex] = virtualBalance.mulTruncate(
                uint256(1e18).sub(maxSlippage)
            );
        }
        // Remove liqudiity
        ICurvePool threePool = ICurvePool(platformAddress);
        threePool.remove_liquidity(totalPTokens, minWithdrawAmounts);
        // Transfer assets out ot Vault
        // Note that Curve will provide all 3 of the assets in 3pool even if
        // we have not set PToken addresses for all of them in this strategy
        for (uint256 i = 0; i < assetsMapped.length; i++) {
            IERC20 asset = IERC20(threePool.coins(i));
            asset.safeTransfer(vaultAddress, asset.balanceOf(address(this)));
        }
    }

    /**
     * @dev Get the total asset value held in the platform
     * @param _asset      Address of the asset
     * @return balance    Total value of the asset in the platform
     */
    function checkBalance(address _asset)
        public
        view
        returns (uint256 balance)
    {
        require(assetToPToken[_asset] != address(0), "Unsupported asset");
        // LP tokens in this contract. This should generally be nothing as we
        // should always stake the full balance in the Gauge, but include for
        // safety
        (, , uint256 totalPTokens) = _getTotalPTokens();
        ICurvePool curvePool = ICurvePool(platformAddress);

        uint256 pTokenTotalSupply = IERC20(assetToPToken[_asset]).totalSupply();
        if (pTokenTotalSupply > 0) {
            uint256 poolCoinIndex = _getPoolCoinIndex(_asset);
            uint256 curveBalance = curvePool.balances(poolCoinIndex);
            if (curveBalance > 0) {
                balance = totalPTokens.mul(curveBalance).div(pTokenTotalSupply);
            }
        }
    }

    /**
     * @dev Retuns bool indicating whether asset is supported by strategy
     * @param _asset Address of the asset
     */
    function supportsAsset(address _asset) external view returns (bool) {
        return assetToPToken[_asset] != address(0);
    }

    /**
     * @dev Approve the spending of all assets by their corresponding pool tokens,
     *      if for some reason is it necessary.
     */
    function safeApproveAllTokens() external {
        // This strategy is a special case since it only supports one asset
        for (uint256 i = 0; i < assetsMapped.length; i++) {
            _abstractSetPToken(assetsMapped[i], assetToPToken[assetsMapped[i]]);
        }
    }

    /**
     * @dev Calculate the total platform token balance (i.e. 3CRV) that exist in
     * this contract or is staked in the Gauge (or in other words, the total
     * amount platform tokens we own).
     * @return totalPTokens Total amount of platform tokens in native decimals
     */
    function _getTotalPTokens()
        internal
        view
        returns (
            uint256 contractPTokens,
            uint256 gaugePTokens,
            uint256 totalPTokens
        )
    {
        contractPTokens = IERC20(assetToPToken[assetsMapped[0]]).balanceOf(
            address(this)
        );
        gaugePTokens = _balanceOfPtokensInRewards();
        totalPTokens = contractPTokens.add(gaugePTokens);
    }

    /**
     * @dev Call the necessary approvals for the Curve pool and gauge
     * @param _asset Address of the asset
     * @param _pToken Address of the corresponding platform token (i.e. 3CRV)
     */
    function _abstractSetPToken(address _asset, address _pToken) internal {
        IERC20 asset = IERC20(_asset);
        IERC20 pToken = IERC20(_pToken);
        // 3Pool for asset (required for adding liquidity)
        asset.safeApprove(platformAddress, 0);
        asset.safeApprove(platformAddress, uint256(-1));
        // 3Pool for LP token (required for removing liquidity)
        pToken.safeApprove(platformAddress, 0);
        pToken.safeApprove(platformAddress, uint256(-1));

        _setupRewards(_pToken);
    }

    /**
     * @dev Get the index of the coin in 3pool
     */
    function _getPoolCoinIndex(address _asset) internal view returns (uint256) {
        for (uint256 i = 0; i < 3; i++) {
            if (assetsMapped[i] == _asset) return i;
        }
        revert("Invalid 3pool asset");
    }

    // Reward token handling
    // ---------------------

    /**
     * @dev Setup allowances for rewards
     */
    function _setupRewards(address pToken) internal;

    /**
     * @dev Place 3CRV into from Rewards
     */
    function _depositToRewards() internal;

    /**
     * @dev Get 3CRV from Rewards
     */
    function _withdrawFromRewards(uint256 amount) internal;

    /**
     * @dev Amount of 3CRV held in rewards
     */
    function _balanceOfPtokensInRewards()
        internal
        view
        returns (uint256 amount);
}