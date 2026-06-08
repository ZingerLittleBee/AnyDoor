import Foundation
import HostsHelperShared

let delegate = HostsHelperListener()
let listener = NSXPCListener(machServiceName: PrivilegedHelperConstants.machServiceName)
listener.delegate = delegate
listener.resume()
// On-demand: launchd starts us on connect; exit when idle.
RunLoop.current.run()
