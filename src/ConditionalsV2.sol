// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Ownable, Ownable2Step} from "@openzeppelin/contracts/access/Ownable2Step.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {EIP712} from "@openzeppelin/contracts/utils/cryptography/EIP712.sol";
import {SignatureChecker} from "@openzeppelin/contracts/utils/cryptography/SignatureChecker.sol";
import {Strings} from "@openzeppelin/contracts/utils/Strings.sol";
import {FixedPointMathLib as FPM} from "solady/utils/FixedPointMathLib.sol";

import {IIntake, IIntakePrice} from "./interfaces/IIntake.sol";
import {IOracleAttestation} from "./interfaces/IOracleAttestation.sol";

/// @title ConditionalsV2
/// @notice Conditional prediction markets in IMD with a logarithmic market maker, settled by the IdentityMD oracle.
///
/// A market asks "if CONDITION, will OUTCOME?" and has four outcomes, index = 2 * world + side:
///   0 condition and outcome, 1 condition and not outcome, 2 no condition and outcome, 3 no condition and not outcome.
/// One share of the outcome that happens pays 1 IMD, so one complete set of all four shares is always worth 1 IMD.
///
/// The creator funds an LMSR maker with a neutral seed of b ln 4, which is the most the creator can lose. From the
/// first trade every outcome has a price, and traders can enter and leave until `closeTime`. `stakeConditional` gives
/// the position of a conditional bet: paid if its world happens on its side, refunded if the other world happens.
///
/// Every sale to or purchase from the maker pays a 2% fee: half accrues to the market's creator, 67/200 is burned
/// (sent to 0x...dEaD) and the rest accrues to the fee recipient. Claims and complete sets redeemed by `exit` are free.
///
/// After `resolveTime` anyone calls `requestResolution`. The contract pays the IdentityMD Intake for two oracle
/// questions (the condition and the outcome) out of the budget the creator deposited, and pins the hash of each
/// question it asked. An answer counts only when the oracle's signer signed it for this contract, for that exact
/// question, with at least the market's panel and quorum.
///
/// Settlement needs both answers. Each share of the outcome that happened claims 1 IMD, and what is left in the maker
/// goes to the creator. A market with no usable answer by `voidAfter` (resolveTime + 30 days) can be voided by anyone:
/// each account gets back what it paid for the shares it still holds, excluding fees and pro rata if short, and the
/// creator is paid last. Gains and losses already realised against the maker are not refunded: a loss one account
/// realised is IMD another account took out, so refunding it would come out of the seed and the other refunds.
/// A void waits while an ask younger than RETRY_DELAY is still live, so an answer on its way cannot be voided away.
///
/// The owner can only rotate the oracle configuration for future markets (behind a 3 day delay) and change the fee
/// recipient. It cannot touch trades, answers or open markets: each market keeps the configuration it was created with.
contract ConditionalsV2 is Ownable2Step, ReentrancyGuard, EIP712, IOracleAttestation {
    using SafeERC20 for IERC20;
    using Strings for uint256;
    using Strings for address;

    // ---------------------------------------------------------------------------------------------------------------
    // Constants
    // ---------------------------------------------------------------------------------------------------------------

    /// @notice Where burned IMD goes. IMD reverts on transfers to the zero address.
    address public constant BURN_ADDRESS = 0x000000000000000000000000000000000000dEaD;

    uint256 internal constant BPS = 10_000;
    /// @notice Fee on every trade with the maker.
    uint256 public constant FEE_BPS = 200;
    /// @notice The fee's split, out of FEE_BPS: creator, burned; the rest goes to the fee recipient.
    uint256 internal constant LP_SHARE_BPS = 100;
    uint256 internal constant BURN_SHARE_BPS = 67;

    /// @notice Smallest trade, 0.001 IMD.
    uint256 public constant MIN_TRADE = 1e15;
    /// @notice Bounds for the liquidity parameter. A market's seed, and the creator's maximum loss, is b ln 4.
    uint256 public constant MIN_B = 0.5 ether;
    uint256 public constant MAX_B = 100 ether;
    /// @notice The widest gap between two outcomes' maker positions, in units of b. It bounds every price away from
    ///         0 (about 2e-9) so the fixed point stays exact, and a saturated market refuses trades instead of misquoting.
    int256 internal constant MAX_SPREAD_B = 20;
    /// @notice The largest spend in one maker purchase, in units of b, which keeps the exponential in range.
    uint256 internal constant MAX_SPEND_B = 30;

    uint256 internal constant MAX_CONDITION_LENGTH = 280;
    uint256 internal constant MAX_OUTCOME_LENGTH = 280;
    uint256 internal constant MAX_RULES_LENGTH = 500;

    /// @notice Furthest a market's resolveTime can be from its creation.
    uint256 internal constant MAX_HORIZON = 730 days;
    /// @notice How long after resolveTime a market waits for answers before anyone can void it.
    uint256 public constant RESOLUTION_PERIOD = 30 days;
    /// @notice How long an unanswered question waits before it can be asked again.
    uint256 public constant RETRY_DELAY = 1 days;
    /// @notice Delay before a proposed oracle configuration can be activated.
    uint256 internal constant CONFIG_DELAY = 3 days;
    /// @notice How long after its delay a proposed configuration stays activatable. A proposal that is not
    ///         activated in this window lapses, so a creator never meets a configuration proposed months earlier.
    uint256 internal constant CONFIG_WINDOW = 7 days;
    /// @notice How far ahead of this chain's clock an attestation's `issuedAt` may sit (the protocol's tolerance).
    uint256 internal constant ISSUED_AT_TOLERANCE = 5 minutes;

    /// @notice Bounds for the oracle configuration.
    uint16 internal constant MIN_PANEL_SIZE = 5;
    uint16 internal constant MAX_PANEL_SIZE = 100;
    uint256 internal constant MAX_PRICE = 10 ether;

    /// @notice The chain the oracle question's window is pinned to, written as a literal in `_document`. On Robinhood
    ///         Chain `block.number` is the Ethereum mainnet block number, so the window is an Ethereum block.
    uint256 internal constant QUESTION_CHAIN_ID = 1;
    /// @notice How far behind `block.number` the question's block is: the oracle needs at least 5 blocks of depth.
    uint256 public constant WINDOW_DEPTH = 10;
    /// @notice How long a signed answer stays valid.
    uint256 internal constant VALID_FOR_SECONDS = 86_400;

    /// @notice The oracle action the contract is deployed with. Each market carries its own (`OracleConfig.action`),
    ///         so a new action version can be rotated in for future markets without a redeploy.
    bytes32 internal constant ORACLE_ACTION = "oracle.request@oracle-1";

    bytes32 internal constant ATTESTATION_TYPEHASH = keccak256(
        "OracleAttestation(bytes32 requestId,uint256 chainId,bytes32 questionHash,uint8 answerType,bytes answer,"
        "uint256 figure,uint64 fromBlock,uint64 toBlock,bytes32 blockHash,bytes32 panelJobId,uint16 panelSize,"
        "uint16 quorum,uint16 agreed,uint64 issuedAt,uint64 expiresAt)"
    );

    uint8 internal constant CONDITION = 0;
    uint8 internal constant OUTCOME = 1;

    /// @dev Answer states.
    uint8 internal constant UNANSWERED = 0;
    uint8 internal constant ANSWER_TRUE = 1;
    uint8 internal constant ANSWER_FALSE = 2;

    // ---------------------------------------------------------------------------------------------------------------
    // Types
    // ---------------------------------------------------------------------------------------------------------------

    enum Status {
        Open,
        Settled,
        Voided
    }

    struct OracleConfig {
        IIntake intake;
        /// @dev The attester: an EOA, or a contract that answers ERC-1271 (the protocol's signer registry).
        address signer;
        uint128 price;
        uint16 panelSize;
        uint16 quorum;
        /// @dev The Intake action id, e.g. bytes32("oracle.request@oracle-1").
        bytes32 action;
    }

    struct Market {
        address creator;
        uint64 closeTime;
        uint64 resolveTime;
        uint64 voidAfter;
        Status status;
        /// @dev Set on settlement: the outcome index that happened.
        uint8 winner;
        /// @dev Per question: UNANSWERED, ANSWER_TRUE or ANSWER_FALSE.
        uint8[2] answers;
        /// @dev Per question: asks sent and not yet called back, and when the last one was sent.
        uint8[2] openAsks;
        uint64[2] lastAskAt;
        /// @dev The oracle configuration this market was created with.
        OracleConfig oracle;
        /// @dev IMD left for oracle questions, deposited by the creator.
        uint256 budget;
        /// @dev The maker's net shares sold per outcome, negative when it holds inventory bought from traders.
        int256[4] q;
        /// @dev The liquidity parameter, fixed at creation.
        uint256 b;
        /// @dev The seed the creator put in, b ln 4.
        uint256 subsidy;
        /// @dev IMD backing the maker. Always at least C(q), the LMSR cost function, so at least every q[i].
        uint256 makerBalance;
        /// @dev Complete sets outstanding, each backed by 1 IMD held outside the maker. Total shares of outcome i are
        ///      q[i] + sets.
        uint256 sets;
        /// @dev Sum of every account's `netIn` (the cost of the shares it holds): what a void has to refund.
        uint256 refundBase;
        /// @dev Set on void: how much of `refundBase` the market can pay.
        uint256 refundPool;
        string condition;
        string outcome;
        string rules;
    }

    struct Ask {
        uint256 marketId;
        uint8 question;
        bool live;
        bytes32 questionHash;
    }

    // ---------------------------------------------------------------------------------------------------------------
    // Storage
    // ---------------------------------------------------------------------------------------------------------------

    IERC20 public immutable imd;

    /// @notice The configuration new markets are created with.
    OracleConfig public oracleConfig;
    /// @notice A proposed configuration and when it can be activated (zero: none).
    OracleConfig public pendingOracleConfig;
    uint256 public pendingOracleConfigAt;

    /// @notice Receives the builder share of the fee.
    address public feeRecipient;

    uint256 public marketCount;
    mapping(uint256 => Market) internal _markets;

    /// @notice Internal, non-transferable shares: shares[marketId][account][outcome].
    mapping(uint256 => mapping(address => uint256[4])) internal _shares;
    /// @notice What each account paid for the shares it holds, per outcome, fees excluded: _basis[marketId][account]
    ///         [outcome]. A buy adds its cost, a stake adds its collateral split over the outcomes it keeps by their
    ///         prices, and a sell or an exit releases the sold shares' share of it. A void refunds the sum (`netIn`).
    mapping(uint256 => mapping(address => uint256[4])) internal _basis;
    mapping(uint256 => mapping(address => bool)) public claimed;

    /// @notice Asks this contract sent, keyed by keccak256(intake, intake requestId).
    mapping(bytes32 => Ask) public asks;

    /// @notice IMD held for a creator or the fee recipient: accrued trading fees, and anything a settlement or void
    ///         could not push because IMD refused the transfer. Collected with `withdrawOwed`.
    mapping(address => uint256) public owed;

    /// @notice Totals, for display.
    uint256 public totalBurned;
    uint256 public totalBuilderFees;
    uint256 public totalCreatorFees;
    uint256 public totalOracleSpend;

    // ---------------------------------------------------------------------------------------------------------------
    // Events and errors
    // ---------------------------------------------------------------------------------------------------------------

    event MarketCreated(
        uint256 indexed marketId,
        address indexed creator,
        uint64 closeTime,
        uint64 resolveTime,
        uint256 b,
        uint256 seed,
        string condition,
        string outcome,
        string rules
    );
    /// @dev `collateral` is the IMD that moved into (positive) or out of (negative) the market, fees excluded.
    event Traded(uint256 indexed marketId, address indexed account, int256 collateral, uint256 fee);
    event ResolutionRequested(
        uint256 indexed marketId, uint8 indexed question, bytes32 requestId, bytes32 questionHash, uint256 windowBlock
    );
    event Answered(uint256 indexed marketId, uint8 indexed question, bool answer, bytes32 oracleRequestId);
    event AnswerIgnored(uint256 indexed marketId, uint8 indexed question, bytes32 requestId);
    event AskFailed(uint256 indexed marketId, uint8 indexed question, bytes32 requestId, uint8 status, bytes32 reason);
    event Settled(uint256 indexed marketId, uint8 winner, uint256 makerResidual);
    event Voided(uint256 indexed marketId, uint256 refundPool, uint256 refundBase, uint256 toCreator);
    event BudgetReturned(uint256 indexed marketId, address indexed creator, uint256 amount);
    event Claimed(uint256 indexed marketId, address indexed trader, uint256 amount);
    event PaymentDeferred(address indexed to, uint256 amount);
    event OwedWithdrawn(address indexed to, uint256 amount);
    event OracleConfigProposed(OracleConfig config, uint256 activatableAt);
    event OracleConfigActivated(OracleConfig config);
    event FeeRecipientSet(address feeRecipient);

    error InvalidText();
    error InvalidTimes();
    error InvalidConfig();
    error InvalidChoice();
    error TradeTooSmall();
    error TradeTooLarge();
    error PriceLimit();
    error SlippageExceeded();
    error InsufficientMaker();
    error NoPosition();
    error UnknownMarket();
    error MarketNotOpen();
    error BettingClosed();
    error TooEarly();
    error NothingToAsk();
    error NotSettleable();
    error NotVoidable();
    error AlreadyClaimed();
    error NothingToClaim();
    error UnknownAsk();
    error BadAttestation();
    error ZeroAddress();
    error DuplicateAsk();
    error BudgetTooHigh(uint256 budget, uint256 maxBudget);
    error ConfigExpired();

    // ---------------------------------------------------------------------------------------------------------------
    // Construction and configuration
    // ---------------------------------------------------------------------------------------------------------------

    /// @param owner_ Can rotate the oracle configuration for future markets and change the fee recipient.
    /// @param imd_ IMD on this chain (Robinhood Chain: 0x5f7bb59365ce557c26dbcaa4ee9d39a4b95b7127).
    /// @param intake_ The IdentityMD Intake (0xa43e6f75ee006411f79ac1c84120606c2330de82).
    /// @param oracleSigner_ The oracle's attester (0x5598aa9146215bc13eb26f2c692ad1461fd32982).
    /// @param feeRecipient_ Receives the builder share of the fee.
    constructor(address owner_, IERC20 imd_, IIntake intake_, address oracleSigner_, address feeRecipient_)
        Ownable(owner_)
        EIP712("IdentityMD Oracle", "2")
    {
        if (address(imd_) == address(0) || feeRecipient_ == address(0)) revert ZeroAddress();
        imd = imd_;
        feeRecipient = feeRecipient_;
        OracleConfig memory config = OracleConfig({
            intake: intake_, signer: oracleSigner_, price: 0.5 ether, panelSize: 5, quorum: 4, action: ORACLE_ACTION
        });
        _validateConfig(config);
        oracleConfig = config;
        emit OracleConfigActivated(config);
        emit FeeRecipientSet(feeRecipient_);
    }

    /// @notice Proposes a new oracle configuration for future markets. Activatable after CONFIG_DELAY.
    function proposeOracleConfig(OracleConfig calldata config) external onlyOwner {
        _validateConfig(config);
        pendingOracleConfig = config;
        pendingOracleConfigAt = block.timestamp + CONFIG_DELAY;
        emit OracleConfigProposed(config, pendingOracleConfigAt);
    }

    /// @notice Activates the proposed configuration, between CONFIG_DELAY and CONFIG_DELAY + CONFIG_WINDOW after
    ///         it was proposed. Markets created earlier keep theirs.
    function activateOracleConfig() external onlyOwner {
        uint256 at = pendingOracleConfigAt;
        if (at == 0 || block.timestamp < at) revert TooEarly();
        if (block.timestamp > at + CONFIG_WINDOW) revert ConfigExpired();
        oracleConfig = pendingOracleConfig;
        delete pendingOracleConfig;
        pendingOracleConfigAt = 0;
        emit OracleConfigActivated(oracleConfig);
    }

    function setFeeRecipient(address feeRecipient_) external onlyOwner {
        if (feeRecipient_ == address(0)) revert ZeroAddress();
        feeRecipient = feeRecipient_;
        emit FeeRecipientSet(feeRecipient_);
    }

    // ---------------------------------------------------------------------------------------------------------------
    // Markets
    // ---------------------------------------------------------------------------------------------------------------

    /// @notice Creates a market. The creator deposits two oracle questions' worth of IMD (1 IMD at 0.5 IMD each), which
    ///         pays for its resolution and returns what is not spent, plus the maker's seed of b ln 4 (`seedFor`).
    /// @param condition The event the market is conditional on, e.g. "The Clarity Act is signed into US law".
    /// @param outcome What traders predict, e.g. "ETH closes above 5000 USD on Coinbase on 2026-12-01".
    /// @param rules How the oracle should judge both, including the sources to use.
    /// @param closeTime Trading stops at this unix time. Set it before the condition or outcome can be known: trades
    ///        are accepted until then whatever has become public, and the seed is what informed trading can take.
    /// @param resolveTime Both statements are judged as of this unix time; resolution can be requested from then.
    /// @param maxBudget The most IMD the creator agrees to deposit for the oracle (two questions at the active price).
    ///        The call reverts if an oracle configuration activated meanwhile charges more.
    /// @param b The liquidity parameter: higher means deeper prices and a larger seed.
    function createMarket(
        string calldata condition,
        string calldata outcome,
        string calldata rules,
        uint64 closeTime,
        uint64 resolveTime,
        uint256 maxBudget,
        uint256 b
    ) external nonReentrant returns (uint256 marketId) {
        _validateText(condition, MAX_CONDITION_LENGTH);
        _validateText(outcome, MAX_OUTCOME_LENGTH);
        // The oracle lowercases a definition that is exactly an address or a 32-byte hex string before hashing it.
        // Such a value has no space, so requiring one keeps the hash this contract computes equal to the oracle's.
        if (!_validateText(rules, MAX_RULES_LENGTH)) revert InvalidText();
        if (closeTime <= block.timestamp || resolveTime < closeTime || resolveTime > block.timestamp + MAX_HORIZON) {
            revert InvalidTimes();
        }
        if (b < MIN_B || b > MAX_B) revert InvalidConfig();

        marketId = ++marketCount;
        Market storage m = _markets[marketId];
        m.creator = msg.sender;
        m.closeTime = closeTime;
        m.resolveTime = resolveTime;
        m.voidAfter = resolveTime + uint64(RESOLUTION_PERIOD);
        m.oracle = oracleConfig;
        m.budget = uint256(m.oracle.price) * 2;
        if (m.budget > maxBudget) revert BudgetTooHigh(m.budget, maxBudget);
        m.condition = condition;
        m.outcome = outcome;
        m.rules = rules;

        uint256 seed = seedFor(b);
        m.b = b;
        m.subsidy = seed;
        m.makerBalance = seed;

        imd.safeTransferFrom(msg.sender, address(this), m.budget + seed);
        emit MarketCreated(marketId, msg.sender, closeTime, resolveTime, b, seed, condition, outcome, rules);
    }

    /// @notice Pays `amount` IMD for a conditional position: if `world` happens the account is paid on `side`, and if
    ///         the other world happens it gets `amount` back. A complete set is minted, the opposite side is sold to
    ///         the maker and the proceeds buy more of the chosen side, so the price is fixed at entry.
    /// @param world 0 the condition happens, 1 it does not.
    /// @param side 0 the outcome happens, 1 it does not.
    /// @param minShares The fewest extra shares of the chosen outcome the caller accepts.
    /// @return shares The extra shares bought with the proceeds.
    function stakeConditional(uint256 marketId, uint8 world, uint8 side, uint256 amount, uint256 minShares)
        external
        nonReentrant
        returns (uint256 shares)
    {
        return _stake(msg.sender, marketId, world, side, amount, minShares);
    }

    /// @notice `stakeConditional` paid by the caller and credited to `account`. Used by the zap that swaps other coins.
    function stakeFor(address account, uint256 marketId, uint8 world, uint8 side, uint256 amount, uint256 minShares)
        external
        nonReentrant
        returns (uint256 shares)
    {
        if (account == address(0)) revert ZeroAddress();
        return _stake(account, marketId, world, side, amount, minShares);
    }

    /// @notice Buys `shares` of `outcome` from the maker.
    /// @return cost What the shares cost, without the fee.
    /// @return fee The fee on top.
    function buy(uint256 marketId, uint8 outcome, uint256 shares, uint256 maxCost)
        external
        nonReentrant
        returns (uint256 cost, uint256 fee)
    {
        Market storage m = _tradable(marketId);
        if (outcome > 3) revert InvalidChoice();
        if (shares < MIN_TRADE) revert TradeTooSmall();
        // int256(shares) would wrap above type(int256).max into a tiny sale credited as `shares` (review e665f90a).
        if (shares > uint256(type(int256).max)) revert TradeTooLarge();

        (int256[4] memory q, uint256 c) = _quote(m.q, m.b, outcome, int256(shares));
        _checkSpread(q, m.b);
        cost = c;
        fee = _fee(cost);
        if (cost + fee > maxCost) revert SlippageExceeded();

        m.q = q;
        m.makerBalance += cost;
        _shares[marketId][msg.sender][outcome] += shares;
        _basis[marketId][msg.sender][outcome] += cost;
        m.refundBase += cost;

        imd.safeTransferFrom(msg.sender, address(this), cost + fee);
        _chargeFee(m, fee);
        emit Traded(marketId, msg.sender, int256(cost), fee);
    }

    /// @notice Sells `shares` of `outcome` to the maker.
    /// @return proceeds What the caller receives, after the fee.
    function sell(uint256 marketId, uint8 outcome, uint256 shares, uint256 minProceeds)
        external
        nonReentrant
        returns (uint256 proceeds)
    {
        Market storage m = _tradable(marketId);
        if (outcome > 3) revert InvalidChoice();
        if (shares < MIN_TRADE) revert TradeTooSmall();
        uint256 fee;
        (proceeds, fee) = _sell(marketId, m, msg.sender, outcome, shares);
        if (proceeds < minProceeds) revert SlippageExceeded();
        imd.safeTransfer(msg.sender, proceeds);
        _chargeFee(m, fee);
        emit Traded(marketId, msg.sender, -int256(proceeds + fee), fee);
    }

    /// @notice Leaves a market at once: redeems every complete set the caller holds and sells the rest to the maker.
    /// @return proceeds What the caller receives, after fees.
    function exit(uint256 marketId, uint256 minProceeds) external nonReentrant returns (uint256 proceeds) {
        Market storage m = _tradable(marketId);
        uint256[4] storage held = _shares[marketId][msg.sender];
        uint256 sets_ = held[0];
        for (uint256 i = 1; i < 4; ++i) {
            if (held[i] < sets_) sets_ = held[i];
        }
        if (sets_ != 0) {
            // Sets bought from the maker one outcome at a time are not in `sets`: the maker redeems those, which moves
            // every q down by the same amount and C(q) with it, so prices do not change and makerBalance >= C(q).
            uint256 minted = FPM.min(sets_, m.sets);
            uint256 fromMaker = sets_ - minted;
            for (uint256 i; i < 4; ++i) {
                _release(marketId, m, msg.sender, i, sets_);
                m.q[i] -= int256(fromMaker);
            }
            m.sets -= minted;
            m.makerBalance -= fromMaker;
            proceeds = sets_;
        }
        uint256 fee;
        for (uint8 i; i < 4; ++i) {
            // Sells only as much as keeps the spread inside MAX_SPREAD_B; shares beyond it are worth under ~2e-9 IMD
            // each and stay with the account.
            uint256 rest = FPM.min(held[i], _sellRoom(m.q, m.b, i));
            if (rest < MIN_TRADE) continue;
            (uint256 net, uint256 f) = _sell(marketId, m, msg.sender, i, rest);
            proceeds += net;
            fee += f;
        }
        if (proceeds == 0) revert NoPosition();
        if (proceeds < minProceeds) revert SlippageExceeded();
        imd.safeTransfer(msg.sender, proceeds);
        _chargeFee(m, fee);
        emit Traded(marketId, msg.sender, -int256(proceeds + fee), fee);
    }

    // ---------------------------------------------------------------------------------------------------------------
    // Resolution
    // ---------------------------------------------------------------------------------------------------------------

    /// @notice Asks the oracle every question the market still needs. Anyone can call it from resolveTime.
    ///         Each ask is paid from the market's budget while it lasts, then by the caller: the budget is drawn down
    ///         to zero and the caller pays only the shortfall. A retry is allowed RETRY_DELAY after the last ask of a
    ///         question that has not been answered, or at once after the Intake reported a failure.
    /// @return asked How many questions were asked.
    function requestResolution(uint256 marketId) external nonReentrant returns (uint256 asked) {
        Market storage m = _market(marketId);
        if (m.status != Status.Open) revert MarketNotOpen();
        if (block.timestamp < m.resolveTime) revert TooEarly();
        if (block.timestamp > m.voidAfter) revert MarketNotOpen();

        for (uint8 q = 0; q < 2; ++q) {
            if (_askable(m, q)) {
                _ask(marketId, m, q);
                ++asked;
            }
        }
        if (asked == 0) revert NothingToAsk();
    }

    /// @notice The Intake's callback with a signed oracle answer. Selector 0x510379c7.
    function onOracleResult(bytes32 requestId, Attestation calldata a, bytes calldata signature) external {
        (uint256 marketId, uint8 question, bytes32 questionHash) = _takeAsk(requestId);
        Market storage m = _markets[marketId];

        if (m.status != Status.Open || m.answers[question] != UNANSWERED) {
            emit AnswerIgnored(marketId, question, requestId);
            return;
        }

        if (
            a.questionHash != questionHash || a.answerType != 0 || a.answer.length != 32
                || a.panelSize < m.oracle.panelSize || a.quorum < m.oracle.quorum || a.agreed < a.quorum
                || a.agreed > a.panelSize || block.timestamp > a.expiresAt
                || a.issuedAt > block.timestamp + ISSUED_AT_TOLERANCE
        ) revert BadAttestation();

        if (!SignatureChecker.isValidSignatureNow(m.oracle.signer, attestationDigest(a), signature)) {
            revert BadAttestation();
        }

        uint256 value = abi.decode(a.answer, (uint256));
        if (value > 1) revert BadAttestation();

        m.answers[question] = value == 1 ? ANSWER_TRUE : ANSWER_FALSE;
        emit Answered(marketId, question, value == 1, a.requestId);
    }

    /// @notice The Intake's callback for a refusal (status 1) or no result (2). Selector 0x5a0df71e.
    ///         Unsigned, so it only clears the ask: the question can be asked again at once.
    function onFailure(bytes32 requestId, uint8 status, bytes32 reason, uint16, uint16, bytes calldata) external {
        (uint256 marketId, uint8 question,) = _takeAsk(requestId);
        emit AskFailed(marketId, question, requestId, status, reason);
    }

    /// @dev Closes the live ask the caller (an intake) made for `requestId` and returns what it was for.
    function _takeAsk(bytes32 requestId) internal returns (uint256 marketId, uint8 question, bytes32 questionHash) {
        bytes32 key = _askKey(msg.sender, requestId);
        Ask storage ask = asks[key];
        if (!ask.live) revert UnknownAsk();
        (marketId, question, questionHash) = (ask.marketId, ask.question, ask.questionHash);
        delete asks[key];
        --_markets[marketId].openAsks[question];
    }

    /// @notice Settles a market once the oracle has answered both questions.
    function settle(uint256 marketId) external nonReentrant {
        Market storage m = _market(marketId);
        if (!_settleable(m)) revert NotSettleable();
        _settle(marketId, m);
    }

    /// @notice Voids a market that has no usable answer by voidAfter. Every stake is refunded. Refused while an
    ///         unanswered question has an ask younger than RETRY_DELAY still live, so an answer on its way counts.
    function voidMarket(uint256 marketId) external nonReentrant {
        Market storage m = _market(marketId);
        if (!_voidable(m)) revert NotVoidable();
        m.status = Status.Voided;
        uint256 balance = m.makerBalance + m.sets;
        uint256 pool = FPM.min(balance, m.refundBase);
        uint256 toCreator = balance - pool;
        m.refundPool = pool;
        emit Voided(marketId, pool, m.refundBase, toCreator);
        _push(m.creator, toCreator);
        _returnBudget(marketId, m);
    }

    /// @notice Pays the caller everything owed to them by a settled or voided market. Settles first if it can.
    ///         Returns 0, and changes nothing, for an account that has nothing to claim.
    function claim(uint256 marketId) external nonReentrant returns (uint256 amount) {
        Market storage m = _market(marketId);
        if (m.status == Status.Open) {
            if (!_settleable(m)) revert NotSettleable();
            _settle(marketId, m);
        }
        if (claimed[marketId][msg.sender]) revert AlreadyClaimed();
        amount = _payout(marketId, m, msg.sender);
        if (amount == 0) return 0;
        claimed[marketId][msg.sender] = true;
        imd.safeTransfer(msg.sender, amount);
        emit Claimed(marketId, msg.sender, amount);
    }

    /// @notice Pays the caller what a settlement or void could not push to them (see `owed`).
    function withdrawOwed() external nonReentrant returns (uint256 amount) {
        amount = owed[msg.sender];
        if (amount == 0) revert NothingToClaim();
        owed[msg.sender] = 0;
        imd.safeTransfer(msg.sender, amount);
        emit OwedWithdrawn(msg.sender, amount);
    }

    // ---------------------------------------------------------------------------------------------------------------
    // Views
    // ---------------------------------------------------------------------------------------------------------------

    function getMarket(uint256 marketId) external view returns (Market memory) {
        return _market(marketId);
    }

    /// @notice An account's shares per outcome.
    function sharesOf(uint256 marketId, address account) external view returns (uint256[4] memory) {
        return _shares[marketId][account];
    }

    /// @notice What an account paid, fees excluded, for the shares it still holds in a market: the cost of its
    ///         position, which a void refunds (pro rata if short). Gains and losses realised by selling or redeeming
    ///         shares are not in it.
    function netIn(uint256 marketId, address account) external view returns (int256) {
        return int256(_basisOf(marketId, account));
    }

    /// @notice The seed a market with liquidity parameter `b` needs: b ln 4, rounded up.
    function seedFor(uint256 b) public pure returns (uint256) {
        int256[4] memory zero;
        return uint256(_cost(zero, b, true));
    }

    /// @notice Each outcome's price in WAD. They sum to 1e18 within a few wei.
    function prices(uint256 marketId) external view returns (uint256[4] memory) {
        Market storage m = _market(marketId);
        return _prices(m.q, m.b);
    }

    /// @notice The market's conditional probabilities of the outcome in each world, in WAD.
    function conditionals(uint256 marketId) external view returns (uint256 yesIfCondition, uint256 yesIfNot) {
        Market storage m = _market(marketId);
        uint256[4] memory p = _prices(m.q, m.b);
        yesIfCondition = FPM.divWad(p[0], p[0] + p[1]);
        yesIfNot = FPM.divWad(p[2], p[2] + p[3]);
    }

    /// @notice What `stakeConditional` would give for `amount` now.
    function quoteStake(uint256 marketId, uint8 world, uint8 side, uint256 amount)
        external
        view
        returns (uint256 shares, uint256 fee)
    {
        Market storage m = _market(marketId);
        if (world > 1 || side > 1) revert InvalidChoice();
        if (amount < MIN_TRADE) revert TradeTooSmall();
        uint256 gross;
        uint256 spend;
        (, shares,, gross, spend,) = _stakeMath(m.q, m.b, m.makerBalance, world, side, amount);
        fee = gross - spend;
    }

    /// @notice What `trader` could claim now, counting an open market `claim` would settle (zero after claiming).
    function claimable(uint256 marketId, address trader) external view returns (uint256) {
        Market storage m = _markets[marketId];
        if (claimed[marketId][trader]) return 0;
        if (m.status == Status.Open) return _settleable(m) ? _shares[marketId][trader][_winner(m)] : 0;
        return _payout(marketId, m, trader);
    }

    /// @notice Whether `requestResolution` would ask `question` now.
    function askable(uint256 marketId, uint8 question) external view returns (bool) {
        Market storage m = _markets[marketId];
        if (!_known(marketId) || question > 1) return false;
        if (m.status != Status.Open || block.timestamp < m.resolveTime || block.timestamp > m.voidAfter) return false;
        return _askable(m, question);
    }

    function settleable(uint256 marketId) external view returns (bool) {
        return _known(marketId) && _settleable(_markets[marketId]);
    }

    /// @notice Whether `voidMarket` would succeed now.
    function voidable(uint256 marketId) external view returns (bool) {
        return _known(marketId) && _voidable(_markets[marketId]);
    }

    /// @notice The EIP-712 digest this contract verifies an attestation's signature against.
    function attestationDigest(Attestation calldata a) public view returns (bytes32) {
        return _hashTypedDataV4(_hashAttestation(a));
    }

    /// @notice The canonical question document the oracle hashes, for `question` asked at `windowBlock`.
    function questionDocument(uint256 marketId, uint8 question, uint256 windowBlock)
        public
        view
        returns (string memory)
    {
        Market storage m = _market(marketId);
        if (question > 1) revert InvalidChoice();
        (string memory document,) = _documents(marketId, m, question, windowBlock);
        return document;
    }

    // ---------------------------------------------------------------------------------------------------------------
    // Internals
    // ---------------------------------------------------------------------------------------------------------------

    function _known(uint256 marketId) internal view returns (bool) {
        return marketId != 0 && marketId <= marketCount;
    }

    function _market(uint256 marketId) internal view returns (Market storage) {
        if (!_known(marketId)) revert UnknownMarket();
        return _markets[marketId];
    }

    function _askable(Market storage m, uint8 q) internal view returns (bool) {
        if (m.answers[q] != UNANSWERED) return false;
        return m.openAsks[q] == 0 || block.timestamp >= uint256(m.lastAskAt[q]) + RETRY_DELAY;
    }

    /// @dev Both questions are needed: the outcome decides the winning side in whichever world happened.
    function _settleable(Market storage m) internal view returns (bool) {
        if (m.status != Status.Open) return false;
        return m.answers[CONDITION] != UNANSWERED && m.answers[OUTCOME] != UNANSWERED;
    }

    function _voidable(Market storage m) internal view returns (bool) {
        if (m.status != Status.Open || block.timestamp <= m.voidAfter || _settleable(m)) return false;
        for (uint8 q = 0; q < 2; ++q) {
            if (
                m.answers[q] == UNANSWERED && m.openAsks[q] != 0
                    && block.timestamp < uint256(m.lastAskAt[q]) + RETRY_DELAY
            ) return false;
        }
        return true;
    }

    /// @dev What an ask pays: the Intake's live price, up to MAX_PRICE (the Intake pulls exactly `amount`). A price
    ///      above the snapshot is paid from the budget while it lasts and then by the caller, so a price rise does
    ///      not leave the market able only to void (audit b37b3ab1). An Intake without `priceOf`, or with a live
    ///      price of zero or above MAX_PRICE, is charged the snapshot.
    function _askPrice(OracleConfig storage config) internal view returns (uint256 price) {
        price = config.price;
        try IIntakePrice(address(config.intake)).priceOf(config.action, address(imd)) returns (uint256 live) {
            if (live != 0 && live <= MAX_PRICE) price = live;
        } catch {}
    }

    function _ask(uint256 marketId, Market storage m, uint8 q) internal {
        OracleConfig storage config = m.oracle;
        uint256 price = _askPrice(config);
        uint256 windowBlock = block.number - WINDOW_DEPTH;

        // The budget pays while it lasts; the caller pays only the shortfall (review fc599613).
        uint256 fromBudget = FPM.min(m.budget, price);
        m.budget -= fromBudget;
        if (price > fromBudget) imd.safeTransferFrom(msg.sender, address(this), price - fromBudget);
        totalOracleSpend += price;

        (string memory document, string memory body) = _documents(marketId, m, q, windowBlock);
        bytes32 questionHash = keccak256(bytes(document));

        imd.forceApprove(address(config.intake), price);
        bytes32 requestId = config.intake
            .requestWithFailure(
                config.action,
                bytes(body),
                IIntake.Callback({target: address(this), selector: this.onOracleResult.selector}),
                this.onFailure.selector,
                address(imd),
                price
            );
        imd.forceApprove(address(config.intake), 0);

        bytes32 key = _askKey(address(config.intake), requestId);
        if (asks[key].live) revert DuplicateAsk();
        asks[key] = Ask({marketId: marketId, question: q, live: true, questionHash: questionHash});
        ++m.openAsks[q];
        m.lastAskAt[q] = uint64(block.timestamp);

        emit ResolutionRequested(marketId, q, requestId, questionHash, windowBlock);
    }

    /// @dev The outcome the stored answers select.
    function _winner(Market storage m) internal view returns (uint8) {
        return 2 * (m.answers[CONDITION] == ANSWER_TRUE ? 0 : 1) + (m.answers[OUTCOME] == ANSWER_TRUE ? 0 : 1);
    }

    function _settle(uint256 marketId, Market storage m) internal {
        uint8 winner = _winner(m);
        m.status = Status.Settled;
        m.winner = winner;

        // The market holds makerBalance + sets and owes q[winner] + sets to shareholders. The maker's solvency
        // (makerBalance >= C(q) >= q[i]) keeps the difference non-negative.
        uint256 residual = uint256(int256(m.makerBalance) - m.q[winner]);
        emit Settled(marketId, winner, residual);

        _push(m.creator, residual);
        _returnBudget(marketId, m);
    }

    function _returnBudget(uint256 marketId, Market storage m) internal {
        uint256 amount = m.budget;
        if (amount == 0) return;
        m.budget = 0;
        _push(m.creator, amount);
        emit BudgetReturned(marketId, m.creator, amount);
    }

    /// @dev Pays a third party (the burn address, the fee recipient, a creator) inside a staker's transaction. IMD
    ///      can refuse a transfer to a blocked address; such a refusal must not block the stakers, so the amount is
    ///      credited to `owed` instead and the recipient collects it with `withdrawOwed`.
    function _push(address to, uint256 amount) internal {
        if (amount == 0) return;
        try imd.transfer(to, amount) returns (bool ok) {
            if (ok) return;
        } catch {}
        owed[to] += amount;
        emit PaymentDeferred(to, amount);
    }

    function _payout(uint256 marketId, Market storage m, address account) internal view returns (uint256) {
        uint256[4] storage held = _shares[marketId][account];
        if (m.status == Status.Settled) return held[m.winner];
        uint256 net = _basisOf(marketId, account);
        uint256 pool = m.refundPool;
        uint256 base = m.refundBase;
        if (pool == base) return net;
        // Short (review bf61cff9): the market holds at least V, every position's value at the final prices, since
        // makerBalance >= C(q) >= sum p_i q_i. Each account is paid between its value v and its cost: the shortfall
        // falls on cost a position's value does not back, in proportion to it. The payouts sum to at most the pool.
        uint256[4] memory p = _prices(m.q, m.b);
        uint256 v;
        uint256 total;
        for (uint256 i; i < 4; ++i) {
            v += FPM.mulWad(held[i], p[i]);
            total += FPM.mulWadUp(uint256(m.q[i] + int256(m.sets)), p[i]);
        }
        if (total >= pool) return FPM.fullMulDiv(v, pool, total);
        return (v * (base - pool) + net * (pool - total)) / (base - total);
    }

    function _basisOf(uint256 marketId, address account) internal view returns (uint256 total) {
        uint256[4] storage basis = _basis[marketId][account];
        for (uint256 i; i < 4; ++i) {
            total += basis[i];
        }
    }

    function _tradable(uint256 marketId) internal view returns (Market storage m) {
        m = _market(marketId);
        if (m.status != Status.Open) revert MarketNotOpen();
        if (block.timestamp >= m.closeTime) revert BettingClosed();
    }

    function _stake(address account, uint256 marketId, uint8 world, uint8 side, uint256 amount, uint256 minShares)
        internal
        returns (uint256 shares)
    {
        Market storage m = _tradable(marketId);
        if (world > 1 || side > 1) revert InvalidChoice();
        if (amount < MIN_TRADE) revert TradeTooSmall();

        (int256[4] memory q, uint256 k, uint256 balance, uint256 gross, uint256 spend, uint256 absorbed) =
            _stakeMath(m.q, m.b, m.makerBalance, world, side, amount);
        if (k < minShares) revert SlippageExceeded();
        shares = k;
        uint256 fee = gross - spend;

        uint8 chosen = 2 * world + side;
        uint8 other = 2 * (1 - world);
        uint256[4] storage held = _shares[marketId][account];
        // One complete set per IMD, less the opposite side sold to the maker, plus what the proceeds bought.
        held[chosen] += amount + k;
        held[other] += amount;
        held[other + 1] += amount;
        // The set cost `amount`: the opposite side's share of it is what it fetched, the three outcomes kept share the
        // rest by their prices before the trade, and the chosen one also carries the proceeds spent on it.
        {
            uint256[4] memory p = _prices(m.q, m.b);
            uint256[4] storage basis = _basis[marketId][account];
            uint256 rest = amount - gross;
            uint256 denominator = p[other] + p[other + 1] + p[chosen];
            uint256 first = rest * p[other] / denominator;
            uint256 second = rest * p[other + 1] / denominator;
            basis[other] += first;
            basis[other + 1] += second;
            basis[chosen] += rest - first - second + spend;
        }
        uint256 collateral = amount - fee;
        m.refundBase += collateral;
        m.q = q;
        m.makerBalance = balance;
        m.sets = m.sets + amount - absorbed;

        imd.safeTransferFrom(msg.sender, address(this), amount);
        _chargeFee(m, fee);

        emit Traded(marketId, account, int256(collateral), fee);
    }

    /// @dev The stake's arithmetic: `gross` is what the opposite side fetched and `spend` what bought the extra
    ///      shares. The two fees add up to `gross - spend`, so `amount - gross + spend` is the collateral that stays.
    function _stakeMath(int256[4] memory q0, uint256 b, uint256 balance0, uint8 world, uint8 side, uint256 amount)
        internal
        pure
        returns (int256[4] memory q, uint256 k, uint256 balance, uint256 gross, uint256 spend, uint256 absorbed)
    {
        uint8 chosen = 2 * world + side;
        uint8 opposite = 2 * world + (1 - side);

        (q, gross) = _quote(q0, b, opposite, -int256(amount));
        absorbed = _absorb(q);
        if (gross > balance0 + absorbed) revert InsufficientMaker();

        // What is left after the sell fee buys shares plus their fee: spend + its fee = gross - sellFee, rounding the
        // spend down.
        spend = (gross - _fee(gross)) * BPS / (BPS + FEE_BPS);
        if (spend == 0) revert TradeTooSmall();
        (q, k) = _quoteBuyExactIn(q, b, chosen, spend);
        _checkSpread(q, b);

        balance = balance0 + absorbed - gross + spend;
    }

    /// @dev Moves `shares` of `outcome` from the account to the maker, and leaves the IMD and the fee to the caller.
    function _sell(uint256 marketId, Market storage m, address account, uint8 outcome, uint256 shares)
        internal
        returns (uint256 proceeds, uint256 fee)
    {
        // Spread-checked like a buy: a sell that pushed an outcome more than MAX_SPREAD_B below the top would price a
        // whole world at zero and lock every buy and stake (audit 913c99ee). `exit` sells only what fits.
        (int256[4] memory q, uint256 gross) = _quote(m.q, m.b, outcome, -int256(shares));
        _checkSpread(q, m.b);
        uint256 absorbed = _absorb(q);
        if (gross > m.makerBalance + absorbed) revert InsufficientMaker();
        _release(marketId, m, account, outcome, shares);
        m.q = q;
        m.sets -= absorbed;
        m.makerBalance = m.makerBalance + absorbed - gross;
        fee = _fee(gross);
        proceeds = gross - fee;
    }

    /// @dev Takes `shares` of `outcome` from the account and releases their share of its cost basis: what they cost
    ///      is no longer refundable, whatever they fetch. Selling all of a holding releases all of its basis.
    function _release(uint256 marketId, Market storage m, address account, uint256 outcome, uint256 shares) internal {
        uint256 held = _shares[marketId][account][outcome];
        uint256 left = held - shares;
        uint256 basis = _basis[marketId][account][outcome];
        uint256 released = left == 0 ? basis : basis * shares / held;
        _shares[marketId][account][outcome] = left;
        _basis[marketId][account][outcome] = basis - released;
        m.refundBase -= released;
    }

    function _fee(uint256 notional) internal pure returns (uint256) {
        return FPM.mulDivUp(notional, FEE_BPS, BPS);
    }

    /// @dev Splits a fee the contract already holds: the creator's and the builder's accrue, the burn is sent.
    function _chargeFee(Market storage m, uint256 fee) internal {
        if (fee == 0) return;
        uint256 toCreator = fee * LP_SHARE_BPS / FEE_BPS;
        uint256 burned = fee * BURN_SHARE_BPS / FEE_BPS;
        uint256 toBuilder = fee - toCreator - burned;
        owed[m.creator] += toCreator;
        owed[feeRecipient] += toBuilder;
        totalCreatorFees += toCreator;
        totalBuilderFees += toBuilder;
        totalBurned += burned;
        _push(BURN_ADDRESS, burned);
    }

    // LMSR ------------------------------------------------------------------------------------------------------------

    /// @dev C(q) = m + b ln(sum exp((q_i - m) / b)), m = max q_i, with every exponent <= 0 so nothing overflows. The
    ///      result is moved by more than the fixed point can be off, up or down as asked, so that a trade priced as
    ///      C_up(after) - C_down(before) always leaves the maker holding at least the true C(q).
    function _cost(int256[4] memory q, uint256 b, bool up) internal pure returns (int256) {
        (int256 max, int256 sum) = _normalised(q, b);
        int256 c = max + FPM.sMulWad(int256(b), FPM.lnWad(sum));
        int256 margin = _margin(b);
        return up ? c + margin : c - margin;
    }

    /// @dev How far `_cost` moves its result from the fixed point's value, in wei.
    function _margin(uint256 b) internal pure returns (int256) {
        return (int256(b) / 1e18 + 1) * 16;
    }

    /// @dev The largest and smallest q.
    function _range(int256[4] memory q) internal pure returns (int256 max, int256 min) {
        max = q[0];
        min = q[0];
        for (uint256 i = 1; i < 4; ++i) {
            if (q[i] > max) max = q[i];
            if (q[i] < min) min = q[i];
        }
    }

    /// @dev The largest q and the sum of exp((q_i - max) / b), which lies in [1e18, 4e18].
    function _normalised(int256[4] memory q, uint256 b) internal pure returns (int256 max, int256 sum) {
        (max,) = _range(q);
        for (uint256 i; i < 4; ++i) {
            sum += FPM.expWad(FPM.sDivWad(q[i] - max, int256(b)));
        }
    }

    function _prices(int256[4] memory q, uint256 b) internal pure returns (uint256[4] memory p) {
        (int256 max, int256 sum) = _normalised(q, b);
        for (uint256 i; i < 4; ++i) {
            p[i] = uint256(FPM.sDivWad(FPM.expWad(FPM.sDivWad(q[i] - max, int256(b))), sum));
        }
    }

    /// @dev When the maker is short of every outcome it holds complete sets bought from traders. Turns them back into
    ///      IMD: q moves up by the amount and C(q) with it, so prices do not change and the balance stays at least C(q),
    ///      which would otherwise fall below zero. The caller moves the amount from `sets` to `makerBalance`.
    function _absorb(int256[4] memory q) internal pure returns (uint256 absorbed) {
        (int256 max,) = _range(q);
        if (max >= 0) return 0;
        for (uint256 i; i < 4; ++i) {
            q[i] -= max;
        }
        absorbed = uint256(-max);
    }

    /// @dev Refuses a state where one outcome's price would fall below the fixed point's useful range.
    function _checkSpread(int256[4] memory q, uint256 b) internal pure {
        (int256 max, int256 min) = _range(q);
        if (max - min > MAX_SPREAD_B * int256(b)) revert PriceLimit();
    }

    /// @dev The most of `outcome` that can be sold before it falls more than MAX_SPREAD_B below the other outcomes'
    ///      top. Every other pair is already inside the spread, so this is the only bound a sell can break.
    function _sellRoom(int256[4] memory q, uint256 b, uint256 outcome) internal pure returns (uint256) {
        int256 top = type(int256).min;
        for (uint256 i; i < 4; ++i) {
            if (i != outcome && q[i] > top) top = q[i];
        }
        int256 room = q[outcome] - top + MAX_SPREAD_B * int256(b);
        return room > 0 ? uint256(room) : 0;
    }

    /// @dev A copy of `q0` with `delta` added to one outcome. Assigning a memory array would only alias it.
    function _moved(int256[4] memory q0, uint256 outcome, int256 delta) internal pure returns (int256[4] memory q) {
        for (uint256 i; i < 4; ++i) {
            q[i] = q0[i];
        }
        q[outcome] += delta;
    }

    /// @dev What moving `outcome` by `delta` costs the trader (a buy, delta > 0) or pays them (a sell, delta < 0): the
    ///      cost after, rounded up, less the cost before, rounded down, or the reverse, so the maker never pays out
    ///      the rounding.
    function _quote(int256[4] memory q0, uint256 b, uint256 outcome, int256 delta)
        internal
        pure
        returns (int256[4] memory q, uint256 amount)
    {
        q = _moved(q0, outcome, delta);
        int256 c = delta > 0 ? _cost(q, b, true) - _cost(q0, b, false) : _cost(q0, b, false) - _cost(q, b, true);
        if (c <= 0) revert TradeTooSmall();
        amount = uint256(c);
    }

    /// @dev The shares `spend` buys of `outcome`, from the closed form
    ///      k = b ln((S exp(x / b) - S + e) / e), rounded down until the quoted cost fits inside `spend`. Each cut is
    ///      at least the shares whose cost at the entry price covers the two rounding margins, so a small spend at a
    ///      low price fits in the tries as well as a large one (review 06e7064f).
    function _quoteBuyExactIn(int256[4] memory q0, uint256 b, uint256 outcome, uint256 spend)
        internal
        pure
        returns (int256[4] memory q, uint256 k)
    {
        if (spend > MAX_SPEND_B * b) revert TradeTooLarge();
        (int256 max, int256 sum) = _normalised(q0, b);
        int256 e = FPM.expWad(FPM.sDivWad(q0[outcome] - max, int256(b)));
        if (e <= 0) revert PriceLimit();
        int256 grown = FPM.expWad(FPM.sDivWad(int256(spend), int256(b)));
        int256 ratio = FPM.sDivWad(FPM.sMulWad(sum, grown) - sum + e, e);
        k = uint256(FPM.sMulWad(int256(b), FPM.lnWad(ratio)));
        uint256 step = 2 * uint256(_margin(b)) * uint256(sum) / uint256(e) + 1;
        k -= k / 1e9;
        for (uint256 tries;; ++tries) {
            if (k < 1e6 || tries == 4) revert TradeTooSmall();
            q = _moved(q0, outcome, int256(k));
            if (_cost(q, b, true) - _cost(q0, b, false) <= int256(spend)) return (q, k);
            uint256 cut = FPM.max(k / 1e6, step);
            k = k > cut ? k - cut : 0;
        }
    }

    function _askKey(address intake, bytes32 requestId) internal pure returns (bytes32) {
        return keccak256(abi.encode(intake, requestId));
    }

    function _hashAttestation(Attestation calldata a) internal pure returns (bytes32) {
        return keccak256(
            abi.encode(
                ATTESTATION_TYPEHASH,
                a.requestId,
                a.chainId,
                a.questionHash,
                a.answerType,
                keccak256(a.answer),
                a.figure,
                a.fromBlock,
                a.toBlock,
                a.blockHash,
                a.panelJobId,
                a.panelSize,
                a.quorum,
                a.agreed,
                a.issuedAt,
                a.expiresAt
            )
        );
    }

    /// @dev The question text. It names this contract and the market so it is unique to them.
    function _questionText(uint256 marketId, Market storage m, uint8 q) internal view returns (string memory) {
        return string.concat(
            "Conditionals market ",
            marketId.toString(),
            " on Robinhood Chain contract ",
            address(this).toHexString(),
            ", ",
            q == CONDITION ? "condition" : "outcome",
            " statement. Was the following statement true as of unix time ",
            uint256(m.resolveTime).toString(),
            " (UTC)? Statement: ",
            q == CONDITION ? m.condition : m.outcome
        );
    }

    /// @dev Definitions sorted by key: "asOf", then "rules".
    function _definitions(Market storage m) internal view returns (string memory) {
        return string.concat(
            "{\"asOf\":\"Judge the statement by what had happened by unix time ",
            uint256(m.resolveTime).toString(),
            " (UTC). Blockchain blocks are context only.\",\"rules\":\"",
            m.rules,
            "\"}"
        );
    }

    /// @dev Canonical question document: compact JSON with sorted keys, as the oracle hashes it
    ///      (https://imd.fun/docs/#intake-binding-an-answer-to-its-request), and the request body, which adds
    ///      panelSize, quorum and validForSeconds in key order. Both are built from the same parts. Text is restricted
    ///      to printable ASCII without quotes or backslashes, so it needs no escaping. `chainId` is QUESTION_CHAIN_ID.
    function _documents(uint256 marketId, Market storage m, uint8 q, uint256 windowBlock)
        internal
        view
        returns (string memory document, string memory body)
    {
        string memory head = string.concat(
            "{\"answerType\":\"bool\",\"chainId\":1,\"definitions\":", _definitions(m), ",\"evidence\":\"panel\""
        );
        string memory question = string.concat(",\"question\":\"", _questionText(marketId, m, q), "\"");
        string memory w = windowBlock.toString();
        string memory tail = string.concat(",\"window\":{\"fromBlock\":", w, ",\"toBlock\":", w, "}}");
        document = string.concat(head, question, ",\"v\":1", tail);
        body = string.concat(
            head,
            ",\"panelSize\":",
            uint256(m.oracle.panelSize).toString(),
            question,
            ",\"quorum\":",
            uint256(m.oracle.quorum).toString(),
            ",\"v\":1,\"validForSeconds\":",
            VALID_FOR_SECONDS.toString(),
            tail
        );
    }

    /// @dev 1 to maxLength bytes of printable ASCII (0x20-0x7e) without `"` or `\`. Reports whether it has a space.
    function _validateText(string calldata text, uint256 maxLength) internal pure returns (bool hasSpace) {
        bytes calldata b = bytes(text);
        if (b.length == 0 || b.length > maxLength) revert InvalidText();
        for (uint256 i; i < b.length; ++i) {
            bytes1 c = b[i];
            if (c < 0x20 || c > 0x7e || c == 0x22 || c == 0x5c) revert InvalidText();
            if (c == 0x20) hasSpace = true;
        }
    }

    function _validateConfig(OracleConfig memory config) internal pure {
        if (address(config.intake) == address(0) || config.signer == address(0)) revert ZeroAddress();
        if (
            config.action == bytes32(0) || config.price == 0 || config.price > MAX_PRICE
                || config.panelSize < MIN_PANEL_SIZE || config.panelSize > MAX_PANEL_SIZE || config.quorum < 2
                || config.quorum > config.panelSize
        ) revert InvalidConfig();
    }
}
