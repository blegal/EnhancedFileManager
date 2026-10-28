import AppKit
// Analyse de l'occupation du disque, partagée avec iBaobab : visible dans tout le module.
@_exported import DiskUsageKit

// Relancé par ssh comme SSH_ASKPASS : on répond à la demande puis on quitte.
if AskPass.isRequested { AskPass.run() }

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.regular)
app.run()
