import SwiftUI
import Foundation

struct ContentView: View {
    @State private var ipaURL: URL? = nil
    @State private var logMessages: [String] = ["IPAファイルをドラッグ＆ドロップしてください。"]

    var body: some View {
        VStack(spacing: 20) {
            Text("simforge GUI Helper")
                .font(.largeTitle)
                .padding(.top)

            // ドラッグ＆ドロップエリア
            RoundedRectangle(cornerRadius: 8)
                .strokeBorder(Color.gray, lineWidth: 2)
                .background(RoundedRectangle(cornerRadius: 8).fill(Color.gray.opacity(0.1)))
                .frame(height: 200)
                .overlay(
                    Text("ここにIPAファイルをドロップ")
                        .foregroundColor(.secondary)
                )
                .onDrop(of: [.fileURL], isTargeted: nil) { providers in
                    if let item = providers.first {
                        item.loadObject(ofClass: URL.self) { (url, error) in
                            if let url = url as? URL {
                                DispatchQueue.main.async {
                                    self.ipaURL = url
                                    self.addLog("IPAファイルを選択: \(url.lastPathComponent)")
                                }
                            }
                        }
                        return true
                    }
                    return false
                }

            Button("処理を開始") {
                guard let ipaURL = ipaURL else {
                    addLog("まずIPAファイルをドロップしてください。")
                    return
                }
                addLog("処理を開始します...")
                processIPA(ipaURL)
            }
            .padding()

            // ログ表示エリア（スクロール可能）
            ScrollView {
                VStack(alignment: .leading) {
                    ForEach(logMessages.indices, id: \.self) { index in
                        Text(logMessages[index])
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.bottom, 2)
                    }
                }
                .padding()
            }
            .background(Color.black.opacity(0.05))
            .frame(height: 200)
            .cornerRadius(8)
        }
        .frame(width: 500, height: 700)
    }

    // ログ追加用のヘルパー関数
    func addLog(_ message: String) {
        let timestamped = "\(timestamp()) \(message)"
        logMessages.append(timestamped)
    }

    // 現在時刻（HH:mm:ss形式）の取得
    func timestamp() -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss"
        return formatter.string(from: Date())
    }

    // --- Step 2: IPAファイルの解凍 ---
    func processIPA(_ ipaURL: URL) {
        guard let documentsDirectory = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first else {
            DispatchQueue.main.async {
                addLog("Documentsディレクトリが取得できません。")
            }
            return
        }
        let workingDirectory = documentsDirectory.appendingPathComponent("ipa_extracted")
        // 既存の作業ディレクトリがあれば削除
        try? FileManager.default.removeItem(at: workingDirectory)

        let unzipTask = Process()
        unzipTask.executableURL = URL(fileURLWithPath: "/usr/bin/unzip")
        unzipTask.arguments = [ipaURL.path, "-d", workingDirectory.path]

        unzipTask.terminationHandler = { process in
            DispatchQueue.main.async {
                if process.terminationStatus == 0 {
                    addLog("IPA解凍完了。Payloadフォルダから.appを検索します。")
                    convertAndSignApp(at: workingDirectory)
                } else {
                    addLog("解凍に失敗しました。終了コード: \(process.terminationStatus)")
                }
            }
        }

        do {
            try unzipTask.run()
        } catch {
            DispatchQueue.main.async {
                addLog("解凍処理の起動に失敗しました: \(error)")
            }
        }
    }

    // --- Step 3: simforge convert の実行 ---
    func convertAndSignApp(at workingDirectory: URL) {
        let payloadDirectory = workingDirectory.appendingPathComponent("Payload")
        do {
            let payloadContents = try FileManager.default.contentsOfDirectory(at: payloadDirectory, includingPropertiesForKeys: nil)
            guard let appURL = payloadContents.first(where: { $0.pathExtension == "app" }) else {
                DispatchQueue.main.async {
                    addLog("Payload内に.appが見つかりません。")
                }
                return
            }

            // simforgeの存在チェック
            let simforgePath = "/usr/local/bin/simforge"
            if !FileManager.default.fileExists(atPath: simforgePath) {
                DispatchQueue.main.async {
                    addLog("simforgeが \(simforgePath) に存在しません。サンドボックス制約等を確認してください。")
                }
                return
            }

            let convertTask = Process()
            convertTask.executableURL = URL(fileURLWithPath: simforgePath)
            convertTask.arguments = ["convert", appURL.path]

            convertTask.terminationHandler = { process in
                DispatchQueue.main.async {
                    if process.terminationStatus == 0 {
                        addLog("simforge convert 完了。コード署名を開始します。")
                        codesignApp(at: appURL)
                    } else {
                        addLog("simforge convert でエラーが発生しました。終了コード: \(process.terminationStatus)")
                    }
                }
            }

            try convertTask.run()
        } catch {
            DispatchQueue.main.async {
                addLog("Payloadフォルダの読み込みに失敗しました: \(error)")
            }
        }
    }

    // --- Step 4: メインアプリのコード署名 ---
    func codesignApp(at appURL: URL) {
        let codesignTask = Process()
        codesignTask.executableURL = URL(fileURLWithPath: "/usr/bin/codesign")
        // メインバイナリの署名（--deep は使用せず、Frameworksは個別に署名する）
        codesignTask.arguments = ["-f", "-s", "-", appURL.path]

        codesignTask.terminationHandler = { process in
            DispatchQueue.main.async {
                if process.terminationStatus == 0 {
                    addLog("アプリ本体のコード署名完了。")
                    // 続いて、Frameworks内の全サブディレクトリを再帰的に署名する
                    codesignFrameworks(at: appURL)
                } else {
                    addLog("アプリ本体のコード署名でエラーが発生しました。終了コード: \(process.terminationStatus)")
                }
            }
        }

        do {
            try codesignTask.run()
        } catch {
            DispatchQueue.main.async {
                addLog("アプリ本体のコード署名の起動に失敗しました: \(error)")
            }
        }
    }

    // --- Step 4-2: Frameworks内の全サブディレクトリに対して再帰的にcodesignを実行 ---
    func codesignFrameworks(at appURL: URL) {
        let frameworksURL = appURL.appendingPathComponent("Frameworks")
        // Frameworksディレクトリが存在しなければ次の処理へ
        guard FileManager.default.fileExists(atPath: frameworksURL.path) else {
            addLog("Frameworksディレクトリが存在しません。")
            exportAndInstallApp(at: appURL)
            return
        }

        let group = DispatchGroup()
        var anyErrorOccurred = false

        // 再帰的にFrameworks以下の全ディレクトリを走査
        if let enumerator = FileManager.default.enumerator(at: frameworksURL, includingPropertiesForKeys: nil) {
            for case let fileURL as URL in enumerator {
                // 署名対象はディレクトリ（＝バンドル形式のFramework）とする
                var isDir: ObjCBool = false
                if FileManager.default.fileExists(atPath: fileURL.path, isDirectory: &isDir), isDir.boolValue {
                    group.enter()
                    let process = Process()
                    process.executableURL = URL(fileURLWithPath: "/usr/bin/codesign")
                    process.arguments = ["-f", "-s", "-", fileURL.path]
                    process.terminationHandler = { p in
                        if p.terminationStatus != 0 {
                            anyErrorOccurred = true
                        }
                        group.leave()
                    }
                    do {
                        try process.run()
                    } catch {
                        anyErrorOccurred = true
                        group.leave()
                    }
                }
            }
        }

        group.notify(queue: .main) {
            if anyErrorOccurred {
                addLog("Frameworksの署名中にエラーが発生しました。")
            } else {
                addLog("Frameworksの署名完了。")
            }
            exportAndInstallApp(at: appURL)
        }
    }

    // --- Step 5: 署名済み.appを元のIPAファイルと同じディレクトリに移動し、作業ディレクトリを削除 ---
    func exportAndInstallApp(at appURL: URL) {
        guard let originalIPAURL = ipaURL else {
            DispatchQueue.main.async { addLog("元のIPAファイルが不明です。") }
            return
        }
        let parentDirectory = originalIPAURL.deletingLastPathComponent()
        let destinationURL = parentDirectory.appendingPathComponent(appURL.lastPathComponent)

        do {
            if FileManager.default.fileExists(atPath: destinationURL.path) {
                try FileManager.default.removeItem(at: destinationURL)
            }
            try FileManager.default.moveItem(at: appURL, to: destinationURL)
            addLog("署名済みアプリを配置しました。シミュレータへのインストールを試みます。")
        } catch {
            DispatchQueue.main.async {
                addLog("アプリの配置に失敗しました: \(error)")
            }
            return
        }

        // 作業ディレクトリ（解凍フォルダ）の削除
        if let documentsDirectory = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first {
            let workingDirectory = documentsDirectory.appendingPathComponent("ipa_extracted")
            try? FileManager.default.removeItem(at: workingDirectory)
        }

        installOnSimulator(appURL: destinationURL)
    }

    // --- Step 6: シミュレータが実行中の場合は、xcrun simctl install booted でインストール ---
    func installOnSimulator(appURL: URL) {
        let listTask = Process()
        let pipe = Pipe()
        listTask.executableURL = URL(fileURLWithPath: "/usr/bin/xcrun")
        listTask.arguments = ["simctl", "list", "devices", "booted"]
        listTask.standardOutput = pipe

        do {
            try listTask.run()
            listTask.waitUntilExit()
        } catch {
            DispatchQueue.main.async {
                addLog("シミュレータの状態取得に失敗しました: \(error)")
            }
            return
        }

        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        let output = String(data: data, encoding: .utf8) ?? ""

        if output.contains("Booted") {
            let installTask = Process()
            installTask.executableURL = URL(fileURLWithPath: "/usr/bin/xcrun")
            installTask.arguments = ["simctl", "install", "booted", appURL.path]

            installTask.terminationHandler = { process in
                DispatchQueue.main.async {
                    if process.terminationStatus == 0 {
                        addLog("シミュレータへのインストールに成功しました。")
                    } else {
                        addLog("シミュレータへのインストールに失敗しました。終了コード: \(process.terminationStatus)")
                    }
                }
            }

            do {
                try installTask.run()
            } catch {
                DispatchQueue.main.async {
                    addLog("シミュレータへのインストール処理の起動に失敗しました: \(error)")
                }
            }
        } else {
            DispatchQueue.main.async {
                addLog("シミュレータは起動していません。処理を終了します。")
            }
        }
    }
}

struct ContentView_Previews: PreviewProvider {
    static var previews: some View {
        ContentView()
    }
}
