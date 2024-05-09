// SPDX-License-Identifier: MIT
pragma solidity 0.8.23;

import {IAccount} from "account-abstraction/interfaces/IAccount.sol";

import {UserOperation, UserOperationLib} from "account-abstraction/interfaces/UserOperation.sol";
import {Receiver} from "solady/accounts/Receiver.sol";
import {SignatureCheckerLib} from "solady/utils/SignatureCheckerLib.sol";
import {UUPSUpgradeable} from "solady/utils/UUPSUpgradeable.sol";
import {WebAuthn} from "webauthn-sol/WebAuthn.sol";

import {IKeyStore} from "./ext/IKeyStore.sol";
import {IVerifier} from "./ext/IVerifier.sol";

import {ERC1271} from "./ERC1271.sol";
import {MultiOwnable} from "./MultiOwnable.sol";

/// @title Coinbase Smart Wallet
///
/// @notice ERC-4337-compatible smart account, based on Solady's ERC4337 account implementation
///         with inspiration from Alchemy's LightAccount and Daimo's DaimoAccount.
///
/// @author Coinbase (https://github.com/coinbase/smart-wallet)
/// @author Solady (https://github.com/vectorized/solady/blob/main/src/accounts/ERC4337.sol)
contract CoinbaseSmartWallet is ERC1271, IAccount, MultiOwnable, UUPSUpgradeable, Receiver {
    /// @notice A wrapper struct used for signature validation.
    struct SignatureWrapper {
        /// @dev The Keyspace key.
        uint256 ksKey;
        /// @dev The general encoding of this field should be:
        ///      `abi.encode(sig, publicKeyX, publicKeyY, stateProof)`
        ///
        ///      The content of `sig` depends on the Keyspace key type:
        ///         - For EOA key type `sig` should be `abi.encodePacked(r, s, v)`
        ///         - For WebAuthn key type `sig` should be `abi.encode(WebAuthnAuth)`
        bytes data;
    }

    /// @notice Represents a call to make.
    struct Call {
        /// @dev The address to call.
        address target;
        /// @dev The value to send when making the call.
        uint256 value;
        /// @dev The data of the call.
        bytes data;
    }

    /// @notice Reserved nonce key (upper 192 bits of `UserOperation.nonce`) for cross-chain replayable
    ///         transactions.
    ///
    /// @dev MUST BE the `UserOperation.nonce` key when `UserOperation.calldata` is calling
    ///      `executeWithoutChainIdValidation`and MUST NOT BE `UserOperation.nonce` key when `UserOperation.calldata` is
    ///      NOT calling `executeWithoutChainIdValidation`.
    ///
    /// @dev Helps enforce sequential sequencing of replayable transactions.
    uint256 public constant REPLAYABLE_NONCE_KEY = 8453;

    /// @notice The KeyStore contract from which the L1 roots are fetched.
    IKeyStore public immutable keyStore;

    /// @notice The StateVerifier contract used to verify state proofs.
    IVerifier public immutable stateVerifier;

    /// @notice Thrown when `initialize` is called but the account already has had at least one owner.
    error Initialized();

    /// @notice Thrown when a call is passed to `executeWithoutChainIdValidation` that is not allowed by
    ///         `canSkipChainIdValidation`
    ///
    /// @param selector The selector of the call.
    error SelectorNotAllowed(bytes4 selector);

    /// @notice Thrown in validateUserOp if the key of `UserOperation.nonce` does not match the calldata.
    ///
    /// @dev Calls to `this.executeWithoutChainIdValidation` MUST use `REPLAYABLE_NONCE_KEY` and
    ///      calls NOT to `this.executeWithoutChainIdValidation` MUST NOT use `REPLAYABLE_NONCE_KEY`.
    ///
    /// @param key The invalid `UserOperation.nonce` key.
    error InvalidNonceKey(uint256 key);

    /// @notice Thrown in `_isValidSignature` if the Keyspace key is not registered as an owner for this account.
    error InvalidKeySpaceKey(uint256 ksKey);

    /// @notice Reverts if the caller is not the EntryPoint.
    modifier onlyEntryPoint() virtual {
        if (msg.sender != entryPoint()) {
            revert Unauthorized();
        }

        _;
    }

    /// @notice Reverts if the caller is neither the EntryPoint nor the account itself.
    modifier onlyEntryPointOrSelf() virtual {
        if (msg.sender != entryPoint()) {
            _ensureIsSelf();
        }

        _;
    }

    /// @notice Sends to the EntryPoint (i.e. `msg.sender`) the missing funds for this transaction.
    ///
    /// @dev Subclass MAY override this modifier for better funds management (e.g. send to the
    ///      EntryPoint more than the minimum required, so that in future transactions it will not
    ///      be required to send again).
    ///
    /// @param missingAccountFunds The minimum value this modifier should send the EntryPoint which
    ///                            MAY be zero, in case there is enough deposit, or the userOp has a
    ///                            paymaster.
    modifier payPrefund(uint256 missingAccountFunds) virtual {
        _;

        assembly ("memory-safe") {
            if missingAccountFunds {
                // Ignore failure (it's EntryPoint's job to verify, not the account's).
                pop(call(gas(), caller(), missingAccountFunds, codesize(), 0x00, codesize(), 0x00))
            }
        }
    }

    constructor(address keyStore_, address stateVerifier_) {
        // Set the immutable variables that will be used by all proxies pointing to this implementation.
        keyStore = IKeyStore(keyStore_);
        stateVerifier = IVerifier(stateVerifier_);

        // Implementation should not be initializable (does not affect proxies which use their own storage).
        KeyAndType[] memory ksKeys = new KeyAndType[](1);
        _initializeOwners(ksKeys);
    }

    /// @notice Initializes the account with the `owners`.
    ///
    /// @dev Reverts if the account has had at least one owner, i.e. has been initialized.
    ///
    /// @param ksKeys Array of initial Keyspace keys.
    function initialize(KeyAndType[] memory ksKeys) external payable virtual {
        if (ownerCount() != 0) {
            revert Initialized();
        }

        _initializeOwners(ksKeys);
    }

    /// @inheritdoc IAccount
    ///
    /// @notice ERC-4337 `validateUserOp` method. The EntryPoint will
    ///         call `UserOperation.sender.call(UserOperation.callData)` only if this validation call returns
    ///         successfully.
    ///
    /// @dev Signature failure should be reported by returning 1 (see: `this._isValidSignature`). This
    ///      allows making a "simulation call" without a valid signature. Other failures (e.g. invalid signature format)
    ///      should still revert to signal failure.
    /// @dev Reverts if the `UserOperation.nonce` key is invalid for `UserOperation.calldata`.
    /// @dev Reverts if the signature format is incorrect or invalid for owner type.
    ///
    /// @param userOp              The `UserOperation` to validate.
    /// @param userOpHash          The `UserOperation` hash, as computed by `EntryPoint.getUserOpHash(UserOperation)`.
    /// @param missingAccountFunds The missing account funds that must be deposited on the Entrypoint.
    ///
    /// @return validationData The encoded `ValidationData` structure:
    ///                        `(uint256(validAfter) << (160 + 48)) | (uint256(validUntil) << 160) | (success ? 0 : 1)`
    ///                        where `validUntil` is 0 (indefinite) and `validAfter` is 0.
    function validateUserOp(UserOperation calldata userOp, bytes32 userOpHash, uint256 missingAccountFunds)
        external
        virtual
        onlyEntryPoint
        payPrefund(missingAccountFunds)
        returns (uint256 validationData)
    {
        uint256 key = userOp.nonce >> 64;

        if (bytes4(userOp.callData) == this.executeWithoutChainIdValidation.selector) {
            userOpHash = getUserOpHashWithoutChainId(userOp);
            if (key != REPLAYABLE_NONCE_KEY) {
                revert InvalidNonceKey(key);
            }
        } else {
            if (key == REPLAYABLE_NONCE_KEY) {
                revert InvalidNonceKey(key);
            }
        }

        // Return 0 if the recovered address matches the owner.
        if (_isValidSignature(userOpHash, userOp.signature)) {
            return 0;
        }

        // Else return 1
        return 1;
    }

    /// @notice Executes `calls` on this account (i.e. self call).
    ///
    /// @dev Can only be called by the Entrypoint.
    /// @dev Reverts if the given call is not authorized to skip the chain ID validtion.
    /// @dev `validateUserOp()` will recompute the `userOpHash` without the chain ID before validating
    ///      it if the `UserOperation.calldata` is calling this function. This allows certain UserOperations
    ///      to be replayed for all accounts sharing the same address across chains. E.g. This may be
    ///      useful for syncing owner changes.
    ///
    /// @param calls An array of calldata to use for separate self calls.
    function executeWithoutChainIdValidation(bytes[] calldata calls) external payable virtual onlyEntryPoint {
        for (uint256 i; i < calls.length; i++) {
            bytes calldata call = calls[i];
            bytes4 selector = bytes4(call);
            if (!canSkipChainIdValidation(selector)) {
                revert SelectorNotAllowed(selector);
            }

            _call(address(this), 0, call);
        }
    }

    /// @notice Executes the given call from this account.
    ///
    /// @dev Can only be called by the Entrypoint or an owner of this account (including itself).
    ///
    /// @param target The address to call.
    /// @param value  The value to send with the call.
    /// @param data   The data of the call.
    function execute(address target, uint256 value, bytes calldata data)
        external
        payable
        virtual
        onlyEntryPointOrSelf
    {
        _call(target, value, data);
    }

    /// @notice Executes batch of `Call`s.
    ///
    /// @dev Can only be called by the Entrypoint or an owner of this account (including itself).
    ///
    /// @param calls The list of `Call`s to execute.
    function executeBatch(Call[] calldata calls) external payable virtual onlyEntryPointOrSelf {
        for (uint256 i; i < calls.length; i++) {
            _call(calls[i].target, calls[i].value, calls[i].data);
        }
    }

    /// @notice Returns the address of the EntryPoint v0.6.
    ///
    /// @return The address of the EntryPoint v0.6
    function entryPoint() public view virtual returns (address) {
        return 0x5FF137D4b0FDCD49DcA30c7CF57E578a026d2789;
    }

    /// @notice Computes the hash of the `UserOperation` in the same way as EntryPoint v0.6, but
    ///         leaves out the chain ID.
    ///
    /// @dev This allows accounts to sign a hash that can be used on many chains.
    ///
    /// @param userOp The `UserOperation` to compute the hash for.
    ///
    /// @return The `UserOperation` hash, which does not depend on chain ID.
    function getUserOpHashWithoutChainId(UserOperation calldata userOp) public view virtual returns (bytes32) {
        return keccak256(abi.encode(UserOperationLib.hash(userOp), entryPoint()));
    }

    /// @notice Returns the implementation of the ERC1967 proxy.
    ///
    /// @return $ The address of implementation contract.
    function implementation() public view returns (address $) {
        assembly {
            $ := sload(_ERC1967_IMPLEMENTATION_SLOT)
        }
    }

    /// @notice Returns whether `functionSelector` can be called in `executeWithoutChainIdValidation`.
    ///
    /// @param functionSelector The function selector to check.
    ////
    /// @return `true` is the function selector is allowed to skip the chain ID validation, else `false`.
    function canSkipChainIdValidation(bytes4 functionSelector) public pure returns (bool) {
        if (
            functionSelector == MultiOwnable.addOwner.selector || functionSelector == MultiOwnable.removeOwner.selector
                || functionSelector == MultiOwnable.removeLastOwner.selector
                || functionSelector == UUPSUpgradeable.upgradeToAndCall.selector
        ) {
            return true;
        }
        return false;
    }

    /// @notice Executes the given call from this account.
    ///
    /// @dev Reverts if the call reverted.
    /// @dev Implementation taken from
    /// https://github.com/alchemyplatform/light-account/blob/43f625afdda544d5e5af9c370c9f4be0943e4e90/src/common/BaseLightAccount.sol#L125
    ///
    /// @param target The target call address.
    /// @param value  The call value to user.
    /// @param data   The raw call data.
    function _call(address target, uint256 value, bytes memory data) internal {
        (bool success, bytes memory result) = target.call{value: value}(data);
        if (!success) {
            assembly ("memory-safe") {
                revert(add(result, 32), mload(result))
            }
        }
    }

    /// @inheritdoc ERC1271
    ///
    /// @dev Used by both `ERC1271.isValidSignature` AND `IAccount.validateUserOp` signature validation.
    /// @dev Reverts if owner at `ownerIndex` is not compatible with `signature` format.
    ///
    /// @param signature ABI encoded `SignatureWrapper`.
    function _isValidSignature(bytes32 h, bytes calldata signature) internal view virtual override returns (bool) {
        SignatureWrapper memory sigWrapper = abi.decode(signature, (SignatureWrapper));

        // Get the signer type and revert if it's None.
        MultiOwnable.KeyspaceKeyType ksKeyType = keyspaceKeyType(sigWrapper.ksKey);
        if (ksKeyType == KeyspaceKeyType.None) {
            revert InvalidKeySpaceKey(sigWrapper.ksKey);
        }

        // Decode the raw `signature`.
        (bytes memory sig, uint256 publicKeyX, uint256 publicKeyY, bytes memory stateProof) =
            abi.decode(sigWrapper.data, (bytes, uint256, uint256, bytes));

        // Handle the EOA signature type.
        if (ksKeyType == KeyspaceKeyType.EOA) {
            bytes memory publicKeyBytes = abi.encode(publicKeyX, publicKeyY);
            address signer = address(bytes20(keccak256(publicKeyBytes) << 96));

            bool isValidSignature = SignatureCheckerLib.isValidSignatureNow(signer, h, sig);
            if (!isValidSignature) {
                return false;
            }
        }
        // Handle the WebAuthn signature type.
        else {
            WebAuthn.WebAuthnAuth memory auth = abi.decode(sig, (WebAuthn.WebAuthnAuth));

            bool isValidSignature = WebAuthn.verify({
                challenge: abi.encode(h),
                requireUV: false,
                webAuthnAuth: auth,
                x: publicKeyX,
                y: publicKeyY
            });

            if (!isValidSignature) {
                return false;
            }
        }

        // Verify the state proof.
        uint256[] memory data = new uint256[](8);
        data[0] = publicKeyX;
        data[1] = publicKeyY;

        uint256[] memory public_inputs = new uint256[](3);
        public_inputs[0] = sigWrapper.ksKey;
        public_inputs[1] = keyStore.root();
        public_inputs[2] = uint256(keccak256(abi.encodePacked(data)) >> 8);
        return stateVerifier.Verify(stateProof, public_inputs);
    }

    /// @inheritdoc UUPSUpgradeable
    ///
    /// @dev Authorization logic is only based on the `msg.sender` being `address(this)`.
    function _authorizeUpgrade(address) internal view virtual override(UUPSUpgradeable) onlySelf {}

    /// @inheritdoc ERC1271
    function _domainNameAndVersion() internal pure override(ERC1271) returns (string memory, string memory) {
        return ("Coinbase Smart Wallet", "1");
    }
}
