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
    mapping(bytes32 => Game) public games; // Map game code to game
    mapping(uint256 => bytes32) public requestIdToGameCode; // Chainlink VRF request mapping

    // Chainlink VRF variables for Sepolia
    VRFCoordinatorV2Interface public COORDINATOR;
    uint64 subscriptionId;
    address vrfCoordinator = 0x8103B0A8A00be2DDC778e6e7eaa21791Cd364625; // Sepolia VRF Coordinator
    bytes32 keyHash = 0x474e34a077df58807dbe9c96d3c009b23b3c6d0cce433e59bbf5b34f823bc56c; // Sepolia key hash
    uint32 callbackGasLimit = 100000;
    uint16 requestConfirmations = 3;
    uint32 numWords = 1;

    enum Move { None, Rock, Paper, Scissors }
    enum GameState { Created, Negotiating, Committed, Revealed, Resolved, Ended }

    struct Game {
        address player1;
        address player2; // address(0) for AI
        uint256 totalWager;
        uint256 wagerPerGame;
        uint256 player1WagerProposal;
        uint256 player2WagerProposal;
        bytes32 player1MoveHash;
        bytes32 player2MoveHash;
        Move player1Move;
        Move player2Move;
        GameState state;
        uint256 player1Balance;
        uint256 player2Balance;
        uint256 roundNumber;
    }

    event GameCreated(bytes32 indexed gameCode, address indexed player1, uint256 totalWager, bool isAI);
    event WagerProposed(bytes32 indexed gameCode, address indexed player, uint256 wager);
    event WagerAccepted(bytes32 indexed gameCode, uint256 wagerPerGame);
    event MoveCommitted(bytes32 indexed gameCode, address indexed player);
    event MoveRevealed(bytes32 indexed gameCode, address indexed player, Move move);
    event RoundResolved(bytes32 indexed gameCode, address indexed winner, uint256 payout);
    event GameEnded(bytes32 indexed gameCode, address indexed quitter);

    constructor(address _iacsToken, uint64 _subscriptionId) Ownable(msg.sender) VRFConsumerBaseV2(vrfCoordinator) {
        iacsToken = IERC20(_iacsToken);
        COORDINATOR = VRFCoordinatorV2Interface(vrfCoordinator);
        subscriptionId = _subscriptionId;
    }

    function createGame(uint256 _totalWager, bool _isAI) external returns (bytes32) {
        require(_totalWager > 0, "Total wager must be greater than 0");
        require(iacsToken.transferFrom(msg.sender, address(this), _totalWager), "Wager transfer failed");

        bytes32 gameCode = keccak256(abi.encodePacked(msg.sender, block.timestamp));
        games[gameCode] = Game({
            player1: msg.sender,
            player2: _isAI ? address(0) : address(0),
            totalWager: _totalWager,
            wagerPerGame: 0,
            player1WagerProposal: 0,
            player2WagerProposal: 0,
            player1MoveHash: bytes32(0),
            player2MoveHash: bytes32(0),
            player1Move: Move.None,
            player2Move: Move.None,
            state: _isAI ? GameState.Committed : GameState.Created,
            player1Balance: _totalWager,
            player2Balance: 0,
            roundNumber: 0
        });

        if (_isAI) {
            requestRandomMove(gameCode);
        }

        emit GameCreated(gameCode, msg.sender, _totalWager, _isAI);
        return gameCode;
    }

    function joinGame(bytes32 _gameCode, uint256 _totalWager, uint256 _wagerPerGame) external {
        Game storage game = games[_gameCode];
        require(game.state == GameState.Created, "Invalid game state");
        require(game.player1 != address(0) && game.player1 != msg.sender, "Invalid game or player");
        require(_totalWager == game.totalWager, "Wager mismatch");
        require(iacsToken.transferFrom(msg.sender, address(this), _totalWager), "Wager transfer failed");

        game.player2 = msg.sender;
        game.player2Balance = _totalWager;
        game.player1WagerProposal = _totalWager / 10; // Default proposal: 10% of total wager
        game.player2WagerProposal = _wagerPerGame;
        game.state = GameState.Negotiating;
        emit WagerProposed(_gameCode, msg.sender, _wagerPerGame);
    }

    function proposeWager(bytes32 _gameCode, uint256 _wagerPerGame) external {
        Game storage game = games[_gameCode];
        require(game.state == GameState.Negotiating, "Invalid game state");
        require(msg.sender == game.player1 || msg.sender == game.player2, "Not a player");
        require(_wagerPerGame <= game.player1Balance && _wagerPerGame <= game.player2Balance, "Wager exceeds balance");

        if (msg.sender == game.player1) {
            game.player1WagerProposal = _wagerPerGame;
        } else {
            game.player2WagerProposal = _wagerPerGame;
        }
        emit WagerProposed(_gameCode, msg.sender, _wagerPerGame);

        if (game.player1WagerProposal == game.player2WagerProposal && game.player1WagerProposal > 0) {
            game.wagerPerGame = game.player1WagerProposal;
            game.state = GameState.Committed;
            emit WagerAccepted(_gameCode, game.wagerPerGame);
        }
    }

    function commitMove(bytes32 _gameCode, bytes32 _moveHash) external {
        Game storage game = games[_gameCode];
        require(game.state == GameState.Committed, "Invalid game state");
        require(msg.sender == game.player1 || msg.sender == game.player2, "Not a player");

        if (msg.sender == game.player1) {
            game.player1MoveHash = _moveHash;
        } else {
            game.player2MoveHash = _moveHash;
        }
        emit MoveCommitted(_gameCode, msg.sender);

        if (game.player1MoveHash != bytes32(0) && game.player2MoveHash != bytes32(0)) {
            game.state = GameState.Revealed;
        }
    }

    function revealMove(bytes32 _gameCode, uint8 _move, bytes32 _salt) external {
        require(_move >= 1 && _move <= 3, "Invalid move");
        Game storage game = games[_gameCode];
        require(game.state == GameState.Revealed, "Invalid game state");
        require(msg.sender == game.player1 || msg.sender == game.player2, "Not a player");
        bytes32 moveHash = keccak256(abi.encodePacked(_move, _salt));

        if (msg.sender == game.player1) {
            require(moveHash == game.player1MoveHash, "Invalid move hash");
            game.player1Move = Move(_move);
        } else {
            require(moveHash == game.player2MoveHash, "Invalid move hash");
            game.player2Move = Move(_move);
        }
        emit MoveRevealed(_gameCode, msg.sender, Move(_move));

        if (game.player1Move != Move.None && (game.player2 == address(0) || game.player2Move != Move.None)) {
            resolveRound(_gameCode);
        }
    }

    function requestRandomMove(bytes32 _gameCode) internal {
        uint256 requestId = COORDINATOR.requestRandomWords(
            keyHash,
            subscriptionId,
            requestConfirmations,
            callbackGasLimit,
            numWords
        );
        requestIdToGameCode[requestId] = _gameCode;
    }

    function fulfillRandomWords(uint256 _requestId, uint256[] memory _randomWords) internal override {
        bytes32 gameCode = requestIdToGameCode[_requestId];
        Game storage game = games[gameCode];
        require(game.player2 == address(0), "Not an AI game");

        game.player2Move = Move((_randomWords[0] % 3) + 1); // Maps to Rock (1), Paper (2), Scissors (3)
        emit MoveRevealed(gameCode, address(0), game.player2Move);
        resolveRound(gameCode);
    }

    function resolveRound(bytes32 _gameCode) internal {
        Game storage game = games[_gameCode];
        require(game.state == GameState.Revealed, "Invalid game state");

        address winner = determineWinner(game.player1Move, game.player2Move);
        uint256 fee = (game.wagerPerGame * 2 * platformFeePercent) / 100;
        uint256 payout = (game.wagerPerGame * 2) - fee;
        totalFees += fee;

        if (winner == game.player1) {
            game.player1Balance += payout;
            game.player2Balance -= game.wagerPerGame;
            game.player1Balance -= game.wagerPerGame;
        } else if (winner == game.player2) {
            game.player2Balance += payout;
            game.player1Balance -= game.wagerPerGame;
            game.player2Balance -= game.wagerPerGame;
        } else {
            // Tie: no balance changes
        }

        game.roundNumber++;
        emit RoundResolved(_gameCode, winner, payout);

        // Check if game should end
        if (game.player1Balance < game.wagerPerGame || game.player2Balance < game.wagerPerGame) {
            endGame(_gameCode);
        } else {
            // Reset for next round
            game.player1MoveHash = bytes32(0);
            game.player2MoveHash = bytes32(0);
            game.player1Move = Move.None;
            game.player2Move = Move.None;
            game.state = GameState.Committed;
            if (game.player2 == address(0)) {
                requestRandomMove(_gameCode);
            }
        }
    }

    function quitGame(bytes32 _gameCode) external {
        Game storage game = games[_gameCode];
        require(game.state != GameState.Ended, "Game already ended");
        require(msg.sender == game.player1 || msg.sender == game.player2, "Not a player");

        endGame(_gameCode);
        emit GameEnded(_gameCode, msg.sender);
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

    function endGame(bytes32 _gameCode) internal {
        Game storage game = games[_gameCode];
        require(iacsToken.transfer(game.player1, game.player1Balance), "Refund failed");
        if (game.player2 != address(0)) {
            require(iacsToken.transfer(game.player2, game.player2Balance), "Refund failed");
        }
        game.state = GameState.Ended;
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