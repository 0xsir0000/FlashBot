const { expect } = require("chai");
const { ethers } = require("hardhat");


describe("TLv3", function () {
  it("套利测试V3", async function () {
    const Greeter = await ethers.getContractFactory("FlashBotV3");
    const greeter = await Greeter.deploy("0xbb4CdB9CBd36B01bD1cBaEBF2De08d9173bc095c", "4000000000000000");

    const addBaseToken1 = await greeter.addBaseToken("0x55d398326f99059fF775485246999027B3197955", "500000000000000000");
    const addBaseToken2 = await greeter.addBaseToken("0xe9e7CEA3DedcA5984780Bafc599bD69ADd087D56", "500000000000000000");
    // const res = await greeter.flashArbitrageforYulin("0x3d94d03eb9ea2D4726886aB8Ac9fc0F18355Fd13","0x0eD7e52944161450477ee417DE9Cd3a859b14fD0",false,"0xbb4CdB9CBd36B01bD1cBaEBF2De08d9173bc095c","0x0E09FaBB73Bd3Ade0a17ECC321fD13a19e81cE82");
    // const res = await greeter.test();
    const res = await greeter.getProfit("7125266306543071511642537", "340028120360655633872965", "6401037538803577859483", "305373934829391083109", "0x55d398326f99059fF775485246999027B3197955");
    console.log(res);
    // const res2 = await greeter.flashArbitrageForYulin("0x6D8163E9dB6c949e92e49C9B3cdB36C69395b680",
    //   "0x8840C6252e2e86e545deFb6da98B2a0E26d8C1BA",
    //   false,
    //   "0xbb4CdB9CBd36B01bD1cBaEBF2De08d9173bc095c",
    //   "0x55d398326f99059fF775485246999027B3197955",
    //   "130500000000000000000");
    // console.log(res2);
  })
});
