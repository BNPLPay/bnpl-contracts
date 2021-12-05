import { Signer, Contract, ethers, BigNumber } from "ethers";
import { HardhatRuntimeEnvironment } from "hardhat/types";
import { BNPLSwapMarketExample, BNPLToken, FakeAaveLendingPool, IERC20 } from "../../typechain";
import { genGetContractWith } from "./genHelpers";
import { getContractForEnvironment } from "./getContractForEnvironment";
import { ms } from '../../utils/math';

function shouldSetupFakeAave(hre: HardhatRuntimeEnvironment) {
  return hre.network.name !== "mainnet" && hre.network.name !== "production" && hre.network.name !== "kovan";
}
function shouldSetupFakeUniswap(hre: HardhatRuntimeEnvironment) {
  return hre.network.name !== "mainnet" && hre.network.name !== "production";
}

const decimals = (d: number) => BigNumber.from(10).pow(d)
const amount = (i: number, d: number) => BigNumber.from(i).mul(decimals(d))

const BNPL_DECIMALS = 18
const DAI_DECIMALS = 18
const USDT_DECIMALS = 6
const USDC_DECIMALS = 6

async function setupFakeAave(hre: HardhatRuntimeEnvironment, signer?: string | Signer | undefined) {
  const { getContract } = genGetContractWith(hre);


  const DAI = await getContract("DAI", signer);
  const aDAI = await getContract("aDAI", signer);

  const USDT = await getContract("USDT", signer);
  const aUSDT = await getContract("aUSDT", signer);

  const USDC = await getContract("USDC", signer);
  const aUSDC = await getContract("aUSDC", signer);
  const { mockContractsDeployer } = await hre.getNamedAccounts();

  const fakeAaveLendingPool = await getContract<FakeAaveLendingPool>("FakeAaveLendingPool", signer || mockContractsDeployer);
  //await fakeAaveLendingPool.deployed();


  const r = await fakeAaveLendingPool.addAssetPair(DAI.address, aDAI.address, { gasLimit: 5500000 });
  await fakeAaveLendingPool.addAssetPair(USDT.address, aUSDT.address, { gasLimit: 5500000 });
  await fakeAaveLendingPool.addAssetPair(USDC.address, aUSDC.address, { gasLimit: 5500000 });

}
async function setupFakeUniswap(hre: HardhatRuntimeEnvironment, signer?: string | Signer | undefined) {
  const { mockContractsDeployer, bnplTokenDeployer } = await hre.getNamedAccounts();
  const realSigner = signer || mockContractsDeployer;
  const { getContract } = genGetContractWith(hre);

  const bnplSwapMarketExample = await getContract<BNPLSwapMarketExample>("BNPLSwapMarketExample", realSigner);


  const DAI = await getContract<IERC20>("DAI", realSigner);
  const USDT = await getContract<IERC20>("USDT", realSigner);
  const USDC = await getContract<IERC20>("USDC", realSigner);


  await bnplSwapMarketExample.setBNPLPrice(DAI.address, amount(1, DAI_DECIMALS), { gasLimit: 5500000 }); // 1 DAI = 1 BNPL
  await bnplSwapMarketExample.setBNPLPrice(USDT.address, amount(1, USDT_DECIMALS), { gasLimit: 5500000 }); // 1 USDT = 1 BNPL
  await bnplSwapMarketExample.setBNPLPrice(USDC.address, amount(1, USDC_DECIMALS), { gasLimit: 5500000 }); // 1 USDC = 1 BNPL

  await DAI.approve(bnplSwapMarketExample.address, amount(50_000_000, DAI_DECIMALS), { gasLimit: 5500000 });
  await bnplSwapMarketExample.depositToken(DAI.address, amount(50_000_000, DAI_DECIMALS), { gasLimit: 5500000 }); // 50,000,000 DAI

  await USDT.approve(bnplSwapMarketExample.address, amount(50_000_000, USDT_DECIMALS), { gasLimit: 5500000 });
  await bnplSwapMarketExample.depositToken(USDT.address, amount(50_000_000, USDT_DECIMALS), { gasLimit: 5500000 }); // 50,000,000 USDT

  await USDC.approve(bnplSwapMarketExample.address, amount(50_000_000, USDC_DECIMALS), { gasLimit: 5500000 });
  await bnplSwapMarketExample.depositToken(USDC.address, amount(50_000_000, USDC_DECIMALS), { gasLimit: 5500000 }); // 50,000,000 USDC
  const bnplToken = await getContractForEnvironment<BNPLToken>(hre, "BNPLToken", bnplTokenDeployer);

  await bnplToken.approve(bnplSwapMarketExample.address, amount(50_000_000, BNPL_DECIMALS), { gasLimit: 5500000 });
  const bnplSwapMarketExampleBNPLTokenDeployer = await getContract<BNPLSwapMarketExample>("BNPLSwapMarketExample", bnplTokenDeployer);
  await bnplSwapMarketExampleBNPLTokenDeployer.depositBNPL("50000000000000000000000000", { gasLimit: 5500000 });// 50,000,000 BNPL

}
async function setupMockEnvTestNet(hre: HardhatRuntimeEnvironment, signer?: string | Signer | undefined) {
  const { mockContractsDeployer, bnplTokenDeployer } = await hre.getNamedAccounts();
  const realSigner = signer || mockContractsDeployer;
  const { getContract } = genGetContractWith(hre);




  const bnplSwapMarketExample = await getContract<BNPLSwapMarketExample>("BNPLSwapMarketExample", realSigner);


  const USDT = await getContract<IERC20>("USDT", realSigner);


  await bnplSwapMarketExample.setBNPLPrice(USDT.address, "1000000", { gasLimit: 5500000 }); // 1 USDT = 1 BNPL


  await USDT.approve(bnplSwapMarketExample.address, "50000000000000", { gasLimit: 5500000 });
  await bnplSwapMarketExample.depositToken(USDT.address, "50000000000000", { gasLimit: 5500000 }); // 50,000,000 USDT
  const bnplToken = await getContractForEnvironment<BNPLToken>(hre, "BNPLToken", bnplTokenDeployer);

  await bnplToken.approve(bnplSwapMarketExample.address, "50000000000000000000000000", { gasLimit: 5500000 });
  const bnplSwapMarketExampleBNPLTokenDeployer = await getContract<BNPLSwapMarketExample>("BNPLSwapMarketExample", bnplTokenDeployer);
  await bnplSwapMarketExampleBNPLTokenDeployer.depositBNPL("50000000000000000000000000", { gasLimit: 5500000 });// 50,000,000 BNPL




  //const aUSDT = await getContract("aUSDT", signer);
  ///  const fakeAaveLendingPool = await getContract<FakeAaveLendingPool>("FakeAaveLendingPool", signer || mockContractsDeployer);
  //await fakeAaveLendingPool.deployed();


  //await fakeAaveLendingPool.addAssetPair(USDT.address, aUSDT.address, { gasLimit: 5500000 });

}
async function setupMockEnvIfNeeded(hre: HardhatRuntimeEnvironment) {
  const { protocolDeployer } = await hre.getNamedAccounts();

  if (shouldSetupFakeAave((hre))) {
    await setupFakeAave(hre, protocolDeployer);
  }
  if (shouldSetupFakeUniswap((hre))) {
    await setupFakeUniswap(hre, protocolDeployer);
  }
}

export {
  shouldSetupFakeAave,
  shouldSetupFakeUniswap,
  setupFakeUniswap,
  setupFakeAave,
  setupMockEnvIfNeeded,
  setupMockEnvTestNet,
}
