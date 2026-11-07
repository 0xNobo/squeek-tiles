// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

interface IERC20 {
    function transferFrom(address from, address to, uint256 amount) external returns (bool);
    function transfer(address to, uint256 amount) external returns (bool);
    function balanceOf(address account) external view returns (uint256);
}

/// @title SqueekTiles — square-grid elimination game for Squeekchain (SQK / Sepolia)
/// @notice Lobbies are perfect squares only: 4 (2x2), 9 (3x3) or 16 (4x4).
///         Entry is 20 SQK: 18 SQK to the final tile's prize, 2 SQK creator fee.
///         The wheel spins 10 seconds per round, then one entered address is
///         randomly eliminated, until one survivor reaches the final tile.
///         The final tile's tier is fixed at game start from the block seed:
///           seed = (block.number * 2654435761 + 97) % 100
///           0-49 FULL (winner takes all) · 50-79 HALF (half to treasury)
///           80-99 EMPTY (all to treasury)
///         Raises: any survivor may propose +20 SQK (always the entry amount).
///         The raise limit depends on the lobby: 1 raise in a 4-player game,
///         2 in a 9-player game, 3 in a 16-player game. A raise has two
///         separate windows: 30 seconds only to accept or decline — which
///         closes early once every alive player has a recorded decision
///         (accepted via acceptRaise, or declined via declineRaise) — then,
///         for everyone who accepted, a further 60 seconds to submit and
///         confirm the +20 SQK transaction on-chain, which also closes
///         early once every accepted transaction has a recorded outcome
///         (confirmed via confirmRaiseTx, or failed via
///         markRaiseTxFailed). Declining, staying
///         silent, or leaving the transaction unconfirmed when its window
///         ends all mean elimination.
///         Treasury draw: every DRAW_INTERVAL blocks (1,800 blocks, about
///         6 hours at Sepolia's ~12-second block time), anyone can call
///         treasuryDraw() to raffle the whole treasury among all addresses
///         that entered a game before that draw block, airdropped to one winner.
contract SqueekTiles {
    IERC20 public immutable sqk;
    address public immutable creator;          // receives the 2 SQK fee per payment
    uint256 public constant ENTRY      = 20 ether;  // SQK has 18 decimals
    uint256 public constant TO_PRIZE   = 18 ether;
    uint256 public constant FEE        = 2 ether;
    uint256 public constant SPIN_TIME  = 10 seconds;
    uint256 public constant RAISE_TIME = 30 seconds; // decision window: accept / decline only
    uint256 public constant TX_TIME    = 60 seconds; // transaction window: submit + confirm
    uint256 public constant DRAW_INTERVAL = 1800; // blocks between treasury draws (~6 hours at ~12s per block)

    enum Tier { Full, Half, Empty }
    enum Phase { Filling, Playing, RaiseOpen, RaiseTx, Finished }

    struct Game {
        uint8 size;                 // 4, 9 or 16
        Phase phase;
        uint256 pot;                // SQK locked in the final tile
        uint256 seedBlock;          // block the tier seed was taken from
        uint256 seed;               // 0..99, fixed at start
        Tier tier;                  // fixed at start, revealed at the end
        uint8 raisesUsed;
        uint8 maxRaises;            // 1 for 4 players, 2 for 9, 3 for 16
        uint256 raiseDeadline;      // end of the 30s decision window
        uint256 txDeadline;         // end of the 60s transaction window
        address raiseProposer;
        uint256 spinReadyAt;        // earliest time the next elimination can run
        address winner;
    }

    uint256 public nextGameId = 1;
    mapping(uint256 => Game) public games;
    mapping(uint256 => address[]) public players;        // every entered address
    mapping(uint256 => mapping(address => bool)) public alive;
    mapping(uint256 => mapping(address => bool)) public raiseAccepted; // decision: accepted
    mapping(uint256 => mapping(address => bool)) public raiseDeclined; // decision: declined
    mapping(uint256 => mapping(address => bool)) public raiseMatched;  // tx outcome: confirmed
    mapping(uint256 => mapping(address => bool)) public raiseTxFailed; // tx outcome: failed
    mapping(uint256 => uint256) public aliveCount;

    uint256 public treasury;
    address[] public entrants;                            // addresses entered since the last treasury draw
    mapping(address => bool) public enteredThisPeriod;
    uint256 public lastDrawBlock;                         // block of the most recent treasury draw

    event Joined(uint256 indexed gameId, address player);
    event GameStarted(uint256 indexed gameId, uint256 seedBlock, uint256 seed);
    event Eliminated(uint256 indexed gameId, address player, uint256 round);
    event RaiseProposed(uint256 indexed gameId, address proposer, uint256 deadline);
    event RaiseAccepted(uint256 indexed gameId, address player);
    event RaiseDeclined(uint256 indexed gameId, address player);
    event TxWindowOpened(uint256 indexed gameId, uint256 txDeadline);
    event RaiseMatched(uint256 indexed gameId, address player);
    event RaiseTxFailed(uint256 indexed gameId, address player);
    event RaiseDropped(uint256 indexed gameId, address player);
    event GameFinished(uint256 indexed gameId, address winner, Tier tier, uint256 paidOut, uint256 toTreasury);
    event TreasuryDrawn(address winner, uint256 amount);

    constructor(address sqkToken, address creatorAddress) {
        sqk = IERC20(sqkToken);
        creator = creatorAddress;
        lastDrawBlock = block.number;
    }

    /// @notice Raise limit per game, by lobby size.
    function maxRaisesFor(uint8 size) public pure returns (uint8) {
        return size == 4 ? 1 : (size == 9 ? 2 : 3);
    }

    /// @dev True once every alive player has a recorded decision for the
    ///      open raise — accepted or declined. This is what lets the
    ///      30-second decision window end early.
    function _allDecided(uint256 gameId) internal view returns (bool) {
        address[] storage ps = players[gameId];
        for (uint256 i = 0; i < ps.length; i++) {
            address p = ps[i];
            if (alive[gameId][p] && !raiseAccepted[gameId][p] && !raiseDeclined[gameId][p]) return false;
        }
        return true;
    }

    /// @dev True once every accepted player has a recorded transaction
    ///      outcome — confirmed or failed. This is what lets the
    ///      60-second transaction window end early.
    function _allTxSettled(uint256 gameId) internal view returns (bool) {
        address[] storage ps = players[gameId];
        for (uint256 i = 0; i < ps.length; i++) {
            address p = ps[i];
            if (alive[gameId][p] && raiseAccepted[gameId][p] && !raiseMatched[gameId][p] && !raiseTxFailed[gameId][p]) return false;
        }
        return true;
    }

    /// @notice Create a lobby. Only square sizes can ever exist.
    function createGame(uint8 size) external returns (uint256 gameId) {
        require(size == 4 || size == 9 || size == 16, "lobby must be 4, 9 or 16");
        gameId = nextGameId++;
        games[gameId].size = size;
        games[gameId].maxRaises = maxRaisesFor(size);
        games[gameId].phase = Phase.Filling;
    }

    /// @notice Join: the player first approves this contract for 20 SQK in their
    ///         wallet, then this call records the entry transaction.
    ///         18 SQK stays here as prize, 2 SQK goes to the creator.
    function joinLobby(uint256 gameId) external {
        Game storage g = games[gameId];
        require(g.phase == Phase.Filling, "game not filling");
        require(!_contains(gameId, msg.sender), "already entered");
        require(players[gameId].length < g.size, "lobby full");

        require(sqk.transferFrom(msg.sender, address(this), ENTRY), "entry transfer failed");
        require(sqk.transfer(creator, FEE), "fee transfer failed");
        g.pot += TO_PRIZE;

        players[gameId].push(msg.sender);
        alive[gameId][msg.sender] = true;
        aliveCount[gameId]++;
        if (!enteredThisPeriod[msg.sender]) {
            enteredThisPeriod[msg.sender] = true;
            entrants.push(msg.sender);
        }
        emit Joined(gameId, msg.sender);

        if (players[gameId].length == g.size) _start(gameId);
    }

    /// @dev The tier is decided here, from the block produced at game start,
    ///      by the published formula. It cannot be changed afterwards.
    function _start(uint256 gameId) internal {
        Game storage g = games[gameId];
        g.phase = Phase.Playing;
        g.seedBlock = block.number;
        g.seed = (block.number * 2654435761 + 97) % 100;
        g.tier = g.seed < 50 ? Tier.Full : (g.seed < 80 ? Tier.Half : Tier.Empty);
        g.spinReadyAt = block.timestamp + SPIN_TIME;
        emit GameStarted(gameId, g.seedBlock, g.seed);
    }

    /// @notice After the 10-second spin, eliminate one random alive address.
    ///         The pick is a plain random draw among the entered addresses.
    function spinAndEliminate(uint256 gameId, uint256 round) external {
        Game storage g = games[gameId];
        require(g.phase == Phase.Playing, "not playing");
        require(block.timestamp >= g.spinReadyAt, "wheel still spinning");
        require(aliveCount[gameId] > 1, "one survivor left");

        uint256 roll = uint256(keccak256(abi.encodePacked(
            blockhash(block.number - 1), gameId, round, g.seed))) % aliveCount[gameId];
        address loser = _nthAlive(gameId, roll);
        alive[gameId][loser] = false;
        aliveCount[gameId]--;
        emit Eliminated(gameId, loser, round);

        if (aliveCount[gameId] == 1) _finish(gameId);
        else g.spinReadyAt = block.timestamp + SPIN_TIME;
    }

    /// @notice Any survivor can propose a raise — always exactly the entry
    ///         amount (20 SQK). The per-game limit depends on the lobby:
    ///         1 raise for 4 players, 2 for 9, 3 for 16. Proposing counts
    ///         as accepting; nobody pays anything yet.
    function proposeRaise(uint256 gameId) external {
        Game storage g = games[gameId];
        require(g.phase == Phase.Playing, "not playing");
        require(alive[gameId][msg.sender], "only survivors can propose");
        require(g.raisesUsed < g.maxRaises, "raise limit reached");
        g.phase = Phase.RaiseOpen;
        g.raisesUsed++;
        g.raiseProposer = msg.sender;
        g.raiseDeadline = block.timestamp + RAISE_TIME; // 30s, decide only
        raiseAccepted[gameId][msg.sender] = true;
        emit RaiseProposed(gameId, msg.sender, g.raiseDeadline);
    }

    /// @notice During the 30-second decision window, accept the raise.
    ///         This moves no tokens — payment happens in the tx window.
    ///         To decline instead, call declineRaise; staying silent also
    ///         counts as a decline once the deadline passes.
    function acceptRaise(uint256 gameId) external {
        Game storage g = games[gameId];
        require(g.phase == Phase.RaiseOpen, "no raise open");
        require(block.timestamp <= g.raiseDeadline, "decision window closed");
        require(alive[gameId][msg.sender], "not in game");
        require(!raiseAccepted[gameId][msg.sender], "already accepted");
        require(!raiseDeclined[gameId][msg.sender], "already declined");
        raiseAccepted[gameId][msg.sender] = true;
        emit RaiseAccepted(gameId, msg.sender);
    }

    /// @notice During the 30-second decision window, decline the raise.
    ///         This records the decision on-chain, so once every alive
    ///         player has accepted or declined, openTxWindow can close
    ///         the window early instead of waiting out the 30 seconds.
    ///         Declining eliminates you when the window is settled.
    function declineRaise(uint256 gameId) external {
        Game storage g = games[gameId];
        require(g.phase == Phase.RaiseOpen, "no raise open");
        require(block.timestamp <= g.raiseDeadline, "decision window closed");
        require(alive[gameId][msg.sender], "not in game");
        require(!raiseAccepted[gameId][msg.sender], "already accepted");
        require(!raiseDeclined[gameId][msg.sender], "already declined");
        raiseDeclined[gameId][msg.sender] = true;
        emit RaiseDeclined(gameId, msg.sender);
    }

    /// @notice Open the transaction window: everyone who did not accept —
    ///         declined on-chain, or stayed silent — is eliminated, and the
    ///         acceptors get a separate 60 seconds to pay on-chain. Callable
    ///         as soon as every alive player has a recorded decision,
    ///         accepted or declined (the decision timer ends early), or
    ///         after the 30s deadline.
    function openTxWindow(uint256 gameId) external {
        Game storage g = games[gameId];
        require(g.phase == Phase.RaiseOpen, "no raise open");
        require(block.timestamp > g.raiseDeadline || _allDecided(gameId), "decision window still open");
        address[] storage ps = players[gameId];
        for (uint256 i = 0; i < ps.length; i++) {
            address p = ps[i];
            if (alive[gameId][p] && !raiseAccepted[gameId][p]) {
                alive[gameId][p] = false;
                aliveCount[gameId]--;
                emit RaiseDropped(gameId, p);
            }
        }
        if (aliveCount[gameId] <= 1) { _finish(gameId); return; }
        g.phase = Phase.RaiseTx;
        g.txDeadline = block.timestamp + TX_TIME; // 60s: submit + confirm
        emit TxWindowOpened(gameId, g.txDeadline);
    }

    /// @notice During the 60-second transaction window, an acceptor pays
    ///         the +20 SQK raise. The transfer landing in this window is
    ///         the confirmation the contract records for that player.
    function confirmRaiseTx(uint256 gameId) external {
        Game storage g = games[gameId];
        require(g.phase == Phase.RaiseTx, "no tx window open");
        require(block.timestamp <= g.txDeadline, "tx window closed");
        require(alive[gameId][msg.sender], "not in game");
        require(raiseAccepted[gameId][msg.sender], "did not accept the raise");
        require(!raiseMatched[gameId][msg.sender], "tx already confirmed");
        require(!raiseTxFailed[gameId][msg.sender], "tx already marked failed");
        require(sqk.transferFrom(msg.sender, address(this), ENTRY), "raise transfer failed");
        require(sqk.transfer(creator, FEE), "fee transfer failed");
        g.pot += TO_PRIZE;
        raiseMatched[gameId][msg.sender] = true;
        emit RaiseMatched(gameId, msg.sender);
    }

    /// @notice During the 60-second transaction window, record that an
    ///         acceptor's raise transaction failed — the wallet rejected
    ///         it, it reverted, or it ran out of gas. This gives that
    ///         player a recorded outcome, so once every accepted
    ///         transaction is confirmed or failed, settleRaise can close
    ///         the window early instead of waiting out the 60 seconds.
    ///         A failed transaction eliminates you when the window settles.
    function markRaiseTxFailed(uint256 gameId) external {
        Game storage g = games[gameId];
        require(g.phase == Phase.RaiseTx, "no tx window open");
        require(block.timestamp <= g.txDeadline, "tx window closed");
        require(alive[gameId][msg.sender], "not in game");
        require(raiseAccepted[gameId][msg.sender], "did not accept the raise");
        require(!raiseMatched[gameId][msg.sender], "tx already confirmed");
        require(!raiseTxFailed[gameId][msg.sender], "tx failure already recorded");
        raiseTxFailed[gameId][msg.sender] = true;
        emit RaiseTxFailed(gameId, msg.sender);
    }

    /// @notice Settle the transaction window: everyone whose transaction
    ///         did not confirm — failed, or never submitted — is eliminated
    ///         on this tile. Callable as soon as every accepted transaction
    ///         has a recorded outcome, confirmed or failed (the 60-second
    ///         timer ends early), or after the 60 seconds are up.
    function settleRaise(uint256 gameId) external {
        Game storage g = games[gameId];
        require(g.phase == Phase.RaiseTx, "no tx window open");
        require(block.timestamp > g.txDeadline || _allTxSettled(gameId), "tx window still open");
        address[] storage ps = players[gameId];
        for (uint256 i = 0; i < ps.length; i++) {
            address p = ps[i];
            if (alive[gameId][p] && !raiseMatched[gameId][p]) {
                alive[gameId][p] = false;
                aliveCount[gameId]--;
                emit RaiseDropped(gameId, p);
            }
            raiseAccepted[gameId][p] = false;
            raiseDeclined[gameId][p] = false;
            raiseMatched[gameId][p] = false;
            raiseTxFailed[gameId][p] = false;
        }
        g.phase = Phase.Playing;
        g.spinReadyAt = block.timestamp + SPIN_TIME;
        if (aliveCount[gameId] == 1) _finish(gameId);
    }

    function _finish(uint256 gameId) internal {
        Game storage g = games[gameId];
        g.phase = Phase.Finished;
        g.winner = _nthAlive(gameId, 0);
        uint256 pot = g.pot;
        g.pot = 0;
        uint256 toWinner = g.tier == Tier.Full ? pot : (g.tier == Tier.Half ? pot / 2 : 0);
        uint256 toTreasury = pot - toWinner;
        if (toWinner > 0) require(sqk.transfer(g.winner, toWinner), "payout failed");
        treasury += toTreasury;
        emit GameFinished(gameId, g.winner, g.tier, toWinner, toTreasury);
    }

    /// @notice Treasury draw: callable by anyone once DRAW_INTERVAL blocks
    ///         (1,800 blocks, about 6 hours at ~12 seconds per block) have
    ///         passed since the last draw. The whole treasury is raffled
    ///         among all addresses that entered a game before this draw
    ///         block and airdropped to one winner by transfer.
    function treasuryDraw() external {
        require(block.number >= lastDrawBlock + DRAW_INTERVAL, "draw not due yet");
        require(treasury > 0, "treasury empty");
        require(entrants.length > 0, "no entrants this period");
        uint256 roll = uint256(keccak256(abi.encodePacked(
            blockhash(block.number - 1), treasury, lastDrawBlock))) % entrants.length;
        address winner = entrants[roll];
        uint256 amount = treasury;
        treasury = 0;
        lastDrawBlock = block.number;
        for (uint256 i = 0; i < entrants.length; i++) enteredThisPeriod[entrants[i]] = false;
        delete entrants;
        require(sqk.transfer(winner, amount), "airdrop failed");
        emit TreasuryDrawn(winner, amount);
    }

    // --- helpers -------------------------------------------------------------
    function _contains(uint256 gameId, address a) internal view returns (bool) {
        address[] storage ps = players[gameId];
        for (uint256 i = 0; i < ps.length; i++) if (ps[i] == a) return true;
        return false;
    }

    function _nthAlive(uint256 gameId, uint256 n) internal view returns (address) {
        address[] storage ps = players[gameId];
        uint256 seen = 0;
        for (uint256 i = 0; i < ps.length; i++) {
            if (alive[gameId][ps[i]]) {
                if (seen == n) return ps[i];
                seen++;
            }
        }
        revert("no such alive player");
    }
}
