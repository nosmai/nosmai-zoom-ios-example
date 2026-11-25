import UIKit

final class HomeViewController: UIViewController {
    private let infoLabel = UILabel()

    override func viewDidLoad() {
        super.viewDidLoad()
        title = "Nosmai × Zoom"
        view.backgroundColor = .systemBackground

        let heading = UILabel()
        heading.text = "Live Streaming Demo"
        heading.font = .systemFont(ofSize: 28, weight: .bold)
        heading.textAlignment = .center

        infoLabel.font = .systemFont(ofSize: 14)
        infoLabel.textColor = .secondaryLabel
        infoLabel.textAlignment = .center
        infoLabel.numberOfLines = 0

        let hostButton = makeButton(title: "Go Live (Host)", color: .systemPink, action: #selector(goLive))
        let watchButton = makeButton(title: "Watch (Audience)", color: .systemIndigo, action: #selector(watch))

        let stack = UIStackView(arrangedSubviews: [heading, infoLabel, hostButton, watchButton])
        stack.axis = .vertical
        stack.spacing = 16
        stack.setCustomSpacing(32, after: infoLabel)
        stack.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(stack)

        NSLayoutConstraint.activate([
            stack.centerYAnchor.constraint(equalTo: view.centerYAnchor),
            stack.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 24),
            stack.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -24),
            hostButton.heightAnchor.constraint(equalToConstant: 54),
            watchButton.heightAnchor.constraint(equalToConstant: 54),
        ])

        switch DemoConfig.load() {
        case .success(let config):
            infoLabel.text = "Session: \(config.sessionName)\nStart the host first, then watch on another phone."
        case .failure(let error):
            infoLabel.text = error.message
            infoLabel.textColor = .systemRed
        }
    }


    private func makeButton(title: String, color: UIColor, action: Selector) -> UIButton {
        let button = UIButton(type: .system)
        button.setTitle(title, for: .normal)
        button.setTitleColor(.white, for: .normal)
        button.titleLabel?.font = .systemFont(ofSize: 18, weight: .semibold)
        button.backgroundColor = color
        button.layer.cornerRadius = 14
        button.addTarget(self, action: action, for: .touchUpInside)
        return button
    }

    @objc private func goLive() { open(role: .host) }
    @objc private func watch() { open(role: .audience) }

    private func requestCredential(for role: LiveViewController.Role, config: DemoConfig) {
        let alert = UIAlertController(title: "Join Zoom session", message: "Enter the session JWT issued by your server for this session and role.", preferredStyle: .alert)
        alert.addTextField { field in
            field.placeholder = "session token"
            field.isSecureTextEntry = true
            field.autocapitalizationType = .none
            field.autocorrectionType = .no
        }
        alert.addAction(UIAlertAction(title: "Cancel", style: .cancel))
        alert.addAction(UIAlertAction(title: "Join", style: .default) { [weak self, weak alert] _ in
            guard let self, let fields = alert?.textFields,
                  let credential = fields.last?.text?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !credential.isEmpty else {
                self?.infoLabel.text = "A session token is required."
                return
            }
            let live = LiveViewController(role: role, config: config, sessionToken: credential)
            self.navigationController?.pushViewController(live, animated: true)
        })
        present(alert, animated: true)
    }

    private func open(role: LiveViewController.Role) {
        switch DemoConfig.load() {
        case .success(let config):
            if role == .host && config.nosmaiAPIKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                infoLabel.text = "Set nosmaiAPIKey in Configuration/Local.plist to broadcast."
                return
            }
            requestCredential(for: role, config: config)
        case .failure(let error):
            let alert = UIAlertController(title: "Config needed", message: error.message, preferredStyle: .alert)
            alert.addAction(UIAlertAction(title: "OK", style: .default))
            present(alert, animated: true)
        }
    }
}
