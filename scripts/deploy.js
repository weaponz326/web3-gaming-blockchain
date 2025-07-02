const hre = require("hardhat");

  async function main() {
    const [deployer] = await hre.ethers.getSigners();
    console.log("Deploying contracts with:", deployer.address);

    const IACSToken = await hre.ethers.getContractFactory("IACSToken");
    const iacsToken = await IACSToken.deploy();
    await iacsToken.waitForDeployment();
    console.log("IACSToken deployed to:", iacsToken.target);

    const RockPaperScissors = await hre.ethers.getContractFactory("RockPaperScissors");
    const rps = await RockPaperScissors.deploy(iacsToken.target, 123); // Replace 123 with actual Chainlink subscription ID
    await rps.waitForDeployment();
    console.log("RockPaperScissors deployed to:", rps.target);
  }

  main().catch((error) => {
    console.error(error);
    process.exitCode = 1;
  });