#include "JavaScriptCoreWatchdog.h"

// Redeclared private JavaScriptCore symbols. These live in JavaScriptCore's
// private headers upstream (JSContextRefPrivate.h) and are exported by the
// shipping dylib, but are absent from the public SDK headers. Redeclaring them
// lets us link against the exported symbols without a private-header dependency.
typedef bool (*ADJSCShouldTerminateCallback)(JSContextRef ctx, void *context);

extern void JSContextGroupSetExecutionTimeLimit(
    JSContextGroupRef group,
    double limit,
    ADJSCShouldTerminateCallback callback,
    void *callbackContext);

extern void JSContextGroupClearExecutionTimeLimit(JSContextGroupRef group);

void ADJSCArmExecutionTimeLimit(JSGlobalContextRef context, double seconds) {
    if (context == NULL) {
        return;
    }
    JSContextGroupRef group = JSContextGetGroup(context);
    // A NULL callback makes the engine terminate the offending job on its own
    // once the deadline passes, which is exactly the behavior we want.
    JSContextGroupSetExecutionTimeLimit(group, seconds, NULL, NULL);
}

void ADJSCDisarmExecutionTimeLimit(JSGlobalContextRef context) {
    if (context == NULL) {
        return;
    }
    JSContextGroupRef group = JSContextGetGroup(context);
    JSContextGroupClearExecutionTimeLimit(group);
}
