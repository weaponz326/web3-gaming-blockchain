const { expect } = require("chai");
  const { ethers } = require("hardhat");

  describe("RockPaperScissors", function () {
    let iacsToken, rps, owner, player1, player2;
    const wager = ethers.parseEther("1");

    beforeEach(async function () {
      [owner, player1, player2] = await ethers.getSigners();

      const IACSToken = await ethers.getContractFactory("IACSToken");
      iacsToken = await IACSToken.deploy();
      await iacsToken.waitForDeployment();

      const RockPaperScissors = await ethers.getContractFactory("RockPaperScissors");
      rps = await RockPaperScissors.deploy(iacsToken.target, 123); // Dummy subscriptionId
      await rps.waitForDeployment();

      await iacsToken.mint(player1.address, ethers.parseEther("100"));
      await iacsToken.mint(player2.address, ethers.parseEther("100"));
      await iacsToken.connect(player1).approve(rps.target, ethers.parseEther("100"));
      await iacsToken.connect(player2).approve(rps.target, ethers.parseEther("100"));
    });

    it("should allow player to create and play AI game", async function () {
      await rps.connect(player1).createGame(wager, true);
      const move = 1; // Rock
      const salt = ethers.randomBytes(32);
      const moveHash = ethers.keccak256(ethers.concat([ethers.toBeArray(move), salt]));
      await rps.connect(player1).commitMove(moveHash);
      await rps.connect(player1).revealMove(move, salt);
      const game = await rps.games(player1.address);
      expect(game.state).to.equal(3); // Revealed
    });

    it("should handle PvP game correctly", async function () {
      await rps.connect(player1).createGame(wager, false);
      const move1 = 1; // Rock
      const salt1 = ethers.randomBytes(32);
      const moveHash1 = ethers.keccak256(ethers.concat([ethers.toBeArray(move1), salt1]));
      await rps.connect(player1).commitMove(moveHash1);

      const move2 = 2; // Paper
      const salt2 = ethers.randomBytes(32);
      const moveHash2 = ethers.keccak256(ethers.concat([ethers.toBeArray(move2), salt2]));
      await rps.connect(player2).joinGame(player1.address, wager, moveHash2);

      await rps.connect(player1).revealMove(move1, salt1);
      await rps.connect(player2).revealPlayer2Move(move2, salt2);

      const game = await rps.games(player1.address);
      expect(game.state).to.equal(4); // Resolved
      const balance = await iacsToken.balanceOf(player2.address);
      expect(balance).to.be.above(ethers.parseEther("100")); // Player2 wins
    });
  });