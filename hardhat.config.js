require("@nomicfoundation/hardhat-toolbox");
  require("dotenv").config();

  module.exports = {
    solidity: {
      version: "0.8.20",
      settings: {
        optimizer: {
          enabled: true,
          runs: 200,
        },
      },
    },
    networks: {
      hardhat: {},
      sepolia: {
        url: process.env.SEPOLIA_URL || "https://rpc.sepolia.org",
        accounts: [process.env.PRIVATE_KEY],
      },
    },
    etherscan: {
      apiKey: process.env.ETHERSCAN_API_KEY,
    },
  };