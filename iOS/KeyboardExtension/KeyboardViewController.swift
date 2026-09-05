import UIKit

final class KeyboardViewController: UIInputViewController {
    private var composition = KeyboardViewController.makeComposition()
    private let sentenceScrollView = UIScrollView()
    private let sentenceBar = UIView()
    // Tap gesture used to pick a trailing whole-sentence candidate in row one.
    private let sentenceCandidateTap = UITapGestureRecognizer()
    // Popup bubble that lists a tapped first-row character's candidates.
    private var candidateBubble: UIView?
    // True when the active character was reached by directly tapping it (show a
    // bubble); false when reached by auto-advancing after a selection (list the
    // candidates inline at the end of the first row instead).
    private var activeUsesBubble = false
    private var bubbleOverlay: UIView?
    private var sentenceContentWidth: CGFloat = 0
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
        sentenceCandidateTap.addTarget(self, action: #selector(sentenceCandidateTapped(_:)))
        sentenceCandidateTap.cancelsTouchesInView = false
        sentenceCandidateTap.isEnabled = false
        sentenceBar.addGestureRecognizer(sentenceCandidateTap)
        root.addArrangedSubview(sentenceScrollView)
        root.setCustomSpacing(1, after: sentenceScrollView)

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
        // Any keypress ends an open candidate bubble.
        dismissCandidateBubble()
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

    private func selectCandidate(at index: Int) {
        // Any selection auto-advances to the next character (if any); show that
        // one's candidates inline in the first row rather than in a bubble.
        activeUsesBubble = false
        if let text = composition.selectDisplayed(index) {
            textDocumentProxy.unmarkText()
            textDocumentProxy.insertText(text)
        }
        updateMarkedText()
        render()
    }

    @objc private func sentenceCandidateTapped(_ gesture: UITapGestureRecognizer) {
        guard gesture.state == .ended else { return }
        let point = gesture.location(in: sentenceBar)
        guard let label = sentenceBar.subviews.compactMap({ $0 as? UILabel })
            .first(where: { $0.frame.contains(point) }) else { return }
        selectCandidate(at: label.tag)
    }

    @objc private func sentenceCharacterTapped(_ sender: UIButton) {
        guard let index = sender.accessibilityValue.flatMap(Int.init) else { return }
        // Opening the bubble (fresh, or switching characters) only lists
        // candidates; the pinyin toggle happens on a further tap while the
        // bubble is already open on that same character.
        let bubbleOpenOnSame = candidateBubble != nil && composition.activeCharacterIndex == index
        activeUsesBubble = true
        composition.activateCharacter(index, allowKeyToggle: bubbleOpenOnSame)
        render()
        showCandidateBubble(anchor: sender)
    }

    // MARK: - Candidate bubble

    // Tapping a first-row character pops up a bubble listing that character's
    // replacement candidates (the content that used to fill the hidden second
    // row). Selecting a candidate applies the correction; tapping outside the
    // bubble dismisses it and clears the first-row selection.
    private func showCandidateBubble(anchor: UIButton) {
        dismissCandidateBubble(deactivate: false)
        let candidates = composition.displayCandidates
        guard !candidates.isEmpty else { return }

        let overlay = UIView(frame: view.bounds)
        overlay.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        overlay.backgroundColor = .clear
        let overlayTap = UITapGestureRecognizer(target: self, action: #selector(bubbleOverlayTapped(_:)))
        overlay.addGestureRecognizer(overlayTap)
        view.addSubview(overlay)
        bubbleOverlay = overlay

        let bubble = UIView()
        bubble.backgroundColor = .secondarySystemBackground
        bubble.layer.cornerRadius = 10
        bubble.layer.shadowColor = UIColor.black.cgColor
        bubble.layer.shadowOpacity = 0.25
        bubble.layer.shadowRadius = 6
        bubble.layer.shadowOffset = CGSize(width: 0, height: 2)

        let scroll = UIScrollView()
        scroll.showsVerticalScrollIndicator = true
        let content = UIView()
        let contentTap = UITapGestureRecognizer(target: self, action: #selector(bubbleContentTapped(_:)))
        contentTap.cancelsTouchesInView = false
        content.addGestureRecognizer(contentTap)
        scroll.addSubview(content)
        bubble.addSubview(scroll)
        view.addSubview(bubble)
        candidateBubble = bubble

        // Wrap candidate cells left-to-right within the available width.
        let padding: CGFloat = 8
        let margin: CGFloat = 6
        let cellHeight: CGFloat = 34
        let gap: CGFloat = 6
        let maxRowWidth = view.bounds.width - 2 * margin - 2 * padding
        let font = UIFont.preferredFont(forTextStyle: .body)
        var x: CGFloat = 0
        var y: CGFloat = 0
        var usedRowWidth: CGFloat = 0
        for (index, candidate) in candidates.enumerated() {
            let textWidth = (candidate.text as NSString).size(withAttributes: [.font: font]).width
            let width = min(max(ceil(textWidth) + 16, cellHeight), maxRowWidth)
            if x > 0 && x + width > maxRowWidth {
                usedRowWidth = max(usedRowWidth, x - gap)
                x = 0
                y += cellHeight + gap
            }
            let label = UILabel(frame: CGRect(x: x, y: y, width: width, height: cellHeight))
            label.text = candidate.text
            label.font = font
            label.textColor = .label
            label.textAlignment = .center
            label.lineBreakMode = .byTruncatingTail
            label.tag = index
            content.addSubview(label)
            x += width + gap
        }
        usedRowWidth = max(usedRowWidth, x - gap)
        let contentWidth = max(usedRowWidth, 0)
        let contentHeight = y + cellHeight
        content.frame = CGRect(x: 0, y: 0, width: contentWidth, height: contentHeight)

        let bubbleWidth = contentWidth + 2 * padding
        let maxBubbleHeight = min(view.bounds.height - 12, cellHeight * 4 + gap * 3 + 2 * padding)
        let bubbleHeight = min(contentHeight + 2 * padding, maxBubbleHeight)
        scroll.frame = CGRect(x: padding, y: padding,
                              width: bubbleWidth - 2 * padding,
                              height: bubbleHeight - 2 * padding)
        scroll.contentSize = content.frame.size

        let anchorRect = sentenceBar.convert(anchor.frame, to: view)
        var bubbleX = anchorRect.midX - bubbleWidth / 2
        bubbleX = min(max(bubbleX, margin), view.bounds.width - margin - bubbleWidth)
        let bubbleY = min(anchorRect.maxY + 2, view.bounds.height - margin - bubbleHeight)
        bubble.frame = CGRect(x: bubbleX, y: bubbleY, width: bubbleWidth, height: bubbleHeight)
    }

    private func dismissCandidateBubble(deactivate: Bool = true) {
        candidateBubble?.removeFromSuperview()
        candidateBubble = nil
        bubbleOverlay?.removeFromSuperview()
        bubbleOverlay = nil
        if deactivate {
            composition.deactivateCharacter()
        }
    }

    @objc private func bubbleOverlayTapped(_ gesture: UITapGestureRecognizer) {
        // A tap that lands on another first-row character switches the bubble
        // to that character instead of just dismissing.
        let point = gesture.location(in: sentenceBar)
        if let button = sentenceBar.subviews.compactMap({ $0 as? UIButton })
            .first(where: { $0.frame.contains(point) }) {
            if button.accessibilityValue.flatMap(Int.init) != nil {
                sentenceCharacterTapped(button)
            } else {
                // The only non-character first-row button is the confirm key.
                confirmSentence()
            }
            return
        }
        dismissCandidateBubble()
        render()
    }

    @objc private func bubbleContentTapped(_ gesture: UITapGestureRecognizer) {
        guard gesture.state == .ended, let content = gesture.view else { return }
        let point = gesture.location(in: content)
        guard let label = content.subviews.compactMap({ $0 as? UILabel })
            .first(where: { $0.frame.contains(point) }) else { return }
        let index = label.tag
        dismissCandidateBubble(deactivate: false)
        selectCandidate(at: index)
    }

    @objc private func confirmSentence() {
        dismissCandidateBubble(deactivate: false)
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
        sentenceCandidateTap.isEnabled = composition.isComposing || !composition.displayCandidates.isEmpty
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
            // Extra breathing room between the confirm key and the trailing
            // candidate list.
            sentenceX += 38
        }
        // Trailing candidates after the per-character top choice and confirm
        // key. With no active character these are the whole-sentence
        // alternatives (skip index 0, already shown per-character). While a
        // character is being edited inline (reached via auto-advance, not a
        // fresh tap) these are that character's replacement candidates. When
        // the character is shown in a bubble instead, list nothing inline.
        if composition.isComposing, !(composition.activeCharacterIndex != nil && activeUsesBubble) {
            let font = UIFont.preferredFont(forTextStyle: .body)
            let candidates = composition.displayCandidates
            let startIndex = composition.activeCharacterIndex == nil ? 1 : 0
            for index in candidates.indices where index >= startIndex {
                let candidate = candidates[index]
                // Locked anchors are ground truth: drop whole-sentence
                // alternatives that disagree with an anchor position.
                if composition.activeCharacterIndex == nil,
                   !composition.matchesAnchors(candidate) { continue }
                let label = UILabel()
                label.text = candidate.text
                label.font = font
                label.textColor = .label
                label.textAlignment = .center
                label.lineBreakMode = .byTruncatingTail
                let textWidth = (candidate.text as NSString).size(withAttributes: [.font: font]).width
                let width = max(ceil(textWidth) + 4, 24)
                label.frame = CGRect(x: sentenceX, y: 0, width: width, height: 28)
                label.tag = index
                sentenceBar.addSubview(label)
                sentenceX += width + 6
            }
        }
        // Not composing: reuse the first row for association (prediction)
        // candidates so they no longer need the removed second row.
        if !composition.isComposing {
            let font = UIFont.preferredFont(forTextStyle: .body)
            for (index, candidate) in composition.displayCandidates.enumerated() {
                let label = UILabel()
                label.text = candidate.text
                label.font = font
                label.textColor = .label
                label.textAlignment = .center
                label.lineBreakMode = .byTruncatingTail
                let textWidth = (candidate.text as NSString).size(withAttributes: [.font: font]).width
                let width = max(ceil(textWidth) + 4, 24)
                label.frame = CGRect(x: sentenceX, y: 0, width: width, height: 28)
                label.tag = index
                sentenceBar.addSubview(label)
                sentenceX += width + 6
            }
        }
        sentenceContentWidth = sentenceX
        sentenceScrollView.setContentOffset(.zero, animated: false)
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
