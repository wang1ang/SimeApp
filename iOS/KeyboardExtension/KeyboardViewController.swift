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
        keyboardScheme.isShuangpin ? "双拼" : "拼音"
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
    // True once `composition` is backed by the native engine, so we only swap
    // decoders once per controller lifetime.
    private var usesNativeDecoder = false
    private var displayedReturnKeyType: UIReturnKeyType?
    private var restoringMarkedText = false
    private var spaceCursorMode = false
    private var spaceLastTranslation: CGFloat = 0
    private var deleteInitialTimer: Timer?
    private var deleteRepeatTimer: Timer?

    private static func makeComposition(inputScheme: InputScheme = InputSettings.scheme) -> Composition {
        // Start with whichever decoder is available without blocking: the
        // shared native engine if it already loaded in this process,
        // otherwise the lightweight builtin so the keyboard stays responsive
        // while the native engine loads in the background.
        Composition(
            decoder: NativePinyinDecoder.sharedIfLoaded ?? BuiltinPinyinDecoder(),
            inputScheme: inputScheme
        )
    }

    /// Load the native engine off the main thread and swap it into the current
    /// composition when ready, preserving any in-progress raw pinyin. Cheap
    /// no-op once the native decoder is already active.
    private func activateNativeDecoder() {
        guard !usesNativeDecoder else { return }
        NativePinyinDecoder.loadShared { [weak self] decoder in
            guard let self, let decoder, !self.usesNativeDecoder else { return }
            self.usesNativeDecoder = true
            let raw = self.composition.raw
            let committed = self.composition.committed
            self.composition = Composition(decoder: decoder, inputScheme: self.keyboardScheme)
            self.composition.restore(raw: raw, committed: committed)
            self.render()
        }
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        usesNativeDecoder = NativePinyinDecoder.sharedIfLoaded != nil
        setupView()
        displayedReturnKeyType = textDocumentProxy.returnKeyType
        render()
        activateNativeDecoder()
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        // The extension view may be detached while the phone is locked.
        // Repaint the in-memory composition when it is attached again.
        let scheme = InputSettings.scheme
        if keyboardScheme != scheme {
            keyboardScheme = scheme
            composition = Self.makeComposition(inputScheme: scheme)
            usesNativeDecoder = NativePinyinDecoder.sharedIfLoaded != nil
            keyboardNeedsRebuild = true
        }
        composition.predictionEnabled = InputSettings.predictionEnabled
        refreshReturnKeyAppearance()
        render()
        activateNativeDecoder()
    }

    override func didReceiveMemoryWarning() {
        super.didReceiveMemoryWarning()
        // Shrink the engine's caches instead of risking a jetsam kill (which
        // shows to the user as the keyboard flashing/reloading). Memory-only
        // hint: decode results are unchanged and caches rebuild on demand.
        NativePinyinDecoder.sharedIfLoaded?.resetCaches()
    }

    override func textDidChange(_ textInput: UITextInput?) {
        super.textDidChange(textInput)
        guard !restoringMarkedText else { return }
        // .missing means the marked pinyin isn't in the focused field (user
        // switched fields/apps): drop it instead of leaking it into the new field.
        if syncCompositionCursor() == .missing {
            composition.cancel()
            updateMarkedText()
            render()
            refreshReturnKeyAppearance()
            return
        }
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

    /// Result of locating the marked pinyin around the host's insertion point.
    private enum CursorSyncResult {
        /// Found; the composition cursor was moved to it.
        case matched
        /// Context available but the pinyin isn't in it — focus moved elsewhere.
        case missing
        /// Host exposed no context, so nothing can be decided.
        case unavailable
    }

    @discardableResult
    private func syncCompositionCursor() -> CursorSyncResult {
        guard composition.isComposing else { return .unavailable }
        // Hosts are allowed to return nil for the context after the insertion
        // point (notably at the end of a note).  The previous all-or-nothing
        // check then missed a tap in marked pinyin and the subsequent
        // setMarkedText replaced it at the wrong position.
        let before = textDocumentProxy.documentContextBeforeInput
        let after = textDocumentProxy.documentContextAfterInput
        guard before != nil || after != nil else { return .unavailable }

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
                return .matched
            }
        }
        // Context was available but the pinyin isn't adjacent to the insertion
        // point — caller cancels rather than re-inject it into a foreign field.
        return .missing
    }

    private func setupView() {
        // The root view must be near-opaque: a transparent keyboard lets gap
        // taps fall through to the host (they never reach hitTest), and an
        // opaque subview backdrop doesn't help — iOS samples this view itself.
        view.backgroundColor = UIColor.secondarySystemBackground.withAlphaComponent(0.9)
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
        let button = KeyButton()
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
        let button = KeyButton()
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
        case ";" where keyboardScheme.usesSemicolonKey:
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
            // Replace any lingering marked preedit with empty before unmarking:
            // unmarkText() alone finalizes the marked text into the document,
            // so deleting the last composing key would leave that key behind.
            textDocumentProxy.setMarkedText("", selectedRange: NSRange(location: 0, length: 0))
            textDocumentProxy.unmarkText()
            return
        }
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
            let isDouble = keyboardScheme.usesSemicolonKey
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
        updateFinalKeyHighlights()
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

    // Tint the letter keys that complete a valid syllable with the Shuangpin
    // initial the user just typed; clear the tint once no initial is pending.
    // A highlighted (legal) key also claims the whole gap toward each
    // non-highlighted neighbor, and that neighbor cedes its facing side, so a
    // tap in the spacing lands on the legal key without shrinking anyone's
    // actual key face.
    // The set of legal Shuangpin final keys drives two INDEPENDENT behaviors,
    // each gated by its own flag below: (1) tinting those keys, and (2)
    // enlarging their touch area. They share only the source set, so turning
    // one off never affects the other.
    private let tintShuangpinFinalKeys = false  // temporarily disabled (see REGRESSION 64b)
    private let enlargeShuangpinFinalKeys = true

    private func updateFinalKeyHighlights() {
        // Source of truth: which final keys form a legal syllable right now.
        let legalFinals = keyboardPage == .letters
            ? composition.shuangpinFinalKeyHighlights() : []
        applyFinalKeyTint(legalFinals: tintShuangpinFinalKeys ? legalFinals : [])
        applyFinalKeyHitAreas(legalFinals: enlargeShuangpinFinalKeys ? legalFinals : [])
    }

    private func char(ofKey button: KeyButton) -> Character? {
        guard let title = button.currentTitle?.lowercased(), title.count == 1
        else { return nil }
        return title.first
    }

    // Behavior 1: tint the legal final keys blue, reset the rest.
    private func applyFinalKeyTint(legalFinals: Set<Character>) {
        for case let row as UIStackView in keyboardStack.arrangedSubviews {
            for case let button as KeyButton in row.arrangedSubviews {
                guard let c = char(ofKey: button),
                      MicrosoftShuangpin.finalKeyCandidates.contains(c) else { continue }
                button.backgroundColor = legalFinals.contains(c)
                    ? UIColor.systemBlue.withAlphaComponent(0.28)
                    : .tertiarySystemBackground
            }
        }
    }

    // Behavior 2: a legal final key claims the whole gap toward each
    // non-legal neighbor (which cedes its facing side), without overlapping
    // any neighbor's key face. With an empty set this is a no-op that restores
    // the default gap-tapping insets (contract 63).
    private func applyFinalKeyHitAreas(legalFinals: Set<Character>) {
        // Inter-key spacing on every letter row (see makeRow).
        let gap: CGFloat = 4
        let defaultInset: CGFloat = 8
        func isLegal(_ button: KeyButton) -> Bool {
            guard let c = char(ofKey: button) else { return false }
            return legalFinals.contains(c)
        }
        for case let row as UIStackView in keyboardStack.arrangedSubviews {
            let buttons = row.arrangedSubviews.compactMap { $0 as? KeyButton }
            for (index, button) in buttons.enumerated() {
                let hi = isLegal(button)
                let leftHi = index > 0 && isLegal(buttons[index - 1])
                let rightHi = index < buttons.count - 1 && isLegal(buttons[index + 1])
                var inset = UIEdgeInsets(top: 0, left: defaultInset,
                                         bottom: 0, right: defaultInset)
                if hi {
                    // Claim exactly the gap toward a non-legal neighbor; keep
                    // the default reach toward edges / other legal keys.
                    if index > 0, !leftHi { inset.left = gap }
                    if index < buttons.count - 1, !rightHi { inset.right = gap }
                } else {
                    // Cede the gap to an adjacent legal key.
                    if leftHi { inset.left = 0 }
                    if rightHi { inset.right = 0 }
                }
                button.hitInset = inset
            }
        }
    }
}

final class KeyButton: UIButton {
    // Grow the touch area horizontally into the gaps between keys so a tap in
    // the spacing lands inside a key and fires. (Only horizontal: the vertical
    // inter-row spacing sits outside the row frame, so a key there is never
    // consulted anyway.)
    var hitInset = UIEdgeInsets(top: 0, left: 8, bottom: 0, right: 8)

    // Custom-type buttons don't dim on press; restore light feedback.
    override var isHighlighted: Bool {
        didSet { alpha = isHighlighted ? 0.4 : 1 }
    }

    override func point(inside point: CGPoint, with event: UIEvent?) -> Bool {
        bounds.inset(by: UIEdgeInsets(top: -hitInset.top, left: -hitInset.left,
                                     bottom: -hitInset.bottom, right: -hitInset.right))
            .contains(point)
    }
}
