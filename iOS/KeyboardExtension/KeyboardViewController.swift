import UIKit

final class KeyboardViewController: UIInputViewController {
    private var composition = Composition()
    private let sentenceScrollView = UIScrollView()
    private let sentenceBar = UIView()
    private let candidateScrollView = UIScrollView()
    private let candidateBar = UIView()
    private let candidateTap = UITapGestureRecognizer()
    private var sentenceContentWidth: CGFloat = 0
    private var candidateContentWidth: CGFloat = 0
    private let keyboardStack = UIStackView()
    private var numberMode = false
    private var shifted = false
    private var keyboardScheme = InputSettings.scheme
    private var keyboardNeedsRebuild = false
    private var deleteInitialTimer: Timer?
    private var deleteRepeatTimer: Timer?

    override func viewDidLoad() {
        super.viewDidLoad()
        setupView()
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
            composition = Composition(inputScheme: scheme)
            keyboardNeedsRebuild = true
        }
        render()
    }

    override func textDidChange(_ textInput: UITextInput?) {
        super.textDidChange(textInput)
        syncCompositionCursor()
    }

    private func syncCompositionCursor() {
        guard composition.isComposing,
              let before = textDocumentProxy.documentContextBeforeInput,
              let after = textDocumentProxy.documentContextAfterInput else { return }
        let raw = composition.raw
        for offset in 0...raw.count {
            let prefix = composition.committed + String(raw.prefix(offset))
            let suffix = String(raw.dropFirst(offset))
            if before.hasSuffix(prefix), after.hasPrefix(suffix) {
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
        let mode = keyButton(numberMode ? "拼音" : "123")
        let space = keyButton("space")
        let enter = keyButton("return")
        if needsInputModeSwitchKey {
            let globe = inputModeButton()
            row.addArrangedSubview(globe)
            globe.widthAnchor.constraint(equalTo: mode.widthAnchor, multiplier: 0.75).isActive = true
        }
        [mode, space, enter].forEach { row.addArrangedSubview($0) }
        mode.widthAnchor.constraint(equalTo: enter.widthAnchor).isActive = true
        space.widthAnchor.constraint(equalTo: mode.widthAnchor, multiplier: 2.1).isActive = true
        return row
    }

    private func keyButton(_ title: String) -> UIButton {
        let displayedTitle: String
        switch title {
        case "space": displayedTitle = "空格"
        case "return": displayedTitle = "换行"
        case "delete": displayedTitle = "⌫"
        default: displayedTitle = title
        }
        let button = UIButton(type: .system)
        button.setTitle(displayedTitle, for: .normal)
        button.setTitleColor(.label, for: .normal)
        button.titleLabel?.font = .systemFont(ofSize: 18)
        button.backgroundColor = .tertiarySystemBackground
        button.layer.cornerRadius = 10
        button.layer.cornerCurve = .continuous
        if displayedTitle == "⌫" {
            button.addTarget(self, action: #selector(beginDeleteRepeat), for: .touchDown)
            button.addTarget(self, action: #selector(endDeleteRepeat),
                             for: [.touchUpInside, .touchUpOutside, .touchCancel])
        } else {
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

    @objc private func keyTapped(_ sender: UIButton) {
        guard let title = sender.currentTitle else { return }
        switch title {
        case "空格": space()
        case "换行":
            if composition.isComposing {
                commitComposition()
            } else {
                textDocumentProxy.insertText("\n")
            }
        case "⇧":
            shifted.toggle()
            keyboardNeedsRebuild = true
            render()
        case "123", "拼音":
            commitComposition()
            numberMode.toggle()
            shifted = false
            keyboardNeedsRebuild = true
            render()
        case ";" where keyboardScheme == .microsoftShuangpin:
            composition.append(title)
            updateMarkedText()
            render()
        case "，", "。", ";":
            commitComposition()
            textDocumentProxy.insertText(title == ";" ? "；" : title)
        default:
            if numberMode {
                textDocumentProxy.insertText(title.lowercased())
            } else {
                composition.append(title)
                shifted = false
                updateMarkedText()
                render()
            }
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
        if numberMode {
            keyboardStack.addArrangedSubview(
                makeRow(["1", "2", "3", "4", "5", "6", "7", "8", "9", "0"])
            )
            keyboardStack.addArrangedSubview(
                makeRow(["-", "/", "：", "；", "(", ")", "￥", "@", "“", "”"])
            )
            keyboardStack.addArrangedSubview(
                makeRow(["#+=", "。", "，", "、", "？", "！", ".", "⌫"])
            )
        } else {
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
            for (index, char) in Array(composition.sentencePreview).enumerated() {
                let button = UIButton(type: .system)
                button.setTitle(String(char), for: .normal)
                button.titleLabel?.font = .preferredFont(forTextStyle: .body)
                button.setTitleColor(index == composition.activeCharacterIndex ? .systemBlue : .label, for: .normal)
                button.frame = CGRect(x: sentenceX, y: 0, width: 24, height: 28)
                button.accessibilityValue = String(index)
                button.addTarget(self, action: #selector(sentenceCharacterTapped(_:)), for: .touchUpInside)
                sentenceBar.addSubview(button)
                sentenceX += 27
            }
        }
        if composition.isComposing {
            let confirm = UIButton(type: .system)
            confirm.setImage(UIImage(systemName: "checkmark"), for: .normal)
            confirm.tintColor = .secondaryLabel
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
