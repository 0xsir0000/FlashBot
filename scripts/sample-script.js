// We require the Hardhat Runtime Environment explicitly here. This is optional
// but useful for running the script in a standalone fashion through `node <script>`.
//
// When running the script with `npx hardhat run <script>` you'll find the Hardhat
// Runtime Environment's members available in the global scope.
const hre = require("hardhat");

async function main() {
  // We get the contract to deploy
  const Greeter = await ethers.getContractFactory("FlashBot");
  const greeter = await Greeter.deploy('0xbb4CdB9CBd36B01bD1cBaEBF2De08d9173bc095c');
  console.log(greeter);
  // console.log(await greeter.getProfit('0x8b2E483216fbA34F0080d3cA1123C811775c80eD','0x884BE30e2c95b9cFed614aD2B5Edf40AF2A144ad'));

  console.log("Greeter deployed to:", greeter.address);
}

main()
  .then(() => process.exit(0))
  .catch((error) => {
    console.error(error);
    process.exit(1);
  });
