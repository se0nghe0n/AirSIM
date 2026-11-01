import UIKit

/// Root of the call window that RootViewController places above the main window, so root sheets and
/// onboarding cannot cover Accept or Decline. VoWLAN calls have no CallKit screen to fall back on.
@MainActor
final class ActiveCallContainerViewController: UIViewController {
    let call: ActiveCallViewController
    override var childForStatusBarStyle: UIViewController? { call }
    override var childForStatusBarHidden: UIViewController? { call }
    init(call: ActiveCallViewController) { self.call = call; super.init(nibName: nil, bundle: nil) }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override func viewDidLoad() {
        super.viewDidLoad()
        addChild(call); call.view.frame = view.bounds; call.view.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        view.addSubview(call.view); call.didMove(toParent: self)
    }
}
