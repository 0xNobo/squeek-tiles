# Squeek Tiles

A square hamster-tile elimination game built on Squeekchain (Sepolia testnet).

Players connect a wallet, approve SQK, and join a lobby. A hamster wheel spins
for 10 seconds, then one entered address is eliminated at random. This repeats
until one tile is left. The final tile decides the payout — it can pay the
whole pot, half of it, or nothing at all.

## Rules

- **Lobbies:** QUICK 4 (2×2), CLASSIC 9 (3×3), BIG 16 (4×4). The player count
  must form a perfect square.
- **Entry:** 20 SQK per player — **18 SQK** goes to the final prize pot,
  **2 SQK** is the creator fee (paid to the creator address in the same call).
  Starting pots: 72 / 162 / 288 SQK.
- **Lobby selection is automatic:** pick a lobby size and press Join. The site
  finds the newest open lobby of that size on the contract, or creates one if
  none is open. While a lobby is filling it shows live how many players have
  joined and how many more are needed; the game starts automatically when the
  lobby is full. Nobody types a game ID.
- **Raises:** after the first elimination, any alive player can propose a
  raise of +20 SQK (18 to pot, 2 fee). Every alive player has 30 seconds to
  accept or decline; accepters then have a separate 60-second window to submit
  their raise transaction. Both timers end early once everyone has responded.
  Max raises per game: 4-player lobby = 1, 9-player = 2, 16-player = 3.
  Players who decline, or whose raise transaction is not confirmed in time,
  are eliminated.
- **Final tile:** decided by a published, fixed formula on the seed block:

  ```
  seed = (block × 2654435761 + 97) mod 100
  ```

  | Seed | Tier  | Result |
  |------|-------|--------|
  | 0–49 | FULL  | Winner takes the whole pot |
  | 50–79 | HALF | Half to the winner, half to the treasury |
  | 80–99 | EMPTY | Winner gets 0 SQK, the whole pot goes to the treasury |

- **Treasury draw:** every **1,800 Sepolia blocks** (about 6 hours) anyone can
  call `treasuryDraw()`. The whole treasury is raffled among all addresses
  that entered a game before that draw block and airdropped to one winner.
  The schedule is set by block count, not by a server clock.
- **Practice mode:** the live game site also has a practice mode with fake
  tokens and bot opponents, so anyone can play and reviewers can test the game
  without a wallet or SQK.

## Deployed contract (Sepolia)

- **SqueekTiles:** `0x7042Fa3563706eAcc8688AF9C3bBcf4Ae1C6F212`
  ([Etherscan](https://sepolia.etherscan.io/address/0x7042Fa3563706eAcc8688AF9C3bBcf4Ae1C6F212))
- **Deploy tx:** `0x7072a5b6824f1657e93d8550c7dd9231e9e9a58098a567539632af8237c0908d`
  (2026-11-07, Status: Success)
- **SQK token:** `0xd78a3956cF63164d1Fa1C622ad3c66623162Fa1e` (ERC-20, 18 decimals)
- **Creator-fee recipient:** `0x8a53644c0CF45EFc0247E8e01d24607b870793C4`

Every meaningful event (`Joined`, `GameStarted`, `Eliminated`,
`RaiseProposed`, `GameFinished`, `TreasuryDrawn`) is emitted on-chain, so any
game can be reconstructed from the chain alone.

## Live game

Play it here: https://muse.ai/s/squeek-tiles-lxk6ecxf76gxwz/y0Q3xwU_NUJ832XeC-sUYn8fCGCy_yp4yHqpfUfJE2Y

Open the link in desktop Chrome with the MetaMask extension installed, switch
MetaMask to Sepolia (chain ID 11155111), and use Real Mode. Practice Mode
needs no wallet.

## How it uses Squeekchain

See `GENESIS_ANSWER.md` — the paste-ready answer for the Genesis submission
form's "How does it use Squeekchain?" question.

## Compile

The contract is `contracts/SqueekTiles.sol` (Solidity `^0.8.24`).

A plain compile fails with "Stack too deep", so it must be compiled with
**via-IR** and the optimizer enabled at **200 runs**:

```json
{
  "language": "Solidity",
  "sources": { "SqueekTiles.sol": { "content": "<contract source>" } },
  "settings": {
    "optimizer": { "enabled": true, "runs": 200 },
    "viaIR": true,
    "outputSelection": { "*": { "*": ["abi", "evm.bytecode"] } }
  }
}
```

With `solc` 0.8.24, via-IR + optimizer 200 runs, the compile succeeds with
0 errors and 0 warnings, 47 ABI entries, and 10,317 bytes of creation
bytecode (SHA-256
`12ed2f55d7d674b206192b232c8f27fe9faa3d2dae5a11ada0e209bd50820405`).

Using Python (`py-solc-x`):

```bash
pip install py-solc-x
python -c "import solcx; solcx.install_solc('0.8.24')"
```

then compile the standard JSON above with `solcx.compile_standard(..., solc_version='0.8.24')`.

## Deploy (Remix + MetaMask, Sepolia)

1. Open [Remix](https://remix.ethereum.org), create `contracts/SqueekTiles.sol`
   and paste the contract source.
2. Solidity Compiler: version **0.8.24**, optimization **enabled, 200 runs**,
   **via-IR enabled**. In Remix 2.6.x there is no via-IR toggle in the panel —
   select "Use configuration file" and add `"viaIR": true` inside
   `solidity-compiler` → `settings` in `remix.config.json`, then compile
   (green check).
3. Deploy & Run Transactions: environment **Injected Provider – MetaMask**,
   network **Sepolia**, contract **SqueekTiles** (not the `IERC20` interface).
4. Constructor arguments, in order:
   - `sqkToken`: `0xd78a3956cF63164d1Fa1C622ad3c66623162Fa1e`
   - `creatorAddress`: `0x8a53644c0CF45EFc0247E8e01d24607b870793C4`
5. Press Deploy and confirm in MetaMask (you need Sepolia ETH for gas —
   the original deploy cost 0.024 ETH).

## Disclaimer

Sepolia testnet only. SQK here is a test token with no real value. The
contract is **unaudited** — do not use it with real funds. Squeekchain has
no separate mainnet chain yet; its contracts and SQK live on Sepolia.
