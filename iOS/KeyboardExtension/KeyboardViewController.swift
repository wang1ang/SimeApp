import UIKit

final class KeyboardViewController: UIInputViewController {
    private let composition = Composition()
    private let sentenceLabel = UILabel()
    private let candidateScrollView = UIScrollView()
    private let candidateBar = UIStackView()
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

    override func textWillChange(_ textInput: UITextInput?) {
        super.textWillChange(textInput)
    }

    override func textDidChange(_ textInput: UITextInput?) {
        super.textDidChange(textInput)
    }

    private func setupView() {
        view.backgroundColor = .secondarySystemBackground
        let root = UIStackView()
        root.axis = .vertical
        root.spacing = 4
        root.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(root)
        NSLayoutConstraint.activate([
            root.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 5),
            root.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -5),
            root.topAnchor.constraint(equalTo: view.topAnchor, constant: 6),
            root.bottomAnchor.constraint(equalTo: view.bottomAnchor, constant: -6)
        ])

        sentenceLabel.font = .preferredFont(forTextStyle: .body)
        sentenceLabel.textColor = .label
        sentenceLabel.textAlignment = .left
        sentenceLabel.numberOfLines = 1
        root.addArrangedSubview(sentenceLabel)
        sentenceLabel.heightAnchor.constraint(equalToConstant: 30).isActive = true

        candidateScrollView.showsHorizontalScrollIndicator = false
        candidateScrollView.addSubview(candidateBar)
        candidateBar.axis = .horizontal
        candidateBar.spacing = 12
        candidateBar.distribution = .equalSpacing
        candidateBar.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            candidateBar.leadingAnchor.constraint(equalTo: candidateScrollView.leadingAnchor, constant: 8),
            candidateBar.trailingAnchor.constraint(equalTo: candidateScrollView.trailingAnchor, constant: -8),
            candidateBar.topAnchor.constraint(equalTo: candidateScrollView.topAnchor),
            candidateBar.bottomAnchor.constraint(equalTo: candidateScrollView.bottomAnchor),
            candidateBar.heightAnchor.constraint(equalTo: candidateScrollView.heightAnchor),
            candidateBar.widthAnchor.constraint(greaterThanOrEqualTo: candidateScrollView.widthAnchor, constant: -16)
        ])
        candidateScrollView.heightAnchor.constraint(equalToConstant: 34).isActive = true
        root.addArrangedSubview(candidateScrollView)

        keyboardStack.axis = .vertical
        keyboardStack.spacing = 5
        root.addArrangedSubview(keyboardStack)
        rebuildKeyboard()
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
        case "换行": commitComposition(); textDocumentProxy.insertText("\n")
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
                render()
            }
        }
    }

    private func delete() {
        if composition.isComposing {
            composition.delete()
            render()
        } else {
            textDocumentProxy.deleteBackward()
        }
    }

    private func space() {
        if let text = composition.commitBestOrRaw() {
            textDocumentProxy.insertText(text)
        } else {
            textDocumentProxy.insertText(" ")
        }
        render()
    }

    private func commitComposition() {
        if let text = composition.commitBestOrRaw() {
            textDocumentProxy.insertText(text)
        }
        render()
    }

    @objc private func selectCandidate(_ sender: UIButton) {
        guard let index = sender.accessibilityValue.flatMap(Int.init),
              let text = composition.select(index) else { return }
        textDocumentProxy.insertText(text)
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
        let topText = composition.candidates.first?.text ?? ""
        sentenceLabel.text = composition.isComposing ? composition.committed + topText : ""
        candidateBar.arrangedSubviews.forEach { $0.removeFromSuperview() }
        if composition.candidates.isEmpty {
            let hint = UILabel()
            hint.text = composition.isComposing ? composition.preedit : ""
            hint.textColor = .secondaryLabel
            hint.textAlignment = .left
            candidateBar.addArrangedSubview(hint)
        } else {
            for (index, candidate) in composition.candidates.enumerated() {
                var config = UIButton.Configuration.plain()
                config.title = candidate.text
                let button = UIButton(configuration: config)
                button.titleLabel?.numberOfLines = 1
                button.titleLabel?.lineBreakMode = .byClipping
                button.widthAnchor.constraint(greaterThanOrEqualToConstant: 48).isActive = true
                button.setContentHuggingPriority(.required, for: .horizontal)
                button.accessibilityValue = String(index)
                button.addTarget(self, action: #selector(selectCandidate(_:)), for: .touchUpInside)
                candidateBar.addArrangedSubview(button)
            }
        }
    }
}
