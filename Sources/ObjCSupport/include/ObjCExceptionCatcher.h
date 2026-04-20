//
//  ObjCExceptionCatcher.h
//  Shield Swift call sites from Objective-C NSException crashes.
//
//  Swift cannot catch NSException. When ScriptingBridge's SBElementArray
//  mutates mid-iteration (e.g., Music.app swaps the currentPlaylist during
//  rapid track switching), the underlying ObjC code throws NSRangeException
//  or NSInternalInconsistencyException — which crashes the process.
//
//  Wrap any unsafe SB access in `OBJCCatch` to convert an NSException into
//  a nil return, letting Swift handle the recoverable case cleanly.
//

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// Execute `block`. If it raises an NSException, capture it and return it;
/// otherwise return nil. The block itself has no return value — callers
/// capture any result via closure variables.
NSException * _Nullable OBJCCatch(void (NS_NOESCAPE ^ block)(void));

NS_ASSUME_NONNULL_END
