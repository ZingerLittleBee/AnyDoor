#import "XPCAuditToken.h"

// NSXPCConnection exposes `auditToken` at runtime (stable since 10.8) but the
// public SDK omits its declaration. Redeclare it so the compiler emits the call.
@interface NSXPCConnection (AnyDoorAuditToken)
@property (nonatomic, readonly) audit_token_t auditToken;
@end

audit_token_t AnyDoorXPCPeerAuditToken(NSXPCConnection *connection, BOOL *ok) {
    if ([connection respondsToSelector:@selector(auditToken)]) {
        if (ok) { *ok = YES; }
        return connection.auditToken;
    }
    if (ok) { *ok = NO; }
    audit_token_t empty;
    memset(&empty, 0, sizeof(empty));
    return empty;
}
