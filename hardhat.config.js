require("@nomicfoundation/hardhat-toolbox");
  require("dotenv").config();

  module.exports = {
    solidity: {
      version: "0.8.28",
      settings: {
        optimizer: {
          enabled: true,
          runs: 200,
        },
      },
    },
    networks: {
      hardhat: {},
      polygonMumbai: {
        url: process.env.POLYGON_MUMBAI_URL || "https://rpc-mumbai.maticvigil.com",
        accounts: [process.env.PRIVATE_KEY],
      },
    },
    etherscan: {
      apiKey: process.env.POLYGONSCAN_API_KEY,
    },
  };