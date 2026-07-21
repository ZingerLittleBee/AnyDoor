import Foundation
import JavaScriptCore
import JavaScriptCoreWatchdog
import PluginInterface

/// One plugin's execution home: a single `JSContext` confined to its own serial
/// queue (ADR-0008). Capability calls trampoline to the main actor and resolve
/// back on the queue; a hard watchdog (JavaScriptCore's execution-time-limit for
/// synchronous runaways, plus a host wall-clock timeout for never-settling
/// promises) destroys a hung context, which is recreated lazily on the next
/// invocation.
///
/// `@unchecked Sendable` is load-bearing and narrow: every stored property that
/// touches JavaScriptCore (`context`, `anydoor`, `registeredImpl`,
/// `pendingResolvers`, `nextToken`) is read and written **only** inside a block
/// dispatched on `queue`. `JSValue`s never leave the queue — results are decoded
/// to `ScriptValue` on the queue before any `await` resumes.
final class ScriptPluginContext: @unchecked Sendable {
    let id: ScriptPluginID

    private let package: ScriptPluginPackage
    private let declaredCapabilities: Set<ScriptCapability>
    private let capabilityHost: ScriptCapabilityHost
    private let store: (any ScriptKeyValueStore)?
    private let timeout: TimeInterval
    private let queue: DispatchQueue

    // MARK: Queue-confined JavaScriptCore state

    private var context: JSContext?
    private var anydoor: JSValue?
    private var registeredImpl: JSValue?
    private var pendingResolvers: [Int: (resolve: JSValue, reject: JSValue)] = [:]
    private var nextToken = 0

    init(
        id: ScriptPluginID,
        package: ScriptPluginPackage,
        capabilityHost: ScriptCapabilityHost,
        store: (any ScriptKeyValueStore)?,
        timeout: TimeInterval
    ) {
        self.id = id
        self.package = package
        self.declaredCapabilities = package.manifest.capabilities
        self.capabilityHost = capabilityHost
        self.store = store
        self.timeout = timeout
        self.queue = DispatchQueue(label: "dev.bybee.AnyDoor.script-plugin.\(id.rawValue)")
    }

    // MARK: - Invocation

    /// Run a plugin entry point under the watchdog and return its decoded result.
    /// A synchronous runaway is killed by the engine's execution-time-limit; a
    /// never-settling async result is killed by the wall-clock timeout. Either
    /// way the context is destroyed and the caller gets `.timedOut`.
    func invoke(_ entryPoint: String, arguments: [ScriptValue]) async throws -> ScriptValue {
        try await withCheckedThrowingContinuation { continuation in
            let box = InvocationBox(continuation: continuation)

            // The timeout timer lives on the same serial queue. If the queue is
            // blocked by a synchronous loop it cannot fire — but the engine's
            // execution-time-limit ends that loop, after which `runInvocation`
            // finishes first and cancels this. For a never-settling promise the
            // queue is idle, so this fires and tears the context down.
            let timeoutWork = DispatchWorkItem { [weak self] in
                self?.finish(box, result: .failure(ScriptPluginError.timedOut), tearDown: true)
            }
            box.timeoutWork = timeoutWork
            queue.asyncAfter(deadline: .now() + timeout, execute: timeoutWork)

            queue.async { [weak self] in
                self?.runInvocation(entryPoint, arguments: arguments, box: box)
            }
        }
    }

    /// Tear down the plugin's context and queue state (used on uninstall).
    ///
    /// Dispatched **async** on purpose: `teardown()` is called from the main
    /// actor (the registry's uninstall path), and a synchronous `queue.sync`
    /// would block that actor until the queue drains. If a synchronous runaway
    /// were mid-flight that wait could last until the execution-time-limit fires
    /// (up to `timeout`, 30 s in production), freezing the UI. Queuing the
    /// destroy behind any in-flight work lets uninstall return immediately;
    /// script deactivation has no external side effects, so nothing depends on
    /// the teardown having completed before uninstall proceeds. `self` is
    /// retained by the block, so the context outlives its removal from the
    /// runtime until the destroy runs.
    func teardown() {
        queue.async { [self] in destroyContext() }
    }

    // MARK: - Queue-confined internals

    private func runInvocation(_ entryPoint: String, arguments: [ScriptValue], box: InvocationBox) {
        let context: JSContext
        do {
            context = try ensureContext()
        } catch {
            finish(box, result: .failure(error), tearDown: false)
            return
        }

        context.exception = nil
        guard let anydoor else {
            finish(box, result: .failure(ScriptPluginError.pluginNotRegistered), tearDown: false)
            return
        }

        guard anydoor.invokeMethod("__isRegistered", withArguments: [])?.toBool() == true else {
            finish(box, result: .failure(ScriptPluginError.pluginNotRegistered), tearDown: false)
            return
        }
        guard anydoor.invokeMethod("__hasEntry", withArguments: [entryPoint])?.toBool() == true else {
            finish(box, result: .failure(ScriptPluginError.entryPointMissing(entryPoint)), tearDown: false)
            return
        }

        let argsArray = ScriptValue.array(arguments).makeJSValue(in: context)
        guard let promise = anydoor.invokeMethod("__dispatch", withArguments: [entryPoint, argsArray]) else {
            finish(box, result: .failure(ScriptPluginError.invocationFailed("dispatch unavailable")), tearDown: false)
            return
        }

        // A synchronous throw or an execution-time-limit termination shows up as
        // an exception on the context after the dispatch call returns.
        if let exception = context.exception {
            context.exception = nil
            finishForException(exception, box: box)
            return
        }

        attachSettlement(to: promise, in: context, box: box)

        // Attaching `.then` drains microtasks; a runaway that surfaced during the
        // drain lands here.
        if let exception = context.exception {
            context.exception = nil
            finishForException(exception, box: box)
        }
    }

    private func attachSettlement(to promise: JSValue, in context: JSContext, box: InvocationBox) {
        let onFulfilled: @convention(block) (JSValue) -> Void = { [weak self] result in
            self?.finish(box, result: .success(ScriptValue(jsValue: result)), tearDown: false)
        }
        let onRejected: @convention(block) (JSValue) -> Void = { [weak self] reason in
            let message = reason.toString() ?? "unknown error"
            self?.finish(box, result: .failure(ScriptPluginError.invocationFailed(message)), tearDown: false)
        }
        let fulfilledValue = JSValue(object: onFulfilled, in: context)
        let rejectedValue = JSValue(object: onRejected, in: context)
        promise.invokeMethod("then", withArguments: [fulfilledValue as Any, rejectedValue as Any])
    }

    private func finishForException(_ exception: JSValue, box: InvocationBox) {
        let description = exception.toString() ?? "unknown error"
        // CONSTRAINT: JavaScriptCore's execution-time-limit aborts a synchronous
        // runaway with an uncatchable exception that stringifies to
        // "JavaScript execution terminated." — there is no structured flag for
        // it (the shim arms the limit with a NULL callback), so a watchdog kill
        // is recognized only by that text. The classification is asymmetric on
        // purpose: a false positive (a plugin that throws its own message
        // containing "terminated") merely destroys a healthy context, which is
        // lazily recreated on the next invocation — wasteful, not harmful. The
        // failure mode to avoid is a false negative (a real kill NOT matching),
        // which would keep a poisoned context; the engine's wording makes that
        // path unreachable today. Revisit if the shim ever adopts a callback
        // that can report the kill directly.
        if description.localizedCaseInsensitiveContains("terminated") {
            finish(box, result: .failure(ScriptPluginError.timedOut), tearDown: true)
        } else {
            finish(box, result: .failure(ScriptPluginError.invocationFailed(description)), tearDown: false)
        }
    }

    /// Resolve an invocation exactly once. Every caller — the settlement
    /// callbacks, the exception paths, and the timeout timer (scheduled with
    /// `queue.asyncAfter`) — already runs on the plugin queue, so the resume
    /// guard needs no locking.
    private func finish(_ box: InvocationBox, result: Result<ScriptValue, Error>, tearDown: Bool) {
        guard !box.hasResumed else { return }
        box.hasResumed = true
        box.timeoutWork?.cancel()
        if tearDown { destroyContext() }
        box.continuation.resume(with: result)
    }

    private func ensureContext() throws -> JSContext {
        if let context { return context }

        guard let context = JSContext() else {
            throw ScriptPluginError.bundleEvaluationFailed("could not create JSContext")
        }
        if #available(macOS 13.3, *) {
            context.isInspectable = true
        }
        // Swallow the default console spew; exceptions are read explicitly.
        context.exceptionHandler = { _, _ in }

        // Arm the synchronous-runaway watchdog for this context's whole life.
        ADJSCArmExecutionTimeLimit(context.jsGlobalContextRef, timeout)

        context.evaluateScript(ScriptRuntimePrelude.source)
        guard let anydoor = context.objectForKeyedSubscript("anydoor"), !anydoor.isUndefined else {
            throw ScriptPluginError.bundleEvaluationFailed("prelude did not install anydoor")
        }
        injectCapabilities(into: anydoor, context: context)

        let source = try package.readBundleSource()
        context.evaluateScript(source, withSourceURL: package.bundleURL)
        if let exception = context.exception {
            context.exception = nil
            throw ScriptPluginError.bundleEvaluationFailed(exception.toString() ?? "bundle threw")
        }
        guard anydoor.invokeMethod("__isRegistered", withArguments: [])?.toBool() == true else {
            throw ScriptPluginError.pluginNotRegistered
        }

        self.context = context
        self.anydoor = anydoor
        return context
    }

    private func destroyContext() {
        if let context {
            ADJSCDisarmExecutionTimeLimit(context.jsGlobalContextRef)
        }
        pendingResolvers.removeAll()
        anydoor = nil
        registeredImpl = nil
        context = nil
    }

    // MARK: - Promise plumbing (queue-confined)

    private func makePromise(in context: JSContext) -> (promise: JSValue, token: Int) {
        let token = nextToken
        nextToken += 1
        let promise = JSValue(newPromiseIn: context) { [weak self] resolve, reject in
            guard let resolve, let reject else { return }
            self?.pendingResolvers[token] = (resolve, reject)
        }
        return (promise ?? JSValue(undefinedIn: context) ?? JSValue(), token)
    }

    /// Settle a capability promise from off-queue work; hops onto the queue.
    private func settle(token: Int, _ outcome: CapabilityOutcome) {
        queue.async { [weak self] in self?.resolveOnQueue(token: token, outcome) }
    }

    /// Resolve/reject a pending capability promise. Must already be on the queue.
    private func resolveOnQueue(token: Int, _ outcome: CapabilityOutcome) {
        guard let context, let pair = pendingResolvers.removeValue(forKey: token) else { return }
        switch outcome {
        case .void:
            pair.resolve.call(withArguments: [JSValue(undefinedIn: context) as Any])
        case let .value(value):
            pair.resolve.call(withArguments: [value.makeJSValue(in: context)])
        case let .fetchResponse(response):
            pair.resolve.call(withArguments: [response.makeJSObject(in: context)])
        case let .failure(message):
            let error = context.objectForKeyedSubscript("Error")?.construct(withArguments: [message])
            pair.reject.call(withArguments: [error ?? message as Any])
        }
    }

    // MARK: - Capability injection

    private func injectCapabilities(into anydoor: JSValue, context: JSContext) {
        if declaredCapabilities.contains(.fetch) { injectFetch(into: anydoor, context: context) }
        if declaredCapabilities.contains(.store) { injectStore(into: anydoor, context: context) }
        if declaredCapabilities.contains(.toast) { injectToast(into: anydoor, context: context) }
        if declaredCapabilities.contains(.pasteboard) { injectPasteboard(into: anydoor, context: context) }
        if declaredCapabilities.contains(.delay) { injectDelay(into: anydoor, context: context) }
        if declaredCapabilities.contains(.openURL) { injectOpenURL(into: anydoor, context: context) }
    }

    private func injectFetch(into anydoor: JSValue, context: JSContext) {
        let transport = capabilityHost.transport
        let block: @convention(block) (JSValue, JSValue) -> JSValue = { [weak self] urlValue, optionsValue in
            guard let self, let context = self.context else { return JSValue() }
            let request = Self.decodeFetchRequest(url: urlValue, options: optionsValue)
            let (promise, token) = self.makePromise(in: context)
            Task {
                do {
                    let response = try await transport.fetch(request)
                    self.settle(token: token, .fetchResponse(response))
                } catch {
                    self.settle(token: token, .failure("fetch failed: \(error.localizedDescription)"))
                }
            }
            return promise
        }
        anydoor.setObject(block, forKeyedSubscript: "fetch" as NSString)
    }

    private func injectStore(into anydoor: JSValue, context: JSContext) {
        // The store is `@MainActor`-isolated, so it is read through `self`
        // inside each `@MainActor` task — never captured across the queue.
        guard let storeObject = JSValue(newObjectIn: context) else { return }

        let get: @convention(block) (JSValue) -> JSValue = { [weak self] keyValue in
            guard let self, let context = self.context else { return JSValue() }
            let key = keyValue.toString() ?? ""
            let (promise, token) = self.makePromise(in: context)
            Task { @MainActor in
                let value = self.store?.get(key) ?? .null
                self.settle(token: token, .value(value))
            }
            return promise
        }
        let set: @convention(block) (JSValue, JSValue) -> JSValue = { [weak self] keyValue, valueValue in
            guard let self, let context = self.context else { return JSValue() }
            let key = keyValue.toString() ?? ""
            let value = ScriptValue(jsValue: valueValue)
            let (promise, token) = self.makePromise(in: context)
            Task { @MainActor in
                self.store?.set(key, value: value)
                self.settle(token: token, .void)
            }
            return promise
        }
        let remove: @convention(block) (JSValue) -> JSValue = { [weak self] keyValue in
            guard let self, let context = self.context else { return JSValue() }
            let key = keyValue.toString() ?? ""
            let (promise, token) = self.makePromise(in: context)
            Task { @MainActor in
                self.store?.remove(key)
                self.settle(token: token, .void)
            }
            return promise
        }
        let keys: @convention(block) () -> JSValue = { [weak self] in
            guard let self, let context = self.context else { return JSValue() }
            let (promise, token) = self.makePromise(in: context)
            Task { @MainActor in
                let all = self.store?.keys() ?? []
                self.settle(token: token, .value(.array(all.map(ScriptValue.string))))
            }
            return promise
        }
        storeObject.setObject(get, forKeyedSubscript: "get" as NSString)
        storeObject.setObject(set, forKeyedSubscript: "set" as NSString)
        storeObject.setObject(remove, forKeyedSubscript: "delete" as NSString)
        storeObject.setObject(keys, forKeyedSubscript: "keys" as NSString)
        anydoor.setObject(storeObject, forKeyedSubscript: "store" as NSString)
    }

    private func injectToast(into anydoor: JSValue, context: JSContext) {
        let present = capabilityHost.presentToast
        let id = id
        let block: @convention(block) (JSValue, JSValue) -> JSValue = { [weak self] kindValue, messageValue in
            guard let self, let context = self.context else { return JSValue() }
            let kind = kindValue.toString() ?? "info"
            let message = messageValue.toString() ?? ""
            let toast = Self.makeToast(kind: kind, message: message)
            let (promise, token) = self.makePromise(in: context)
            Task { @MainActor in
                present(id, toast)
                self.settle(token: token, .void)
            }
            return promise
        }
        anydoor.setObject(block, forKeyedSubscript: "toast" as NSString)
    }

    private func injectPasteboard(into anydoor: JSValue, context: JSContext) {
        let write = capabilityHost.writePasteboard
        let block: @convention(block) (JSValue) -> JSValue = { [weak self] textValue in
            guard let self, let context = self.context else { return JSValue() }
            let text = textValue.toString() ?? ""
            let (promise, token) = self.makePromise(in: context)
            Task { @MainActor in
                write(text)
                self.settle(token: token, .void)
            }
            return promise
        }
        anydoor.setObject(block, forKeyedSubscript: "copy" as NSString)
    }

    private func injectDelay(into anydoor: JSValue, context: JSContext) {
        let block: @convention(block) (JSValue) -> JSValue = { [weak self] msValue in
            guard let self, let context = self.context else { return JSValue() }
            let milliseconds = max(0, msValue.toDouble())
            let (promise, token) = self.makePromise(in: context)
            // Scheduled on the plugin queue; resolves the promise in place.
            self.queue.asyncAfter(deadline: .now() + milliseconds / 1000.0) { [weak self] in
                self?.resolveOnQueue(token: token, .void)
            }
            return promise
        }
        anydoor.setObject(block, forKeyedSubscript: "delay" as NSString)
    }

    private func injectOpenURL(into anydoor: JSValue, context: JSContext) {
        let open = capabilityHost.openURL
        let block: @convention(block) (JSValue) -> JSValue = { [weak self] urlValue in
            guard let self, let context = self.context else { return JSValue() }
            let string = urlValue.toString() ?? ""
            let (promise, token) = self.makePromise(in: context)
            guard let url = URL(string: string) else {
                self.resolveOnQueue(token: token, .failure("openURL: invalid URL \(string)"))
                return promise
            }
            Task { @MainActor in
                open(url)
                self.settle(token: token, .void)
            }
            return promise
        }
        anydoor.setObject(block, forKeyedSubscript: "openURL" as NSString)
    }

    // MARK: - Helpers

    private static func decodeFetchRequest(url: JSValue, options: JSValue) -> ScriptFetchRequest {
        let urlString = url.toString() ?? ""
        var method = "GET"
        var headers: [String: String] = [:]
        var body: String?
        if options.isObject {
            if let methodValue = options.objectForKeyedSubscript("method"), methodValue.isString {
                method = methodValue.toString() ?? method
            }
            if let headerValue = options.objectForKeyedSubscript("headers"), headerValue.isObject,
               let dictionary = headerValue.toDictionary() as? [String: Any] {
                for (key, value) in dictionary {
                    headers[key] = String(describing: value)
                }
            }
            if let bodyValue = options.objectForKeyedSubscript("body"), bodyValue.isString {
                body = bodyValue.toString()
            }
        }
        return ScriptFetchRequest(url: urlString, method: method, headers: headers, body: body)
    }

    private static func makeToast(kind: String, message: String) -> PluginToast {
        switch kind.lowercased() {
        case "success": return .success(message)
        case "failure", "error": return .failure(message)
        default: return .info(message)
        }
    }
}

/// Per-invocation resume guard. Created on the caller's actor but read and
/// written only on the plugin queue thereafter, which is what makes the
/// `@unchecked Sendable` sound.
private final class InvocationBox: @unchecked Sendable {
    let continuation: CheckedContinuation<ScriptValue, Error>
    var hasResumed = false
    var timeoutWork: DispatchWorkItem?

    init(continuation: CheckedContinuation<ScriptValue, Error>) {
        self.continuation = continuation
    }
}

/// The Sendable result of a capability's off-queue work, converted to a JSValue
/// back on the plugin queue.
private enum CapabilityOutcome: Sendable {
    case void
    case value(ScriptValue)
    case fetchResponse(ScriptFetchResponse)
    case failure(String)
}

private extension ScriptFetchResponse {
    func makeJSObject(in context: JSContext) -> JSValue {
        guard let object = JSValue(newObjectIn: context) else {
            return JSValue(undefinedIn: context) ?? JSValue()
        }
        object.setObject(status, forKeyedSubscript: "status" as NSString)
        object.setObject(status >= 200 && status < 300, forKeyedSubscript: "ok" as NSString)
        object.setObject(headers, forKeyedSubscript: "headers" as NSString)
        object.setObject(body, forKeyedSubscript: "body" as NSString)
        return object
    }
}
