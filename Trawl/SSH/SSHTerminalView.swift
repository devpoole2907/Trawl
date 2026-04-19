import SwiftUI
import SwiftTerm

// MARK: - Bridge

final class SSHTerminalBridge: @unchecked Sendable {
    #if os(iOS)
    var terminalView: ScrollableTerminalView?
    #else
    weak var terminalView: TerminalView?
    #endif

    func receive(bytes: [UInt8]) {
        guard let tv = terminalView else { return }
        assert(Thread.isMainThread)
        tv.feed(byteArray: bytes[...])
    }

    var sendToSSH: ((Data) -> Void)?
    var onResize: ((Int, Int) -> Void)?
    var onTitleChange: ((String) -> Void)?

    #if os(iOS)
    var onKeyboardVisibilityChange: ((Bool) -> Void)?

    func hideKeyboard() {
        guard let terminalView, terminalView.window != nil, terminalView.isFirstResponder else { return }
        DispatchQueue.main.async {
            guard terminalView.window != nil, terminalView.isFirstResponder else { return }
            _ = terminalView.resignFirstResponder()
        }
    }

    func scrollToBottom() {
        terminalView?.scrollToBottom()
    }
    #endif
}

// MARK: - iOS

#if os(iOS)

// MARK: Scrollable TerminalView subclass

/// Subclass that preserves the user's scroll position instead of snapping to
/// the bottom every time new terminal output arrives.
final class ScrollableTerminalView: TerminalView {

    /// True when the view should follow new output (user is at the bottom).
    private(set) var isPinnedToBottom = true
    private var isBufferUpdate = false
    var onKeyboardFocusChange: ((Bool) -> Void)?

    private var bottomOffsetY: CGFloat {
        let visibleHeight = bounds.height - adjustedContentInset.top - adjustedContentInset.bottom
        return max(-adjustedContentInset.top, contentSize.height - visibleHeight)
    }

    // Override contentOffset to track whether the user has scrolled up.
    override var contentOffset: CGPoint {
        get { super.contentOffset }
        set {
            if !isBufferUpdate {
                isPinnedToBottom = newValue.y >= bottomOffsetY - 4
            }
            super.contentOffset = newValue
        }
    }

    override func layoutSubviews() {
        super.layoutSubviews()

        guard isPinnedToBottom, !isDragging, !isTracking, !isDecelerating else { return }

        // Keep the latest prompt visible when keyboard or safe-area insets change.
        let bottomY = bottomOffsetY
        if abs(contentOffset.y - bottomY) > 1 {
            isBufferUpdate = true
            super.contentOffset = CGPoint(x: contentOffset.x, y: bottomY)
            isBufferUpdate = false
        }
    }

    override func didMoveToWindow() {
        super.didMoveToWindow()

        if window == nil {
            isPinnedToBottom = true
        }
    }

    override func becomeFirstResponder() -> Bool {
        let becameFirstResponder = super.becomeFirstResponder()
        if becameFirstResponder {
            DispatchQueue.main.async { [weak self] in
                self?.onKeyboardFocusChange?(true)
            }
        }
        return becameFirstResponder
    }

    override func resignFirstResponder() -> Bool {
        let resignedFirstResponder = super.resignFirstResponder()
        if resignedFirstResponder {
            DispatchQueue.main.async { [weak self] in
                self?.onKeyboardFocusChange?(false)
            }
        }
        return resignedFirstResponder
    }

    // Called by SwiftTerm whenever new lines arrive in the buffer.
    override func bufferActivated(source: Terminal) {
        if isPinnedToBottom {
            // Standard behaviour: snap to the latest output.
            isBufferUpdate = true
            super.bufferActivated(source: source)
            isBufferUpdate = false
        } else {
            // User has scrolled up — grow contentSize but keep their position.
            let savedY = contentOffset.y
            isBufferUpdate = true
            super.bufferActivated(source: source)
            isBufferUpdate = false
            super.contentOffset = CGPoint(x: 0, y: savedY)
        }
    }

    /// Scroll to the latest output and re-enable auto-follow.
    func scrollToBottom() {
        isPinnedToBottom = true
        setContentOffset(CGPoint(x: contentOffset.x, y: bottomOffsetY), animated: true)
    }
}

// MARK: UIViewRepresentable

final class TerminalHostingView: UIView {
    func embed(_ terminalView: UIView) {
        if terminalView.superview !== self {
            terminalView.removeFromSuperview()
            addSubview(terminalView)
            terminalView.translatesAutoresizingMaskIntoConstraints = false
            NSLayoutConstraint.activate([
                terminalView.leadingAnchor.constraint(equalTo: leadingAnchor),
                terminalView.trailingAnchor.constraint(equalTo: trailingAnchor),
                terminalView.topAnchor.constraint(equalTo: topAnchor),
                terminalView.bottomAnchor.constraint(equalTo: bottomAnchor)
            ])
        }
    }
}

struct SwiftTermView: UIViewRepresentable {
    let bridge: SSHTerminalBridge
    let wantsKeyboard: Bool
    let colorScheme: ColorScheme

    func makeUIView(context: Context) -> TerminalHostingView {
        let hostingView = TerminalHostingView()
        let terminalView = bridge.terminalView ?? ScrollableTerminalView(frame: .zero)
        terminalView.terminalDelegate = context.coordinator
        terminalView.bounces = false
        terminalView.alwaysBounceVertical = false
        terminalView.inputAccessoryView = SSHKeyboardBar(bridge: bridge)
        terminalView.onKeyboardFocusChange = { [weak bridge] isFocused in
            bridge?.onKeyboardVisibilityChange?(isFocused)
        }
        applyAppearance(to: terminalView)
        bridge.terminalView = terminalView
        hostingView.embed(terminalView)
        return hostingView
    }

    func updateUIView(_ uiView: TerminalHostingView, context: Context) {
        guard let terminalView = bridge.terminalView else { return }
        uiView.embed(terminalView)
        applyAppearance(to: terminalView)

        if wantsKeyboard {
            DispatchQueue.main.async {
                guard terminalView.window != nil, !terminalView.isFirstResponder else { return }
                _ = terminalView.becomeFirstResponder()
            }
        } else if terminalView.isFirstResponder {
            DispatchQueue.main.async {
                guard terminalView.window != nil, terminalView.isFirstResponder else { return }
                _ = terminalView.resignFirstResponder()
            }
        }
    }

    static func dismantleUIView(_ uiView: TerminalHostingView, coordinator: Coordinator) {
        coordinator.bridge.terminalView?.onKeyboardFocusChange = nil
        coordinator.bridge.terminalView?.terminalDelegate = nil
    }

    func makeCoordinator() -> Coordinator { Coordinator(bridge: bridge) }

    private func applyAppearance(to terminalView: ScrollableTerminalView) {
        let backgroundColor = UIColor.clear
        let foregroundColor: UIColor = colorScheme == .dark ? .white : .black

        terminalView.overrideUserInterfaceStyle = colorScheme == .dark ? .dark : .light
        terminalView.keyboardAppearance = colorScheme == .dark ? .dark : .light
        terminalView.backgroundColor = backgroundColor
        terminalView.layer.backgroundColor = UIColor.clear.cgColor
        terminalView.nativeBackgroundColor = backgroundColor
        terminalView.nativeForegroundColor = foregroundColor
        terminalView.caretColor = colorScheme == .dark ? .systemGreen : UIColor(red: 0.10, green: 0.48, blue: 0.24, alpha: 1)
    }

    final class Coordinator: TerminalViewDelegate {
        let bridge: SSHTerminalBridge
        init(bridge: SSHTerminalBridge) { self.bridge = bridge }

        func send(source: TerminalView, data: ArraySlice<UInt8>) {
            bridge.sendToSSH?(Data(data))
        }
        func sizeChanged(source: TerminalView, newCols: Int, newRows: Int) {
            bridge.onResize?(newCols, newRows)
        }
        func setTerminalTitle(source: TerminalView, title: String) {
            DispatchQueue.main.async { self.bridge.onTitleChange?(title) }
        }
        func scrolled(source: TerminalView, position: Double) {}
        func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) {}
        func requestOpenLink(source: TerminalView, link: String, params: [String: String]) {}
        func rangeChanged(source: TerminalView, startY: Int, endY: Int) {}
        func bell(source: TerminalView) {
            UIImpactFeedbackGenerator(style: .light).impactOccurred()
        }
        func clipboardCopy(source: TerminalView, content: Data) {
            UIPasteboard.general.string = String(data: content, encoding: .utf8)
        }
    }
}

// MARK: - Keyboard toolbar

private final class SSHKeyboardBar: UIInputView {
    private static let barHeight: CGFloat  = 70
    private static let keyHeight: CGFloat  = 36
    private static let keyFont    = UIFont.monospacedSystemFont(ofSize: 13, weight: .medium)
    private static let barColor   = UIColor.clear
    private static let chromeColor = UIColor { traits in
        traits.userInterfaceStyle == .dark
            ? UIColor(red: 0.10, green: 0.10, blue: 0.11, alpha: 0.94)
            : UIColor(red: 0.94, green: 0.95, blue: 0.97, alpha: 0.96)
    }
    private static let keyColor = UIColor { traits in
        traits.userInterfaceStyle == .dark
            ? UIColor(white: 0.24, alpha: 1)
            : UIColor(white: 1.0, alpha: 0.98)
    }
    private static let pressedKeyColor = UIColor { traits in
        traits.userInterfaceStyle == .dark
            ? UIColor(white: 0.36, alpha: 1)
            : UIColor(white: 0.88, alpha: 1)
    }
    private static let dividerColor = UIColor { traits in
        traits.userInterfaceStyle == .dark
            ? UIColor(white: 0.28, alpha: 1)
            : UIColor(white: 0.78, alpha: 1)
    }
    private static let keyForegroundColor = UIColor { traits in
        traits.userInterfaceStyle == .dark ? .white : .label
    }
    private static let dismissColor = UIColor { traits in
        UIColor.white
    }
    private static let dismissBackgroundColor = UIColor { traits in
        traits.userInterfaceStyle == .dark
            ? UIColor(white: 1.0, alpha: 0.08)
            : UIColor(white: 0.32, alpha: 0.78)
    }
    private static let horizontalInset: CGFloat = 10

    private static let keys: [(String, [UInt8])] = [
        ("Esc",  [0x1B]),
        ("Tab",  [0x09]),
        ("↑",    [0x1B, 0x5B, 0x41]),
        ("↓",    [0x1B, 0x5B, 0x42]),
        ("←",    [0x1B, 0x5B, 0x44]),
        ("→",    [0x1B, 0x5B, 0x43]),
        ("^C",   [0x03]),
        ("^D",   [0x04]),
        ("^W",   [0x17]),
        ("^Z",   [0x1A]),
        ("^A",   [0x01]),
        ("^E",   [0x05]),
        ("^L",   [0x0C]),
        ("|",    [0x7C]),
        ("/",    [0x2F]),
        ("\\",   [0x5C]),
        ("~",    [0x7E]),
        ("-",    [0x2D]),
        ("_",    [0x5F]),
        ("[",    [0x5B]),
        ("]",    [0x5D]),
        ("{",    [0x7B]),
        ("}",    [0x7D]),
    ]

    private unowned let bridge: SSHTerminalBridge

    init(bridge: SSHTerminalBridge) {
        self.bridge = bridge
        super.init(
            frame: CGRect(x: 0, y: 0, width: 0, height: SSHKeyboardBar.barHeight),
            inputViewStyle: .keyboard
        )
        autoresizingMask = .flexibleWidth
        allowsSelfSizing = true
        backgroundColor = SSHKeyboardBar.barColor
        setupContent()
    }
    required init?(coder: NSCoder) { fatalError() }

    // MARK: Layout

    private func setupContent() {
        let chrome = UIVisualEffectView(effect: UIBlurEffect(style: .systemChromeMaterialDark))
        chrome.backgroundColor = SSHKeyboardBar.chromeColor
        chrome.layer.cornerRadius = 24
        chrome.layer.cornerCurve = .continuous
        chrome.clipsToBounds = true
        chrome.translatesAutoresizingMaskIntoConstraints = false
        addSubview(chrome)

        // Dismiss button — fixed on the right
        let dismiss = makeDismissButton()
        dismiss.translatesAutoresizingMaskIntoConstraints = false
        chrome.contentView.addSubview(dismiss)

        // Vertical divider between scroll area and dismiss button
        let divider = UIView()
        divider.backgroundColor = SSHKeyboardBar.dividerColor
        divider.translatesAutoresizingMaskIntoConstraints = false
        chrome.contentView.addSubview(divider)

        // Scrollable key area on the left
        let scroll = UIScrollView()
        scroll.showsHorizontalScrollIndicator = false
        scroll.showsVerticalScrollIndicator = false
        scroll.alwaysBounceHorizontal = true
        scroll.alwaysBounceVertical = false
        scroll.bounces = true
        scroll.isDirectionalLockEnabled = true
        scroll.contentInsetAdjustmentBehavior = .never
        scroll.contentInset = UIEdgeInsets(top: 0, left: 12, bottom: 0, right: 10)
        scroll.translatesAutoresizingMaskIntoConstraints = false
        chrome.contentView.addSubview(scroll)

        let stack = UIStackView()
        stack.axis = .horizontal
        stack.spacing = 7
        stack.alignment = .center
        stack.translatesAutoresizingMaskIntoConstraints = false
        scroll.addSubview(stack)

        for (label, bytes) in SSHKeyboardBar.keys {
            stack.addArrangedSubview(makeKey(label, bytes: bytes))
        }

        NSLayoutConstraint.activate([
            chrome.leadingAnchor.constraint(equalTo: leadingAnchor, constant: SSHKeyboardBar.horizontalInset),
            chrome.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -SSHKeyboardBar.horizontalInset),
            chrome.topAnchor.constraint(equalTo: topAnchor, constant: 8),
            chrome.bottomAnchor.constraint(equalTo: safeAreaLayoutGuide.bottomAnchor, constant: -8),

            // Dismiss button
            dismiss.trailingAnchor.constraint(equalTo: chrome.contentView.trailingAnchor, constant: -8),
            dismiss.centerYAnchor.constraint(equalTo: chrome.contentView.centerYAnchor),
            dismiss.widthAnchor.constraint(equalToConstant: 38),
            dismiss.heightAnchor.constraint(equalToConstant: SSHKeyboardBar.keyHeight),

            // Divider
            divider.trailingAnchor.constraint(equalTo: dismiss.leadingAnchor, constant: -6),
            divider.centerYAnchor.constraint(equalTo: chrome.contentView.centerYAnchor),
            divider.widthAnchor.constraint(equalToConstant: 0.5),
            divider.heightAnchor.constraint(equalToConstant: 24),

            // Scroll view
            scroll.leadingAnchor.constraint(equalTo: chrome.contentView.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: divider.leadingAnchor, constant: -2),
            scroll.topAnchor.constraint(equalTo: chrome.contentView.topAnchor),
            scroll.bottomAnchor.constraint(equalTo: chrome.contentView.bottomAnchor),

            // Key stack inside scroll view
            stack.leadingAnchor.constraint(equalTo: scroll.contentLayoutGuide.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: scroll.contentLayoutGuide.trailingAnchor),
            stack.topAnchor.constraint(equalTo: scroll.contentLayoutGuide.topAnchor),
            stack.bottomAnchor.constraint(equalTo: scroll.contentLayoutGuide.bottomAnchor),
            stack.heightAnchor.constraint(equalTo: scroll.frameLayoutGuide.heightAnchor),
        ])
    }

    // MARK: Key buttons

    private func makeKey(_ label: String, bytes: [UInt8]) -> UIButton {
        var cfg = UIButton.Configuration.filled()
        cfg.title = label
        cfg.titleTextAttributesTransformer = UIConfigurationTextAttributesTransformer { a in
            var a = a; a.font = SSHKeyboardBar.keyFont; return a
        }
        cfg.baseBackgroundColor = SSHKeyboardBar.keyColor
        cfg.baseForegroundColor = SSHKeyboardBar.keyForegroundColor
        cfg.contentInsets = NSDirectionalEdgeInsets(top: 0, leading: 11, bottom: 0, trailing: 11)
        cfg.background.cornerRadius = 8

        let btn = UIButton(configuration: cfg)
        btn.heightAnchor.constraint(equalToConstant: SSHKeyboardBar.keyHeight).isActive = true
        btn.widthAnchor.constraint(greaterThanOrEqualToConstant: 34).isActive = true
        btn.configurationUpdateHandler = { b in
            var c = b.configuration!
            c.baseBackgroundColor = b.isHighlighted ? SSHKeyboardBar.pressedKeyColor : SSHKeyboardBar.keyColor
            c.baseForegroundColor = SSHKeyboardBar.keyForegroundColor
            b.configuration = c
        }
        btn.addAction(UIAction { [weak self] _ in
            self?.bridge.sendToSSH?(Data(bytes))
            UIImpactFeedbackGenerator(style: .light).impactOccurred()
        }, for: .touchUpInside)
        return btn
    }

    private func makeDismissButton() -> UIButton {
        var cfg = UIButton.Configuration.plain()
        cfg.image = UIImage(systemName: "keyboard.chevron.compact.down",
                            withConfiguration: UIImage.SymbolConfiguration(pointSize: 15, weight: .regular))
        cfg.baseForegroundColor = SSHKeyboardBar.dismissColor
        cfg.contentInsets = .zero

        let btn = UIButton(configuration: cfg)
        btn.configurationUpdateHandler = { b in
            var c = b.configuration!
            c.baseForegroundColor = b.isHighlighted ? SSHKeyboardBar.keyForegroundColor : SSHKeyboardBar.dismissColor
            b.configuration = c
        }
        btn.backgroundColor = SSHKeyboardBar.dismissBackgroundColor
        btn.layer.cornerRadius = SSHKeyboardBar.keyHeight / 2
        btn.layer.cornerCurve = .continuous
        btn.addAction(UIAction { [weak self] _ in
            self?.bridge.hideKeyboard()
            UIImpactFeedbackGenerator(style: .light).impactOccurred()
        }, for: .touchUpInside)
        return btn
    }
}

#endif

// MARK: - macOS

#if os(macOS)
struct SwiftTermView: NSViewRepresentable {
    let bridge: SSHTerminalBridge

    func makeNSView(context: Context) -> TerminalView {
        let tv = TerminalView(frame: .zero)
        tv.terminalDelegate = context.coordinator
        bridge.terminalView = tv
        DispatchQueue.main.async { tv.window?.makeFirstResponder(tv) }
        return tv
    }

    func updateNSView(_ nsView: TerminalView, context: Context) {}

    func makeCoordinator() -> Coordinator { Coordinator(bridge: bridge) }

    final class Coordinator: TerminalViewDelegate {
        private let bridge: SSHTerminalBridge
        init(bridge: SSHTerminalBridge) { self.bridge = bridge }

        func send(source: TerminalView, data: ArraySlice<UInt8>) {
            bridge.sendToSSH?(Data(data))
        }
        func sizeChanged(source: TerminalView, newCols: Int, newRows: Int) {
            bridge.onResize?(newCols, newRows)
        }
        func setTerminalTitle(source: TerminalView, title: String) {
            DispatchQueue.main.async { self.bridge.onTitleChange?(title) }
        }
        func scrolled(source: TerminalView, position: Double) {}
        func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) {}
        func requestOpenLink(source: TerminalView, link: String, params: [String: String]) {}
        func rangeChanged(source: TerminalView, startY: Int, endY: Int) {}
        func bell(source: TerminalView) {}
        func clipboardCopy(source: TerminalView, content: Data) {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(String(data: content, encoding: .utf8) ?? "", forType: .string)
        }
    }
}
#endif
