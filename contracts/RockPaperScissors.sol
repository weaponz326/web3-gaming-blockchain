// SPDX-License-Identifier: MIT
  pragma solidity ^0.8.20;

  import "@openzeppelin/contracts/access/Ownable.sol";
  import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
  import "@chainlink/contracts/src/v0.8/VRFConsumerBaseV2.sol";
  import "@chainlink/contracts/src/v0.8/interfaces/VRFCoordinatorV2Interface.sol";

  contract RockPaperScissors is Ownable, VRFConsumerBaseV2 {
      IERC20 public iacsToken;
      uint256 public platformFeePercent = 5; // 5% fee
      uint256 public totalFees;
      mapping(address => Game) public games;
      mapping(uint256 => address) public requestIdToPlayer;

      // Chainlink VRF variables for Sepolia
      VRFCoordinatorV2Interface public COORDINATOR;
      uint64 subscriptionId;
      address vrfCoordinator = 0x8103B0A8A00be2DDC778e6e7eaa21791Cd364625; // Sepolia VRF Coordinator
      bytes32 keyHash = 0x474e34a077df58807dbe9c96d3c009b23b3c6d0cce433e59bbf5b34f823bc56c; // Sepolia key hash
      uint32 callbackGasLimit = 100000;
      uint16 requestConfirmations = 3;
      uint32 numWords = 1;

      enum Move { None, Rock, Paper, Scissors }
      enum GameState { Created, Committed, Revealed, Resolved }

      struct Game {
          address player1;
          address player2; // address(0) for AI
          uint256 wager;
          bytes32 player1MoveHash;
          Move player1Move;
          Move player2Move;
          GameState state;
      }

      event GameCreated(address indexed player1, uint256 wager, bool isAI);
      event MoveCommitted(address indexed player, bytes32 moveHash);
      event MoveRevealed(address indexed player, Move move);
      event GameResolved(address indexed winner, uint256 payout);
      event RandomnessRequested(uint256 requestId, address indexed player);

      constructor(address _iacsToken, uint64 _subscriptionId) Ownable(msg.sender) VRFConsumerBaseV2(vrfCoordinator) {
          iacsToken = IERC20(_iacsToken);
          COORDINATOR = VRFCoordinatorV2Interface(vrfCoordinator);
          subscriptionId = _subscriptionId;
      }

      function createGame(uint256 _wager, bool _isAI) external {
          require(games[msg.sender].state == GameState.Resolved || games[msg.sender].player1 == address(0), "Game in progress");
          require(_wager > 0, "Wager must be greater than 0");
          require(iacsToken.transferFrom(msg.sender, address(this), _wager), "Wager transfer failed");

          games[msg.sender] = Game({
              player1: msg.sender,
              player2: _isAI ? address(0) : address(0),
              wager: _wager,
              player1MoveHash: bytes32(0),
              player1Move: Move.None,
              player2Move: Move.None,
              state: GameState.Created
          });

          if (_isAI) {
              requestRandomMove(msg.sender);
          }

          emit GameCreated(msg.sender, _wager, _isAI);
      }

      function commitMove(bytes32 _moveHash) external {
          Game storage game = games[msg.sender];
          require(game.state == GameState.Created, "Invalid game state");
          require(game.player1 == msg.sender, "Not player1");

          game.player1MoveHash = _moveHash;
          game.state = GameState.Committed;
          emit MoveCommitted(msg.sender, _moveHash);
      }

      function revealMove(uint8 _move, bytes32 _salt) external {
          require(_move >= 1 && _move <= 3, "Invalid move");
          Game storage game = games[msg.sender];
          require(game.state == GameState.Committed, "Invalid game state");
          require(game.player1 == msg.sender, "Not player1");
          require(keccak256(abi.encodePacked(_move, _salt)) == game.player1MoveHash, "Invalid move hash");

          game.player1Move = Move(_move);
          game.state = GameState.Revealed;
          emit MoveRevealed(msg.sender, Move(_move));

          if (game.player2 == address(0)) {
              // AI move already set by VRF
              resolveGame(msg.sender);
          }
      }

      function joinGame(address _player1, uint256 _wager, bytes32 _moveHash) external {
          Game storage game = games[_player1];
          require(game.state == GameState.Created, "Invalid game state");
          require(game.player2 == address(0), "Game already has player2");
          require(_wager == game.wager, "Wager mismatch");
          require(iacsToken.transferFrom(msg.sender, address(this), _wager), "Wager transfer failed");

          game.player2 = msg.sender;
          game.player1MoveHash = _moveHash; // Player2 commits move directly
          game.state = GameState.Committed;
          emit MoveCommitted(msg.sender, _moveHash);
      }

      function revealPlayer2Move(uint8 _move, bytes32 _salt) external {
          require(_move >= 1 && _move <= 3, "Invalid move");
          Game storage game = games[msg.sender];
          require(game.state == GameState.Committed, "Invalid game state");
          require(game.player2 == msg.sender, "Not player2");
          require(keccak256(abi.encodePacked(_move, _salt)) == game.player1MoveHash, "Invalid move hash");

          game.player2Move = Move(_move);
          game.state = GameState.Revealed;
          emit MoveRevealed(msg.sender, Move(_move));
          resolveGame(game.player1);
      }

      function requestRandomMove(address _player) internal {
          uint256 requestId = COORDINATOR.requestRandomWords(
              keyHash,
              subscriptionId,
              requestConfirmations,
              callbackGasLimit,
              numWords
          );
          requestIdToPlayer[requestId] = _player;
          emit RandomnessRequested(requestId, _player);
      }

      function fulfillRandomWords(uint256 _requestId, uint256[] memory _randomWords) internal override {
          address player = requestIdToPlayer[_requestId];
          Game storage game = games[player];
          require(game.player2 == address(0), "Not an AI game");

          game.player2Move = Move((_randomWords[0] % 3) + 1); // Maps to Rock (1), Paper (2), Scissors (3)
          emit MoveRevealed(address(0), game.player2Move);
      }

      function resolveGame(address _player1) internal {
          Game storage game = games[_player1];
          require(game.state == GameState.Revealed, "Invalid game state");

          address winner = determineWinner(game.player1Move, game.player2Move);
          uint256 fee = (game.wager * 2 * platformFeePercent) / 100;
          uint256 payout = (game.wager * 2) - fee;
          totalFees += fee;

          if (winner != address(0)) {
              require(iacsToken.transfer(winner, payout), "Payout failed");
          } else {
              // Tie: refund both players
              require(iacsToken.transfer(game.player1, game.wager), "Refund failed");
              if (game.player2 != address(0)) {
                  require(iacsToken.transfer(game.player2, game.wager), "Refund failed");
              }
          }

          game.state = GameState.Resolved;
          emit GameResolved(winner, payout);
      }

      function determineWinner(Move move1, Move move2) internal pure returns (address) {
          if (move1 == move2) return address(0); // Tie
          if ((move1 == Move.Rock && move2 == Move.Scissors) ||
              (move1 == Move.Paper && move2 == Move.Rock) ||
              (move1 == Move.Scissors && move2 == Move.Paper)) {
              return msg.sender; // Player1 wins
          }
          return address(0); // Player2 wins or tie
      }

      function withdrawFees() external onlyOwner {
          uint256 amount = totalFees;
          totalFees = 0;
          require(iacsToken.transfer(owner(), amount), "Fee withdrawal failed");
      }

      function setPlatformFeePercent(uint256 _newFeePercent) external onlyOwner {
          require(_newFeePercent <= 10, "Fee too high");
          platformFeePercent = _newFeePercent;
      }
  }