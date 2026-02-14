import AppKit
import CryptoKit
import Darwin
import Foundation
import Network
import os

// MARK: - Local Callback Server

/// A lightweight HTTP server that listens on a dynamically assigned localhost port for OAuth callbacks
/// SAFETY: @unchecked Sendable is used because:
/// 1. All network operations are serialized through a dedicated DispatchQueue (`queue`)
/// 2. The listener and onCodeReceived are only modified from that queue
/// 3. The logger is thread-safe by design (os.Logger)
private final nonisolated class LocalCallbackServer: @unchecked Sendable {
    private final class StartupWaitState: @unchecked Sendable {
        private let lock = NSLock()
        private let semaphore = DispatchSemaphore(value: 0)
        private var result: Result<UInt16, Error>?

        func complete(_ result: Result<UInt16, Error>) {
            lock.lock()
            defer { lock.unlock() }
            guard self.result == nil else { return }
            self.result = result
            semaphore.signal()
        }

        func wait(timeout: TimeInterval) -> Result<UInt16, Error>? {
            let waitResult = semaphore.wait(timeout: .now() + timeout)
            guard waitResult == .success else {
                return nil
            }

            lock.lock()
            defer { lock.unlock() }
            return result
        }
    }

    private var listener: NWListener?
    private var onCodeReceived: ((String, String?) -> Void)? // (code, state)
    private let logger = Logger(subsystem: "com.flowstay.core", category: "LocalCallbackServer")
    private let queue = DispatchQueue(label: "com.flowstay.oauth.server")

    /// Start the server on localhost.
    /// - Parameter preferredPort: Optional fixed port. If nil, the system assigns a free port.
    /// - Returns: The port number the server is listening on
    func start(preferredPort: UInt16? = nil, onCode: @escaping (String, String?) -> Void) throws -> UInt16 {
        onCodeReceived = onCode

        let parameters = NWParameters.tcp
        parameters.allowLocalEndpointReuse = true
        parameters.includePeerToPeer = false

        let nwPort: NWEndpoint.Port
        if let preferredPort {
            guard let fixedPort = NWEndpoint.Port(rawValue: preferredPort) else {
                throw NSError(
                    domain: "com.flowstay.oauth",
                    code: -10,
                    userInfo: [NSLocalizedDescriptionKey: "Invalid callback port"]
                )
            }
            nwPort = fixedPort
        } else {
            nwPort = .any
        }

        listener = try NWListener(using: parameters, on: nwPort)
        let startupState = StartupWaitState()

        listener?.stateUpdateHandler = { [weak self] state in
            guard let self else { return }

            switch state {
            case .ready:
                if let port = listener?.port, port.rawValue != 0 {
                    logger.info("[Server] Listening on port \(port.rawValue)")
                    startupState.complete(.success(port.rawValue))
                } else {
                    let error = NSError(
                        domain: "com.flowstay.oauth",
                        code: -1,
                        userInfo: [NSLocalizedDescriptionKey: "Failed to bind to any port"]
                    )
                    startupState.complete(.failure(error))
                }
            case let .failed(error):
                logger.error("[Server] Failed: \(error.localizedDescription)")
                startupState.complete(.failure(error))
            case .cancelled:
                logger.info("[Server] Cancelled")
            default:
                break
            }
        }

        listener?.newConnectionHandler = { [weak self] connection in
            self?.handleConnection(connection)
        }

        listener?.start(queue: queue)

        guard let finalResult = startupState.wait(timeout: 3.0) else {
            stop()
            throw NSError(
                domain: "com.flowstay.oauth",
                code: -2,
                userInfo: [NSLocalizedDescriptionKey: "OAuth callback server startup timed out"]
            )
        }

        switch finalResult {
        case let .success(port):
            return port
        case let .failure(error):
            stop()
            throw error
        }
    }

    /// Stop the server
    func stop() {
        listener?.cancel()
        listener = nil
        onCodeReceived = nil
        logger.info("[Server] Stopped")
    }

    private func handleConnection(_ connection: NWConnection) {
        connection.stateUpdateHandler = { [weak self] state in
            guard let self else {
                connection.cancel()
                return
            }

            switch state {
            case .ready:
                // Defense in depth: reject non-loopback peers if binding changes in the future.
                if !isLoopbackConnection(connection.endpoint) {
                    logger.error("[Server] Rejected non-loopback callback connection")
                    connection.cancel()
                    return
                }
                receiveData(from: connection)
            case let .failed(error):
                logger.error("[Server] Connection failed: \(error.localizedDescription)")
                connection.cancel()
            default:
                break
            }
        }
        connection.start(queue: queue)
    }

    private func isLoopbackConnection(_ endpoint: NWEndpoint) -> Bool {
        guard case let .hostPort(host, _) = endpoint else {
            return false
        }

        let value = String(describing: host).lowercased()
        return value == "127.0.0.1" ||
            value == "::1" ||
            value == "localhost" ||
            value.contains("127.0.0.1") ||
            value.contains("localhost")
    }

    private func receiveData(from connection: NWConnection) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 4096) { [weak self] data, _, isComplete, error in
            guard let self else { return }

            if let error {
                logger.error("[Server] Receive error: \(error.localizedDescription)")
                connection.cancel()
                return
            }

            if let data, let request = String(data: data, encoding: .utf8) {
                logger.debug("[Server] Received request")

                // Parse the HTTP request to extract the code and state parameters
                if let (code, state) = extractCodeAndState(from: request) {
                    logger.info("[Server] Extracted authorization code")

                    // Send success response
                    sendSuccessResponse(to: connection) {
                        // Notify the callback with the code and state
                        DispatchQueue.main.async {
                            self.onCodeReceived?(code, state)
                        }
                    }
                } else {
                    // Send error response
                    sendErrorResponse(to: connection)
                }
            }

            if isComplete {
                connection.cancel()
            }
        }
    }

    /// Extract code and state from OAuth callback request
    /// - Returns: Tuple of (code, state) or nil if missing
    private func extractCodeAndState(from request: String) -> (code: String, state: String?)? {
        // Parse HTTP request line: GET /callback?code=xxx&state=yyy HTTP/1.1
        guard let firstLine = request.components(separatedBy: "\r\n").first else { return nil }
        let parts = firstLine.split(separator: " ")
        guard parts.count >= 2, parts[0] == "GET" else { return nil }

        let urlPart = String(parts[1])

        // Parse URL query parameters
        guard let url = URL(string: "http://localhost\(urlPart)"),
              let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              components.path == "/callback",
              let code = components.queryItems?.first(where: { $0.name == "code" })?.value,
              !code.isEmpty
        else {
            return nil
        }

        let state = components.queryItems?.first(where: { $0.name == "state" })?.value
        return (code, state)
    }

    private func sendSuccessResponse(to connection: NWConnection, completion: @escaping @Sendable () -> Void) {
        let html = """
        <!DOCTYPE html>
        <html>
        <head>
            <title>Flowstay - Connected</title>
            <style>
                body {
                    font-family: -apple-system, BlinkMacSystemFont, 'Segoe UI', Roboto, sans-serif;
                    display: flex;
                    justify-content: center;
                    align-items: center;
                    height: 100vh;
                    margin: 0;
                    background: linear-gradient(135deg, #667eea 0%, #764ba2 100%);
                    color: white;
                }
                .container {
                    text-align: center;
                    padding: 40px;
                    background: rgba(255,255,255,0.1);
                    border-radius: 20px;
                    backdrop-filter: blur(10px);
                }
                h1 { margin-bottom: 10px; }
                p { opacity: 0.9; }
                .checkmark {
                    font-size: 64px;
                    margin-bottom: 20px;
                }
            </style>
        </head>
        <body>
            <div class="container">
                <div class="checkmark">&#10003;</div>
                <h1>Connected to OpenRouter</h1>
                <p>You can close this tab and return to Flowstay.</p>
            </div>
        </body>
        </html>
        """
        sendHTMLResponse(to: connection, statusLine: "200 OK", html: html, completion: completion)
    }

    private func sendErrorResponse(to connection: NWConnection) {
        let html = """
        <!DOCTYPE html>
        <html>
        <head>
            <title>Flowstay - Error</title>
            <style>
                body {
                    font-family: -apple-system, BlinkMacSystemFont, sans-serif;
                    display: flex;
                    justify-content: center;
                    align-items: center;
                    height: 100vh;
                    margin: 0;
                    background: #f5f5f5;
                }
                .container { text-align: center; padding: 40px; }
                h1 { color: #e74c3c; }
            </style>
        </head>
        <body>
            <div class="container">
                <h1>Authentication Failed</h1>
                <p>Please try again from Flowstay.</p>
            </div>
        </body>
        </html>
        """
        sendHTMLResponse(to: connection, statusLine: "400 Bad Request", html: html)
    }

    private func sendHTMLResponse(
        to connection: NWConnection,
        statusLine: String,
        html: String,
        completion: (@Sendable () -> Void)? = nil
    ) {
        let response = """
        HTTP/1.1 \(statusLine)\r
        Content-Type: text/html; charset=utf-8\r
        Content-Length: \(html.utf8.count)\r
        Connection: close\r
        \r
        \(html)
        """

        connection.send(content: response.data(using: .utf8), completion: .contentProcessed { [weak self] error in
            if let error {
                self?.logger.error("[Server] Send error: \(error.localizedDescription)")
            }
            connection.cancel()
            completion?()
        })
    }
}

// MARK: - OAuth Manager

/// Manages OAuth PKCE authentication flow with OpenRouter
@MainActor
public class OpenRouterOAuthManager: ObservableObject {
    public static let shared = OpenRouterOAuthManager()

    @Published public var isAuthenticating = false
    @Published public var authError: String?
    @Published public private(set) var isConnected = false

    private var codeVerifier: String?
    private var stateParameter: String? // CSRF protection
    private var callbackServer: LocalCallbackServer?
    private var authenticationTimeoutTask: Task<Void, Never>?
    private let keychainService: KeychainServiceProtocol
    private let networkService = OpenRouterNetworkService()
    private let logger = Logger(subsystem: "com.flowstay.core", category: "OpenRouterOAuth")

    private init(keychainService: KeychainServiceProtocol = KeychainService.shared) {
        self.keychainService = keychainService

        // Check initial connection status
        Task {
            await checkConnectionStatus()
        }
    }

    /// Check if connected to OpenRouter
    public func checkConnectionStatus() async {
        isConnected = await keychainService.hasAPIKey(for: AIProviderIdentifier.openRouter.rawValue)
    }

    /// Start OAuth PKCE flow - opens browser
    public func startAuthentication() {
        guard !isAuthenticating else {
            logger.info("[OAuth] Authentication already in progress; ignoring duplicate start request")
            return
        }

        callbackServer?.stop()
        callbackServer = nil
        authenticationTimeoutTask?.cancel()
        authenticationTimeoutTask = nil

        isAuthenticating = true
        authError = nil

        // Generate PKCE code verifier (43-128 chars, URL-safe)
        codeVerifier = generateCodeVerifier()

        // Generate state parameter for CSRF protection
        stateParameter = generateStateParameter()

        guard let verifier = codeVerifier, let state = stateParameter else {
            authError = "Failed to generate security codes"
            isAuthenticating = false
            return
        }

        // Start local callback server. Prefer OpenRouter's common localhost port,
        // but gracefully fallback if the port is already in use on the machine.
        let callbackPort: UInt16
        do {
            callbackPort = try startCallbackServerWithFallbackPorts()
        } catch {
            logger.error("[OAuth] Failed to start callback server: \(error.localizedDescription)")
            authError = "Failed to start authentication server: \(error.localizedDescription)"
            isAuthenticating = false
            return
        }

        // Generate code challenge (SHA256 hash of verifier, base64url encoded)
        let codeChallenge = generateCodeChallenge(from: verifier)

        // Build authorization URL with localhost callback
        var components = URLComponents(string: "https://openrouter.ai/auth")!
        components.queryItems = [
            URLQueryItem(name: "callback_url", value: "http://localhost:\(callbackPort)/callback"),
            URLQueryItem(name: "code_challenge", value: codeChallenge),
            URLQueryItem(name: "code_challenge_method", value: "S256"),
            URLQueryItem(name: "state", value: state), // CSRF protection
        ]

        guard let url = components.url else {
            authError = "Failed to build authorization URL"
            isAuthenticating = false
            callbackServer?.stop()
            return
        }

        logger.info("[OAuth] Opening browser for authentication")
        NSWorkspace.shared.open(url)
        scheduleAuthenticationTimeout(seconds: 180)
    }

    /// Handle the authorization code received from the callback server
    private func handleAuthorizationCode(_ code: String, state: String?) async {
        logger.info("[OAuth] Received authorization code")
        authenticationTimeoutTask?.cancel()
        authenticationTimeoutTask = nil

        // Stop the callback server
        callbackServer?.stop()
        callbackServer = nil

        // Validate state parameter for CSRF protection
        guard let expectedState = stateParameter else {
            authError = "Authentication session expired. Please try again."
            isAuthenticating = false
            logger.error("[OAuth] No state parameter stored")
            return
        }

        guard state == expectedState else {
            authError = "Security validation failed. Please try again."
            isAuthenticating = false
            stateParameter = nil
            codeVerifier = nil
            logger.error("[OAuth] State parameter mismatch - possible CSRF attack")
            return
        }

        guard let verifier = codeVerifier else {
            authError = "Authentication session expired. Please try again."
            isAuthenticating = false
            stateParameter = nil
            logger.error("[OAuth] No code verifier stored")
            return
        }

        do {
            logger.info("[OAuth] Exchanging code for API key")
            let apiKey = try await networkService.exchangeCodeForKey(code: code, codeVerifier: verifier)

            await keychainService.saveAPIKey(apiKey, for: AIProviderIdentifier.openRouter.rawValue)
            codeVerifier = nil // Clear after use
            stateParameter = nil

            isAuthenticating = false
            isConnected = true
            authError = nil

            logger.info("[OAuth] Authentication completed successfully")

            // Post notification for UI updates
            NotificationCenter.default.post(name: .openRouterAuthenticationCompleted, object: nil)

        } catch {
            logger.error("[OAuth] Failed to exchange code: \(error.localizedDescription)")
            authError = error.localizedDescription
            isAuthenticating = false
            codeVerifier = nil
            stateParameter = nil
        }
    }

    /// Disconnect from OpenRouter (delete API key)
    public func disconnect() async {
        await keychainService.deleteAPIKey(for: AIProviderIdentifier.openRouter.rawValue)
        isConnected = false
        logger.info("[OAuth] Disconnected from OpenRouter")

        NotificationCenter.default.post(name: .openRouterDisconnected, object: nil)
    }

    /// Cancel authentication in progress
    public func cancelAuthentication() {
        authenticationTimeoutTask?.cancel()
        authenticationTimeoutTask = nil
        callbackServer?.stop()
        callbackServer = nil
        isAuthenticating = false
        codeVerifier = nil
        stateParameter = nil
        authError = nil
        logger.info("[OAuth] Authentication cancelled")
    }

    private func scheduleAuthenticationTimeout(seconds: UInt64) {
        authenticationTimeoutTask?.cancel()
        authenticationTimeoutTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: seconds * 1_000_000_000)
            guard !Task.isCancelled else { return }
            await MainActor.run {
                guard let self, self.isAuthenticating else { return }
                self.logger.warning("[OAuth] Authentication timed out after \(seconds) seconds")
                self.cancelAuthentication()
                self.authError = "Authentication timed out. Please try again."
            }
        }
    }

    private func startCallbackServerWithRetry(preferredPort: UInt16?, maxAttempts: Int) throws -> UInt16 {
        var lastError: Error?

        for attempt in 1 ... maxAttempts {
            let server = LocalCallbackServer()
            do {
                let port = try server.start(preferredPort: preferredPort) { [weak self] code, state in
                    Task { @MainActor in
                        await self?.handleAuthorizationCode(code, state: state)
                    }
                }

                callbackServer = server
                if attempt > 1 {
                    logger.info("[OAuth] Callback server started successfully on retry \(attempt)")
                }
                return port
            } catch {
                lastError = error
                server.stop()
                callbackServer = nil
                logger.error("[OAuth] Callback server start attempt \(attempt) failed: \(error.localizedDescription)")
                if attempt < maxAttempts {
                    Thread.sleep(forTimeInterval: 0.15)
                }
            }
        }

        throw lastError ?? NSError(
            domain: "com.flowstay.oauth",
            code: -3,
            userInfo: [NSLocalizedDescriptionKey: "Unable to start callback server"]
        )
    }

    private func startCallbackServerWithFallbackPorts() throws -> UInt16 {
        let candidatePorts: [UInt16?] = [3000, 3001, 3002, nil]
        var lastError: Error?

        for candidatePort in candidatePorts {
            do {
                let port = try startCallbackServerWithRetry(preferredPort: candidatePort, maxAttempts: 2)
                if let candidatePort, candidatePort != 3000 {
                    logger.warning("[OAuth] Port 3000 unavailable, using fallback port \(candidatePort)")
                }
                if candidatePort == nil {
                    logger.warning("[OAuth] Fixed localhost ports unavailable, using dynamic callback port")
                }
                return port
            } catch {
                lastError = error

                if let candidatePort, isAddressInUseError(error) {
                    logger.warning("[OAuth] Callback port \(candidatePort) is already in use; trying fallback")
                    continue
                }

                // Non-port-collision errors should fail fast.
                throw error
            }
        }

        throw lastError ?? NSError(
            domain: "com.flowstay.oauth",
            code: -11,
            userInfo: [NSLocalizedDescriptionKey: "No available localhost callback port"]
        )
    }

    private func isAddressInUseError(_ error: Error) -> Bool {
        if let nwError = error as? NWError {
            switch nwError {
            case let .posix(code):
                return code == .EADDRINUSE
            default:
                break
            }
        }

        let nsError = error as NSError
        return nsError.domain == NSPOSIXErrorDomain && nsError.code == Int(EADDRINUSE)
    }

    // MARK: - PKCE Helpers

    /// Generate a random code verifier (43-128 chars, base64url)
    private func generateCodeVerifier() -> String {
        var bytes = [UInt8](repeating: 0, count: 32)
        let result = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)

        guard result == errSecSuccess else {
            logger.error("[OAuth] Failed to generate random bytes")
            return UUID().uuidString.replacingOccurrences(of: "-", with: "")
        }

        return Data(bytes).base64URLEncodedString()
    }

    /// Generate a random state parameter for CSRF protection
    private func generateStateParameter() -> String {
        var bytes = [UInt8](repeating: 0, count: 16)
        let result = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)

        guard result == errSecSuccess else {
            logger.error("[OAuth] Failed to generate state parameter random bytes")
            return UUID().uuidString
        }

        return Data(bytes).base64URLEncodedString()
    }

    /// Generate SHA256 code challenge from verifier
    private func generateCodeChallenge(from verifier: String) -> String {
        let data = Data(verifier.utf8)
        let hash = SHA256.hash(data: data)
        return Data(hash).base64URLEncodedString()
    }
}

// MARK: - Notifications

public extension Notification.Name {
    static let openRouterAuthenticationCompleted = Notification.Name("openRouterAuthenticationCompleted")
    static let openRouterDisconnected = Notification.Name("openRouterDisconnected")
}

// MARK: - Base64URL Encoding

extension Data {
    /// Encode data as base64url (URL-safe base64 without padding)
    func base64URLEncodedString() -> String {
        base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}
