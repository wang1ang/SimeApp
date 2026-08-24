import UIKit

final class KeyboardViewController: UIInputViewController {
    private let composition = Composition()
    private let sentenceScrollView = UIScrollView()
    private let sentenceBar = UIView()
    private let candidateScrollView = UIScrollView()
    private let candidateBar = UIView()
    private var sentenceContentWidth: CGFloat = 0
    private var candidateContentWidth: CGFloat = 0
    private let keyboardStack = UIStackView()
    private var chineseMode = true
    private var numberMode = false
    private var shifted = false
    private var keyboardNeedsRebuild = false

    override func viewDidLoad() {
        super.viewDidLoad()
        setupView()
        render()
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        // The extension view may be detached while the phone is locked.
        // Repaint the in-memory composition when it is attached again.
        render()
    }

    override func textWillChange(_ textInput: UITextInput?) {
        super.textWillChange(textInput)
    }

    override func textDidChange(_ textInput: UITextInput?) {
        super.textDidChange(textInput)
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
            root.topAnchor.constraint(equalTo: view.topAnchor),
            root.bottomAnchor.constraint(equalTo: view.bottomAnchor, constant: -6)
        ])

        sentenceScrollView.showsHorizontalScrollIndicator = false
        sentenceScrollView.addSubview(sentenceBar)
        sentenceScrollView.heightAnchor.constraint(equalToConstant: 28).isActive = true
        root.addArrangedSubview(sentenceScrollView)
        root.setCustomSpacing(1, after: sentenceScrollView)

        candidateScrollView.showsHorizontalScrollIndicator = false
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

        // Mirrors the native Chinese keyboard's compact bottom row. iOS
        // supplies the input-mode globe and dictation controls below it.
        let mode = keyButton(numberMode ? "拼音" : "123")
        let space = keyButton("space")
        let enter = keyButton("return")
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
        button.addTarget(self, action: #selector(keyTapped(_:)), for: .touchUpInside)
        return button
    }

    @objc private func keyTapped(_ sender: UIButton) {
        guard let title = sender.currentTitle else { return }
        switch title {
        case "⌫": delete()
        case "空格": space()
        case "换行":
            if composition.isComposing {
                commitComposition()
            } else {
                textDocumentProxy.insertText("\n")
            }
        case "🌐": advanceToNextInputMode()
        case "⇧":
            shifted.toggle()
            keyboardNeedsRebuild = true
            render()
        case "中/英":
            commitComposition()
            chineseMode.toggle()
            shifted = false
            keyboardNeedsRebuild = true
            render()
        case "123", "ABC", "拼音":
            commitComposition()
            numberMode.toggle()
            shifted = false
            keyboardNeedsRebuild = true
            render()
        case "，", "。", ";":
            commitComposition()
            textDocumentProxy.insertText(title == ";" && chineseMode ? "；" : title)
        default:
            if numberMode || !chineseMode {
                textDocumentProxy.insertText(title.lowercased())
            } else {
                composition.append(title)
                shifted = false
                updateMarkedText()
                render()
            }
        }
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
            textDocumentProxy.unmarkText()
            return
        }
        let text = composition.preedit
        textDocumentProxy.setMarkedText(text,
            selectedRange: NSRange(location: text.utf16.count, length: 0))
    }

    @objc private func selectCandidate(_ sender: UIButton) {
        guard let index = sender.accessibilityValue.flatMap(Int.init) else { return }
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
            let home = shifted ? "ASDFGHJKL;" : "asdfghjkl;"
            let bottom = shifted ? "ZXCVBNM" : "zxcvbnm"
            keyboardStack.addArrangedSubview(makeRow(Array(letters).map(String.init)))
            keyboardStack.addArrangedSubview(makeRow(Array(home).map(String.init)))
            keyboardStack.addArrangedSubview(
                makeRow(["⇧"] + Array(bottom).map(String.init) + ["⌫"])
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
                button.frame = CGRect(x: sentenceX, y: 0, width: 30, height: 28)
                button.accessibilityValue = String(index)
                button.addTarget(self, action: #selector(sentenceCharacterTapped(_:)), for: .touchUpInside)
                sentenceBar.addSubview(button)
                sentenceX += 33
            }
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
                var config = UIButton.Configuration.plain()
                config.title = candidate.text
                config.titleLineBreakMode = .byTruncatingTail
                config.contentInsets = .zero
                let button = UIButton(configuration: config)
                button.titleLabel?.numberOfLines = 1
                button.titleLabel?.lineBreakMode = .byTruncatingTail
                let textWidth = (candidate.text as NSString).size(withAttributes: [.font: font]).width
                let width = max(48, ceil(textWidth) + 20)
                button.frame = CGRect(x: candidateX, y: 0, width: width, height: 34)
                button.accessibilityValue = String(index)
                button.addTarget(self, action: #selector(selectCandidate(_:)), for: .touchUpInside)
                candidateBar.addSubview(button)
                candidateX += width + 6
            }
            candidateContentWidth = candidateX
        }
        sentenceScrollView.setContentOffset(.zero, animated: false)
        candidateScrollView.setContentOffset(.zero, animated: false)
        view.setNeedsLayout()
    }
}
