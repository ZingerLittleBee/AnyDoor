import Foundation

/// The JavaScript prelude evaluated into every fresh plugin context before the
/// plugin bundle. It defines the `anydoor` global with `registerPlugin` and the
/// host-only dispatch/introspection helpers; capability functions are grafted
/// onto `anydoor` from Swift afterwards, and only for declared capabilities.
enum ScriptRuntimePrelude {
    static let source = """
    (function () {
      var __impl = null;
      globalThis.anydoor = {
        // Plugins call this once at load to register their entry points.
        registerPlugin: function (impl) { __impl = impl; },
        // Host-only introspection. Prefixed to signal "not plugin API".
        __isRegistered: function () { return __impl != null; },
        __hasEntry: function (name) {
          return __impl != null && typeof __impl[name] === 'function';
        },
        // Host-only dispatch: normalize a sync or async entry point into a
        // single Promise so the Swift side always awaits the same shape. A
        // synchronous throw becomes a rejected promise; a synchronous return
        // becomes a resolved one.
        __dispatch: function (name, args) {
          return new Promise(function (resolve, reject) {
            try { resolve(__impl[name].apply(__impl, args)); }
            catch (error) { reject(error); }
          });
        }
      };
    })();
    """
}
