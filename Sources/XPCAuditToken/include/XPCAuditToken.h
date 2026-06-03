#import <Foundation/Foundation.h>
#import <bsm/libbsm.h>

NS_ASSUME_NONNULL_BEGIN

/// Returns the peer audit token for an NSXPCConnection. Sets `ok` to false if
/// the connection does not expose an audit token.
audit_token_t AnyDoorXPCPeerAuditToken(NSXPCConnection *connection, BOOL *ok);

NS_ASSUME_NONNULL_END
