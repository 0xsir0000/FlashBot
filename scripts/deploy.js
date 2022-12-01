async function main() {
    // We get the contract to deploy
    const Greeter = await ethers.getContractFactory("FlashBotV3");
    const greeter = await Greeter.deploy('0xbb4CdB9CBd36B01bD1cBaEBF2De08d9173bc095c','4000000000000000');
    
    const addBaseToken1 = await greeter.addBaseToken("0x55d398326f99059fF775485246999027B3197955","500000000000000000");
    const addBaseToken2 = await greeter.addBaseToken("0xe9e7CEA3DedcA5984780Bafc599bD69ADd087D56","500000000000000000");
    // const res = await greeter.getProfit("91751796636748831853", "2326355367108391350409", "276932778905836382595832", "6468219678035999955297807", "0xbb4CdB9CBd36B01bD1cBaEBF2De08d9173bc095c");
    // console.log(res);
    // const res2 = await greeter.flashArbitrageForYulin("0xDE60997a41A224215857a3F2cC46E190B4EB7a8C",
    //   "0x4Cb29498595A733c4B0d710E766BB89345eE945b",
    //   true,
    //   "0xbb4CdB9CBd36B01bD1cBaEBF2De08d9173bc095c",
    //   "0xF0A8EcBCE8caADB7A07d1FcD0f87Ae1Bd688dF43",
    //   res.borrowAmount);
    // console.log(res2);
    await greeter.deployed();
  
    console.log("v3 deployed to:", greeter.address);
  }
  
  main()
    .then(() => process.exit(0))
    .catch((error) => {
      console.error(error);
      process.exit(1);
    });