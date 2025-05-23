#if !COCOAPODS
import Apollo
import ApolloAPI
#endif
import Foundation

// MARK: - Transport Delegate

public protocol WebSocketTransportDelegate: AnyObject {
  func webSocketTransportDidConnect(_ webSocketTransport: WebSocketTransport)
  func webSocketTransportDidReconnect(_ webSocketTransport: WebSocketTransport)
  func webSocketTransport(_ webSocketTransport: WebSocketTransport, didDisconnectWithError error:(any Error)?)
}

public extension WebSocketTransportDelegate {
  func webSocketTransportDidConnect(_ webSocketTransport: WebSocketTransport) {}
  func webSocketTransportDidReconnect(_ webSocketTransport: WebSocketTransport) {}
  func webSocketTransport(_ webSocketTransport: WebSocketTransport, didDisconnectWithError error:(any Error)?) {}
  func webSocketTransport(_ webSocketTransport: WebSocketTransport, didReceivePingData: Data?) {}
  func webSocketTransport(_ webSocketTransport: WebSocketTransport, didReceivePongData: Data?) {}
}

// MARK: - WebSocketTransport

/// A network transport that uses web sockets requests to send GraphQL subscription operations to a server.
public class WebSocketTransport {
  public weak var delegate: (any WebSocketTransportDelegate)?

  let websocket: any WebSocketClient
  let store: ApolloStore?
  private(set) var config: Configuration
  @Atomic var error: (any Error)?
  let serializationFormat = JSONSerializationFormat.self

  /// non-private for testing - you should not use this directly
  enum SocketConnectionState {
    case disconnected
    case connected
    case failed
    
    var isConnected: Bool {
      self == .connected
    }
  }
  @Atomic var socketConnectionState: SocketConnectionState = .disconnected

  /// Indicates if the websocket connection has been acknowledged by the server.
  private var acked = false

  private var queue: [Int: String] = [:]

  @Atomic
  private var subscribers = [String: (Result<JSONObject, any Error>) -> Void]()
  @Atomic
  private var subscriptions : [String: String] = [:]
  let processingQueue = DispatchQueue(label: "com.apollographql.WebSocketTransport")

  fileprivate var reconnected = false

  var reconnect: Bool {
    get { config.reconnect }
    set { config.$reconnect.mutate { $0 = newValue } }
  }

  /// - NOTE: Setting this won't override immediately if the socket is still connected, only on reconnection.
  public var clientName: String {
    get { config.clientName }
    set {
      config.clientName = newValue
      self.addApolloClientHeaders(to: &self.websocket.request)
    }
  }

  /// - NOTE: Setting this won't override immediately if the socket is still connected, only on reconnection.
  public var clientVersion: String {
    get { config.clientVersion }
    set {
      config.clientVersion = newValue
      self.addApolloClientHeaders(to: &self.websocket.request)
    }
  }

  public struct Configuration {
    /// The client name to use for this client. Defaults to `Self.defaultClientName`
    public fileprivate(set) var clientName: String
    /// The client version to use for this client. Defaults to `Self.defaultClientVersion`.
    public fileprivate(set) var clientVersion: String
    /// Whether to auto reconnect when websocket looses connection. Defaults to true.
    @Atomic public var reconnect: Bool
    /// How long to wait before attempting to reconnect. Defaults to half a second.
    public let reconnectionInterval: TimeInterval
    /// Allow sending duplicate messages. Important when reconnected. Defaults to true.
    public let allowSendingDuplicates: Bool
    ///  Whether the websocket connects immediately on creation.
    ///  If false, remember to call `resumeWebSocketConnection()` to connect.
    ///  Defaults to true.
    public let connectOnInit: Bool
    /// [optional]The payload to send on connection. Defaults to an empty `JSONEncodableDictionary`.
    public fileprivate(set) var connectingPayload: JSONEncodableDictionary?
    /// The `RequestBodyCreator` to use when serializing requests. Defaults to an `ApolloRequestBodyCreator`.
    public let requestBodyCreator: any RequestBodyCreator
    /// The `OperationMessageIdCreator` used to generate a unique message identifier per request.
    /// Defaults to `ApolloSequencedOperationMessageIdCreator`.
    public let operationMessageIdCreator: any OperationMessageIdCreator

    /// The designated initializer
    public init(
      clientName: String = WebSocketTransport.defaultClientName,
      clientVersion: String = WebSocketTransport.defaultClientVersion,
      reconnect: Bool = true,
      reconnectionInterval: TimeInterval = 0.5,
      allowSendingDuplicates: Bool = true,
      connectOnInit: Bool = true,
      connectingPayload: JSONEncodableDictionary? = [:],
      requestBodyCreator: any RequestBodyCreator = ApolloRequestBodyCreator(),
      operationMessageIdCreator: any OperationMessageIdCreator = ApolloSequencedOperationMessageIdCreator()
    ) {
      self.clientName = clientName
      self.clientVersion = clientVersion
      self._reconnect = Atomic(wrappedValue: reconnect)
      self.reconnectionInterval = reconnectionInterval
      self.allowSendingDuplicates = allowSendingDuplicates
      self.connectOnInit = connectOnInit
      self.connectingPayload = connectingPayload
      self.requestBodyCreator = requestBodyCreator
      self.operationMessageIdCreator = operationMessageIdCreator
    }
  }

  /// Determines whether a SOCKS proxy is enabled on the underlying request.
  /// Mostly useful for debugging with tools like Charles Proxy.
  /// Note: Will return `false` from the getter and no-op the setter for implementations that do not conform to `SOCKSProxyable`.
  public var enableSOCKSProxy: Bool {
    get {
      guard let websocket = websocket as? (any SOCKSProxyable) else {
        // If it's not proxyable, then the proxy can't be enabled
        return false
      }

      return websocket.enableSOCKSProxy
    }

    set {
      guard var websocket = websocket as? (any SOCKSProxyable) else {
        // If it's not proxyable, there's nothing to do here.
        return
      }

      websocket.enableSOCKSProxy = newValue
    }
  }

  /// Designated initializer
  ///
  /// - Parameters:
  ///   - websocket: The websocket client to use for creating a websocket connection.
  ///   - store: [optional] The `ApolloStore` used as a local cache.
  ///   - config: A `WebSocketTransport.Configuration` object with options for configuring the
  ///             web socket connection. Defaults to a configuration with default values.
  public init(
    websocket: any WebSocketClient,
    store: ApolloStore? = nil,
    config: Configuration = Configuration()
  ) {
    self.websocket = websocket
    self.store = store
    self.config = config

    self.addApolloClientHeaders(to: &self.websocket.request)

    self.websocket.delegate = self
    // Keep the assignment of the callback queue before attempting to connect. There is the
    // potential of a data race if the connection fails early and the disconnect logic reads
    // the callback queue while it's being set.
    self.websocket.callbackQueue = processingQueue

    if config.connectOnInit {
      self.websocket.connect()
    }
  }

  public func isConnected() -> Bool {
    return self.socketConnectionState.isConnected
  }

  public func ping(data: Data, completionHandler: (() -> Void)? = nil) {
    return websocket.write(ping: data, completion: completionHandler)
  }

  private func processMessage(text: String) {
    OperationMessage(serialized: text).parse { parseHandler in
      guard
        let type = parseHandler.type,
        let messageType = OperationMessage.Types(rawValue: type) else {
          self.notifyErrorAllHandlers(WebSocketError(payload: parseHandler.payload,
                                                     error: parseHandler.error,
                                                     kind: .unprocessedMessage(text)))
          return
      }

      switch messageType {
      case .data, .next, .error:
        guard let id = parseHandler.id else {
          let websocketError = WebSocketError(
            payload: parseHandler.payload,
            error: parseHandler.error,
            kind: .unprocessedMessage(text)
          )
          self.notifyErrorAllHandlers(websocketError)

          break
        }

        // If we have a handler ID but no subscriber exists for that ID then the
        // subscriber probably unsubscribed.
        if let responseHandler = subscribers[id] {
          if let payload = parseHandler.payload {
            responseHandler(.success(payload))
          } else if let error = parseHandler.error {
            responseHandler(.failure(error))
          } else {
            let websocketError = WebSocketError(payload: parseHandler.payload,
                                                error: parseHandler.error,
                                                kind: .neitherErrorNorPayloadReceived)
            responseHandler(.failure(websocketError))
          }
        }
      case .complete:
        if let id = parseHandler.id {
          // remove the callback if NOT a subscription
          if subscriptions[id] == nil {
            $subscribers.mutate { $0.removeValue(forKey: id) }
          }
        } else {
          notifyErrorAllHandlers(WebSocketError(payload: parseHandler.payload,
                                                error: parseHandler.error,
                                                kind: .unprocessedMessage(text)))
        }

      case .connectionAck:
        acked = true
        writeQueue()

      case .connectionKeepAlive,
           .startAck,
           .pong:
        writeQueue()

      case .ping:
        if let str = OperationMessage(type: .pong).rawMessage {
          write(str)
          writeQueue()
        }

      case .connectionInit,
           .connectionTerminate,
           .subscribe,
           .start,
           .stop,
           .connectionError:
        notifyErrorAllHandlers(WebSocketError(payload: parseHandler.payload,
                                              error: parseHandler.error,
                                              kind: .unprocessedMessage(text)))
      }
    }
  }

  private func notifyErrorAllHandlers(_ error: any Error) {
    for (_, handler) in subscribers {
      handler(.failure(error))
    }
  }

  private func writeQueue() {
    guard !self.queue.isEmpty else {
      return
    }

    let queue = self.queue.sorted(by: { $0.0 < $1.0 })
    self.queue.removeAll()
    for (id, msg) in queue {
      self.write(msg, id: id)
    }
  }

  private func processMessage(data: Data) {
    print("WebSocketTransport::unprocessed event \(data)")
  }

  public func initServer() {
    processingQueue.async {
      self.acked = false

      if let str = OperationMessage(payload: self.config.connectingPayload,
                                    type: .connectionInit).rawMessage {
        self.write(str, force:true)
      }
    }
  }

  public func closeConnection() {
    self.reconnect = false

    let str = OperationMessage(type: .connectionTerminate).rawMessage
    processingQueue.async {
      if let str = str {
        self.write(str)
      }

      self.queue.removeAll()
      self.$subscriptions.mutate { $0.removeAll() }
    }
  }

  private func write(_ str: String,
                     force forced: Bool = false,
                     id: Int? = nil) {
    if self.socketConnectionState.isConnected && (acked || forced) {
      websocket.write(string: str)
    } else {
      // using sequence number to make sure that the queue is processed correctly
      // either using the earlier assigned id or with the next higher key
      if let id = id {
        queue[id] = str
      } else if let id = queue.keys.max() {
        queue[id+1] = str
      } else {
        queue[1] = str
      }
    }
  }

  deinit {
    websocket.disconnect(forceTimeout: nil)
    self.websocket.delegate = nil
  }

  func sendHelper<Operation: GraphQLOperation>(operation: Operation, resultHandler: @escaping (_ result: Result<JSONObject, any Error>) -> Void) -> String? {
    let body = config.requestBodyCreator.requestBody(for: operation,
                                              sendQueryDocument: true,
                                              autoPersistQuery: false)
    let identifier = config.operationMessageIdCreator.requestId()

    let messageType: OperationMessage.Types
    switch websocket.request.wsProtocol {
    case .graphql_ws: messageType = .start
    case .graphql_transport_ws: messageType = .subscribe
    default: return nil
    }

    guard let message = OperationMessage(payload: body, id: identifier, type: messageType).rawMessage else {
      return nil
    }

    processingQueue.async {
      self.write(message)

      self.$subscribers.mutate { $0[identifier] = resultHandler }
      if Operation.operationType == .subscription {
        self.$subscriptions.mutate { $0[identifier] = message }
      }
    }

    return identifier
  }

  public func unsubscribe(_ subscriptionId: String) {
    let messageType: OperationMessage.Types
    switch websocket.request.wsProtocol {
    case .graphql_transport_ws: messageType = .complete
    default: messageType = .stop
    }

    let str = OperationMessage(id: subscriptionId, type: messageType).rawMessage

    processingQueue.async {
      if let str = str {
        self.write(str)
      }
      self.$subscribers.mutate { $0.removeValue(forKey: subscriptionId) }
      self.$subscriptions.mutate { $0.removeValue(forKey: subscriptionId) }
    }
  }

  public func updateHeaderValues(_ values: [String: String?], reconnectIfConnected: Bool = true) {
    for (key, value) in values {
      self.websocket.request.setValue(value, forHTTPHeaderField: key)
    }

    if reconnectIfConnected && isConnected() {
      self.reconnectWebSocket()
    }
  }

  public func updateConnectingPayload(_ payload: JSONEncodableDictionary, reconnectIfConnected: Bool = true) {
    self.config.connectingPayload = payload

    if reconnectIfConnected && isConnected() {
      self.reconnectWebSocket()
    }
  }

  private func reconnectWebSocket() {
    let oldReconnectValue = reconnect
    self.reconnect = false

    self.websocket.disconnect(forceTimeout: 0)
    self.websocket.connect()

    self.reconnect = oldReconnectValue
  }
  
  /// Disconnects the websocket while setting the auto-reconnect value to false,
  /// allowing purposeful disconnects that do not dump existing subscriptions.
  /// NOTE: You will receive an error on the subscription (should be a `WebSocket.WSError` with code 1000) when the socket disconnects.
  /// ALSO NOTE: In case pauseWebSocketConnection is called when app is backgrounded, app might get suspended within 5 seconds. In case disconnect did not complete within that time, websocket won't resume properly. That is why forceTimeout is set to 2 seconds.
  /// ALSO NOTE: To reconnect after calling this, you will need to call `resumeWebSocketConnection`.
  public func pauseWebSocketConnection() {
    self.reconnect = false
    self.websocket.disconnect(forceTimeout: 2.0)
  }
  
  /// Reconnects a paused web socket.
  ///
  /// - Parameter autoReconnect: `true` if you want the websocket to automatically reconnect if the connection drops. Defaults to true.
  public func resumeWebSocketConnection(autoReconnect: Bool = true) {
    self.reconnect = autoReconnect
    self.websocket.connect()
  }
}

extension URLRequest {
  fileprivate var wsProtocol: WebSocket.WSProtocol? {
    guard let header = value(forHTTPHeaderField: WebSocket.Constants.headerWSProtocolName) else {
      return nil
    }

    switch header {
    case WebSocket.WSProtocol.graphql_transport_ws.description: return .graphql_transport_ws
    case WebSocket.WSProtocol.graphql_ws.description: return .graphql_ws
    default: return nil
    }
  }
}

// MARK: - NetworkTransport conformance

extension WebSocketTransport: NetworkTransport {
  public func send<Operation: GraphQLOperation>(
    operation: Operation,
    cachePolicy: CachePolicy,
    contextIdentifier: UUID? = nil,
    context: (any RequestContext)? = nil,
    callbackQueue: DispatchQueue = .main,
    completionHandler: @escaping (Result<GraphQLResult<Operation.Data>, any Error>) -> Void) -> any Cancellable {
    
      func callCompletion(with result: Result<GraphQLResult<Operation.Data>, any Error>) {
      callbackQueue.async {
        completionHandler(result)
      }
    }
    
    if let error = self.error {
      callCompletion(with: .failure(error))
      return EmptyCancellable()
    }

    return WebSocketTask(self, operation) { [weak store, contextIdentifier, callbackQueue] result in
      switch result {
      case .success(let jsonBody):
        do {
          let response = GraphQLResponse(operation: operation, body: jsonBody)

          if let store = store {
            let (graphQLResult, parsedRecords) = try response.parseResult()
            guard let records = parsedRecords else {
              callCompletion(with: .success(graphQLResult))
              return
            }

            store.publish(records: records,
                          identifier: contextIdentifier,
                          callbackQueue: callbackQueue) { result in
              switch result {
              case .success:
                completionHandler(.success(graphQLResult))

              case let .failure(error):
                callCompletion(with: .failure(error))
              }
            }

          } else {
            let graphQLResult = try response.parseResultFast()
            callCompletion(with: .success(graphQLResult))
          }

        } catch {
          callCompletion(with: .failure(error))
        }
      case .failure(let error):
        callCompletion(with: .failure(error))
      }
    }
  }
}

// MARK: - WebSocketDelegate implementation

extension WebSocketTransport: WebSocketClientDelegate {

  public func websocketDidConnect(socket: any WebSocketClient) {
    self.handleConnection()
  }

  public func handleConnection() {
    self.$error.mutate { $0 = nil }
    self.$socketConnectionState.mutate { $0 = .connected }
    initServer()
    if self.reconnected {
      self.delegate?.webSocketTransportDidReconnect(self)
      // re-send the subscriptions whenever we are re-connected
      // for the first connect, any subscriptions are already in queue
      for (_, msg) in self.subscriptions {
        if self.config.allowSendingDuplicates {
          write(msg)
        } else {
          // search duplicate message from the queue
          let id = queue.first { $0.value == msg }?.key
          write(msg, id: id)
        }
      }
    } else {
      self.delegate?.webSocketTransportDidConnect(self)
    }

    self.reconnected = true
  }

  public func websocketDidDisconnect(socket: any WebSocketClient, error: (any Error)?) {
    self.$socketConnectionState.mutate { $0 = .disconnected }
    if let error = error {
      handleDisconnection(with: error)

    } else {
      self.$error.mutate { $0 = nil }
      self.handleDisconnection()
    }
  }

  private func handleDisconnection(with error: any Error) {
    // Set state to `.failed`, and grab its previous value.
    let previousState: SocketConnectionState = self.$socketConnectionState.mutate { socketConnectionState in
      let previousState = socketConnectionState
      socketConnectionState = .failed
      return previousState
    }
    // report any error to all subscribers
    self.$error.mutate { $0 = WebSocketError(payload: nil,
                                            error: error,
                                            kind: .networkError) }
    self.notifyErrorAllHandlers(error)

    switch previousState {
    case .connected, .disconnected:
      self.handleDisconnection()
    case .failed:
      // Don't attempt at reconnecting if already failed.
      // Websockets will sometimes notify several errors in a row, and
      // we don't want to perform disconnection handling multiple times.
      // This avoids https://github.com/apollographql/apollo-ios/issues/1753
      break
    }
  }

  private func handleDisconnection()  {
    self.delegate?.webSocketTransport(self, didDisconnectWithError: self.error)
    self.acked = false // need new connect and ack before sending

    self.attemptReconnectionIfDesired()
  }

  private func attemptReconnectionIfDesired() {
    guard self.reconnect else {
      return
    }

    DispatchQueue.main.asyncAfter(deadline: .now() + config.reconnectionInterval) { [weak self] in
      guard let self = self else { return }
      self.$socketConnectionState.mutate { socketConnectionState in
        switch socketConnectionState {
        case .disconnected, .connected:
          break
        case .failed:
          // Reset state to `.disconnected`, so that we can perform
          // disconnection handling if this reconnection triggers an error.
          // (See how errors are handled in didReceive(event:client:).
          socketConnectionState = .disconnected
        }
      }
      self.websocket.connect()
    }
  }

  public func websocketDidReceiveMessage(socket: any WebSocketClient, text: String) {
    self.processMessage(text: text)
  }

  public func websocketDidReceiveData(socket: any WebSocketClient, data: Data) {
    self.processMessage(data: data)
  }
  
}
