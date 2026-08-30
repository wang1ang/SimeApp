import UIKit

final class KeyboardViewController: UIInputViewController {
    private var composition = KeyboardViewController.makeComposition()
    private let sentenceScrollView = UIScrollView()
    private let sentenceBar = UIView()
    private let candidateScrollView = UIScrollView()
    private let candidateBar = UIView()
    private let candidateTap = UITapGestureRecognizer()
    private var sentenceContentWidth: CGFloat = 0
    private var candidateContentWidth: CGFloat = 0
    private let keyboardStack = UIStackView()
    private enum KeyboardPage { case letters, numbers, symbols }
    private var keyboardPage: KeyboardPage = .letters
    // The letter-page toggle key reflects the active scheme so the user knows
    // which layout tapping it returns to.
    private var schemeLabel: String {
        keyboardScheme == .microsoftShuangpin ? "双拼" : "拼音"
    }
    // Shift mirrors the system keyboard's default: a single tap uppercases
    // the next letter only (one-shot), then reverts. There is no caps lock.
    // Uppercase letters are literal English and never join the pinyin
    // composition.
    private enum ShiftState { case off, oneShot }
    private var shiftState: ShiftState = .off
    private var shifted: Bool { shiftState != .off }
    private var keyboardScheme = InputSettings.scheme
    private var keyboardNeedsRebuild = false
    private var displayedReturnKeyType: UIReturnKeyType?
    private var restoringMarkedText = false
    private var spaceCursorMode = false
    private var spaceLastTranslation: CGFloat = 0
    private var deleteInitialTimer: Timer?
    private var deleteRepeatTimer: Timer?

    private static func makeComposition(inputScheme: InputScheme = InputSettings.scheme) -> Composition {
        Composition(
            decoder: NativePinyinDecoder() ?? BuiltinPinyinDecoder(),
            inputScheme: inputScheme
        )
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        setupView()
        displayedReturnKeyType = textDocumentProxy.returnKeyType
        composition.restore(
            raw: InputSettings.pendingRaw,
            committed: InputSettings.pendingCommitted
        )
        render()
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        // The extension view may be detached while the phone is locked.
        // Repaint the in-memory composition when it is attached again.
        let scheme = InputSettings.scheme
        if keyboardScheme != scheme {
            keyboardScheme = scheme
            composition = Self.makeComposition(inputScheme: scheme)
            keyboardNeedsRebuild = true
        }
        refreshReturnKeyAppearance()
        render()
    }

    override func textDidChange(_ textInput: UITextInput?) {
        super.textDidChange(textInput)
        guard !restoringMarkedText else { return }
        syncCompositionCursor()
        if composition.isComposing {
            refreshHostContext()
        }
        refreshReturnKeyAppearance()

        // Some hosts temporarily unmark the entire composition when the user
        // places the insertion point inside it. Restore it at the detected
        // position instead of letting the raw pinyin disappear.
        guard composition.isComposing else { return }
        DispatchQueue.main.async { [weak self] in
            guard let self, self.composition.isComposing else { return }
            self.restoringMarkedText = true
            self.updateMarkedText()
            DispatchQueue.main.async { [weak self] in
                self?.restoringMarkedText = false
            }
        }
    }

    private func refreshHostContext() {
        guard var before = textDocumentProxy.documentContextBeforeInput else { return }
        // UIKit normally includes the marked preedit before the cursor. It is
        // not committed host text and must not become language-model context.
        if composition.isComposing {
            let markedPrefix = composition.markedPrefix
            if before.hasSuffix(markedPrefix) {
                before.removeLast(markedPrefix.count)
            }
        }
        // UITextDocumentProxy already bounds this context; retain an explicit
        // recent window as a safeguard for hosts that return more text.
        composition.updateHostContext(from: String(before.suffix(128)))
    }

    private func refreshReturnKeyAppearance() {
        let type = textDocumentProxy.returnKeyType
        guard displayedReturnKeyType != type else { return }
        displayedReturnKeyType = type
        keyboardNeedsRebuild = true
    }

    private func syncCompositionCursor() {
        guard composition.isComposing else { return }
        // Hosts are allowed to return nil for the context after the insertion
        // point (notably at the end of a note).  The previous all-or-nothing
        // check then missed a tap in marked pinyin and the subsequent
        // setMarkedText replaced it at the wrong position.
        let before = textDocumentProxy.documentContextBeforeInput
        let after = textDocumentProxy.documentContextAfterInput
        guard before != nil || after != nil else { return }

        let raw = composition.raw
        for offset in 0...raw.count {
            let prefix = composition.committed + String(raw.prefix(offset))
            let suffix = String(raw.dropFirst(offset))
            let prefixMatches = before?.hasSuffix(prefix) ?? false
            let suffixMatches = after?.hasPrefix(suffix) ?? false

            // Prefer both sides when available, but either immediate document
            // context is sufficient when the host only exposes one side.
            if (before != nil && after != nil && prefixMatches && suffixMatches)
                || (before != nil && after == nil && prefixMatches)
                || (before == nil && after != nil && suffixMatches) {
                composition.moveCursor(to: offset)
                return
            }
        }
    }

    private func setupView() {
        view.backgroundColor = .clear
        let root = UIStackView()
        root.axis = .vertical
        root.spacing = 4
        root.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(root)
        NSLayoutConstraint.activate([
            root.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 5),
            root.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -5),
            root.topAnchor.constraint(equalTo: view.topAnchor, constant: -6),
            root.bottomAnchor.constraint(equalTo: view.bottomAnchor, constant: -6)
        ])

        sentenceScrollView.showsHorizontalScrollIndicator = false
        sentenceScrollView.addSubview(sentenceBar)
        sentenceScrollView.heightAnchor.constraint(equalToConstant: 28).isActive = true
        root.addArrangedSubview(sentenceScrollView)
        root.setCustomSpacing(1, after: sentenceScrollView)

        candidateScrollView.showsHorizontalScrollIndicator = false
        candidateTap.addTarget(self, action: #selector(candidateBarTapped(_:)))
        candidateTap.cancelsTouchesInView = false
        candidateBar.addGestureRecognizer(candidateTap)
        candidateScrollView.addSubview(candidateBar)
        candidateScrollView.heightAnchor.constraint(equalToConstant: 34).isActive = true
        root.addArrangedSubview(candidateScrollView)

        keyboardStack.axis = .vertical
        keyboardStack.spacing = 5
        root.addArrangedSubview(keyboardStack)
        rebuildKeyboard()
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        sentenceBar.frame.size.width = max(sentenceScrollView.bounds.width, sentenceContentWidth)
        sentenceBar.frame.size.height = sentenceScrollView.bounds.height
        sentenceScrollView.contentSize = sentenceBar.bounds.size
        candidateBar.frame.size.width = max(candidateScrollView.bounds.width, candidateContentWidth)
        candidateBar.frame.size.height = candidateScrollView.bounds.height
        candidateScrollView.contentSize = candidateBar.bounds.size
    }

    private func makeRow(_ keys: [String], indented: Bool = false) -> UIStackView {
        let row = UIStackView()
        row.axis = .horizontal
        row.spacing = 4
        row.distribution = .fillEqually
        row.isLayoutMarginsRelativeArrangement = true
        if indented {
            row.layoutMargins = UIEdgeInsets(top: 0, left: 18, bottom: 0, right: 18)
        }
        row.heightAnchor.constraint(equalToConstant: 43).isActive = true
        keys.forEach { row.addArrangedSubview(keyButton($0)) }
        return row
    }

    private func makeBottomRow() -> UIStackView {
        let row = UIStackView()
        row.axis = .horizontal
        row.spacing = 8
        row.distribution = .fill
        row.heightAnchor.constraint(equalToConstant: 43).isActive = true

        // Mirrors the native Chinese keyboard's compact bottom row.
        let mode = keyButton(keyboardPage == .letters ? "123" : schemeLabel)
        let space = keyButton("space")
        let enter = keyButton("return")
        // Add every key to the row before activating cross-key width
        // constraints. Constraining against a sibling that is not yet in the
        // shared stack view has no common ancestor and aborts (crashes when
        // the globe key is present, e.g. on iPad).
        var globe: UIButton?
        if needsInputModeSwitchKey {
            globe = inputModeButton()
            row.addArrangedSubview(globe!)
        }
        [mode, space, enter].forEach { row.addArrangedSubview($0) }
        mode.widthAnchor.constraint(equalTo: enter.widthAnchor).isActive = true
        space.widthAnchor.constraint(equalTo: mode.widthAnchor, multiplier: 2.1).isActive = true
        globe?.widthAnchor.constraint(equalTo: mode.widthAnchor, multiplier: 0.75).isActive = true
        return row
    }

    private func keyButton(_ title: String) -> UIButton {
        let displayedTitle: String
        switch title {
        case "space":
            displayedTitle = "空格"
        case "return": displayedTitle = returnKeyTitle()
        case "delete": displayedTitle = "⌫"
        default: displayedTitle = title
        }
        let button = UIButton(type: .system)
        button.setTitle(displayedTitle, for: .normal)
        if title == "space" || title == "return" || title == "⇧" {
            button.accessibilityValue = title
        }
        button.setTitleColor(.label, for: .normal)
        button.titleLabel?.font = .systemFont(ofSize: 18)
        // Highlight Shift while a one-shot uppercase is armed.
        button.backgroundColor = (title == "⇧" && shifted)
            ? UIColor.label.withAlphaComponent(0.18) : .tertiarySystemBackground
        button.layer.cornerRadius = 10
        button.layer.cornerCurve = .continuous
        if displayedTitle == "⌫" {
            button.addTarget(self, action: #selector(beginDeleteRepeat), for: .touchDown)
            button.addTarget(self, action: #selector(endDeleteRepeat),
                             for: [.touchUpInside, .touchUpOutside, .touchCancel])
        } else {
            if title == "space" {
                let gesture = UILongPressGestureRecognizer(target: self,
                                                           action: #selector(moveCursorWithSpace(_:)))
                gesture.minimumPressDuration = 0.25
                gesture.cancelsTouchesInView = false
                button.addGestureRecognizer(gesture)
            }
            button.addTarget(self, action: #selector(keyTapped(_:)), for: .touchUpInside)
        }
        return button
    }

    private func inputModeButton() -> UIButton {
        let button = UIButton(type: .system)
        button.setImage(UIImage(systemName: "globe"), for: .normal)
        button.tintColor = .label
        button.backgroundColor = .tertiarySystemBackground
        button.layer.cornerRadius = 10
        button.layer.cornerCurve = .continuous
        // UIInputViewController supplies Apple's input-mode picker here. It
        // includes keyboard placement controls on devices that support them.
        button.addTarget(self,
                         action: #selector(handleInputModeList(from:with:)),
                         for: .allTouchEvents)
        return button
    }

    private func returnKeyTitle() -> String {
        switch textDocumentProxy.returnKeyType {
        case .send: return "发送"
        case .search: return "搜索"
        case .done: return "完成"
        case .go: return "前往"
        case .next: return "下一项"
        case .join: return "加入"
        case .continue: return "继续"
        case .route: return "路线"
        default: return "换行"
        }
    }

    @objc private func keyTapped(_ sender: UIButton) {
        guard let title = sender.accessibilityValue ?? sender.currentTitle else { return }
        switch title {
        case "space":
            if spaceCursorMode {
                spaceCursorMode = false
            } else {
                space()
            }
        case "return":
            if let text = composition.commitPreeditLiterally() {
                // Return is the literal-English escape hatch: unlike space or
                // the candidate-bar confirmation, it must not decode pinyin.
                textDocumentProxy.unmarkText()
                textDocumentProxy.insertText(text)
                updateMarkedText()
                render()
            } else {
                textDocumentProxy.insertText("\n")
            }
        case "⇧":
            shiftState = (shiftState == .off) ? .oneShot : .off
            keyboardNeedsRebuild = true
            render()
        case "123":
            // Enter the number page from letters, or step back to it from the
            // symbol page. Switching pages must not force-commit the
            // composition; keep it marked and commit only when a digit or
            // symbol is actually inserted (see the page branch below and
            // insertPunctuation).
            keyboardPage = .numbers
            shiftState = .off
            keyboardNeedsRebuild = true
            render()
        case "#+=":
            keyboardPage = .symbols
            shiftState = .off
            keyboardNeedsRebuild = true
            render()
        case "拼音", "双拼":
            keyboardPage = .letters
            shiftState = .off
            keyboardNeedsRebuild = true
            render()
        case ";" where keyboardScheme == .microsoftShuangpin:
            composition.append(title)
            updateMarkedText()
            render()
        case "，", "。", ";", "-", "/", "：", "；", "（", "）", "￥", "@", "“", "”", "、", "？", "！", ".":
            insertPunctuation(title)
        default:
            switch keyboardPage {
            case .numbers:
                // Commit any pending composition before the digit so the
                // marked pinyin isn't dropped; deferred from the 123 tap.
                commitComposition()
                textDocumentProxy.insertText(title.lowercased())
            case .symbols:
                // Symbols insert literally and stay on the symbol page, like
                // the system keyboard's #+= layout.
                commitComposition()
                textDocumentProxy.insertText(title)
            case .letters:
                // `title` is already uppercase when Shift is active; the
                // composition preserves its case and surfaces it as a literal
                // English candidate (committed on space/enter/tap), so
                // uppercase does not go straight to the document.
                composition.append(title)
                if shiftState == .oneShot {
                    shiftState = .off
                    keyboardNeedsRebuild = true
                }
                updateMarkedText()
                render()
            }
        }
    }

    @objc private func moveCursorWithSpace(_ gesture: UILongPressGestureRecognizer) {
        guard !composition.isComposing else { return }
        switch gesture.state {
        case .began:
            spaceCursorMode = true
            spaceLastTranslation = gesture.location(in: gesture.view).x
            // Match the native keyboard's acknowledgement that the space bar
            // has entered cursor-tracking mode.
            let feedback = UIImpactFeedbackGenerator(style: .light)
            feedback.prepare()
            feedback.impactOccurred()
        case .changed:
            let position = gesture.location(in: gesture.view).x
            let delta = position - spaceLastTranslation
            // UITextDocumentProxy can move only by whole characters, but map
            // the finger's continuous displacement at a fine resolution
            // instead of waiting for the former 18pt discrete jumps.  Consume
            // all crossed steps so a fast drag cannot lose cursor movement.
            let pointsPerCharacter: CGFloat = 6
            let offset = Int(delta / pointsPerCharacter)
            guard offset != 0 else { return }
            textDocumentProxy.adjustTextPosition(byCharacterOffset: offset)
            spaceLastTranslation += CGFloat(offset) * pointsPerCharacter
        default:
            break
        }
    }

    @objc private func beginDeleteRepeat() {
        endDeleteRepeat()
        delete()
        deleteInitialTimer = Timer.scheduledTimer(withTimeInterval: 0.35, repeats: false) { [weak self] _ in
            guard let self else { return }
            self.deleteRepeatTimer = Timer.scheduledTimer(withTimeInterval: 0.08, repeats: true) { [weak self] _ in
                self?.delete()
            }
            if let deleteRepeatTimer = self.deleteRepeatTimer {
                RunLoop.main.add(deleteRepeatTimer, forMode: .common)
            }
        }
        if let deleteInitialTimer {
            RunLoop.main.add(deleteInitialTimer, forMode: .common)
        }
    }

    @objc private func endDeleteRepeat() {
        deleteInitialTimer?.invalidate()
        deleteInitialTimer = nil
        deleteRepeatTimer?.invalidate()
        deleteRepeatTimer = nil
    }

    private func insertPunctuation(_ punctuation: String) {
        commitComposition()
        textDocumentProxy.insertText(punctuation == ";" ? "；" : punctuation)
        if keyboardPage != .letters {
            keyboardPage = .letters
            shiftState = .off
            keyboardNeedsRebuild = true
        }
        render()
    }

    private func delete() {
        if composition.isComposing {
            composition.delete()
            updateMarkedText()
            render()
        } else {
            textDocumentProxy.deleteBackward()
        }
    }

    private func space() {
        if let text = composition.commitBestOrRaw() {
            textDocumentProxy.unmarkText()
            textDocumentProxy.insertText(text)
        } else {
            textDocumentProxy.insertText(" ")
        }
        updateMarkedText()
        render()
    }

    private func commitComposition() {
        if let text = composition.commitBestOrRaw() {
            textDocumentProxy.unmarkText()
            textDocumentProxy.insertText(text)
        }
        updateMarkedText()
        render()
    }

    private func updateMarkedText() {
        guard composition.isComposing else {
            InputSettings.pendingRaw = ""
            InputSettings.pendingCommitted = ""
            textDocumentProxy.unmarkText()
            return
        }
        InputSettings.pendingRaw = composition.raw
        InputSettings.pendingCommitted = composition.committed
        let text = composition.preedit
        textDocumentProxy.setMarkedText(text,
            selectedRange: NSRange(location: composition.selectionLocation, length: 0))
    }

    @objc private func candidateBarTapped(_ gesture: UITapGestureRecognizer) {
        guard gesture.state == .ended else { return }
        let point = gesture.location(in: candidateBar)
        guard let label = candidateBar.subviews.compactMap({ $0 as? UILabel })
            .first(where: { $0.frame.contains(point) }) else { return }
        selectCandidate(at: label.tag)
    }

    private func selectCandidate(at index: Int) {
        if let text = composition.selectDisplayed(index) {
            textDocumentProxy.unmarkText()
            textDocumentProxy.insertText(text)
        }
        updateMarkedText()
        render()
    }

    @objc private func sentenceCharacterTapped(_ sender: UIButton) {
        guard let index = sender.accessibilityValue.flatMap(Int.init) else { return }
        composition.activateCharacter(index)
        render()
    }

    @objc private func confirmSentence() {
        commitComposition()
    }

    private func rebuildKeyboard() {
        keyboardStack.arrangedSubviews.forEach { $0.removeFromSuperview() }
        switch keyboardPage {
        case .numbers:
            keyboardStack.addArrangedSubview(
                makeRow(["1", "2", "3", "4", "5", "6", "7", "8", "9", "0"])
            )
            keyboardStack.addArrangedSubview(
                makeRow(["-", "/", "：", "；", "（", "）", "￥", "@", "“", "”"])
            )
            keyboardStack.addArrangedSubview(
                makeRow(["#+=", "。", "，", "、", "？", "！", ".", "⌫"])
            )
        case .symbols:
            keyboardStack.addArrangedSubview(
                makeRow(["【", "】", "｛", "｝", "#", "%", "^", "*", "+", "="])
            )
            keyboardStack.addArrangedSubview(
                makeRow(["_", "—", "\\", "｜", "～", "《", "》", "$", "&", "·"])
            )
            keyboardStack.addArrangedSubview(
                makeRow(["123", "…", ",", "°", "?", "!", "'", "⌫"])
            )
        case .letters:
            let letters = shifted ? "QWERTYUIOP" : "qwertyuiop"
            let isDouble = keyboardScheme == .microsoftShuangpin
            let home = isDouble
                ? (shifted ? "ASDFGHJKL;" : "asdfghjkl;")
                : (shifted ? "ASDFGHJKL" : "asdfghjkl")
            let bottom = shifted ? "ZXCVBNM" : "zxcvbnm"
            keyboardStack.addArrangedSubview(makeRow(Array(letters).map(String.init)))
            keyboardStack.addArrangedSubview(
                makeRow(Array(home).map(String.init), indented: !isDouble)
            )
            keyboardStack.addArrangedSubview(
                makeRow(["⇧"] + Array(bottom).map(String.init) + ["delete"])
            )
        }
        keyboardStack.addArrangedSubview(makeBottomRow())
    }

    private func render() {
        if keyboardNeedsRebuild {
            rebuildKeyboard()
            keyboardNeedsRebuild = false
        }
        sentenceBar.subviews.forEach { $0.removeFromSuperview() }
        var sentenceX: CGFloat = 8
        if composition.isComposing {
            let font = UIFont.preferredFont(forTextStyle: .body)
            for (index, char) in Array(composition.sentencePreview).enumerated() {
                let isActive = index == composition.activeCharacterIndex
                let title = isActive ? (composition.activeEnteredKeys ?? String(char)) : String(char)
                let button = UIButton(type: .system)
                button.setTitle(title, for: .normal)
                button.titleLabel?.font = font
                button.setTitleColor(isActive ? .systemBlue : .label, for: .normal)
                let textWidth = (title as NSString).size(withAttributes: [.font: font]).width
                let width = max(24, ceil(textWidth) + 4)
                button.frame = CGRect(x: sentenceX, y: 0, width: width, height: 28)
                button.accessibilityValue = String(index)
                button.addTarget(self, action: #selector(sentenceCharacterTapped(_:)), for: .touchUpInside)
                sentenceBar.addSubview(button)
                sentenceX += width + 3
            }
        }
        if composition.isComposing {
            let confirm = UIButton(type: .system)
            confirm.setImage(UIImage(systemName: "return"), for: .normal)
            confirm.tintColor = .label
            confirm.frame = CGRect(x: sentenceX, y: 0, width: 24, height: 28)
            confirm.addTarget(self, action: #selector(confirmSentence), for: .touchUpInside)
            sentenceBar.addSubview(confirm)
            sentenceX += 27
        }
        sentenceContentWidth = sentenceX
        candidateBar.subviews.forEach { $0.removeFromSuperview() }
        let displayedCandidates = composition.displayCandidates
        if displayedCandidates.isEmpty {
            let hint = UILabel()
            hint.text = composition.isComposing ? composition.preedit : ""
            hint.textColor = .secondaryLabel
            hint.textAlignment = .left
            hint.frame = CGRect(x: 8, y: 0, width: 120, height: 34)
            candidateBar.addSubview(hint)
            candidateContentWidth = candidateScrollView.bounds.width
        } else {
            var candidateX: CGFloat = 8
            let font = UIFont.preferredFont(forTextStyle: .body)
            for (index, candidate) in displayedCandidates.enumerated() {
                let label = UILabel()
                label.text = candidate.text
                label.font = font
                label.textColor = .label
                label.textAlignment = .center
                label.lineBreakMode = .byTruncatingTail
                let textWidth = (candidate.text as NSString).size(withAttributes: [.font: font]).width
                let width = max(ceil(textWidth) + 4, 22)
                label.frame = CGRect(x: candidateX, y: 0, width: width, height: 34)
                label.tag = index
                candidateBar.addSubview(label)
                candidateX += width + 6
            }
            candidateContentWidth = candidateX
        }
        // Do not wait for a later layout pass before making the horizontal
        // range available; otherwise a freshly rendered candidate row cannot
        // be dragged on some keyboard-hosting views.
        candidateBar.frame.size.width = max(candidateScrollView.bounds.width, candidateContentWidth)
        candidateBar.frame.size.height = candidateScrollView.bounds.height
        candidateScrollView.contentSize = candidateBar.bounds.size
        sentenceScrollView.setContentOffset(.zero, animated: false)
        candidateScrollView.setContentOffset(.zero, animated: false)
        view.setNeedsLayout()
    }
}
