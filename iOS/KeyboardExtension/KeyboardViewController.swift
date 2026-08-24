import UIKit

final class KeyboardViewController: UIInputViewController {
    private let composition = Composition()
    private let candidateBar = UIStackView()
    private let keyboardStack = UIStackView()
    private var chineseMode = true
    private var numberMode = false
    private var shifted = false

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
        root.spacing = 7
        root.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(root)
        NSLayoutConstraint.activate([
            root.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 5),
            root.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -5),
            root.topAnchor.constraint(equalTo: view.topAnchor, constant: 6),
            root.bottomAnchor.constraint(equalTo: view.bottomAnchor, constant: -6)
        ])

        candidateBar.axis = .horizontal
        candidateBar.spacing = 8
        candidateBar.distribution = .fillProportionally
        candidateBar.heightAnchor.constraint(equalToConstant: 39).isActive = true
        root.addArrangedSubview(candidateBar)

        keyboardStack.axis = .vertical
        keyboardStack.spacing = 7
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
        let mode = keyButton(numberMode ? "ABC" : "123")
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
            render()
        case "中/英":
            commitComposition()
            chineseMode.toggle()
            shifted = false
            render()
        case "123", "ABC":
            commitComposition()
            numberMode.toggle()
            shifted = false
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
            for row in ["123", "456", "789"] {
                keyboardStack.addArrangedSubview(makeRow(Array(row).map(String.init), indented: true))
            }
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
        rebuildKeyboard()
        candidateBar.arrangedSubviews.forEach { $0.removeFromSuperview() }
        if composition.candidates.isEmpty {
            let hint = UILabel()
            hint.text = composition.isComposing ? composition.preedit : ""
            hint.textColor = .secondaryLabel
            hint.textAlignment = .left
            candidateBar.addArrangedSubview(hint)
        } else {
            let preedit = UILabel()
            preedit.text = composition.preedit
            preedit.font = .preferredFont(forTextStyle: .body)
            preedit.textColor = .secondaryLabel
            preedit.textAlignment = .center
            preedit.widthAnchor.constraint(greaterThanOrEqualToConstant: 54).isActive = true
            candidateBar.addArrangedSubview(preedit)
            for (index, candidate) in composition.candidates.enumerated() {
                var config = UIButton.Configuration.plain()
                config.title = "\(index + 1). \(candidate.text)"
                let button = UIButton(configuration: config)
                button.accessibilityValue = String(index)
                button.addTarget(self, action: #selector(selectCandidate(_:)), for: .touchUpInside)
                candidateBar.addArrangedSubview(button)
            }
        }
    }
}
