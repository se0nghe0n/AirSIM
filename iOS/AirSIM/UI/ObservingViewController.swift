import UIKit
import Observation

/// Explicit observation also works on iOS 17, before UIKit's automatic observation support.
/// Re-arm after the mutation completes; keep controls and navigation controllers alive.
@MainActor
class ObservingViewController: UIViewController {
    var observesWhileHidden: Bool { false }
    private var observing = false
    private var generation = 0
    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        observing = true
        observeChanges()
    }
    override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
        if !observesWhileHidden { observing = false; generation += 1 }
    }
    func render() {}
    func observeChanges() {
        guard observing, isViewLoaded else { return }
        generation += 1
        let token = generation
        withObservationTracking { render() } onChange: { [weak self] in
            Task { @MainActor [weak self] in
                guard let self, self.observing, self.generation == token else { return }
                self.observeChanges()
            }
        }
    }
}
