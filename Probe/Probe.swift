import UIKit

/// A test app for the simulator. The screen turns white while a finger is down and black when
/// it comes up, so a benchmark can time a touch by the frame that changes. The text field takes
/// the keyboard on launch and saves what it receives to Documents/typed.txt.
@main
final class ProbeApp: UIResponder, UIApplicationDelegate {
    func application(_ application: UIApplication, configurationForConnecting session: UISceneSession,
                     options: UIScene.ConnectionOptions) -> UISceneConfiguration {
        let configuration = UISceneConfiguration(name: nil, sessionRole: session.role)
        configuration.delegateClass = ProbeScene.self
        return configuration
    }
}

final class ProbeScene: UIResponder, UIWindowSceneDelegate {
    var window: UIWindow?

    func scene(_ scene: UIScene, willConnectTo session: UISceneSession, options: UIScene.ConnectionOptions) {
        guard let scene = scene as? UIWindowScene else { return }
        let window = UIWindow(windowScene: scene)
        window.rootViewController = ProbeController()
        window.makeKeyAndVisible()
        self.window = window
    }
}

final class ProbeController: UIViewController {
    private let field = UITextField()
    private let typed = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("typed.txt")

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .black
        field.backgroundColor = .darkGray
        field.textColor = .white
        field.font = .monospacedSystemFont(ofSize: 22, weight: .regular)
        field.autocorrectionType = .no
        field.autocapitalizationType = .none
        field.spellCheckingType = .no
        field.smartQuotesType = .no
        field.smartDashesType = .no
        field.smartInsertDeleteType = .no
        field.addTarget(self, action: #selector(changed), for: .editingChanged)
        view.addSubview(field)
        try? "".write(to: typed, atomically: true, encoding: .utf8)
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        let area = view.safeAreaLayoutGuide.layoutFrame
        field.frame = CGRect(x: area.minX + 16, y: area.minY + 16, width: area.width - 32, height: 44)
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        field.becomeFirstResponder()
    }

    @objc private func changed() {
        try? (field.text ?? "").write(to: typed, atomically: true, encoding: .utf8)
    }

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {
        view.backgroundColor = .white
    }

    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent?) {
        view.backgroundColor = .black
    }

    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent?) {
        view.backgroundColor = .black
    }
}
