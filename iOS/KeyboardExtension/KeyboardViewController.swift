import UIKit

final class KeyboardViewController: UIInputViewController {
    private let composition = Composition()
    private let candidateBar = UIStackView()
    private let keyboardStack = UIStackView()
    private let preeditLabel = UILabel()
    private var chineseMode = true
    private var numberMode = false

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

        let preedit = UIView()
        preedit.translatesAutoresizingMaskIntoConstraints = false
        preedit.heightAnchor.constraint(equalToConstant: 25).isActive = true
        preeditLabel.font = .preferredFont(forTextStyle: .caption1)
        preeditLabel.textColor = .secondaryLabel
        preeditLabel.translatesAutoresizingMaskIntoConstraints = false
        preedit.addSubview(preeditLabel)
        NSLayoutConstraint.activate([
            preeditLabel.leadingAnchor.constraint(equalTo: preedit.leadingAnchor, constant: 8),
            preeditLabel.centerYAnchor.constraint(equalTo: preedit.centerYAnchor)
        ])
        root.addArrangedSubview(preedit)

        candidateBar.axis = .horizontal
        candidateBar.spacing = 4
        candidateBar.distribution = .fillEqually
        candidateBar.heightAnchor.constraint(equalToConstant: 39).isActive = true
        root.addArrangedSubview(candidateBar)

        keyboardStack.axis = .vertical
        keyboardStack.spacing = 7
        root.addArrangedSubview(keyboardStack)
        rebuildKeyboard()
    }

    private func makeRow(_ keys: [String]) -> UIStackView {
        let row = UIStackView()
        row.axis = .horizontal
        row.spacing = 5
        row.distribution = .fillEqually
        row.heightAnchor.constraint(equalToConstant: 43).isActive = true
        keys.forEach { row.addArrangedSubview(keyButton($0)) }
        return row
    }

    private func makeBottomRow() -> UIStackView {
        let row = UIStackView()
        row.axis = .horizontal
        row.spacing = 5
        row.distribution = .fillProportionally
        row.heightAnchor.constraint(equalToConstant: 43).isActive = true
        [numberMode ? "ABC" : "123", "🌐", "中/En", "space", "return", "delete"].forEach {
            row.addArrangedSubview(keyButton($0))
        }
        return row
    }

    private func keyButton(_ title: String) -> UIButton {
        var config = UIButton.Configuration.filled()
        config.title = title == "space" ? "空格" : title == "return" ? "换行" : title == "delete" ? "⌫" : title
        config.baseBackgroundColor = .tertiarySystemBackground
        config.baseForegroundColor = .label
        config.cornerStyle = .medium
        let button = UIButton(configuration: config)
        button.titleLabel?.font = .systemFont(ofSize: 16)
        button.addTarget(self, action: #selector(keyTapped(_:)), for: .touchUpInside)
        return button
    }

    @objc private func keyTapped(_ sender: UIButton) {
        guard let title = sender.configuration?.title else { return }
        switch title {
        case "⌫": delete()
        case "空格": space()
        case "换行": commitComposition(); textDocumentProxy.insertText("\n")
        case "🌐": advanceToNextInputMode()
        case "中/En":
            commitComposition()
            chineseMode.toggle()
            render()
        case "123", "ABC":
            commitComposition()
            numberMode.toggle()
            render()
        default:
            if numberMode || !chineseMode {
                textDocumentProxy.insertText(title.lowercased())
            } else {
                composition.append(title)
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

    private func selectCandidate(_ sender: UIButton) {
        guard let index = sender.accessibilityValue.flatMap(Int.init),
              let text = composition.select(index) else { return }
        textDocumentProxy.insertText(text)
        render()
    }

    private func rebuildKeyboard() {
        keyboardStack.arrangedSubviews.forEach { $0.removeFromSuperview() }
        let rows = numberMode ? ["123", "456", "789"] : ["QWERTYUIOP", "ASDFGHJKL", "ZXCVBNM"]
        for row in rows {
            keyboardStack.addArrangedSubview(makeRow(Array(row).map(String.init)))
        }
        keyboardStack.addArrangedSubview(makeBottomRow())
    }

    private func render() {
        rebuildKeyboard()
        preeditLabel.text = composition.isComposing ? composition.preedit : (numberMode ? "数字" : (chineseMode ? "中文" : "English"))
        candidateBar.arrangedSubviews.forEach { $0.removeFromSuperview() }
        if composition.candidates.isEmpty {
            let hint = UILabel()
            hint.text = chineseMode && !numberMode ? "输入拼音" : ""
            hint.textColor = .secondaryLabel
            hint.textAlignment = .center
            candidateBar.addArrangedSubview(hint)
        } else {
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
