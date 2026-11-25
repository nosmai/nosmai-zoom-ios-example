import UIKit

/// Host-side controls for Nosmai: beauty sliders, cloud filters and cloud AR effects.
/// Everything applied here is rendered by Nosmai before the frame reaches Zoom,
/// so viewers see exactly what the host sees.
final class EffectsPanelView: UIView {
    private enum Tab: Int, CaseIterable {
        case beauty, filters, effects

        var title: String {
            switch self {
            case .beauty: return "Beauty"
            case .filters: return "Filters"
            case .effects: return "AR Effects"
            }
        }

        /// Category name understood by the Nosmai cloud filter API.
        var cloudType: String? {
            switch self {
            case .beauty: return nil
            case .filters: return "filter"
            case .effects: return "effects"
            }
        }
    }

    private struct CloudItem {
        let id: String
        let name: String
        let thumbnailURL: URL?

        init?(_ dict: [AnyHashable: Any]) {
            func text(_ keys: String...) -> String? {
                for key in keys {
                    if let value = dict[key] as? String, !value.isEmpty { return value }
                    if let value = dict[key] as? NSNumber { return value.stringValue }
                }
                return nil
            }
            // The download/apply APIs take the catalog slug ("filterId"); the
            // catalog's "id" is a database UUID the download endpoint rejects.
            guard let id = text("filterId", "id") else { return nil }
            self.id = id
            self.name = text("displayName", "name") ?? id
            self.thumbnailURL = text("thumbnailUrl", "mobilePreviewUrl", "previewUrl").flatMap(URL.init(string:))
        }
    }

    private enum LoadState {
        case idle, loading, loaded, failed(String)
    }

    private var effects: NosmaiEffectsEngine? { NosmaiCore.shared().effects }

    private var tab: Tab = .beauty
    private var ready = false
    private var items: [Tab: [CloudItem]] = [:]
    private var loadState: [Tab: LoadState] = [:]
    /// Selected cloud item id per tab; nil means "None".
    private var selected: [Tab: String] = [:]
    private var downloading: Set<String> = []

    private let segmented = UISegmentedControl(items: Tab.allCases.map(\.title))
    private let beautyStack = UIStackView()
    private let messageLabel = UILabel()
    private let collectionView: UICollectionView

    /// Short user-facing feedback ("Downloading…", errors).
    var onStatus: ((String) -> Void)?

    override init(frame: CGRect) {
        let layout = UICollectionViewFlowLayout()
        layout.scrollDirection = .horizontal
        layout.itemSize = CGSize(width: 72, height: 96)
        layout.minimumLineSpacing = 10
        layout.sectionInset = UIEdgeInsets(top: 0, left: 12, bottom: 0, right: 12)
        collectionView = UICollectionView(frame: .zero, collectionViewLayout: layout)
        super.init(frame: frame)
        build()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    // MARK: - Public

    /// Call once Nosmai is initialised and the camera is running.
    func nosmaiReady() {
        ready = true
        showCurrentTab()
    }

    // MARK: - UI

    private func build() {
        backgroundColor = UIColor.black.withAlphaComponent(0.55)
        layer.cornerRadius = 14
        clipsToBounds = true

        segmented.selectedSegmentIndex = tab.rawValue
        segmented.selectedSegmentTintColor = .systemPink
        segmented.setTitleTextAttributes([.foregroundColor: UIColor.white], for: .normal)
        segmented.setTitleTextAttributes([.foregroundColor: UIColor.white], for: .selected)
        segmented.addTarget(self, action: #selector(tabChanged), for: .valueChanged)

        beautyStack.axis = .vertical
        beautyStack.spacing = 2
        beautyStack.distribution = .fillEqually
        let sliders: [(String, Selector)] = [
            ("Smooth", #selector(smoothChanged(_:))),
            ("Whiten", #selector(whitenChanged(_:))),
            ("Slim", #selector(slimChanged(_:))),
            ("Big Eyes", #selector(eyesChanged(_:))),
            ("Sharpen", #selector(sharpenChanged(_:))),
        ]
        sliders.forEach { beautyStack.addArrangedSubview(makeSlider(title: $0.0, action: $0.1)) }

        collectionView.backgroundColor = .clear
        collectionView.showsHorizontalScrollIndicator = false
        collectionView.dataSource = self
        collectionView.delegate = self
        collectionView.register(EffectCell.self, forCellWithReuseIdentifier: EffectCell.reuseID)

        messageLabel.textColor = .white
        messageLabel.font = .systemFont(ofSize: 13)
        messageLabel.textAlignment = .center
        messageLabel.numberOfLines = 0

        for subview in [segmented, beautyStack, collectionView, messageLabel] {
            subview.translatesAutoresizingMaskIntoConstraints = false
            addSubview(subview)
        }
        NSLayoutConstraint.activate([
            heightAnchor.constraint(equalToConstant: 216),

            segmented.topAnchor.constraint(equalTo: topAnchor, constant: 10),
            segmented.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),
            segmented.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12),

            beautyStack.topAnchor.constraint(equalTo: segmented.bottomAnchor, constant: 8),
            beautyStack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 14),
            beautyStack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -14),
            beautyStack.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -8),

            collectionView.leadingAnchor.constraint(equalTo: leadingAnchor),
            collectionView.trailingAnchor.constraint(equalTo: trailingAnchor),
            collectionView.centerYAnchor.constraint(equalTo: beautyStack.centerYAnchor),
            collectionView.heightAnchor.constraint(equalToConstant: 100),

            messageLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 16),
            messageLabel.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -16),
            messageLabel.centerYAnchor.constraint(equalTo: beautyStack.centerYAnchor),
        ])
        showCurrentTab()
    }

    private func makeSlider(title: String, action: Selector) -> UIView {
        let label = UILabel()
        label.text = title
        label.textColor = .white
        label.font = .systemFont(ofSize: 13, weight: .medium)
        label.widthAnchor.constraint(equalToConstant: 68).isActive = true

        let slider = UISlider()
        slider.minimumValue = 0
        slider.maximumValue = 1
        slider.minimumTrackTintColor = .systemPink
        slider.addTarget(self, action: action, for: .valueChanged)

        let row = UIStackView(arrangedSubviews: [label, slider])
        row.axis = .horizontal
        row.spacing = 8
        row.alignment = .center
        return row
    }

    @objc private func tabChanged() {
        tab = Tab(rawValue: segmented.selectedSegmentIndex) ?? .beauty
        showCurrentTab()
    }

    private func showCurrentTab() {
        beautyStack.isHidden = true
        collectionView.isHidden = true
        messageLabel.isHidden = true

        func show(message: String) {
            messageLabel.text = message
            messageLabel.isHidden = false
        }

        guard ready, let effects else { return show(message: "Starting Nosmai…") }

        if tab == .beauty {
            if effects.isBeautyEffectEnabled() {
                beautyStack.isHidden = false
            } else {
                show(message: "Beauty effects are not enabled for this Nosmai license.")
            }
            return
        }

        guard effects.isCloudFilterEnabled() else {
            return show(message: "Cloud filters are not enabled for this Nosmai license.")
        }
        switch loadState[tab] ?? .idle {
        case .idle:
            loadCloudItems(for: tab)
            show(message: "Loading…")
        case .loading:
            show(message: "Loading…")
        case .failed(let reason):
            show(message: "\(reason)\nSwitch tabs to retry.")
            loadState[tab] = .idle
        case .loaded:
            if items[tab]?.isEmpty ?? true {
                show(message: "No \(tab.title.lowercased()) available for this license.")
            } else {
                collectionView.isHidden = false
                collectionView.reloadData()
            }
        }
    }

    // MARK: - Cloud filters

    private func loadCloudItems(for tab: Tab) {
        guard let effects, let cloudType = tab.cloudType else { return }
        loadState[tab] = .loading
        let options = NosmaiCloudFilterRequestOptions()
        options.page = 1
        options.limit = 50
        options.fetchAllPages = true
        options.filterType = cloudType
        effects.getCloudFilters(with: options) { [weak self] filters, _, error in
            DispatchQueue.main.async {
                guard let self else { return }
                if let filters {
                    self.items[tab] = filters.compactMap { CloudItem($0) }
                    self.loadState[tab] = .loaded
                } else {
                    self.loadState[tab] = .failed(error?.localizedDescription ?? "Could not load \(tab.title.lowercased()).")
                }
                if self.tab == tab { self.showCurrentTab() }
            }
        }
    }

    private func clear(_ tab: Tab) {
        selected[tab] = nil
        if tab == .filters { effects?.clearFilter() } else { effects?.clearAREffect() }
        collectionView.reloadData()
    }

    private func select(_ item: CloudItem, in tab: Tab) {
        guard let effects, !downloading.contains(item.id) else { return }
        selected[tab] = item.id
        collectionView.reloadData()

        if effects.isCloudFilterDownloaded(item.id) {
            apply(item, in: tab)
            return
        }
        downloading.insert(item.id)
        collectionView.reloadData()
        onStatus?("Downloading \(item.name)…")
        effects.downloadCloudFilter(item.id, progress: nil) { [weak self] success, _, error in
            DispatchQueue.main.async {
                guard let self else { return }
                self.downloading.remove(item.id)
                if success {
                    // Only apply if the user has not picked something else meanwhile.
                    if self.selected[tab] == item.id { self.apply(item, in: tab) }
                } else {
                    if self.selected[tab] == item.id { self.selected[tab] = nil }
                    self.onStatus?("Download failed: \(error?.localizedDescription ?? item.name)")
                }
                self.collectionView.reloadData()
            }
        }
    }

    private func apply(_ item: CloudItem, in tab: Tab) {
        effects?.applyCloudFilter(item.id) { [weak self] success, error in
            DispatchQueue.main.async {
                guard let self else { return }
                if success {
                    self.onStatus?("\(item.name) applied")
                } else {
                    if self.selected[tab] == item.id { self.selected[tab] = nil }
                    self.collectionView.reloadData()
                    self.onStatus?("Could not apply \(item.name): \(error?.localizedDescription ?? "unknown error")")
                }
            }
        }
    }

    // MARK: - Beauty

    @objc private func smoothChanged(_ slider: UISlider) { effects?.applySkinSmoothing(slider.value) }
    @objc private func whitenChanged(_ slider: UISlider) { effects?.applySkinWhitening(slider.value) }
    @objc private func slimChanged(_ slider: UISlider) { effects?.applyFaceSlimming(slider.value) }
    @objc private func eyesChanged(_ slider: UISlider) { effects?.applyEyeEnlargement(slider.value) }
    @objc private func sharpenChanged(_ slider: UISlider) { effects?.applySharpening(slider.value) }
}

// MARK: - Collection view

extension EffectsPanelView: UICollectionViewDataSource, UICollectionViewDelegate {
    func collectionView(_ collectionView: UICollectionView, numberOfItemsInSection section: Int) -> Int {
        (items[tab]?.count ?? 0) + 1 // +1 for "None"
    }

    func collectionView(_ collectionView: UICollectionView,
                        cellForItemAt indexPath: IndexPath) -> UICollectionViewCell {
        let cell = collectionView.dequeueReusableCell(withReuseIdentifier: EffectCell.reuseID, for: indexPath) as! EffectCell
        if indexPath.item == 0 {
            cell.configureNone(selected: selected[tab] == nil)
        } else if let item = items[tab]?[indexPath.item - 1] {
            cell.configure(name: item.name,
                           thumbnailURL: item.thumbnailURL,
                           selected: selected[tab] == item.id,
                           downloading: downloading.contains(item.id),
                           downloaded: effects?.isCloudFilterDownloaded(item.id) ?? false)
        }
        return cell
    }

    func collectionView(_ collectionView: UICollectionView, didSelectItemAt indexPath: IndexPath) {
        if indexPath.item == 0 {
            clear(tab)
        } else if let item = items[tab]?[indexPath.item - 1] {
            select(item, in: tab)
        }
    }
}

// MARK: - Cell

private final class EffectCell: UICollectionViewCell {
    static let reuseID = "EffectCell"
    private static let imageCache = NSCache<NSURL, UIImage>()

    private let imageView = UIImageView()
    private let nameLabel = UILabel()
    private let badge = UIImageView()
    private let spinner = UIActivityIndicatorView(style: .medium)
    private var currentURL: URL?

    override init(frame: CGRect) {
        super.init(frame: frame)
        imageView.contentMode = .scaleAspectFill
        imageView.clipsToBounds = true
        imageView.layer.cornerRadius = 12
        imageView.layer.borderColor = UIColor.systemPink.cgColor
        imageView.backgroundColor = UIColor.white.withAlphaComponent(0.15)
        imageView.tintColor = .white

        nameLabel.textColor = .white
        nameLabel.font = .systemFont(ofSize: 11)
        nameLabel.textAlignment = .center

        badge.image = UIImage(systemName: "arrow.down.circle.fill")
        badge.tintColor = .white

        spinner.color = .white
        spinner.hidesWhenStopped = true

        for subview in [imageView, nameLabel, badge, spinner] {
            subview.translatesAutoresizingMaskIntoConstraints = false
            contentView.addSubview(subview)
        }
        NSLayoutConstraint.activate([
            imageView.topAnchor.constraint(equalTo: contentView.topAnchor),
            imageView.centerXAnchor.constraint(equalTo: contentView.centerXAnchor),
            imageView.widthAnchor.constraint(equalToConstant: 68),
            imageView.heightAnchor.constraint(equalToConstant: 68),

            nameLabel.topAnchor.constraint(equalTo: imageView.bottomAnchor, constant: 4),
            nameLabel.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
            nameLabel.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),

            badge.trailingAnchor.constraint(equalTo: imageView.trailingAnchor, constant: -3),
            badge.bottomAnchor.constraint(equalTo: imageView.bottomAnchor, constant: -3),
            badge.widthAnchor.constraint(equalToConstant: 18),
            badge.heightAnchor.constraint(equalToConstant: 18),

            spinner.centerXAnchor.constraint(equalTo: imageView.centerXAnchor),
            spinner.centerYAnchor.constraint(equalTo: imageView.centerYAnchor),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func configureNone(selected: Bool) {
        currentURL = nil
        nameLabel.text = "None"
        imageView.contentMode = .center
        imageView.image = UIImage(systemName: "nosign")
        imageView.layer.borderWidth = selected ? 3 : 0
        badge.isHidden = true
        spinner.stopAnimating()
    }

    func configure(name: String, thumbnailURL: URL?, selected: Bool, downloading: Bool, downloaded: Bool) {
        nameLabel.text = name
        imageView.layer.borderWidth = selected ? 3 : 0
        badge.isHidden = downloaded || downloading
        downloading ? spinner.startAnimating() : spinner.stopAnimating()
        loadThumbnail(thumbnailURL)
    }

    private func loadThumbnail(_ url: URL?) {
        guard url != currentURL || imageView.image == nil else { return }
        currentURL = url
        imageView.contentMode = .center
        imageView.image = UIImage(systemName: "sparkles")
        guard let url else { return }
        if let cached = Self.imageCache.object(forKey: url as NSURL) {
            show(cached)
            return
        }
        URLSession.shared.dataTask(with: url) { [weak self] data, _, _ in
            guard let data, let image = UIImage(data: data) else { return }
            Self.imageCache.setObject(image, forKey: url as NSURL)
            DispatchQueue.main.async {
                guard let self, self.currentURL == url else { return }
                self.show(image)
            }
        }.resume()
    }

    private func show(_ image: UIImage) {
        imageView.contentMode = .scaleAspectFill
        imageView.image = image
    }
}
