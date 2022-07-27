import { toUsd } from "../../shared/units";
import { deployContract } from "../../shared/fixtures";

export const errors = [
  "Vault: zero error",
  "Vault: already initialized",
  "Vault: invalid _maxLeverage",
  "Vault: invalid _taxBasisPoints",
  "Vault: invalid _stableTaxBasisPoints",
  "Vault: invalid _mintBurnFeeBasisPoints",
  "Vault: invalid _swapFeeBasisPoints",
  "Vault: invalid _stableSwapFeeBasisPoints",
  "Vault: invalid _marginFeeBasisPoints",
  "Vault: invalid _liquidationFeeUsd",
  "Vault: invalid _fundingInterval",
  "Vault: invalid _fundingRateFactor",
  "Vault: invalid _stableFundingRateFactor",
  "Vault: token not whitelisted",
  "Vault: _token not whitelisted",
  "Vault: invalid tokenAmount",
  "Vault: _token not whitelisted",
  "Vault: invalid tokenAmount",
  "Vault: invalid usdvAmount",
  "Vault: _token not whitelisted",
  "Vault: invalid usdvAmount",
  "Vault: invalid redemptionAmount",
  "Vault: invalid amountOut",
  "Vault: swaps not enabled",
  "Vault: _tokenIn not whitelisted",
  "Vault: _tokenOut not whitelisted",
  "Vault: invalid tokens",
  "Vault: invalid amountIn",
  "Vault: leverage not enabled",
  "Vault: insufficient collateral for fees",
  "Vault: invalid position.size",
  "Vault: empty position",
  "Vault: position size exceeded",
  "Vault: position collateral exceeded",
  "Vault: invalid liquidator",
  "Vault: empty position",
  "Vault: position cannot be liquidated",
  "Vault: invalid position",
  "Vault: invalid _averagePrice",
  "Vault: collateral should be withdrawn",
  "Vault: _size must be more than _collateral",
  "Vault: invalid msg.sender",
  "Vault: mismatched tokens",
  "Vault: _collateralToken not whitelisted",
  "Vault: _collateralToken must not be a stableToken",
  "Vault: _collateralToken not whitelisted",
  "Vault: _collateralToken must be a stableToken",
  "Vault: _indexToken must not be a stableToken",
  "Vault: _indexToken not shortable",
  "Vault: invalid increase",
  "Vault: reserve exceeds pool",
  "Vault: max USDV exceeded",
  "Vault: reserve exceeds pool",
  "Vault: forbidden",
  "Vault: forbidden",
  "Vault: maxGasPrice exceeded",
];

export async function initVaultErrors(vault: any) {
  const vaultErrorController = await deployContract("VaultErrorController", []);
  await vault.setErrorController(vaultErrorController.address);
  await vaultErrorController.setErrors(vault.address, errors);
  return vaultErrorController;
}

export async function initVaultUtils(vault: any) {
  const vaultUtils = await deployContract("VaultUtils", [vault.address]);
  await vault.setVaultUtils(vaultUtils.address);
  return vaultUtils;
}

export async function initVault(
  vault: any,
  router: any,
  usdv: any,
  priceFeed: any
) {
  await vault.initialize(
    router.address, // router
    usdv.address, // usdv
    priceFeed.address, // priceFeed
    toUsd(5), // liquidationFeeUsd
    600, // fundingRateFactor
    600 // stableFundingRateFactor
  );

  const vaultUtils = await initVaultUtils(vault);
  const vaultErrorController = await initVaultErrors(vault);

  return { vault, vaultUtils, vaultErrorController };
}

export async function validateVaultBalance(
  expect: any,
  vault: any,
  token: any,
  offset: any = 0
) {
  const poolAmount = await vault.poolAmounts(token.address);
  const feeReserve = await vault.feeReserves(token.address);
  const balance = await token.balanceOf(vault.address);
  let amount = poolAmount.add(feeReserve);
  expect(balance).gt(0);
  expect(poolAmount.add(feeReserve).add(offset)).eq(balance);
}

export function getBnbConfig(bnb: any, bnbPriceFeed: any) {
  return [
    bnb.address, // _token
    18, // _tokenDecimals
    10000, // _tokenWeight
    75, // _minProfitBps,
    0, // _maxUsdvAmount
    false, // _isStable
    true, // _isShortable
  ];
}

export function getEthConfig(eth: any, ethPriceFeed: any) {
  return [
    eth.address, // _token
    18, // _tokenDecimals
    10000, // _tokenWeight
    75, // _minProfitBps
    0, // _maxUsdvAmount
    false, // _isStable
    true, // _isShortable
  ];
}

export function getBtcConfig(btc: any, btcPriceFeed: any) {
  return [
    btc.address, // _token
    8, // _tokenDecimals
    10000, // _tokenWeight
    75, // _minProfitBps
    0, // _maxUsdvAmount
    false, // _isStable
    true, // _isShortable
  ];
}

export function getDaiConfig(dai: any, daiPriceFeed: any) {
  return [
    dai.address, // _token
    18, // _tokenDecimals
    10000, // _tokenWeight
    75, // _minProfitBps
    0, // _maxUsdvAmount
    true, // _isStable
    false, // _isShortable
  ];
}
