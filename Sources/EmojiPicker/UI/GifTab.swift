import AppKit
import PickerCore
import os

/// The GIF tab. Empty query: quick-search chips, "Recently used", then GIPHY trending. Typing
/// searches GIPHY (quoted words must all match, see `GifQuery`) after a short debounce. Results sit
/// in a two-column masonry grid that pages in more as you scroll. Picking downloads the full GIF
/// while the panel stays open, then hands it to the inserter.
@MainActor
final class GifTab: NSObject, PickerTabContent, NSCollectionViewDataSource, NSCollectionViewDelegate,
    MasonryLayoutDataSource {
    static let ratingKey = "gifRating"
    static let chips = ["Trending", "thumbs up", "lol", "thank you", "facepalm", "yes", "no", "wow"]
    private static let debounce: Duration = .milliseconds(300)
    /// Trending is kept in memory between opens and refetched only when older than this.
    private static let trendingMaxAge: TimeInterval = 10 * 60
    private static let footerHeight: CGFloat = 22
    private static let chipRowHeight: CGFloat = 30
    /// Start fetching the next page when the bottom of the content is this close.
    private static let prefetchDistance: CGFloat = 400
    private static let log = Logger(subsystem: "com.emojipicker.app", category: "gif")

    let view: NSView
    /// Opens Settings (where the GIPHY key is entered).
    var onOpenSettings: (() -> Void)?
    /// Replaces the picker's search text (used by the chips).
    var onRequestQuery: ((String) -> Void)?

    private let recents: RecentsStore<GifResult>
    private let commit: (InsertPayload) -> Void
    private let images = GifImageLoader()
    private let apiSession = URLSession(configuration: .ephemeral)
    private let downloadSession = URLSession(configuration: .ephemeral)

    // Views
    private let root: GifRootView
    private let chipRow = NSScrollView()
    private let scrollView = NSScrollView()
    private let collectionView = GridCollectionView()
    private let layout = MasonryLayout()
    private let centre = NSStackView()
    private let spinner = NSProgressIndicator()
    private let messageLabel = NSTextField(labelWithString: "")
    private let settingsButton = NSButton(title: "Open Settings", target: nil, action: nil)
    private let footerStatus = NSButton(title: "", target: nil, action: nil)
    private let attribution = NSTextField(labelWithString: "Powered by GIPHY")

    // State
    private enum Feed {
        case trending
        /// A new query is waiting for its debounce or its session: nothing is shown or loaded.
        case pending(GifQuery)
        case search(GifSearchSession, GifQuery)
    }

    private struct Problem {
        let text: String
        var opensSettings = false
    }

    private struct Section {
        let title: String?
        var items: [GifResult]
    }

    private var feed: Feed = .trending
    private var query = ""
    private var sections: [Section] = []
    private var searchResults: [GifResult] = []
    private var trending: [GifResult] = []
    private var trendingNextOffset: Int? = 0
    private var trendingFetchedAt: Date?
    /// Bumped on every new query/feed: results from an older generation are dropped.
    private var generation = 0
    private var debounceTask: Task<Void, Never>?
    private var loadTask: Task<Void, Never>?
    /// At most one fetch at a time: `GifSearchSession.nextBatch()` must not run concurrently.
    private var inFlight = false
    /// No more pages, or the last fetch failed (a new query or reopening retries).
    private var exhausted = false
    private var problem: Problem?
    /// The last feed fetch failed (as opposed to a download): reopening the picker retries it.
    private var fetchFailed = false
    private var keyLoad: Task<String?, Never>?
    private var recentsChanged = false
    /// Return was pressed before the new query's first results arrived: pick the first one then.
    private var activateWhenLoaded = false

    private var selection: IndexPath?
    /// The picker's keyboard zone is on the GIFs (otherwise the highlight is drawn dimmed).
    private var contentFocused = false
    private var pressed: IndexPath?
    /// See `GridView`: hover doesn't move the highlight until the mouse moves after the panel opens.
    private var mouseAtReset: NSPoint?
    private var hoverArmed = true
    private var pick: (id: String, task: Task<Void, Never>)?

    init(frame: NSRect, recents: RecentsStore<GifResult>, commit: @escaping (InsertPayload) -> Void) {
        self.recents = recents
        self.commit = commit
        root = GifRootView(frame: frame)
        view = root
        super.init()
        buildViews()
        rebuild(resetSelection: true)
    }

    // MARK: Views

    private func buildViews() {
        root.onLayout = { [weak self] in self?.layoutViews() }
        root.onVisibilityChange = { [weak self] in self?.visibilityChanged() }

        let chips = NSStackView()
        chips.orientation = .horizontal
        chips.spacing = 4
        chips.edgeInsets = NSEdgeInsets(top: 0, left: 8, bottom: 0, right: 8)
        for title in Self.chips {
            let chip = NSButton(title: title, target: self, action: #selector(chipClicked(_:)))
            chip.bezelStyle = .push
            chip.controlSize = .small
            chip.font = .systemFont(ofSize: 11)
            chip.refusesFirstResponder = true // the search field keeps the keyboard
            chips.addArrangedSubview(chip)
        }
        chips.frame = NSRect(origin: .zero, size: NSSize(width: chips.fittingSize.width, height: Self.chipRowHeight))
        chipRow.documentView = chips
        chipRow.drawsBackground = false
        chipRow.hasHorizontalScroller = false
        chipRow.hasVerticalScroller = false
        chipRow.horizontalScrollElasticity = .allowed
        chipRow.verticalScrollElasticity = .none
        root.addSubview(chipRow)

        layout.dataSource = self
        collectionView.collectionViewLayout = layout
        collectionView.dataSource = self
        collectionView.delegate = self
        collectionView.isSelectable = false
        collectionView.backgroundColors = [.clear]
        collectionView.register(GifCell.self, forItemWithIdentifier: GifCell.identifier)
        collectionView.register(
            GifHeader.self, forSupplementaryViewOfKind: NSCollectionView.elementKindSectionHeader,
            withIdentifier: GifHeader.identifier)
        collectionView.onHover = { [weak self] point in self?.hover(at: point) }
        collectionView.onPress = { [weak self] point in
            self?.pressed = self?.indexPath(at: point)
            self?.onFocusRequest?(.content)
        }
        collectionView.onRelease = { [weak self] point in self?.release(at: point) }

        scrollView.drawsBackground = false
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.scrollerStyle = .overlay
        scrollView.documentView = collectionView
        collectionView.frame = NSRect(origin: .zero, size: scrollView.contentSize)
        collectionView.autoresizingMask = [.width]
        scrollView.contentView.postsBoundsChangedNotifications = true
        NotificationCenter.default.addObserver(
            self, selector: #selector(didScroll),
            name: NSView.boundsDidChangeNotification, object: scrollView.contentView)
        root.addSubview(scrollView)

        spinner.style = .spinning
        spinner.controlSize = .small
        spinner.isDisplayedWhenStopped = false
        messageLabel.textColor = .secondaryLabelColor
        messageLabel.font = .systemFont(ofSize: 12)
        messageLabel.alignment = .center
        messageLabel.lineBreakMode = .byTruncatingTail
        settingsButton.target = self
        settingsButton.action = #selector(openSettings)
        settingsButton.bezelStyle = .push
        settingsButton.controlSize = .small
        settingsButton.refusesFirstResponder = true
        centre.orientation = .vertical
        centre.detachesHiddenViews = true
        centre.alignment = .centerX
        centre.spacing = 8
        for v in [spinner, messageLabel, settingsButton] as [NSView] { centre.addArrangedSubview(v) }
        root.addSubview(centre)

        // Footer: one-line status (an error while results are shown) and the GIPHY attribution.
        footerStatus.isBordered = false
        footerStatus.font = .systemFont(ofSize: 11)
        footerStatus.alignment = .left
        footerStatus.lineBreakMode = .byTruncatingTail
        footerStatus.refusesFirstResponder = true
        footerStatus.target = self
        footerStatus.action = #selector(openSettings)
        root.addSubview(footerStatus)
        attribution.font = .systemFont(ofSize: 10, weight: .medium)
        attribution.textColor = .secondaryLabelColor
        attribution.alignment = .right
        root.addSubview(attribution)

        NotificationCenter.default.addObserver(
            self, selector: #selector(windowStateChanged(_:)),
            name: NSWindow.didChangeOcclusionStateNotification, object: nil)
        NotificationCenter.default.addObserver(
            self, selector: #selector(windowStateChanged(_:)),
            name: NSWindow.didBecomeKeyNotification, object: nil)
        NotificationCenter.default.addObserver(
            self, selector: #selector(windowResignedKey(_:)),
            name: NSWindow.didResignKeyNotification, object: nil)
        layoutViews()
    }

    private var showsChips: Bool {
        if case .trending = feed { return true }
        return false
    }

    private func layoutViews() {
        let b = root.bounds
        let footer = Self.footerHeight
        let chipHeight = showsChips ? Self.chipRowHeight : 0
        chipRow.isHidden = !showsChips
        chipRow.frame = NSRect(x: 0, y: b.height - chipHeight, width: b.width, height: chipHeight)
        scrollView.frame = NSRect(x: 0, y: footer, width: b.width, height: max(0, b.height - footer - chipHeight))
        collectionView.frame.size.width = scrollView.contentSize.width
        let attributionWidth: CGFloat = 100
        attribution.frame = NSRect(x: b.width - 8 - attributionWidth, y: 4, width: attributionWidth, height: 14)
        footerStatus.frame = NSRect(x: 8, y: 2, width: b.width - 24 - attributionWidth, height: 18)
        let centreSize = NSSize(width: b.width - 16, height: 70)
        centre.frame = NSRect(
            x: 8, y: scrollView.frame.midY - centreSize.height / 2, width: centreSize.width, height: centreSize.height)
        messageLabel.preferredMaxLayoutWidth = centreSize.width
    }

    // MARK: PickerTabContent

    func setQuery(_ q: String) {
        cancelPick()
        let parsed = GifQuery.parse(q)
        // Only whitespace or quotes: nothing to send to GIPHY, so show the empty-query view.
        let normalized = parsed.apiQuery.isEmpty ? "" : q.trimmingCharacters(in: .whitespacesAndNewlines)
        guard normalized != query || (normalized.isEmpty && recentsChanged) else { return }
        query = normalized
        activateWhenLoaded = false
        debounceTask?.cancel()
        debounceTask = nil
        cancelLoad()
        if normalized.isEmpty {
            showTrending()
        } else {
            // Clear the previous feed now so Return during the debounce can't pick from it.
            feed = .pending(parsed)
            searchResults = []
            problem = nil
            fetchFailed = false
            exhausted = false
            rebuild(resetSelection: true)
            debounceTask = Task { [weak self] in
                try? await Task.sleep(for: Self.debounce)
                guard !Task.isCancelled else { return }
                self?.startSearch(parsed)
            }
        }
    }

    let zones: [PickerZone] = [.search, .content]
    var onFocusRequest: ((PickerZone) -> Void)?

    func handle(_ key: ZoneKey, in zone: PickerZone) -> ZoneResult {
        handleSearchOrContent(key, in: zone, move: moveSelection, activate: activateSelection)
    }

    func focusChanged(to zone: PickerZone) {
        contentFocused = zone == .content
        if contentFocused, selection == nil {
            scrollView.layoutSubtreeIfNeeded()
            setSelection(firstIndex, scroll: true)
        }
        if let selection { cell(at: selection)?.isDimmed = !contentFocused }
    }

    /// Returns whether the highlight moved (false with nothing above, below or beside it).
    private func moveSelection(_ d: Direction) -> Bool {
        scrollView.layoutSubtreeIfNeeded()
        guard let current = selection else {
            setSelection(firstIndex, scroll: true)
            return selection != nil
        }
        if let next = layout.geometry.neighbour(of: current, d) {
            setSelection(next, scroll: true)
            return true
        }
        if d == .down { loadMoreIfNeeded(force: true) }
        return false
    }

    /// Return: picks the highlight, or the first result once a just-typed query's results arrive.
    private func activateSelection() {
        if awaitingFirstResults {
            activateWhenLoaded = true
            return
        }
        guard let selection else { return }
        activate(selection)
    }

    /// A query was typed and its first results haven't arrived yet.
    private var awaitingFirstResults: Bool {
        switch feed {
        case .trending: return false
        case .pending: return true
        case .search: return searchResults.isEmpty && inFlight
        }
    }

    func didShow() {
        // Read the key on every show (a key added in Settings is picked up without a restart),
        // off the main thread so the open-time budget never waits on the keychain.
        loadKey()
        if recentsChanged, case .trending = feed {
            recentsChanged = false
            rebuild(resetSelection: true)
        }
        resetSelectionAndScroll()
        // Fetches are async: the panel is shown first, results arrive after.
        if fetchFailed {
            retry()
        } else {
            refreshTrendingIfNeeded()
        }
    }

    // MARK: Feeds

    private func showTrending() {
        feed = .trending
        problem = nil
        fetchFailed = false
        exhausted = trendingNextOffset == nil
        recentsChanged = false
        rebuild(resetSelection: true)
        if isOnScreen { refreshTrendingIfNeeded() }
    }

    /// The content rating changed: cached trending was fetched with the old one, so refetch it
    /// the next time trending is shown.
    func ratingChanged() {
        trendingFetchedAt = nil
    }

    private func refreshTrendingIfNeeded() {
        guard case .trending = feed, query.isEmpty else { return }
        let stale = trendingFetchedAt.map { Date().timeIntervalSince($0) > Self.trendingMaxAge } ?? true
        if trending.isEmpty || stale { load(fresh: true) }
    }

    private func retry() {
        switch feed {
        case .trending:
            problem = nil
            fetchFailed = false
            load(fresh: true)
        case .pending(let q), .search(_, let q):
            startSearch(q)
        }
    }

    private func startSearch(_ q: GifQuery) {
        cancelLoad()
        feed = .pending(q) // the previous session is dropped here and never asked again
        let gen = generation
        inFlight = true
        render()
        loadTask = Task { [weak self] in
            guard let self else { return }
            let client = await self.makeClient()
            guard gen == self.generation, !Task.isCancelled else { return }
            self.feed = .search(GifSearchSession(client: client, query: q), q)
            self.searchResults = []
            self.exhausted = false
            self.problem = nil
            self.fetchFailed = false
            self.inFlight = false
            self.rebuild(resetSelection: true)
            self.load(fresh: false)
        }
    }

    private func cancelLoad() {
        generation += 1
        loadTask?.cancel()
        loadTask = nil
        inFlight = false
    }

    /// Fetches the next page of the current feed. `fresh` restarts trending at offset 0.
    private func load(fresh: Bool) {
        // No session yet for a pending query; the abandoned one must never be asked again.
        if case .pending = feed { return }
        guard !inFlight, fresh || !exhausted else { return }
        inFlight = true
        let gen = generation
        let feed = self.feed
        let offset = fresh ? 0 : (trendingNextOffset ?? 0)
        render()
        loadTask = Task { [weak self] in
            guard let self else { return }
            let outcome: Result<[GifResult], any Error>
            var nextOffset: Int?
            do {
                switch feed {
                case .pending:
                    return
                case .search(let session, _):
                    outcome = .success(try await session.nextBatch())
                case .trending:
                    let page = try await self.makeClient().trending(offset: offset)
                    nextOffset = page.nextOffset
                    outcome = .success(page.results)
                }
            } catch {
                outcome = .failure(error)
            }
            guard gen == self.generation else { return }
            self.inFlight = false
            self.finishLoad(outcome, fresh: fresh, nextTrendingOffset: nextOffset)
        }
    }

    private func finishLoad(_ outcome: Result<[GifResult], any Error>, fresh: Bool, nextTrendingOffset: Int?) {
        switch outcome {
        case .failure(let error):
            guard let p = Self.problem(for: error) else {
                render() // cancelled: say nothing
                return
            }
            Self.log.notice("gif fetch failed: \(String(describing: error), privacy: .public)")
            activateWhenLoaded = false
            problem = p
            fetchFailed = true
            exhausted = true // no retry loop: a new query or reopening the picker tries again
            render()
        case .success(let batch):
            problem = nil
            fetchFailed = false
            switch feed {
            case .pending:
                return
            case .search:
                exhausted = batch.isEmpty
                searchResults += batch
                append(batch)
                if activateWhenLoaded {
                    activateWhenLoaded = false
                    if let first = firstIndex {
                        render()
                        activate(first)
                        return
                    }
                }
            case .trending:
                trendingNextOffset = nextTrendingOffset
                exhausted = nextTrendingOffset == nil || batch.isEmpty
                if fresh {
                    trending = batch
                    trendingFetchedAt = Date()
                    rebuild(resetSelection: selection == nil || !isOnScreen)
                } else {
                    trending += batch
                    append(batch)
                }
            }
            render()
            loadMoreIfNeeded(force: false)
        }
    }

    /// Content height for the current sections, computed now rather than read from the layout,
    /// which only recomputes on its next pass (reading it right after an append would see the old,
    /// shorter content and fire an extra request).
    private var currentContentHeight: CGFloat {
        MasonryGeometry(width: collectionView.bounds.width, sections: masonrySections()).contentHeight
    }

    private static func problem(for error: any Error) -> Problem? {
        if error is CancellationError { return nil }
        if let e = error as? URLError {
            return e.code == .cancelled ? nil : Problem(text: "You're offline.")
        }
        switch error as? GiphyError {
        case .missingKey: return Problem(text: "Add your free GIPHY key in Settings", opensSettings: true)
        case .invalidKey: return Problem(text: "Your GIPHY key was rejected. Check it in Settings.")
        case .rateLimited: return Problem(text: "GIPHY's hourly limit was reached. Try again later.")
        case .offline: return Problem(text: "You're offline.")
        case .server(let code): return Problem(text: "GIPHY isn't responding (\(code)). Try again later.")
        case nil: return Problem(text: "Something went wrong loading GIFs.")
        }
    }

    private func loadMoreIfNeeded(force: Bool) {
        guard !inFlight, !exhausted, !fetchFailed, isOnScreen || force else { return }
        // Called from scroll notifications, which can arrive mid-layout: no forced layout here.
        let visibleBottom = scrollView.contentView.bounds.maxY
        if force || visibleBottom > currentContentHeight - Self.prefetchDistance {
            load(fresh: false)
        }
    }

    @objc private func didScroll() { loadMoreIfNeeded(force: false) }

    // MARK: Key and client

    @discardableResult
    private func loadKey() -> Task<String?, Never> {
        let task = Task.detached(priority: .userInitiated) { GiphyKeyStore.standard.load() }
        keyLoad = task
        return task
    }

    private func makeClient() async -> GiphyClient {
        let rating = UserDefaults.standard.string(forKey: Self.ratingKey) ?? "pg-13"
        #if DEBUG
        if let fixture = FixtureHTTP.fromEnvironment() {
            return GiphyClient(apiKey: "fixture", rating: rating, http: fixture)
        }
        #endif
        let key = await (keyLoad ?? loadKey()).value
        return GiphyClient(apiKey: key, rating: rating, http: apiSession)
    }

    // MARK: Content

    private func rebuild(resetSelection: Bool) {
        switch feed {
        case .trending:
            sections = []
            if !recents.items.isEmpty { sections.append(Section(title: "Recently used", items: recents.items)) }
            sections.append(Section(title: "Trending", items: trending))
        case .pending, .search:
            sections = [Section(title: nil, items: searchResults)]
        }
        layoutViews()
        collectionView.reloadData()
        if resetSelection || !isValid(selection) {
            selection = firstIndex
            scroll(toY: 0)
        }
        render()
    }

    /// Appends to the last section without reloading the cells already shown (keeps them animating).
    private func append(_ batch: [GifResult]) {
        guard !batch.isEmpty, let last = sections.indices.last else { return }
        let start = sections[last].items.count
        sections[last].items += batch
        if start == 0 {
            collectionView.reloadData()
            if selection == nil { selection = firstIndex }
        } else {
            collectionView.insertItems(at: Set((start..<start + batch.count).map { IndexPath(item: $0, section: last) }))
        }
    }

    private var isEmpty: Bool { sections.allSatisfy { $0.items.isEmpty } }

    /// Updates spinner, message and footer from the current state.
    private func render() {
        let empty = isEmpty
        var message: String?
        if empty {
            if let problem {
                message = problem.text
            } else if !inFlight, exhausted, case .search(_, let q) = feed {
                message = q.requiredWords.isEmpty
                    ? "No GIFs found"
                    : "No GIFs match all of \"\(q.requiredWords.joined(separator: " "))\""
            }
        }
        var pending = false
        if case .pending = feed { pending = true }
        let loading = empty && problem == nil && (inFlight || pending)
        if loading { spinner.startAnimation(nil) } else { spinner.stopAnimation(nil) }
        messageLabel.stringValue = message ?? ""
        messageLabel.isHidden = message == nil
        settingsButton.isHidden = !(empty && problem?.opensSettings == true)
        centre.isHidden = !loading && message == nil

        let footerProblem = empty ? nil : problem
        footerStatus.isHidden = footerProblem == nil
        footerStatus.isEnabled = footerProblem?.opensSettings == true
        footerStatus.attributedTitle = NSAttributedString(string: footerProblem?.text ?? "", attributes: [
            .font: NSFont.systemFont(ofSize: 11),
            .foregroundColor: footerProblem?.opensSettings == true ? NSColor.linkColor : NSColor.secondaryLabelColor,
        ])
    }

    private func result(at path: IndexPath) -> GifResult? {
        guard sections.indices.contains(path.section),
              sections[path.section].items.indices.contains(path.item) else { return nil }
        return sections[path.section].items[path.item]
    }

    private func isValid(_ path: IndexPath?) -> Bool { path.map { result(at: $0) != nil } ?? false }

    private var firstIndex: IndexPath? {
        sections.indices.first { !sections[$0].items.isEmpty }.map { IndexPath(item: 0, section: $0) }
    }

    // MARK: Selection and scrolling

    private func resetSelectionAndScroll() {
        mouseAtReset = NSEvent.mouseLocation
        hoverArmed = false
        setSelection(firstIndex, scroll: false)
        scroll(toY: 0)
    }

    private func setSelection(_ new: IndexPath?, scroll: Bool) {
        if let old = selection, old != new { cell(at: old)?.isCurrent = false }
        selection = new
        guard let new else { return }
        cell(at: new)?.isDimmed = !contentFocused
        cell(at: new)?.isCurrent = true
        if scroll, let frame = layout.layoutAttributesForItem(at: new)?.frame {
            collectionView.scrollToVisible(frame.insetBy(dx: 0, dy: -6))
        }
    }

    private func cell(at path: IndexPath) -> GifCell? { collectionView.item(at: path) as? GifCell }

    private func scroll(toY y: CGFloat) {
        let clip = scrollView.contentView
        let target = clip.constrainBoundsRect(NSRect(origin: NSPoint(x: 0, y: y), size: clip.bounds.size))
        clip.scroll(to: target.origin)
        scrollView.reflectScrolledClipView(clip)
    }

    // MARK: Mouse and chips

    private func indexPath(at point: NSPoint) -> IndexPath? { collectionView.indexPathForItem(at: point) }

    private func hover(at point: NSPoint?) {
        guard let point, let path = indexPath(at: point) else { return }
        if !hoverArmed {
            guard NSEvent.mouseLocation != mouseAtReset else { return }
            hoverArmed = true
        }
        if path != selection { setSelection(path, scroll: false) }
    }

    private func release(at point: NSPoint) {
        defer { pressed = nil }
        guard let path = indexPath(at: point), path == pressed else { return }
        setSelection(path, scroll: false)
        activate(path)
    }

    @objc private func chipClicked(_ sender: NSButton) {
        if sender.title == Self.chips[0] {
            if query.isEmpty {
                // Already showing trending: jump to it.
                guard let s = sections.firstIndex(where: { $0.title == "Trending" }),
                      let header = layout.layoutAttributesForSupplementaryView(
                        ofKind: NSCollectionView.elementKindSectionHeader, at: IndexPath(item: 0, section: s))
                else { return }
                scroll(toY: header.frame.minY)
                if !sections[s].items.isEmpty { setSelection(IndexPath(item: 0, section: s), scroll: false) }
            } else {
                onRequestQuery?("")
            }
        } else {
            onRequestQuery?(sender.title)
        }
    }

    @objc private func openSettings() { onOpenSettings?() }

    // MARK: Picking

    private func activate(_ path: IndexPath) {
        guard pick == nil, let gif = result(at: path) else { return }
        if !fetchFailed, problem != nil {
            problem = nil // an earlier download error
            render()
        }
        let session = downloadSession
        let task = Task { [weak self] in
            let outcome: Result<(Data, URL), any Error>
            do {
                outcome = .success(try await GifDownload.fetch(gif, session: session))
            } catch {
                outcome = .failure(error)
            }
            guard let self, self.pick?.id == gif.id, !Task.isCancelled else { return }
            self.endPick()
            switch outcome {
            case .success(let (data, fileURL)):
                // Esc or a click outside closed the panel meanwhile: insert nothing.
                guard self.view.window?.isVisible == true else { return }
                self.recents.record(gif)
                self.recentsChanged = true
                self.commit(.gif(data: data, fileURL: fileURL))
            case .failure(let error):
                Self.log.notice("gif download failed: \(String(describing: error), privacy: .public)")
                if let e = error as? URLError, e.code == .cancelled { return }
                self.problem = Self.downloadProblem(for: error)
                self.render()
            }
        }
        pick = (gif.id, task)
        setBusy(gif.id, true)
    }

    private static func downloadProblem(for error: any Error) -> Problem {
        let offline: [URLError.Code] = [
            .notConnectedToInternet, .networkConnectionLost, .cannotConnectToHost, .cannotFindHost,
            .timedOut, .dnsLookupFailed, .dataNotAllowed,
        ]
        if let e = error as? URLError, offline.contains(e.code) { return Problem(text: "You're offline.") }
        if case GifDownload.Failure.tooLarge? = error as? GifDownload.Failure {
            return Problem(text: "That GIF is too large to paste.")
        }
        return Problem(text: "Couldn't download that GIF. Try another one.")
    }

    private func cancelPick() {
        guard let pick else { return }
        pick.task.cancel()
        endPick()
    }

    private func endPick() {
        guard let id = pick?.id else { return }
        pick = nil
        setBusy(id, false)
    }

    private func setBusy(_ id: String, _ busy: Bool) {
        for path in collectionView.indexPathsForVisibleItems() where result(at: path)?.id == id {
            cell(at: path)?.isBusy = busy
        }
    }

    // MARK: Visibility (only visible cells animate)

    private var isOnScreen: Bool { view.window?.isVisible == true && !view.isHiddenOrHasHiddenAncestor }

    private func updateAnimations() {
        let on = isOnScreen
        for item in collectionView.visibleItems() { (item as? GifCell)?.animates = on }
    }

    private func visibilityChanged() {
        if !isOnScreen {
            cancelPick()
            activateWhenLoaded = false
        }
        updateAnimations()
    }

    @objc private func windowStateChanged(_ note: Notification) {
        guard (note.object as? NSWindow) === view.window else { return }
        updateAnimations()
    }

    @objc private func windowResignedKey(_ note: Notification) {
        guard (note.object as? NSWindow) === view.window else { return }
        cancelPick() // Esc or a click outside closes the panel: abandon the download
        activateWhenLoaded = false
        updateAnimations()
    }

    // MARK: MasonryLayoutDataSource

    func masonrySections() -> [MasonryGeometry.Section] {
        sections.map { MasonryGeometry.Section(hasHeader: $0.title != nil, sizes: $0.items.map(\.previewSize)) }
    }

    // MARK: NSCollectionViewDataSource / Delegate

    func numberOfSections(in collectionView: NSCollectionView) -> Int { sections.count }

    func collectionView(_ collectionView: NSCollectionView, numberOfItemsInSection section: Int) -> Int {
        sections[section].items.count
    }

    func collectionView(
        _ collectionView: NSCollectionView, itemForRepresentedObjectAt indexPath: IndexPath
    ) -> NSCollectionViewItem {
        let item = collectionView.makeItem(withIdentifier: GifCell.identifier, for: indexPath)
        if let cell = item as? GifCell, let gif = result(at: indexPath) {
            cell.show(gif.previewURL, loader: images)
            cell.isCurrent = indexPath == selection
            cell.isDimmed = !contentFocused
            cell.isBusy = pick?.id == gif.id
            cell.view.setAccessibilityLabel(gif.title)
        }
        return item
    }

    func collectionView(
        _ collectionView: NSCollectionView,
        viewForSupplementaryElementOfKind kind: NSCollectionView.SupplementaryElementKind,
        at indexPath: IndexPath
    ) -> NSView {
        let view = collectionView.makeSupplementaryView(ofKind: kind, withIdentifier: GifHeader.identifier, for: indexPath)
        (view as? GifHeader)?.title = sections.indices.contains(indexPath.section)
            ? sections[indexPath.section].title ?? "" : ""
        return view
    }

    func collectionView(
        _ collectionView: NSCollectionView, willDisplay item: NSCollectionViewItem,
        forRepresentedObjectAt indexPath: IndexPath
    ) {
        (item as? GifCell)?.animates = isOnScreen
    }

    func collectionView(
        _ collectionView: NSCollectionView, didEndDisplaying item: NSCollectionViewItem,
        forRepresentedObjectAt indexPath: IndexPath
    ) {
        (item as? GifCell)?.animates = false
    }
}

// MARK: - Download

/// Downloads a picked GIF's full rendition and writes it to `~/Library/Caches/EmojiPicker/gifs/<id>.gif`.
enum GifDownload {
    enum Failure: Error { case badResponse, notAGif, tooLarge }

    /// Larger originals fall back to the downsized rendition; chat apps reject huge files anyway.
    static let maxBytes = 15 * 1024 * 1024

    /// Files older than this are removed when a new GIF is written.
    private static let maxAge: TimeInterval = 7 * 24 * 3600

    static var directory: URL {
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("EmojiPicker/gifs", isDirectory: true)
    }

    /// Tries the original, then the downsized rendition, skipping any over `maxBytes`.
    @concurrent static func fetch(_ gif: GifResult, session: URLSession) async throws -> (Data, URL) {
        var found: Data?
        for url in gif.pasteURLs {
            if let data = try await fetchCapped(url, session: session) {
                found = data
                break
            }
        }
        guard let data = found else { throw Failure.tooLarge }
        guard data.starts(with: Data("GIF8".utf8)) else { throw Failure.notAGif }
        try Task.checkCancellation()
        let id = gif.id
        let url = try await Task.detached(priority: .userInitiated) { try write(data, id: id) }.value
        return (data, url)
    }

    /// The body, or `nil` when the Content-Length or the bytes received exceed `maxBytes`.
    @concurrent private static func fetchCapped(_ url: URL, session: URLSession) async throws -> Data? {
        let (bytes, response) = try await session.bytes(from: url)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            bytes.task.cancel()
            throw Failure.badResponse
        }
        if response.expectedContentLength > Int64(maxBytes) {
            bytes.task.cancel()
            return nil
        }
        var data = Data()
        if response.expectedContentLength > 0 { data.reserveCapacity(Int(response.expectedContentLength)) }
        for try await byte in bytes {
            data.append(byte)
            if data.count > maxBytes {
                bytes.task.cancel()
                return nil
            }
        }
        return data
    }

    private static func write(_ data: Data, id: String) throws -> URL {
        let fm = FileManager.default
        let dir = directory
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        prune(dir)
        // GIPHY ids are alphanumeric; never let one escape the cache directory.
        var name = String(id.unicodeScalars.filter { CharacterSet.alphanumerics.contains($0) }.map(Character.init))
        if name.isEmpty { name = UUID().uuidString }
        let url = dir.appendingPathComponent(name).appendingPathExtension("gif")
        try data.write(to: url, options: .atomic)
        return url
    }

    private static func prune(_ dir: URL) {
        let fm = FileManager.default
        let cutoff = Date().addingTimeInterval(-maxAge)
        let files = (try? fm.contentsOfDirectory(
            at: dir, includingPropertiesForKeys: [.contentModificationDateKey])) ?? []
        for file in files {
            let modified = try? file.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate
            if let modified, modified < cutoff { try? fm.removeItem(at: file) }
        }
    }
}

// MARK: - Preview images

/// Loads preview GIFs through a URL cache (20 MB memory, 50 MB disk) and keeps decoded images in
/// memory. Decoding happens off the main thread.
@MainActor
final class GifImageLoader {
    private let session: URLSession
    private let decoded = NSCache<NSURL, NSImage>()

    init() {
        let directory = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("EmojiPicker/http", isDirectory: true)
        let config = URLSessionConfiguration.default
        config.urlCache = URLCache(memoryCapacity: 20 << 20, diskCapacity: 50 << 20, directory: directory)
        // Preview renditions never change at a given URL: use the cache without revalidating.
        config.requestCachePolicy = .returnCacheDataElseLoad
        session = URLSession(configuration: config)
        decoded.totalCostLimit = 40 << 20
    }

    func cached(_ url: URL) -> NSImage? { decoded.object(forKey: url as NSURL) }

    func image(for url: URL) async -> NSImage? {
        if let image = cached(url) { return image }
        guard let (data, response) = try? await session.data(from: url),
              let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode)
        else { return nil }
        guard let image = await Task.detached(priority: .userInitiated, operation: { Self.decode(data) }).value
        else { return nil }
        decoded.setObject(image, forKey: url as NSURL, cost: data.count)
        return image
    }

    private nonisolated static func decode(_ data: Data) -> NSImage? {
        guard let rep = NSBitmapImageRep(data: data) else { return nil }
        _ = rep.cgImage // decode the first frame here rather than on the main thread at draw time
        let image = NSImage(size: rep.size)
        image.addRepresentation(rep)
        return image
    }
}

// MARK: - Pieces

/// Root view that reports resizes and hide/unhide (tab switches) to the tab.
private final class GifRootView: NSView {
    var onLayout: (() -> Void)?
    var onVisibilityChange: (() -> Void)?

    override func resizeSubviews(withOldSize oldSize: NSSize) {
        super.resizeSubviews(withOldSize: oldSize)
        onLayout?()
    }

    override func viewDidHide() {
        super.viewDidHide()
        onVisibilityChange?()
    }

    override func viewDidUnhide() {
        super.viewDidUnhide()
        onVisibilityChange?()
    }
}

final class GifCell: NSCollectionViewItem {
    static let identifier = NSUserInterfaceItemIdentifier("GifCell")

    private let cellView = GifCellView()
    private let preview = NSImageView()
    private let spinner = NSProgressIndicator()
    private var url: URL?
    private var loadTask: Task<Void, Never>?

    var isCurrent = false { didSet { cellView.isCurrent = isCurrent } }
    var isDimmed = false { didSet { cellView.isDimmed = isDimmed } }
    var isBusy = false {
        didSet {
            spinner.isHidden = !isBusy
            if isBusy { spinner.startAnimation(nil) } else { spinner.stopAnimation(nil) }
        }
    }
    var animates: Bool {
        get { preview.animates }
        set { if preview.animates != newValue { preview.animates = newValue } }
    }

    override func loadView() {
        preview.imageScaling = .scaleAxesIndependently
        preview.animates = false
        preview.frame = cellView.bounds
        preview.autoresizingMask = [.width, .height]
        cellView.addSubview(preview)
        spinner.style = .spinning
        spinner.controlSize = .small
        spinner.isHidden = true
        // Centred with constraints set up once. Setting its frame from viewDidLayout re-marked the
        // panel as needing layout on every pass, and AppKit aborted the app after too many passes.
        spinner.translatesAutoresizingMaskIntoConstraints = false
        cellView.addSubview(spinner)
        NSLayoutConstraint.activate([
            spinner.centerXAnchor.constraint(equalTo: cellView.centerXAnchor),
            spinner.centerYAnchor.constraint(equalTo: cellView.centerYAnchor),
        ])
        view = cellView
    }

    func show(_ previewURL: URL, loader: GifImageLoader) {
        guard previewURL != url else { return }
        loadTask?.cancel()
        url = previewURL
        if let image = loader.cached(previewURL) {
            preview.image = image
            loadTask = nil
            return
        }
        preview.image = nil
        loadTask = Task { [weak self] in
            let image = await loader.image(for: previewURL)
            guard let self, self.url == previewURL, !Task.isCancelled else { return }
            self.preview.image = image
        }
    }

    override func prepareForReuse() {
        super.prepareForReuse()
        loadTask?.cancel()
        loadTask = nil
        url = nil
        preview.image = nil
        animates = false
        isBusy = false
        isCurrent = false
    }
}

private final class GifCellView: NSView {
    var isCurrent = false { didSet { if isCurrent != oldValue { needsDisplay = true } } }
    /// Keyboard focus is in the search field: a thinner, fainter border.
    var isDimmed = false { didSet { if isDimmed != oldValue { needsDisplay = true } } }

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override var wantsUpdateLayer: Bool { true }

    override func updateLayer() {
        guard let layer else { return }
        layer.cornerRadius = 6
        layer.masksToBounds = true
        layer.backgroundColor = NSColor.quaternaryLabelColor.cgColor
        // The border is composited above the image.
        layer.borderWidth = isCurrent ? (isDimmed ? 2 : 3) : 0
        layer.borderColor = NSColor.controlAccentColor.withAlphaComponent(isDimmed ? 0.5 : 1).cgColor
    }
}

private final class GifHeader: NSView, NSCollectionViewElement {
    static let identifier = NSUserInterfaceItemIdentifier("GifHeader")
    var title = "" { didSet { needsDisplay = true } }

    override func draw(_ dirtyRect: NSRect) {
        let string = NSAttributedString(string: title, attributes: [
            .font: NSFont.systemFont(ofSize: 11, weight: .medium),
            .foregroundColor: NSColor.secondaryLabelColor,
        ])
        let size = string.size()
        string.draw(at: NSPoint(x: GridView.horizontalInset + 2, y: (bounds.height - size.height) / 2))
    }
}

#if DEBUG
/// Debug-only smoke-test hook: with `EMOJIPICKER_GIPHY_FIXTURE=/path/page.json` set, every GIPHY
/// API call returns that file (status from `EMOJIPICKER_GIPHY_FIXTURE_STATUS`, default 200) and no
/// key is needed. Preview and download URLs still go to the network.
struct FixtureHTTP: HTTPFetching {
    let data: Data
    let status: Int

    static func fromEnvironment() -> FixtureHTTP? {
        let env = ProcessInfo.processInfo.environment
        guard let path = env["EMOJIPICKER_GIPHY_FIXTURE"] else { return nil }
        return FixtureHTTP(
            data: FileManager.default.contents(atPath: path) ?? Data(),
            status: env["EMOJIPICKER_GIPHY_FIXTURE_STATUS"].flatMap(Int.init) ?? 200)
    }

    func get(_ url: URL) async throws -> (Data, HTTPURLResponse) {
        NSLog("gif fixture request %@", url.path)
        try await Task.sleep(for: .milliseconds(200))
        return (data, HTTPURLResponse(url: url, statusCode: status, httpVersion: nil, headerFields: nil)!)
    }
}
#endif
