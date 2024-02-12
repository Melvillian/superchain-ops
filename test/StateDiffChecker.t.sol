// SPDX-License-Identifier: MIT
pragma solidity ^0.8.15;

import {Test} from "forge-std/Test.sol";
import {VmSafe} from "forge-std/Vm.sol";
import {stdJson} from "forge-std/StdJson.sol";
import {LibStateDiffChecker as Checker} from "script/LibStateDiffChecker.sol";

/// @dev A simple contract to which makes some state modifications for the purpose of testing state diff checking.
contract Target {
    uint256 public x;
    address public y;
    mapping(uint256 => bytes32) public z;

    constructor() {
        x = 1;
    }

    function set() public {
        x = 0;
        y = address(0xabba);
        z[1] = hex"acdc";
    }
}

/// @dev Tests for LibStateDiffChecker
contract StateDiffChecker_Test is Test {
    Target public target;

    error StateDiffMismatch(string field, bytes32 expected, bytes32 actual);

    function setUp() public {
        target = new Target();
    }

    /// @dev Test that the sample testDiff.json file is read and parsed correctly
    function test_parseDiffSpecs() public {
        string memory _path = "test/testDiff.json";
        string memory json = vm.readFile(_path);
        Checker.StateDiffSpec memory diffSpec = Checker.parseDiffSpecs(json);

        assertEq(diffSpec.chainId, 31337);
        assertEq(diffSpec.storageSpecs.length, 3);
        assertEq(diffSpec.storageSpecs[0].slot, bytes32(0));
        assertEq(diffSpec.storageSpecs[0].newValue, bytes32(0));
        assertEq(diffSpec.storageSpecs[1].slot, bytes32(uint256(1)));
        assertEq(diffSpec.storageSpecs[1].newValue, bytes32(uint256(uint160(address(0xabba)))));
        assertEq(diffSpec.storageSpecs[2].slot, keccak256(abi.encodePacked(uint256(1), uint256(2))));
        assertEq(diffSpec.storageSpecs[2].newValue, hex"acdc");
    }

    /// @dev Utility function which sets up the subsequent tests by executing Target.set(), parsing the diff spec
    ///      from testDiff.json, and returning the resulting state diff structs.
    function _executeAndGetDiffs()
        internal
        returns (Checker.StateDiffSpec memory expectedDiff_, Checker.StateDiffSpec memory actualDiff_)
    {
        vm.startStateDiffRecording();
        target.set();
        VmSafe.AccountAccess[] memory accountAccesses = vm.stopAndReturnStateDiff();

        string memory _path = "test/testDiff.json";
        string memory json = vm.readFile(_path);
        expectedDiff_ = Checker.parseDiffSpecs(json);

        actualDiff_ = Checker.extractDiffSpecFromAccountAccesses(accountAccesses);
    }

    /// @dev Test that the state diff generated by running Target.set() matches the expected state diff
    ///      as defined in testDiff.json
    function test_checkStateDiff_succeeds() public {
        (Checker.StateDiffSpec memory expectedDiff, Checker.StateDiffSpec memory actualDiff) = _executeAndGetDiffs();
        Checker.checkStateDiff(expectedDiff, actualDiff);
    }

    /// @dev Test that the correct error is thrown when the chain ID does not match.
    function test_checkStateDiff_chainIdMismatch_reverts() public {
        (Checker.StateDiffSpec memory expectedDiff, Checker.StateDiffSpec memory actualDiff) = _executeAndGetDiffs();
        actualDiff.chainId = 31338;
        vm.expectRevert(abi.encodeWithSelector(StateDiffMismatch.selector, "chainId", 31337, 31338));
        Checker.checkStateDiff(expectedDiff, actualDiff);
    }

    /// @dev Test that the correct error is thrown when the number of storage modifications does not match.
    function test_checkStateDiff_lengthMismatch_reverts() public {
        (Checker.StateDiffSpec memory expectedDiff,) = _executeAndGetDiffs();
        Checker.StateDiffSpec memory shorterDiff = Checker.StateDiffSpec({
            chainId: 31337,
            storageSpecs: new Checker.StorageDiffSpec[](expectedDiff.storageSpecs.length - 1)
        });
        shorterDiff.storageSpecs[0] = expectedDiff.storageSpecs[0];
        vm.expectRevert(
            abi.encodeWithSelector(
                StateDiffMismatch.selector,
                "storageSpecs.length",
                expectedDiff.storageSpecs.length,
                shorterDiff.storageSpecs.length
            )
        );
        Checker.checkStateDiff(expectedDiff, shorterDiff);
    }

    /// @dev A utility function to copy a StateDiffSpec struct so that we can modify it without affecting the original.
    function copyDiff(Checker.StateDiffSpec memory diff) internal pure returns (Checker.StateDiffSpec memory) {
        Checker.StateDiffSpec memory copy;
        copy.chainId = diff.chainId;
        copy.storageSpecs = new Checker.StorageDiffSpec[](diff.storageSpecs.length);
        for (uint256 i = 0; i < diff.storageSpecs.length; i++) {
            copy.storageSpecs[i].account = diff.storageSpecs[i].account;
            copy.storageSpecs[i].slot = diff.storageSpecs[i].slot;
            copy.storageSpecs[i].newValue = diff.storageSpecs[i].newValue;
            copy.storageSpecs[i].previousValue = diff.storageSpecs[i].previousValue;

            // Ensure that all values have been copied over
            require(
                keccak256(abi.encode(copy.storageSpecs[i])) == keccak256(abi.encode(diff.storageSpecs[i])),
                "StateDiffCheckerTest: StorageDiffSpec copying failed"
            );
        }
        return copy;
    }

    /// @dev Test that the correct error is thrown when a storage spec account does not match.
    function test_checkStateDiff_storageSpecAccountMismatch_reverts() public {
        (Checker.StateDiffSpec memory expectedDiff,) = _executeAndGetDiffs();
        Checker.StateDiffSpec memory brokenDiff = copyDiff(expectedDiff);

        brokenDiff.storageSpecs[0].account = address(0);
        vm.expectRevert(
            abi.encodeWithSelector(
                StateDiffMismatch.selector,
                string.concat("storageSpecs[0].account"),
                expectedDiff.storageSpecs[0].account,
                address(0)
            )
        );
        Checker.checkStateDiff(expectedDiff, brokenDiff);
    }

    /// @dev Test that the correct error is thrown when a storage spec slot does not match.
    function test_checkStateDiff_storageSpecSlotMismatch_reverts() public {
        (Checker.StateDiffSpec memory expectedDiff,) = _executeAndGetDiffs();
        Checker.StateDiffSpec memory brokenDiff = copyDiff(expectedDiff);

        // break the slot field
        brokenDiff.storageSpecs[0].slot = bytes32(hex"deadbeef");
        vm.expectRevert(
            abi.encodeWithSelector(
                StateDiffMismatch.selector,
                string.concat("storageSpecs[0].slot"),
                expectedDiff.storageSpecs[0].slot,
                bytes32(hex"deadbeef")
            )
        );
        Checker.checkStateDiff(expectedDiff, brokenDiff);
    }

    /// @dev Test that the correct error is thrown when a storage spec newValue does not match.
    function test_checkStateDiff_storageSpecNewValueMismatch_reverts() public {
        (Checker.StateDiffSpec memory expectedDiff,) = _executeAndGetDiffs();
        Checker.StateDiffSpec memory brokenDiff = copyDiff(expectedDiff);

        // break the newValue field
        brokenDiff.storageSpecs[0].newValue = bytes32(hex"deadbeef");
        vm.expectRevert(
            abi.encodeWithSelector(
                StateDiffMismatch.selector,
                "storageSpecs[0].newValue",
                expectedDiff.storageSpecs[0].newValue,
                bytes32(hex"deadbeef")
            )
        );
        Checker.checkStateDiff(expectedDiff, brokenDiff);
    }

    /// @dev Test that the correct error is thrown when a storage spec previousValue does not match.
    function test_checkStateDiff_storageSpecPreviousValueMismatch_reverts() public {
        (Checker.StateDiffSpec memory expectedDiff,) = _executeAndGetDiffs();
        Checker.StateDiffSpec memory brokenDiff = copyDiff(expectedDiff);

        // break the previousValue field
        brokenDiff.storageSpecs[0].slot = expectedDiff.storageSpecs[0].slot;
        brokenDiff.storageSpecs[0].previousValue = bytes32(hex"deadbeef");
        vm.expectRevert(
            abi.encodeWithSelector(
                StateDiffMismatch.selector,
                "storageSpecs[0].previousValue",
                expectedDiff.storageSpecs[0].previousValue,
                bytes32(hex"deadbeef")
            )
        );
        Checker.checkStateDiff(expectedDiff, brokenDiff);
    }
}
