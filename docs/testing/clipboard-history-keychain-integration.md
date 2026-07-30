# Clipboard History Cross-Identity Keychain Verification

The automated integration test uses the production
`ClipboardHistoryKeychainStore`, including its fixed service and account
identifiers. It creates a disposable unlocked Keychain and runs the same test
bundle under two copied `xctest` hosts with distinct ad-hoc signing
identifiers. Both creator/accessor orders are exercised.

Run the deterministic pre-prompt check:

```bash
swift test \
  --filter ClipboardHistoryModuleTests/testProductionKeychainCrossIdentityACLBoundary
```

The accessor process disables Keychain interaction before reading. On the
current macOS runner, Security returns `errSecAuthFailed`, which the production
adapter maps to `accessDenied`. The test verifies that the Keychain was
successfully unlocked first, that the module reports `keyAccessDenied`, and
that the encrypted database is not replaced or modified.

The final ACL authorization cannot be automated without defeating the behavior
under test. To exercise the user-approval boundary, run:

```bash
ANYDOOR_RUN_INTERACTIVE_KEYCHAIN_ACL=1 swift test \
  --filter ClipboardHistoryModuleTests/testProductionKeychainCrossIdentityACLBoundary
```

Approve each macOS Keychain prompt. The harness then requires the second
identity to open the existing encrypted store and read its single entry in
both identity orders. Denying or cancelling a prompt fails the test.
