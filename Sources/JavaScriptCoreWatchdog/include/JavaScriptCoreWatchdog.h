#ifndef ANYDOOR_JAVASCRIPTCORE_WATCHDOG_H
#define ANYDOOR_JAVASCRIPTCORE_WATCHDOG_H

#import <JavaScriptCore/JavaScriptCore.h>

/// Thin shim over JavaScriptCore's execution-time-limit facility.
///
/// `JSContextGroupSetExecutionTimeLimit` is exported by the JavaScriptCore
/// dylib (it appears in the framework's `.tbd`) but is not declared in the
/// public SDK headers, so Swift's JavaScriptCore overlay does not surface it.
/// This shim redeclares the two symbols we need and wraps them in a stable,
/// documented C API — the same technique the repo already uses for the private
/// `NSXPCConnection.auditToken` (see `XPCAuditToken`).
///
/// The execution time limit is the only reliable way to interrupt a *synchronous*
/// runaway script (e.g. `while (true) {}`): JavaScriptCore checks the deadline
/// periodically while executing and aborts the running job once it is exceeded.
/// A never-settling *asynchronous* promise leaves the engine idle, so the host
/// pairs this with its own wall-clock timeout.

/// Arm a per-plugin execution deadline. Any single synchronous run on `context`
/// that exceeds `seconds` is terminated by the engine (the running job throws a
/// terminated exception). Idempotent; re-arming replaces the previous limit.
void ADJSCArmExecutionTimeLimit(JSGlobalContextRef context, double seconds);

/// Disarm the execution deadline previously set on `context`.
void ADJSCDisarmExecutionTimeLimit(JSGlobalContextRef context);

#endif /* ANYDOOR_JAVASCRIPTCORE_WATCHDOG_H */
