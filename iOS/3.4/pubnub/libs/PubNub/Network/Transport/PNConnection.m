//
//  PNConnection.m
//  pubnub
//
//  This is core class for communication over
//  the network with PubNub services.
//  It allow to establish socket connection and
//  organize write packet requests into FIFO queue.
//
//  Created by Sergey Mamontov on 12/10/12.
//
//

#import "PNConnection.h"
#import <Security/SecureTransport.h>
#import "PNConnection+Protected.h"
#import "PNResponseDeserialize.h"
#import "PubNub+Protected.h"
#import "PNWriteBuffer.h"
#import "PNResponseProtocol.h"


#pragma mark Structures

typedef NS_OPTIONS(NSUInteger, PNConnectionStateFlag)  {

    // Flag which allow to set whether read stream configuration started or not
    PNReadStreamConfiguring = 1 << 0,

    // Flag which allow to set whether write stream configuration started or not
    PNWriteStreamConfiguring = 1 << 1,

    // Flag which allow to set whether connection configuration started or not
    PNConnectionConfiguring = (PNReadStreamConfiguring | PNWriteStreamConfiguring),

    // Flag which allow to set whether read stream configured or not
    PNReadStreamConfigured = 1 << 2,

    // Flag which allow to set whether write stream configured or not
    PNWriteStreamConfigured = 1 << 3,

    // Flag which allow to set whether connection configured or not
    PNConnectionConfigured = (PNReadStreamConfigured | PNWriteStreamConfigured),

    // Flag which allow to set whether read stream is connecting right now or not
    PNReadStreamConnecting = 1 << 4,

    // Flag which allow to set whether write stream is connecting right now or not
    PNWriteStreamConnecting = 1 << 5,

    // Flag which allow to set whether client is connecting at this moment or not
    PNConnectionConnecting = (PNReadStreamConnecting | PNWriteStreamConnecting),

    // Flag which allow to set whether read stream is connected right now or not
    PNReadStreamConnected = 1 << 6,

    // Flag which allow to set whether write stream is connected right now or not
    PNWriteStreamConnected = 1 << 7,

    // Flag which allow to set whether connection channel is preparing to establish connection
    PNConnectionPrepareToConnect = 1 << 8,

    // Flag which allow to set whether client is connected or not
    PNConnectionConnected = (PNReadStreamConnected | PNWriteStreamConnected),

    // Flag which allow to set whether client is reconnecting at this moment or not
    PNConnectionReconnecting = 1 << 9,

    // Flag which allow to set whether client is waking up it's connection or not
    PNConnectionReconnectingOnWakeUp = 1 << 10,

#if __IPHONE_OS_VERSION_MIN_REQUIRED
    // Flag which allow to set whether connection is suspended or not or not
    PNConnectionResuming = 1 << 11,
#endif

    // Flag which allow to set whether read stream is disconnecting right now or not
    PNReadStreamDisconnecting = 1 << 12,

    // Flag which allow to set whether write stream is disconnecting right now or not
    PNWriteStreamDisconnecting = 1 << 13,

    // Flag which allow to set whether client is disconnecting at this moment or not
    PNConnectionDisconnecting = (PNReadStreamDisconnecting | PNWriteStreamDisconnecting),

#if __IPHONE_OS_VERSION_MIN_REQUIRED
    // Flag which allow to set whether connection is suspending or not or not
    PNConnectionSuspending = 1 << 14,
#endif

    // Flag which allow to set whether read stream is disconnected right now or not
    PNReadStreamDisconnected = 1 << 15,

    // Flag which allow to set whether write stream is disconnected right now or not
    PNWriteStreamDisconnected = 1 << 16,

    // Flag which allow to set whether client is disconnected at this moment or not
    PNConnectionDisconnected = (PNReadStreamDisconnected | PNWriteStreamDisconnected),

    // Flag which allow to set whether client should connect back as soon as disconnection will be completed or not
    PNConnectionReconnectOnDisconnection = 1 << 17,

#if __IPHONE_OS_VERSION_MIN_REQUIRED
    // Flag which allow to set whether connection is suspended or not or not
    PNConnectionSuspended = 1 << 18,
#endif

    // Flag which allow to set whether connection should schedule next requests or not
    PNConnectionProcessingRequests = 1 << 19,

    // Flag which allow to set whether connection is expecting to be terminated by server or not
    // (usable for situations when server doesn't support 'keep-alive' connection)
    PNConnectionExpectingServerToCloseConnection = 1 << 20
};

typedef NS_OPTIONS(NSUInteger, PNConnectionActionOwnerFlag)  {

    // Flag which allow to set whether action on connection has been triggered by user or not
    PNByUserRequest = 1 << 21
};

typedef NS_OPTIONS(NSUInteger, PNConnectionDataSendingStateFlag)  {

    // Flag which allow to set whether action on connection has been triggered by user or not
    PNSendingData = 1 << 22
};

typedef NS_OPTIONS(NSUInteger, PNConnectionErrorStateFlag)  {

    // Flag which allow to set whether error occurred on read stream or not
    PNReadStreamError = 1 << 23,

    // Flag which allow to set whether error occurred on write stream or not
    PNWriteStreamError = 1 << 24,

    // Flag which allow to set whether client is experiencing some error or not
    PNConnectionError = (PNReadStreamError | PNWriteStreamError)
};

typedef NS_OPTIONS(NSUInteger, PNConnectionCleanStateFlag)  {

    // Flag which can be used to clean configuration states related to read stream
    PNReadStreamCleanConfiguration = (PNReadStreamConfiguring | PNReadStreamConfigured),

    // Flag which can be used to clean connection states related to read stream
    PNReadStreamCleanConnection = (PNReadStreamConnecting | PNReadStreamConnected),

    // Flag which can be used to clean connection states related to read stream
    PNReadStreamCleanDisconnection = (PNReadStreamDisconnecting | PNReadStreamDisconnected),

    // Flag which can be used to clean all states related to read stream
    PNReadStreamCleanAll = (PNReadStreamCleanConfiguration | PNReadStreamCleanConnection |
                            PNReadStreamCleanDisconnection | PNReadStreamError),

    // Flag which can be used to clean configuration states related to write stream
    PNWriteStreamCleanConfiguration = (PNWriteStreamConfiguring | PNWriteStreamConfigured),

    // Flag which can be used to clean connection states related to write stream
    PNWriteStreamCleanConnection = (PNWriteStreamConnecting | PNWriteStreamConnected),

    // Flag which can be used to clean connection states related to write stream
    PNWriteStreamCleanDisconnection = (PNWriteStreamDisconnecting | PNWriteStreamDisconnected),

    // Flag which can be used to clean all states related to write stream
    PNWriteStreamCleanAll = (PNWriteStreamCleanConfiguration | PNWriteStreamCleanConnection |
                             PNWriteStreamCleanDisconnection | PNWriteStreamError),

    // Flag which allow to set whether client is experiencing some error or not
    PNConnectionErrorCleanAll = (PNReadStreamError | PNWriteStreamError)
};

typedef enum _PNConnectionSSLConfigurationLevel {

    // This option will check all information on remote origin SSL certificate to ensure in authority
    PNConnectionSSLConfigurationStrict,

    // This option will skip most of validations and as fact will allow to work with server which uses invalid SSL
    // certificate or certificate from another server
    PNConnectionSSLConfigurationBarelySecure,

    // This option will tell that connection should be opened w/o SSL (if user won't to discard security options)
    PNConnectionSSLConfigurationInsecure,
} PNConnectionSSLConfigurationLevel;

struct PNConnectionIdentifiersStruct PNConnectionIdentifiers = {
    
    .messagingConnection = @"PNMessagingConnectionIdentifier",
    .serviceConnection = @"PNServiceConnectionIdentifier"
};


#pragma mark - Static

// Stores reference on created connection instances which can be used/reused
static NSMutableDictionary *_connectionsPool = nil;
static dispatch_once_t onceToken;

// Delay which is used by wake up timer to fire
static int64_t const kPNWakeUpTimerInterval = 5;

// Default origin host connection port
static UInt32 const kPNOriginConnectionPort = 80;

// Default origin host SSL connection port
static UInt32 const kPNOriginSSLConnectionPort = 443;

// Default data buffer size (Default: 32kb)
static int const kPNStreamBufferSize = 32768;

// Delay after which connection should retry
static int64_t const kPNConnectionRetryDelay = 2;

// Maximum retry count which can be performed for single operation
static NSUInteger const kPNMaximumRetryCount = 3;


#pragma mark - Private interface methods

@interface PNConnection ()

#pragma mark - Properties

// Stores connection name (identifier)
@property (nonatomic, copy) NSString *name;

// Connection configuration information
@property (nonatomic, strong) PNConfiguration *configuration;

// Stores reference on response deserializer which will parse response into objects array and update provided data to
// insert offset on amount of parsed data
@property (nonatomic, strong) PNResponseDeserialize *deserializer;

// Stores reference on binary data object which stores
// server response from socket read stream
@property (nonatomic, strong) NSMutableData *retrievedData;

// Stores reference on binary data object which temporary stores data received from socket read stream (used while
// deserializer is working)
@property (nonatomic, strong) NSMutableData *temporaryRetrievedData;

// Stores reference on buffer which should be sent to the PubNub service via socket
@property (nonatomic, strong) PNWriteBuffer *writeBuffer;

@property (nonatomic, assign) NSUInteger retryCount;

// Stores connection channel state
@property (nonatomic, assign) NSUInteger state;

// Stores reference on timer which should awake connection channel if it doesn't reconnect back because of some
// race of states and conditions
@property (nonatomic, pn_dispatch_property_ownership) dispatch_source_t wakeUpTimer;
@property (nonatomic, assign, getter = isWakeUpTimerSuspended) BOOL wakeUpTimerSuspended;

// Socket streams and state
@property (nonatomic, assign) CFReadStreamRef socketReadStream;
@property (nonatomic, assign) CFWriteStreamRef socketWriteStream;
@property (nonatomic, assign, getter = isWriteStreamCanHandleData) BOOL writeStreamCanHandleData;

// Socket streams configuration and security
@property (nonatomic, strong) NSDictionary *proxySettings;
@property (nonatomic, assign) CFMutableDictionaryRef streamSecuritySettings;
@property (nonatomic, assign) PNConnectionSSLConfigurationLevel sslConfigurationLevel;


#pragma mark - Class methods

/**
 * Retrieve reference on connection with specified identifier from connections pool
 */
+ (PNConnection *)connectionFromPoolWithIdentifier:(NSString *)identifier;

/**
 * Store connection instance inside connections pool
 */
+ (void)storeConnection:(PNConnection *)connection withIdentifier:(NSString *)identifier;

/**
 * Returns reference on dictionary of connections (it will be created on runtime)
 */
+ (NSMutableDictionary *)connectionsPool;


#pragma mark - Instance methods

/**
 * Perform connection initialization with user-provided configuration (they will be obtained from PubNub client)
 */
- (id)initWithConfiguration:(PNConfiguration *)configuration;


#pragma mark - Streams management methods

/**
 * Will create read/write pair streams to specific host at
 */
- (BOOL)prepareStreams;

- (void)disconnectOnInternalRequest;

/**
 * Will destroy both read and write streams
 */
- (void)destroyStreams;

/**
 * Allow to configure read stream with set of parameters 
 * like:
 *   - proxy
 *   - security (SSL)
 * If stream already configured, it won't accept any new
 * settings.
 */
- (void)configureReadStream:(CFReadStreamRef)readStream;
- (void)openReadStream:(CFReadStreamRef)readStream;
- (void)disconnectReadStream:(CFReadStreamRef)readStream;
- (void)destroyReadStream:(CFReadStreamRef)readStream;

/**
 * Process response which was fetched from read stream so far
 */
- (void)processResponse;

/**
 * Read out content which is waiting in read stream
 */
- (void)readStreamContent;

/**
 * Allow to complete write stream configuration (additional settings will be transferred from paired read stream on
 * configuration). If stream already configured, it won't accept any new settings.
 */
- (void)configureWriteStream:(CFWriteStreamRef)writeStream;
- (void)openWriteStream:(CFWriteStreamRef)writeStream;
- (void)disconnectWriteStream:(CFWriteStreamRef)writeStream;
- (void)destroyWriteStream:(CFWriteStreamRef)writeStream;

/**
 * Retrieve and prepare next request which should be sent
 */
- (void)prepareNextRequestPacket;

/**
 * Writes buffer portion into socket
 */
- (void)writeBufferContent;


#pragma mark - Handler methods

/**
 * Called every time when one of streams (read/write) successfully open connection
 */
- (void)handleStreamConnection;

/**
 * Called every time when one of streams (read/write) disconnected
 */
- (void)handleStreamClose;

/**
 * Called each time when new portion of data available in socket read stream for reading
 */
- (void)handleReadStreamHasData;

/**
 * Called each time when write stream is ready to accept data from PubNub client
 */
- (void)handleWriteStreamCanAcceptData;

/**
 * Called when client is about to close write stream and we need to do something with write buffer if it was assigned
 */
- (void)handleRequestSendingCancelation;

/**
 * Called each time when server close stream because of timeout
 */
- (void)handleStreamTimeout;

/**
 * Called each time when wake up timer is fired
 */
- (void)handleWakeUpTimer;

/**
 * Converts stream status enum value into string representation
 */
- (NSString *)stringifyStreamStatus:(CFStreamStatus)status;

- (void)handleStreamError:(CFErrorRef)error;
- (void)handleStreamError:(CFErrorRef)error shouldCloseConnection:(BOOL)shouldCloseConnection;
- (void)handleStreamSetupError;
- (void)handleRequestProcessingError:(CFErrorRef)error;


#pragma mark - Misc methods

/**
 * Construct/reuse and launch/resume/suspend/stop 'wakeup' timer to help restore connection if it will be required
 */
- (void)startWakeUpTimer;
- (void)suspendWakeUpTimer;
- (void)resumeWakeUpTimer;
- (void)stopWakeUpTimer;
- (void)resetWakeUpTimer;

/**
 * Check whether specified error is from POSIX domain and report that error is caused by connection failure or not
 */
- (BOOL)isConnectionIssuesError:(CFErrorRef)error;

/**
 * Check whether specified error is from OSStatus error domain and report that error is caused by SSL issue
 */
- (BOOL)isSecurityTransportError:(CFErrorRef)error;
- (BOOL)isInternalSecurityTransportError:(CFErrorRef)error;
- (BOOL)isTemporaryServerError:(CFErrorRef)error;

- (CFStreamClientContext)streamClientContext;

/**
 * Retrieving global network proxy configuration
 */
- (void)retrieveSystemProxySettings;

/**
 * Stream error processing methods
 */
- (PNError *)processStreamError:(CFErrorRef)error;

/**
 * Print our current connection state
 */
- (NSString *)stateDescription;


@end


#pragma mark - Public interface methods

@implementation PNConnection


#pragma mark - Class methods

+ (PNConnection *)connectionWithIdentifier:(NSString *)identifier {

    // Try to retrieve connection from pool
    PNConnection *connection = [self connectionFromPoolWithIdentifier:identifier];

    if (connection == nil) {

        connection = [[[self class] alloc] initWithConfiguration:[PubNub sharedInstance].configuration];
        connection.name = identifier;
        [self storeConnection:connection withIdentifier:identifier];
    }


    return connection;
}

+ (PNConnection *)connectionFromPoolWithIdentifier:(NSString *)identifier {

    return [[self connectionsPool] valueForKey:identifier];
}

+ (void)storeConnection:(PNConnection *)connection withIdentifier:(NSString *)identifier {

    [[self connectionsPool] setValue:connection forKey:identifier];
}

+ (void)destroyConnection:(PNConnection *)connection {

    if (connection != nil) {

        // Iterate over the list of connection pool and remove connection from it
        NSMutableArray *connectionIdentifiersForDelete = [NSMutableArray array];
        [[self connectionsPool] enumerateKeysAndObjectsUsingBlock:^(id connectionIdentifier, id connectionFromPool,
                                                                    BOOL *connectionEnumeratorStop) {

            // Check whether found connection in connection pool or not
            if (connectionFromPool == connection) {

                // Adding identifier to the list of keys which should be removed (there can be many keys for single
                // connection because of performance and network issues on iOS)
                [connectionIdentifiersForDelete addObject:connectionIdentifier];
            }
        }];

        [[self connectionsPool] removeObjectsForKeys:connectionIdentifiersForDelete];
    }
}

+ (void)closeAllConnections {

    // Check whether has some connection in pool or not
    if ([_connectionsPool count] > 0) {

        // Store list of connections before purge connections pool
        NSArray *connections = [_connectionsPool allValues];

        // Clean up connections pool
        [_connectionsPool removeAllObjects];


        // Close all connections
        [connections makeObjectsPerformSelector:@selector(disconnectOnInternalRequest)];
    }
}

+ (NSMutableDictionary *)connectionsPool {

    dispatch_once(&onceToken, ^{

        _connectionsPool = [NSMutableDictionary new];
    });


    return _connectionsPool;
}

+ (void)resetConnectionsPool {

    onceToken = 0;

    // Reset connections
    if ([_connectionsPool count]) {

        [[_connectionsPool allValues] makeObjectsPerformSelector:@selector(setDataSource:) withObject:nil];
        [[_connectionsPool allValues] makeObjectsPerformSelector:@selector(setDelegate:) withObject:nil];
    }

    _connectionsPool = nil;
}


#pragma mark - Instance methods

- (id)initWithConfiguration:(PNConfiguration *)configuration {

    // Check whether initialization was successful or not
    if ((self = [super init])) {

        // Perform connection initialization
        self.configuration = configuration;
        self.deserializer = [PNResponseDeserialize new];

        // Perform streams initial options and security initializations
        [self prepareStreams];
    }


    return self;
}


#pragma mark - Requests queue execution management

- (void)scheduleNextRequestExecution {

    PNBitOn(&_state, PNConnectionProcessingRequests);

    // Ensure that both streams connected at this moment or not
    if (PNBitStrictIsOn(self.state, PNConnectionConnected)) {

        // Check whether sending data at this moment or not
        if (!PNBitIsOn(self.state, PNSendingData)) {

            if (self.writeBuffer == nil) {

                [self prepareNextRequestPacket];
            }
            else {

                [self.writeBuffer reset];
            }

            if (self.writeBuffer != nil) {

                // Try to initiate request sending process
                [self writeBufferContent];
            }

        }
    }
}

- (void)unscheduleRequestsExecution {

    PNBitOff(&_state, PNConnectionProcessingRequests);

    [self handleRequestSendingCancelation];
}


#pragma mark - Streams callback methods

void readStreamCallback(CFReadStreamRef stream, CFStreamEventType type, void *clientCallBackInfo) {

    NSCAssert([(__bridge id)clientCallBackInfo isKindOfClass:[PNConnection class]],
              @"{ERROR}[READ] WRONG CLIENT INSTANCE HAS BEEN SENT AS CLIENT");
    PNConnection *connection = (__bridge PNConnection *)clientCallBackInfo;

    NSString *status = [connection stringifyStreamStatus:CFReadStreamGetStatus(stream)];

    switch (type) {

        // Stream successfully opened
        case kCFStreamEventOpenCompleted:

            PNLog(PNLogConnectionLayerInfoLevel, connection, @"[CONNECTION::%@::READ] STREAM OPENED (%@)(STATE: %d)",
                  connection.name ? connection.name : connection, status, connection.state);

            PNBitOff(&(connection->_state), PNReadStreamCleanDisconnection);
            PNBitOn(&(connection->_state), PNReadStreamConnected);

            [connection handleStreamConnection];
            break;

        // Read stream has some data which arrived from remote server
        case kCFStreamEventHasBytesAvailable:

            PNLog(PNLogConnectionLayerInfoLevel, connection, @"[CONNECTION::%@::READ] HAS DATA FOR READ OUT (%@)(STATE: %d)",
                  connection.name ? connection.name : connection, status, connection.state);

            [connection handleReadStreamHasData];
            break;

        // Some error occurred on read stream
        case kCFStreamEventErrorOccurred:

            PNLog(PNLogConnectionLayerErrorLevel, connection, @"[CONNECTION::%@::READ] ERROR OCCURRED (%@)(STATE: %d)",
                  connection.name ? connection.name : connection, status, connection.state);

            // Check whether error occurred while stream tried to establish connection or not
            BOOL isConnecting = PNBitIsOn(connection->_state, PNReadStreamConnecting);
            PNBitOff(&(connection->_state), PNReadStreamCleanAll);

            // Calculate target stream state basing on whether it tried to connect or already was connected
            NSUInteger stateBit = isConnecting ? PNReadStreamConnecting : PNReadStreamDisconnecting;
            PNBitsOn(&(connection->_state), stateBit, PNReadStreamError, 0);

            CFErrorRef error = CFReadStreamCopyError(stream);
            [connection handleStreamError:error shouldCloseConnection:YES];

            PNCFRelease(&error);
            break;

        // Server disconnected socket probably because of timeout
        case kCFStreamEventEndEncountered:

            PNLog(PNLogConnectionLayerInfoLevel, connection, @"[CONNECTION::%@::READ] NOTHING TO READ (%@)(STATE: %d)",
                  connection.name ? connection.name : connection, status, connection.state);

            PNBitOff(&(connection->_state), PNReadStreamCleanAll);
            PNBitOn(&(connection->_state), PNReadStreamDisconnected);

            [connection handleStreamTimeout];
            break;

        default:
            break;
    }
}

void writeStreamCallback(CFWriteStreamRef stream, CFStreamEventType type, void *clientCallBackInfo) {

    NSCAssert([(__bridge id)clientCallBackInfo isKindOfClass:[PNConnection class]],
              @"{ERROR}[WRITE] WRONG CLIENT INSTANCE HAS BEEN SENT AS CLIENT");
    PNConnection *connection = (__bridge PNConnection *)clientCallBackInfo;

    NSString *status = [connection stringifyStreamStatus:CFWriteStreamGetStatus(stream)];

    switch (type) {

        // Stream successfully opened
        case kCFStreamEventOpenCompleted:

            PNLog(PNLogConnectionLayerInfoLevel, connection, @"[CONNECTION::%@::WRITE] STREAM OPENED (%@)(STATE: %d)",
                  connection.name ? connection.name : connection, status, connection.state);

            PNBitOff(&(connection->_state), PNWriteStreamCleanDisconnection);
            PNBitOn(&(connection->_state), PNWriteStreamConnected);

            [connection handleStreamConnection];
            break;

        // Write stream is ready to accept data from data source
        case kCFStreamEventCanAcceptBytes:

            PNLog(PNLogConnectionLayerInfoLevel, connection, @"[CONNECTION::%@::WRITE] READY TO SEND (%@)(STATE: %d)",
                  connection.name ? connection.name : connection, status, connection.state);

            [connection handleWriteStreamCanAcceptData];
            break;

        // Some error occurred on write stream
        case kCFStreamEventErrorOccurred:

            PNLog(PNLogConnectionLayerErrorLevel, connection, @"[CONNECTION::%@::WRITE] ERROR OCCURRED (%@)(STATE: %d)",
                  connection.name ? connection.name : connection, status, connection.state);

            // Check whether error occurred while stream tried to establish connection or not
            BOOL isConnecting = PNBitIsOn(connection->_state, PNWriteStreamConnecting);
            PNBitOff(&(connection->_state), PNWriteStreamCleanAll);

            // Calculate target stream state basing on whether it tried to connect or already was connected
            NSUInteger stateBit = isConnecting ? PNWriteStreamConnecting : PNWriteStreamDisconnecting;
            PNBitsOn(&(connection->_state), stateBit, PNWriteStreamError, 0);

            CFErrorRef error = CFWriteStreamCopyError(stream);
            [connection handleStreamError:error shouldCloseConnection:YES];

            PNCFRelease(&error);
            break;

        // Server disconnected socket probably because of timeout
        case kCFStreamEventEndEncountered:

            PNLog(PNLogConnectionLayerInfoLevel, connection, @"[CONNECTION::%@::WRITE] MAYBE STREAM IS CLOSED (%@)(STATE: %d)",
                  connection.name ? connection.name : connection, status, connection.state);

            PNBitOff(&(connection->_state), PNWriteStreamCleanAll);
            PNBitOn(&(connection->_state), PNWriteStreamDisconnected);

            [connection handleStreamTimeout];
            break;

        default:
            break;
    }
}


#pragma mark - Connection state

- (BOOL)isDisconnected {
#if __IPHONE_OS_VERSION_MIN_REQUIRED
    return PNBitStrictIsOn(self.state, PNConnectionDisconnected) || PNBitIsOn(self.state, PNConnectionSuspended);
#else
    return PNBitStrictIsOn(self.state, PNConnectionDisconnected);
#endif
}

- (BOOL)isConnectionIssuesError:(CFErrorRef)error {

    BOOL isConnectionIssue = NO;

    NSString *errorDomain = CFBridgingRelease(CFErrorGetDomain(error));
    if ([errorDomain isEqualToString:(NSString *)kCFErrorDomainPOSIX]) {

        switch (CFErrorGetCode(error)) {

            case ENETDOWN:      // Network went down
            case ENETUNREACH:   // Network is unreachable
            case EHOSTDOWN:     // Host is down
            case EHOSTUNREACH:  // Can't reach host
            case ETIMEDOUT:     // Socket timeout

                isConnectionIssue = YES;
                break;
            default:
                break;
        }
    }
    else if ([errorDomain isEqualToString:(NSString *)kCFErrorDomainCFNetwork]) {

        switch (CFErrorGetCode(error)) {

            case kCFHostErrorHostNotFound:
            case kCFHostErrorUnknown:
            case kCFErrorHTTPConnectionLost:

                isConnectionIssue = YES;
                break;
            default:
                break;
        }
    }


    return isConnectionIssue;
}

- (BOOL)isSecurityTransportError:(CFErrorRef)error {
    
    BOOL isSecurityTransportError = NO;

    CFIndex errorCode = CFErrorGetCode(error);
    NSString *errorDomain = CFBridgingRelease(CFErrorGetDomain(error));
    if ([errorDomain isEqualToString:(NSString *)kCFErrorDomainOSStatus]) {

        isSecurityTransportError = (errSSLLast <= errorCode) && (errorCode <= errSSLProtocol);
    }
    else if ([errorDomain isEqualToString:(NSString *)kCFErrorDomainCFNetwork]) {
        
        isSecurityTransportError = (kCFURLErrorCannotLoadFromNetwork <= errorCode) && (errorCode <= kCFURLErrorSecureConnectionFailed);
    }
    
    
    return isSecurityTransportError;
}

- (BOOL)isInternalSecurityTransportError:(CFErrorRef)error {

    CFIndex code = CFErrorGetCode(error);
    
    return (code == errSSLInternal) || (code == errSSLClosedAbort);
}

- (BOOL)isTemporaryServerError:(CFErrorRef)error {
    
    BOOL isServerError = NO;
    
    CFIndex errorCode = CFErrorGetCode(error);
    NSString *errorDomain = (__bridge NSString *)CFErrorGetDomain(error);
    
    if ([errorDomain isEqualToString:(NSString *)kCFErrorDomainPOSIX]) {
        
        switch (errorCode) {
            case ENETRESET:     // Network dropped connection on reset
            case ECONNABORTED:  // Connection was aborted by software (OS)
            case ECONNRESET:    // Connection reset by peer
            case ENOBUFS:       // No buffer space available
            case ENOTCONN:      // Socket not connected or was disconnected
            case ECONNREFUSED:  // Connection refused
            case ESHUTDOWN:     // Can't send after socket shutdown
            case ENOENT:        // No such file or directory
            case EPIPE:         // Something went wrong and pipe was damaged
            case EAGAIN:        // Requested resource not available

                isServerError = YES;
                break;
            default:
                break;
        }
    }
    else if ([errorDomain isEqualToString:(NSString *)kCFErrorDomainCFNetwork]) {

        isServerError = (kCFNetServiceErrorDNSServiceFailure <= errorCode) && (errorCode <= kCFNetServiceErrorUnknown);
    }
    
    
    return isServerError;
}


#pragma mark - Connection lifecycle management methods

- (BOOL)prepareStreams {

    PNLog(PNLogConnectionLayerInfoLevel, self, @"[CONNECTION::%@] PREPARE READ/WRITE STREAMS (STATE: %d)",
          self.name ? self.name : self, self.state);

    BOOL streamsPrepared = YES;

    // Check whether stream was prepared and configured before
    if (PNBitStrictIsOn(self.state, PNConnectionConfigured)) {
#if __IPHONE_OS_VERSION_MIN_REQUIRED
        if (PNBitStrictIsOn(self.state, PNConnectionConnecting) || PNBitIsOn(self.state, PNConnectionReconnecting) ||
            PNBitIsOn(self.state, PNConnectionResuming)) {
#else
        if (PNBitStrictIsOn(self.state, PNConnectionConnecting) || PNBitIsOn(self.state, PNConnectionReconnecting)) {

#endif
            PNLog(PNLogConnectionLayerInfoLevel, self, @"[CONNECTION::%@] ALREADY CONFIGURATED CONFIGURED STREAMS AND CONNECTEDING (STATE: %d)",
                  self.name ? self.name : self, self.state);

        } else if (PNBitStrictIsOn(self.state, PNConnectionConnected)) {

            PNLog(PNLogConnectionLayerInfoLevel, self, @"[CONNECTION::%@] ALREADY CONFIGURATED CONFIGURED STREAMS AND CONNECTED (STATE: %d)",
                  self.name ? self.name : self, self.state);
        }
        else {

            PNLog(PNLogConnectionLayerInfoLevel, self, @"[CONNECTION::%@] ALREADY CONFIGURATED CONFIGURED STREAMS (STATE: %d)",
                  self.name ? self.name : self, self.state);
        }
    }
    else {

        PNLog(PNLogConnectionLayerInfoLevel, self, @"[CONNECTION::%@] CONFIGURATION STARTED (STATE: %d)",
                (self.name ? self.name : self), self.state);

        // Make sure that streams will be unable to operate
        [self destroyStreams];
        PNBitsOff(&_state, PNReadStreamCleanDisconnection, PNWriteStreamCleanDisconnection, 0);

        // Define connection port which should be used by connection for further usage
        // (depends on current connection security policy)
        UInt32 targetPort = kPNOriginConnectionPort;
        if (self.configuration.shouldUseSecureConnection &&
            self.sslConfigurationLevel != PNConnectionSSLConfigurationInsecure) {

            targetPort = kPNOriginSSLConnectionPort;
        }

        // Retrieve connection proxy configuration
        [self retrieveSystemProxySettings];


        // Create stream pair on socket which is connected to specified remote host
        CFStreamCreatePairWithSocketToHost(CFAllocatorGetDefault(), (__bridge CFStringRef)(self.configuration.origin),
                                           targetPort, &_socketReadStream, &_socketWriteStream);

        [self configureReadStream:_socketReadStream];
        [self configureWriteStream:_socketWriteStream];

        // Check whether stream successfully configured or configuration failed
        if (!PNBitIsOn(self.state, PNConnectionConfigured)) {

            PNLog(PNLogConnectionLayerErrorLevel, self, @"[CONNECTION::%@] CONFIGURATION FAILED (STATE: %d)",
                  self.name ? self.name : self, self.state);

            streamsPrepared = NO;
            [self destroyStreams];
            [self handleStreamSetupError];
        }
        else {

            PNLog(PNLogConnectionLayerInfoLevel, self, @"[CONNECTION::%@] CONFIGURATION COMPLETED (STATE: %d)",
                  self.name ? self.name : self, self.state);
        }
    }


    return streamsPrepared;
}

- (BOOL)connect {

    return [self connectByUserRequest:YES];
}

- (BOOL)connectByUserRequest:(BOOL)byUserRequest {

    PNLog(PNLogConnectionLayerInfoLevel, self, @"[CONNECTION::%@] TRYING ESTABLISH CONNECTION (BY USER REQUEST? %@)(STATE: %d)",
          self.name ? self.name : self, byUserRequest ? @"YES" : @"NO", self.state);

    __block BOOL isStreamOpened = NO;

    if (byUserRequest) {

        PNBitOff(&_state, PNConnectionError);
        PNBitOn(&_state, PNByUserRequest);
    }
    else {

        PNBitOff(&_state, PNByUserRequest);
    }

    PNBitOn(&_state, PNConnectionPrepareToConnect);


    // Check whether client configured or not
    if (PNBitStrictIsOn(self.state, PNConnectionConfigured)) {

        PNBitOff(&_state, PNConnectionPrepareToConnect);

#if __IPHONE_OS_VERSION_MIN_REQUIRED
        if (!PNBitIsOn(self.state, PNConnectionConnecting) && !PNBitIsOn(self.state, PNConnectionReconnecting) &&
            !PNBitIsOn(self.state, PNConnectionResuming) && !PNBitIsOn(self.state, PNConnectionConnected) &&
            !PNBitIsOn(self.state, PNConnectionDisconnecting)) {
#else
        if (!PNBitStrictIsOn(self.state, PNConnectionConnecting) && !PNBitIsOn(self.state, PNConnectionReconnecting) &&
            !PNBitStrictIsOn(self.state, PNConnectionConnected)) {
#endif
            PNBitsOff(&_state, PNConnectionDisconnecting, PNConnectionDisconnected, 0);
#if __IPHONE_OS_VERSION_MIN_REQUIRED
            // Checking whether client was suspended before, to launch restore process
            if (PNBitIsOn(self.state, PNConnectionSuspended)) {

                PNBitsOff(&_state, PNConnectionReconnecting, PNConnectionSuspending, PNConnectionSuspended,
                                   PNConnectionErrorCleanAll, 0);
                PNBitOn(&_state, PNConnectionResuming);
                PNLog(PNLogConnectionLayerInfoLevel, self, @"[CONNECTION::%@] RESUMING... (STATE: %d)",
                      self.name ? self.name : self, self.state);
            }
            else if (!PNBitStrictIsOn(self.state, PNConnectionConnected)) {

                PNBitsOff(&_state, PNConnectionResuming, PNConnectionSuspending, PNConnectionSuspended, 0);
#else
            if (!PNBitStrictIsOn(self.state, PNConnectionConnected)) {
#endif
                PNLog(PNLogConnectionLayerInfoLevel, self, @"[CONNECTION::%@] CONNECTING... (STATE: %d)",
                      self.name ? self.name : self, self.state);
            }

            isStreamOpened = YES;

            [self openReadStream:self.socketReadStream];
            [self openWriteStream:self.socketWriteStream];

            [self suspendWakeUpTimer];
        }
        else {

            void(^forciblyConnectionBlock)(void) = ^{

                [self suspendWakeUpTimer];

                PNLog(PNLogConnectionLayerInfoLevel, self, @"[CONNECTION::%@] LOOKS LIKE STREAMS IN INTERMEDIATE STATE AND OUT OF SYNC. FORCIBLY CONNECTING... (STATE: %d)",
                      self.name ? self.name : self, self.state);

                // Forcibly close all connections
                [self disconnectByUserRequest:NO];
                isStreamOpened = [self connectByUserRequest:byUserRequest];
            };

            if (!PNBitIsOn(self.state, PNConnectionDisconnecting)) {

                // Check whether tried to connect while already connected(-ing) or not
                if (PNBitStrictIsOn(self.state, PNConnectionConnecting) || PNBitStrictIsOn(self.state, PNConnectionConnected) ||
                    PNBitIsOn(self.state, PNConnectionReconnecting) || PNBitIsOn(self.state, PNConnectionResuming)) {

                    NSString *state = @"CONNECTED";
                    if (!PNBitStrictIsOn(self.state, PNConnectionConnecting)) {

                        state = @"CONNECTING";
                    }
                    PNLog(PNLogConnectionLayerInfoLevel, self, @"[CONNECTION::%@] ALREADY %@ (STATE: %d)",
                          self.name ? self.name : self, state, self.state);
                }
                // Looks like tried to connect while was in some intermediate state (both streams in different states
                // as for 'connected' or 'connecting'
                else {

                    forciblyConnectionBlock();
                }
            }
            else {

                if (PNBitStrictIsOn(self.state, PNConnectionDisconnecting)) {

                    PNLog(PNLogConnectionLayerInfoLevel, self, @"[CONNECTION::%@] TRIED TO CONNECT WHILE DISCONNETING. WAIT FOR DISCONNECTION... (STATE: %d)",
                          self.name ? self.name : self, self.state);

                    // Mark that client should try to connect back as soon as disconnection will be completed
                    PNBitOn(&_state, PNConnectionReconnectOnDisconnection);
                }
                else {

                    forciblyConnectionBlock();
                }
            }
        }
    }
    // Looks like configuration not completed
    else {

        PNLog(PNLogConnectionLayerInfoLevel, self, @"[CONNECTION::%@] NOT CONFIGURED YET (STATE: %d)",
              self.name ? self.name : self, self.state);

        // Try prepare connection's streams for future usage
        if ([self prepareStreams]) {

            isStreamOpened = [self connectByUserRequest:byUserRequest];
        }
    }


    return isStreamOpened;
}

- (void)reconnect {

    PNLog(PNLogConnectionLayerInfoLevel, self, @"[CONNECTION::%@] TRYING RECONNECT (STATE: %d)",
            self.name ? self.name : self, self.state);
    PNBitOn(&_state, PNConnectionReconnecting);

    if ([self.delegate connectionShouldRestoreConnection:self]) {

        // Marking that connection instance is reconnecting now and after last connection will be closed should
        // automatically renew connection
        PNBitOff(&_state, PNConnectionReconnectOnDisconnection);

        [self disconnectByUserRequest:PNBitIsOn(self.state, PNByUserRequest)];
    }
    else {

        PNLog(PNLogConnectionLayerInfoLevel, self, @"[CONNECTION::%@] RECONNECT IS IMPOSSIBLE AT THIS MOMENT. WAITING. (STATE: %d)",
              self.name ? self.name : self, self.state);

        [self resumeWakeUpTimer];
    }
}

- (void)disconnect {

    [self disconnectByUserRequest:YES];
}

- (void)disconnectOnInternalRequest {

    [self disconnectByUserRequest:NO];
}

- (void)disconnectByUserRequest:(BOOL)byUserRequest {

    [self startWakeUpTimer];

    PNLog(PNLogConnectionLayerInfoLevel, self, @"[CONNECTION::%@] TRYING DISCONNECT (BY USER REQUEST? %@)(STATE: %d)",
          self.name ? self.name : self, byUserRequest ? @"YES" : @"NO", self.state);

    PNBitsOff(&_state, PNByUserRequest, PNConnectionConnecting, PNConnectionConnected, PNConnectionPrepareToConnect, 0);
#if __IPHONE_OS_VERSION_MIN_REQUIRED
    PNBitOff(&_state, PNConnectionResuming);
#endif
    if (byUserRequest) {

        PNBitOn(&_state, PNByUserRequest);
        PNBitsOff(&_state, PNConnectionReconnectOnDisconnection, PNConnectionExpectingServerToCloseConnection,
                           PNConnectionReconnecting, PNConnectionErrorCleanAll, 0);
#if __IPHONE_OS_VERSION_MIN_REQUIRED
        PNBitsOff(&_state, PNConnectionResuming, PNConnectionSuspending, PNConnectionSuspended, 0);
#endif
    }

    // Clean up cached data
    [self unscheduleRequestsExecution];
    self.proxySettings = nil;

    [self disconnectReadStream:_socketReadStream];
    [self disconnectWriteStream:_socketWriteStream];
}

- (void)destroyStreams {

    PNLog(PNLogConnectionLayerInfoLevel, self, @"[CONNECTION::%@] DESTROY STREAMS (STATE: %d)",
          self.name ? self.name : self, self.state);

    // Clean up cached data
    [self unscheduleRequestsExecution];
    self.proxySettings = nil;

    BOOL isConfiguring = PNBitIsOn(self.state, PNConnectionConfiguring);

    [self destroyReadStream:_socketReadStream];
    [self destroyWriteStream:_socketWriteStream];

    if (isConfiguring) {

        PNBitOn(&_state, PNConnectionConfiguring);
        PNBitsOff(&_state, PNReadStreamCleanConnection, PNReadStreamCleanDisconnection,
                           PNWriteStreamCleanConnection, PNWriteStreamCleanDisconnection, 0);
    }
    else {

        PNBitsOff(&_state, PNReadStreamCleanAll, PNWriteStreamCleanAll, 0);
    }
}

#if __IPHONE_OS_VERSION_MIN_REQUIRED
- (void)suspend {

    // Ensure that connection channel is not in suspended mode already
    if (PNBitStrictIsOn(self.state, PNConnectionConnected) &&
        !PNBitsIsOn(self.state, NO, PNConnectionSuspending, PNConnectionSuspended, 0)) {

        PNBitsOff(&_state, PNConnectionExpectingServerToCloseConnection, PNConnectionReconnectOnDisconnection,
                           PNConnectionPrepareToConnect, PNConnectionReconnecting, PNConnectionErrorCleanAll, 0);
        PNBitOn(&_state, PNConnectionSuspending);
        [self disconnectByUserRequest:NO];
    }
    else if (PNBitIsOn(self.state, PNConnectionSuspended)) {

        [self.delegate connectionDidSuspend:self];
    }

    [self suspendWakeUpTimer];
}

- (void)resume {

    // Ensure that connection channel is in suspended mode
    if (PNBitIsOn(self.state, PNConnectionSuspended) ||
        (!PNBitIsOn(self.state, PNConnectionConnecting) && !PNBitIsOn(self.state, PNConnectionConnected))) {

        [self connectByUserRequest:NO];
    }
    else if (PNBitIsOn(self.state, PNConnectionConnecting) || PNBitIsOn(self.state, PNConnectionConnected)) {

        [self.delegate connectionDidResume:self];
    }

    [self resumeWakeUpTimer];
}
#endif


#pragma mark - Read stream lifecycle management methods

- (void)configureReadStream:(CFReadStreamRef)readStream {

    PNLog(PNLogConnectionLayerInfoLevel, self, @"[CONNECTION::%@::READ] CONFIGURING... (STATE: %d)",
          self.name ? self.name : self, self.state);

    PNBitOff(&_state, PNReadStreamCleanConfiguration);
    PNBitOn(&_state, PNReadStreamConfiguring);

    CFOptionFlags options = (kCFStreamEventOpenCompleted | kCFStreamEventHasBytesAvailable |
                             kCFStreamEventErrorOccurred | kCFStreamEventEndEncountered);
    CFStreamClientContext client = [self streamClientContext];

    // Configuring connection channel instance as client for read stream with described set of handling events
    BOOL isStreamReady = CFReadStreamSetClient(readStream, options, readStreamCallback, &client);
    if (isStreamReady) {

        isStreamReady = CFReadStreamSetProperty(readStream, kCFStreamPropertyShouldCloseNativeSocket, kCFBooleanTrue);
    }

    if (self.streamSecuritySettings != NULL && isStreamReady) {

        // Configuring stream to establish SSL connection
        isStreamReady = CFReadStreamSetProperty(readStream,
                                                (__bridge CFStringRef)NSStreamSocketSecurityLevelKey,
                                                (__bridge CFStringRef)NSStreamSocketSecurityLevelSSLv3);

        if (isStreamReady) {

            // Specify connection security options
            isStreamReady = CFReadStreamSetProperty(readStream, kCFStreamPropertySSLSettings, self.streamSecuritySettings);
        }
    }


    if (isStreamReady) {

        PNLog(PNLogConnectionLayerInfoLevel, self, @"[CONNECTION::%@::READ] CONFIGURATION COMPLETED (STATE: %d)",
              self.name ? self.name : self, self.state);

        PNBitOff(&_state, PNReadStreamConfiguring);
        PNBitOn(&_state, PNReadStreamConfigured);

        // Schedule read stream on current run-loop
        CFReadStreamScheduleWithRunLoop(readStream, CFRunLoopGetCurrent(), kCFRunLoopCommonModes);
    }
    else {

        PNLog(PNLogConnectionLayerInfoLevel, self, @"[CONNECTION::%@::READ] CONFIGURATION FAILED (STATE: %d)",
              self.name ? self.name : self, self.state);

        PNBitOn(&_state, PNReadStreamError);
    }
}

- (void)openReadStream:(CFReadStreamRef)readStream {

    PNLog(PNLogConnectionLayerInfoLevel, self, @"[CONNECTION::%@::READ] OPENING... (STATE: %d)",
          self.name ? self.name : self, self.state);

    PNBitOff(&_state, PNReadStreamCleanConnection);
    PNBitOn(&_state, PNReadStreamConnecting);

    if (!CFReadStreamOpen(readStream)) {

        CFErrorRef error = CFReadStreamCopyError(readStream);
        if (error && CFErrorGetCode(error) != 0) {

            PNLog(PNLogConnectionLayerInfoLevel, self, @"[CONNECTION::%@::READ] FAILED TO OPEN (STATE: %d)",
                  self.name ? self.name : self, self.state);

            PNBitOn(&_state, PNReadStreamError);
            [self handleStreamError:error];
        }
        else {

            CFRunLoopRun();
        }

        PNCFRelease(&error);
    }
    else {

        PNLog(PNLogConnectionLayerInfoLevel, self, @"[CONNECTION::%@::READ] OPEN IS SCHEDUELD (STATE: %d)",
              self.name ? self.name : self, self.state);
    }
}

- (void)disconnectReadStream:(CFReadStreamRef)readStream {

    PNLog(PNLogConnectionLayerInfoLevel, self, @"[CONNECTION::%@::READ] DISCONNECTING... (STATE: %d)",
          self.name ? self.name : self, self.state);

    PNBitsOff(&_state, PNReadStreamCleanConnection, PNReadStreamCleanDisconnection, 0);
    PNBitOn(&_state, PNReadStreamDisconnecting);

    // Check whether there is some data received from server and try to parse it
    if ([_retrievedData length] > 0 || [self.temporaryRetrievedData length] > 0) {

        [self processResponse];
    }

    // Destroying input buffer
    _retrievedData = nil;

    BOOL streamHasError = PNBitIsOn(self.state, PNReadStreamError);
    [self destroyReadStream:readStream];

    if (streamHasError) {

        PNBitOn(&_state, PNReadStreamError);
    }
    [self handleStreamClose];
}

- (void)destroyReadStream:(CFReadStreamRef)readStream {

    PNLog(PNLogConnectionLayerInfoLevel, self, @"[CONNECTION::%@::READ] DESTROYING... (STATE: %d)",
          self.name ? self.name : self, self.state);

    if (readStream != NULL) {

        CFReadStreamSetClient(readStream, kCFStreamEventNone, NULL, NULL);
        CFReadStreamClose(readStream);
        PNCFRelease(&readStream);
        self.socketReadStream = NULL;
    }

    PNBitOff(&_state, PNReadStreamCleanConfiguration);

    PNLog(PNLogConnectionLayerInfoLevel, self, @"[CONNECTION::%@::READ] DESTROYED (STATE: %d)",
          self.name ? self.name : self, self.state);
}


#pragma mark - Read stream lifecycle data processing methods

- (void)readStreamContent {

    PNLog(PNLogConnectionLayerInfoLevel, self, @"[CONNECTION::%@::READ] READING ARRIVED DATA (STATE: %d)",
          self.name ? self.name : self, self.state);

    if (CFReadStreamHasBytesAvailable(self.socketReadStream)) {

        UInt8 buffer[kPNStreamBufferSize];
        CFIndex readedBytesCount = CFReadStreamRead(self.socketReadStream, buffer, kPNStreamBufferSize);
        if (readedBytesCount > 0) {

            PNLog(PNLogConnectionLayerInfoLevel, self, @"[CONNECTION::%@::READ] READED %d BYTES (STATE: %d)",
                  self.name ? self.name : self, readedBytesCount, self.state);

            // Check whether working on data deserialization or not
            if (self.deserializer.isDeserializing) {

                // Temporary store data in object
                [self.temporaryRetrievedData appendBytes:buffer length:(NSUInteger)readedBytesCount];
            }
            else {

                // Store fetched data
                [self.retrievedData appendBytes:buffer length:(NSUInteger)readedBytesCount];
                [self processResponse];
            }
        }
        // Looks like there is no data or error occurred while tried to read out stream content
        else if (readedBytesCount < 0) {

            PNLog(PNLogConnectionLayerInfoLevel, self, @"[CONNECTION::%@::READ] READ ERROR (STATE: %d)",
                  self.name ? self.name : self, self.state);

            CFErrorRef error = CFReadStreamCopyError(self.socketReadStream);
            PNBitOn(&_state, PNReadStreamError);
            [self handleStreamError:error];

            PNCFRelease(&error);
        }
    }
}

- (void)processResponse {

    // Retrieve response objects from server response
    NSArray *responses = [self.deserializer parseResponseData:self.retrievedData];

    PNLog(PNLogConnectionLayerInfoLevel, self, @"[CONNECTION::%@::READ] {%d} RESPONSE MESSAGES PROCESSED (STATE: %d)",
          self.name ? self.name : self, [responses count], self.state);

    if ([responses count] > 0) {

        [responses enumerateObjectsUsingBlock:^(id response, NSUInteger responseIdx, BOOL *responseEnumeratorStop) {

            if (!PNBitIsOn(self.state, PNConnectionExpectingServerToCloseConnection) &&
                [(id<PNResponseProtocol>)response isLastResponseOnConnection]) {

                PNBitOn(&_state, PNConnectionExpectingServerToCloseConnection);
            }

            [self.delegate connection:self didReceiveResponse:response];
        }];
    }


    // Check whether connection stored some response in temporary storage or not
    if ([self.temporaryRetrievedData length] > 0) {

        [self.retrievedData appendData:self.temporaryRetrievedData];
        self.temporaryRetrievedData.length = 0;

        // Try to process retrieved data once more (maybe some full response arrived from remote server)
        [self processResponse];
    }
}


#pragma mark - Write stream lifecycle management methods


- (void)configureWriteStream:(CFWriteStreamRef)writeStream {

    PNLog(PNLogConnectionLayerInfoLevel, self, @"[CONNECTION::%@::WRITE] CONFIGURING... (STATE: %d)",
          self.name ? self.name : self, self.state);

    PNBitOff(&_state, PNWriteStreamCleanConfiguration);
    PNBitOn(&_state, PNWriteStreamConfiguring);

    CFOptionFlags options = (kCFStreamEventOpenCompleted | kCFStreamEventCanAcceptBytes |
                             kCFStreamEventErrorOccurred | kCFStreamEventEndEncountered);
    CFStreamClientContext client = [self streamClientContext];

    // Configuring connection channel instance as client for write stream with described set of
    // handling events
    BOOL isStreamReady = CFWriteStreamSetClient(writeStream, options, writeStreamCallback, &client);
    if (isStreamReady) {
        
        isStreamReady = CFWriteStreamSetProperty(writeStream, kCFStreamPropertyShouldCloseNativeSocket, kCFBooleanTrue);
    }


    if (isStreamReady) {

        PNLog(PNLogConnectionLayerInfoLevel, self, @"[CONNECTION::%@::WRITE] CONFIGURATION COMPLETED (STATE: %d)",
              self.name ? self.name : self, self.state);

        PNBitOff(&_state, PNWriteStreamConfiguring);
        PNBitOn(&_state, PNWriteStreamConfigured);

        // Schedule write stream on current run-loop
        CFWriteStreamScheduleWithRunLoop(writeStream, CFRunLoopGetCurrent(), kCFRunLoopCommonModes);
    }
    else {

        PNLog(PNLogConnectionLayerInfoLevel, self, @"[CONNECTION::%@::WRITE] CONFIGURATION FAILED (STATE: %d)",
              self.name ? self.name : self, self.state);

        PNBitOn(&_state, PNWriteStreamError);
    }
}

- (void)openWriteStream:(CFWriteStreamRef)writeStream {

    PNLog(PNLogConnectionLayerInfoLevel, self, @"[CONNECTION::%@::WRITE] OPENING... (STATE: %d)",
          self.name ? self.name : self, self.state);

    PNBitOff(&_state, PNWriteStreamCleanConnection);
    PNBitOn(&_state, PNWriteStreamConnecting);

    if (!CFWriteStreamOpen(writeStream)) {

        CFErrorRef error = CFWriteStreamCopyError(writeStream);
        if (error && CFErrorGetCode(error) != 0) {

            PNLog(PNLogConnectionLayerInfoLevel, self, @"[CONNECTION::%@::WRITE] FAILED TO OPEN (STATE: %d)",
                  self.name ? self.name : self, self.state);

            PNBitOn(&_state, PNWriteStreamError);
            [self handleStreamError:error];
        }
        else {

            CFRunLoopRun();
        }

        PNCFRelease(&error);
    }
    else {

        PNLog(PNLogConnectionLayerInfoLevel, self, @"[CONNECTION::%@::WRITE] OPEN IS SCHEDULED (STATE: %d)",
              self.name ? self.name : self, self.state);
    }
}

- (void)disconnectWriteStream:(CFWriteStreamRef)writeStream {

    PNLog(PNLogConnectionLayerInfoLevel, self, @"[CONNECTION::%@::WRITE] DISCONNECTING... (STATE: %d)",
          self.name ? self.name : self, self.state);

    PNBitsOff(&_state, PNWriteStreamCleanConnection, PNWriteStreamCleanDisconnection, 0);
    PNBitOn(&_state, PNWriteStreamDisconnecting);
    self.writeStreamCanHandleData = NO;

    // Handle canceled request (if there was such)
    [self handleRequestSendingCancelation];

    BOOL streamHasError = PNBitIsOn(self.state, PNWriteStreamError);
    [self destroyWriteStream:writeStream];

    if (streamHasError) {

        PNBitOn(&_state, PNWriteStreamError);
    }
    [self handleStreamClose];
}

- (void)destroyWriteStream:(CFWriteStreamRef)writeStream {

    PNLog(PNLogConnectionLayerInfoLevel, self, @"[CONNECTION::%@::WRITE] DESTROYING... (STATE: %d)",
          self.name ? self.name : self, self.state);

    if (writeStream != NULL) {

        CFWriteStreamSetClient(writeStream, kCFStreamEventNone, NULL, NULL);
        CFWriteStreamClose(writeStream);

        PNCFRelease(&writeStream);
        self.socketWriteStream = NULL;
    }

    PNBitOff(&_state, PNWriteStreamCleanConfiguration);

    PNLog(PNLogConnectionLayerInfoLevel, self, @"[CONNECTION::%@::WRITE] DESTROYED (STATE: %d)",
          self.name ? self.name : self, self.state);
}


#pragma mark - Write stream buffer management methods

- (void)prepareNextRequestPacket {

    // Check whether data source can provide some data right after connection is established or not
    if ([self.dataSource hasDataForConnection:self]) {

        NSString *requestIdentifier = [self.dataSource nextRequestIdentifierForConnection:self];
        self.writeBuffer = [self.dataSource connection:self requestDataForIdentifier:requestIdentifier];
    }
}

- (void)writeBufferContent {

    PNLog(PNLogConnectionLayerInfoLevel, self, @"[CONNECTION::%@::WRITE] WRITE BUFFER CONTENT (STATE: %d)",
          self.name ? self.name : self, self.state);

    // Check whether there is connection which can be used to write data
    if (PNBitStrictIsOn(self.state, PNConnectionConnected) && self.writeBuffer != nil) {

        PNBitOff(&_state, PNWriteStreamError);

        if (self.writeBuffer != nil && self.writeBuffer.length > 0) {

            PNBitOff(&_state, PNWriteStreamError);
            PNBitOn(&_state, PNSendingData);

            // Check whether connection can pull some data
            // from write buffer or not
            BOOL isWriteBufferIsEmpty = ![self.writeBuffer hasData];
            if (!isWriteBufferIsEmpty) {

                if (self.isWriteStreamCanHandleData) {

                    // Check whether we just started request processing or not
                    if (self.writeBuffer.offset == 0) {

                        // Mark that buffer content sending was initiated
                        self.writeBuffer.sendingBytes = YES;

                        // Notify data source that we started request processing
                        [self.dataSource connection:self processingRequestWithIdentifier:self.writeBuffer.requestIdentifier];
                    }


                    // Try write data into write stream
                    CFIndex bytesWritten = CFWriteStreamWrite(self.socketWriteStream, [self.writeBuffer buffer],
                                                              [self.writeBuffer bufferLength]);

                    // Check whether error occurred while tried to process request
                    if (bytesWritten < 0) {

                        PNLog(PNLogConnectionLayerInfoLevel, self, @"[CONNECTION::%@::WRITE] WRITE ERROR (STATE: %d)",
                              self.name ? self.name : self, self.state);

                        // Mark that buffer content is not processed at this moment
                        self.writeBuffer.sendingBytes = NO;

                        // Retrieve error which occurred while tried to write buffer into socket
                        CFErrorRef writeError = CFWriteStreamCopyError(self.socketWriteStream);
                        PNBitOn(&_state, PNWriteStreamError);
                        [self handleRequestProcessingError:writeError];

                        isWriteBufferIsEmpty = YES;

                        PNCFRelease(&writeError);
                    }
                    // Check whether socket was able to transfer whole write buffer at once or not
                    else if (bytesWritten == self.writeBuffer.length) {

                        PNLog(PNLogConnectionLayerInfoLevel, self, @"[CONNECTION::%@::WRITE] WRITTEN WHOLE REQUEST BODY (%d/%d BYTES)(STATE: %d)",
                              self.name ? self.name : self, bytesWritten, self.writeBuffer.length, self.state);

                        // Mark that buffer content is not processed at this moment
                        self.writeBuffer.sendingBytes = NO;

                        // Set readout offset to buffer content length (there is no more data to send)
                        self.writeBuffer.offset = self.writeBuffer.length;

                        isWriteBufferIsEmpty = YES;
                    }
                    else {

                        PNLog(PNLogConnectionLayerInfoLevel, self, @"[CONNECTION::%@::WRITE] WRITTEN PART OF REQUEST BODY (%d/%d BYTES)(STATE: %d)",
                              self.name ? self.name : self, bytesWritten, self.writeBuffer.length, self.state);

                        // Increase buffer readout offset
                        self.writeBuffer.offset = (self.writeBuffer.offset + bytesWritten);
                        if (self.writeBuffer.offset == self.writeBuffer.length) {

                            isWriteBufferIsEmpty = YES;
                        }
                    }
                }
            }


            if (isWriteBufferIsEmpty) {

                PNBitOff(&_state, PNSendingData);

                // Retrieving reference on request's identifier who's body has been sent
                NSString *identifier = self.writeBuffer.requestIdentifier;
                self.writeBuffer = nil;

                [self.dataSource connection:self didSendRequestWithIdentifier:identifier];


                // Check whether should try to send next request or not
                if (PNBitIsOn(self.state, PNConnectionProcessingRequests)) {

                    [self scheduleNextRequestExecution];
                }
            }
        }
        // Looks like because of some reasons there is no new data
        else {

            if (PNBitIsOn(self.state, PNConnectionProcessingRequests)) {

                [self scheduleNextRequestExecution];
            }
        }
    }
    else if (PNBitStrictIsOn(self.state, PNConnectionConnected)) {

        PNLog(PNLogConnectionLayerInfoLevel, self, @"[CONNECTION::%@::WRITE] NOTHING TO WRITE (STATE: %d)",
              self.name ? self.name : self, self.state);
    }
}


#pragma mark - Handler methods

- (void)handleStreamConnection {

    PNLog(PNLogConnectionLayerInfoLevel, self, @"[CONNECTION::%@] HANDLE STREAM CONNECTION OPENED (STATE: %d)",
          self.name ? self.name : self, self.state);

    // Ensure that both read and write streams are connected before notify
    // delegate about successful connection
    if (PNBitStrictIsOn(self.state, PNConnectionConnecting) && PNBitStrictIsOn(self.state, PNConnectionConnected)) {

        // Terminate wake up timer
        [self stopWakeUpTimer];

        BOOL connectedAfterError = PNBitIsOn(self.state, PNConnectionError);
        BOOL isConnectedAfterExpectedDisconnection = PNBitIsOn(self.state, PNConnectionExpectingServerToCloseConnection);
        BOOL isReconnecting = PNBitIsOn(self.state, PNConnectionReconnecting);
        PNBitsOff(&_state, PNConnectionExpectingServerToCloseConnection, PNConnectionConnecting, PNConnectionReconnecting,
                           PNConnectionDisconnecting, PNConnectionDisconnected, PNConnectionReconnectOnDisconnection,
                           PNConnectionErrorCleanAll, 0);

        [self.delegate connection:self didConnectToHost:self.configuration.origin];

        // Check whether we restored connection after server gracefully closed it.
        // In case if server previously closed connection gracefully, there is no need in delegate notifying
        // (only restore requests processing).
        if (!isConnectedAfterExpectedDisconnection) {

    #if __IPHONE_OS_VERSION_MIN_REQUIRED
            PNBitsOff(&_state, PNConnectionSuspending, PNConnectionSuspended, 0);

            // Check whether connection is restoring from suspended mode or not
            if (PNBitIsOn(self.state, PNConnectionResuming)) {

                PNLog(PNLogConnectionLayerInfoLevel, self, @"[CONNECTION::%@] RESUMED (STATE: %d)",
                      self.name ? self.name : self, self.state);

                PNBitOff(&_state, PNConnectionResuming);

                [self.delegate connectionDidResume:self];
            }
            else if (!connectedAfterError) {
    #else
            if (!connectedAfterError) {
    #endif
                NSString *action = @"CONNECTED";
                if (isReconnecting) {

                    action = @"RECONNECTED";
                }
                PNLog(PNLogConnectionLayerInfoLevel, self, @"[CONNECTION::%@] %@ (BY USER REQUEST? %@)(STATE: %d)",
                      self.name ? self.name : self, action, PNBitIsOn(self.state, PNByUserRequest) ? @"YES" : @"NO", self.state);

                [self.delegate connection:self didReconnectToHost:self.configuration.origin];
            }
            else {

                PNLog(PNLogConnectionLayerInfoLevel, self, @"[CONNECTION::%@] RECONNECTED AFTER ERROR (STATE: %d)",
                      self.name ? self.name : self, self.state);

                [self.delegate connection:self didReconnectToHost:self.configuration.origin];
            }
            PNBitOff(&_state, PNByUserRequest);
        }

        // Check whether channel should process requests from upper layers or not
        if (PNBitIsOn(self.state, PNConnectionProcessingRequests)) {

            [self scheduleNextRequestExecution];
        }
    }
}

- (void)handleStreamClose {

    PNLog(PNLogConnectionLayerInfoLevel, self, @"[CONNECTION::%@] HANDLE STREAM CONNECTION CLOSED (STATE: %d)",
          self.name ? self.name : self, self.state);

    // Ensure that both read and write streams reset before notify delegate
    // about connection close event
    if (PNBitStrictIsOn(self.state, PNConnectionDisconnecting) && !PNBitStrictIsOn(self.state, PNConnectionDisconnected)) {

        BOOL isDisconnectedOnError = PNBitIsOn(self.state, PNConnectionError);
        PNBitsOff(&_state, PNReadStreamCleanAll, PNWriteStreamCleanAll, 0);
        PNBitOn(&_state, PNConnectionDisconnected);

        // Check whether there was attempt to connect while was connection was in disconnection state
        if (PNBitIsOn(self.state, PNConnectionExpectingServerToCloseConnection) ||
            PNBitIsOn(self.state, PNConnectionReconnecting) ||
            PNBitIsOn(self.state, PNConnectionReconnectOnDisconnection)) {

            if (PNBitIsOn(self.state, PNConnectionReconnectOnDisconnection)) {

                PNLog(PNLogConnectionLayerInfoLevel, self, @"[CONNECTION::%@] CONNECTING BECAUSE OF PREVIOUS CONNECTINO ATTEMPT... (STATE: %d)",
                        self.name ? self.name : self, self.state);
            }
            else if (PNBitIsOn(self.state, PNConnectionExpectingServerToCloseConnection)) {

                PNLog(PNLogConnectionLayerInfoLevel, self, @"[CONNECTION::%@] EXPECTED DISCONNECTION. RECONNECTING... (STATE: %d)",
                        self.name ? self.name : self, self.state);
            }
            else if (PNBitIsOn(self.state, PNConnectionReconnecting)) {

                PNLog(PNLogConnectionLayerInfoLevel, self, @"[CONNECTION::%@] RECONNECTING... (STATE: %d)",
                        self.name ? self.name : self, self.state);
            }

            PNBitOff(&_state, PNConnectionReconnectOnDisconnection);
            PNBitOff(&_state, PNConnectionReconnecting);
            [self connectByUserRequest:PNBitIsOn(self.state, PNByUserRequest)];
        }
        // Proceed with disconnection
        else {

            if (isDisconnectedOnError) {

                PNBitOn(&_state, PNConnectionError);
            }

#if __IPHONE_OS_VERSION_MIN_REQUIRED
            if (PNBitIsOn(self.state, PNConnectionSuspending)) {

                PNLog(PNLogConnectionLayerInfoLevel, self, @"[CONNECTION::%@] SUSPENDED (STATE: %d)",
                      self.name ? self.name : self, self.state);

                PNBitOff(&_state, PNConnectionSuspending);
                PNBitOn(&_state, PNConnectionSuspended);

                [self.delegate connectionDidSuspend:self];
            }
            else {
#endif
                NSString *errorReason = @"";
                if (isDisconnectedOnError) {

                    errorReason = @"BECAUSE OF ERROR ";
                }
                PNLog(PNLogConnectionLayerInfoLevel, self, @"[CONNECTION::%@] DISCONNECTED %@(STATE: %d)",
                      self.name ? self.name : self, errorReason, self.state);

#if __IPHONE_OS_VERSION_MIN_REQUIRED
                PNBitsOff(&_state, PNConnectionSuspending, PNConnectionSuspended, PNConnectionResuming, 0);
            }

            if (!PNBitIsOn(self.state, PNConnectionSuspended)) {
#endif
                // Check whether connection has been terminated because of error or not
                if (isDisconnectedOnError) {

                    // Attempt to restore connection after small delay defined in 'static' section of this class
                    __pn_desired_weak __typeof__(self) weakSelf = self;
                    dispatch_time_t popTime = dispatch_time(DISPATCH_TIME_NOW, (int64_t) (kPNConnectionRetryDelay * NSEC_PER_SEC));
                    dispatch_after(popTime, dispatch_get_main_queue(), ^{

                        // Check whether connection is still in bad state before issue connection
                        if (PNBitIsOn(weakSelf.state, PNConnectionError)) {

                            PNLog(PNLogConnectionLayerInfoLevel, self, @"[CONNECTION::%@] RECONNECTING ON ERROR... (STATE: %d)",
                                  self.name ? self.name : self, self.state);

                            [weakSelf connectByUserRequest:PNBitIsOn(weakSelf.state, PNByUserRequest)];
                        }
                    });
                }
                else {

                    if (PNBitIsOn(self.state, PNConnectionReconnectingOnWakeUp)) {

                        PNLog(PNLogConnectionLayerInfoLevel, self, @"[CONNECTION::%@] DISCONNECTED ON 'CONNECTION' WAKEUP (STATE: %d)",
                              self.name ? self.name : self, self.state);
                        PNBitOff(&_state, PNConnectionReconnectingOnWakeUp);
                    }
                    else {

                        PNLog(PNLogConnectionLayerInfoLevel, self, @"[CONNECTION::%@] NOTIFY DELEGATE ABOUT DISCONNECTION (STATE: %d)",
                              self.name ? self.name : self, self.state);

                        PNBitOff(&_state, PNByUserRequest);
                        [self.delegate connection:self didDisconnectFromHost:self.configuration.origin];
                    }
                }
#if __IPHONE_OS_VERSION_MIN_REQUIRED
            }
#endif
        }

#if __IPHONE_OS_VERSION_MIN_REQUIRED
        if (!PNBitIsOn(self.state, PNConnectionSuspended)) {
#endif
            [self resumeWakeUpTimer];
#if __IPHONE_OS_VERSION_MIN_REQUIRED
            }
#endif
    }
}

- (void)handleReadStreamHasData {

    [self readStreamContent];
}

- (void)handleWriteStreamCanAcceptData {

    self.writeStreamCanHandleData = YES;
    [self writeBufferContent];
}

- (void)handleRequestSendingCancelation {

    // Check whether data sending layer is processing some request or not
    if (PNBitIsOn(self.state, PNSendingData) || self.writeBuffer != nil) {

        NSString *interruptedRequestIdentifier = self.writeBuffer.requestIdentifier;

        PNLog(PNLogConnectionLayerInfoLevel, self, @"[CONNECTION::%@] UNSCHEDULE REQUEST SENDING (%@)(STATE: %d)",
              self.name ? self.name : self, interruptedRequestIdentifier, self.state);

        self.writeBuffer = nil;
        PNBitOff(&_state, PNSendingData);

        // Notify delegate about that request processing hasn't been completed
        [self.dataSource connection:self didCancelRequestWithIdentifier:interruptedRequestIdentifier];
    }
}

- (void)handleStreamTimeout {

    PNBitsOff(&_state, PNConnectionReconnecting, PNConnectionReconnectOnDisconnection, 0);
#if __IPHONE_OS_VERSION_MIN_REQUIRED
    PNBitsOff(&_state, PNConnectionSuspending, PNConnectionSuspended, PNConnectionResuming, 0);
#endif
    [self reconnect];
}

- (void)handleWakeUpTimer {

    PNLog(PNLogConnectionLayerInfoLevel, self, @"[CONNECTION::%@] WAKE UP TIMER FIRED (%@)(STATE: %d)",
          self.name ? self.name : self, [self stateDescription], self.state);


    // Check whether connection not connected
    if (!PNBitStrictIsOn(self.state, PNConnectionConnected) && !PNBitStrictIsOn(self.state, PNConnectionConnecting)) {

        PNLog(PNLogConnectionLayerInfoLevel, self, @"[CONNECTION::%@] STILL IN BAD STATE (STATE: %d)",
              self.name ? self.name : self, [self stateDescription], self.state);

        // Ask delegate on whether connection should be restored or not
        if ([self.delegate connectionShouldRestoreConnection:self]) {

            PNLog(PNLogConnectionLayerInfoLevel, self, @"[CONNECTION::%@] HAVE A CHANCE TO FIX ITS STATE (STATE: %d)",
                  self.name ? self.name : self, [self stateDescription], self.state);
            PNBitOn(&_state, PNConnectionReconnectingOnWakeUp);

            if (PNBitIsOn(self.state, PNConnectionReconnecting)) {

                [self reconnect];
            }
            else {

                PNBitsOff(&_state, PNReadStreamCleanAll, PNWriteStreamCleanAll, PNConnectionReconnecting,
                                   PNConnectionReconnectOnDisconnection, PNConnectionExpectingServerToCloseConnection, 0);
                [self disconnectByUserRequest:NO];
                [self connectByUserRequest:NO];
            }
        }
        else {

            // Looks like connection can't be established, so there can be no 'connecting' state
            PNBitsOff(&_state, PNConnectionConnecting, PNConnectionDisconnecting, 0);
        }
    }
}

- (NSString *)stringifyStreamStatus:(CFStreamStatus)status {

    NSString *stringifiedStatus = @"NOTHING INTERESTING";

    switch (status) {
        case kCFStreamStatusNotOpen:

            stringifiedStatus = @"STREAM NOT OPENED";
            break;
        case kCFStreamStatusOpening:

            stringifiedStatus = @"STREAM IS OPENING";
            break;
        case kCFStreamStatusOpen:

            stringifiedStatus = @"STREAM IS OPENED";
            break;
        case kCFStreamStatusReading:

            stringifiedStatus = @"READING FROM STREAM";
            break;
        case kCFStreamStatusWriting:

            stringifiedStatus = @"WRITING INTO STREAM";
            break;
        case kCFStreamStatusAtEnd:

            stringifiedStatus = @"STREAM CAN'T READ/WRITE DATA";
            break;
        case kCFStreamStatusClosed:

            stringifiedStatus = @"STREAM CLOSED";
            break;
        case kCFStreamStatusError:

            stringifiedStatus = @"STREAM ERROR OCCURRED";
            break;
    }


    return stringifiedStatus;
}

- (void)handleStreamError:(CFErrorRef)error {

    [self handleStreamError:error shouldCloseConnection:NO];
}

- (void)handleStreamError:(CFErrorRef)error shouldCloseConnection:(BOOL)shouldCloseConnection {

    if (error && CFErrorGetCode(error) != 0) {

        NSString *errorDomain = CFBridgingRelease(CFErrorGetDomain(error));
        PNError *errorObject = [self processStreamError:error];

        PNLog(PNLogConnectionLayerErrorLevel, self, @"[CONNECTION::%@] GOT ERROR: %@ (CFNetwork error code: %d (Domain: %@); connection should be close? %@)(STATE: %d)",
                self.name ? self.name : self, errorObject, CFErrorGetCode(error),
                (__bridge NSString *)CFErrorGetDomain(error),
                shouldCloseConnection ? @"YES" : @"NO", self.state);

        // Check whether error is caused by SSL issues or not
        if ([self isSecurityTransportError:error]) {

            PNLog(PNLogConnectionLayerErrorLevel, self, @"[CONNECTION::%@] SSL ERROR OCCURRED (STATE: %d)",
                  self.name ? self.name : self, self.state);

            if (![self isInternalSecurityTransportError:error]) {

                PNLog(PNLogConnectionLayerInfoLevel, self, @"[CONNECTION::%@] IS SECURITY LEVEL REDUCTION ALLOWED? %@",
                      self.name ? self.name : self, self.configuration.shouldReduceSecurityLevelOnError ? @"YES" : @"NO");
                PNLog(PNLogConnectionLayerInfoLevel, self, @"[CONNECTION::%@] IS IT ALLOWED TO DISCARD SECURITY SETTINGS? %@",
                      self.name ? self.name : self, self.configuration.canIgnoreSecureConnectionRequirement ? @"YES" : @"NO");
                PNLog(PNLogConnectionLayerInfoLevel, self, @"[CONNECTION::%@] CURRENT SSL CONFIGURATION LEVEL: %d",
                      self.name ? self.name : self, self.sslConfigurationLevel);
                
                // Checking whether user allowed to decrease security options and we can do it
                if (self.configuration.shouldReduceSecurityLevelOnError &&
                    self.sslConfigurationLevel == PNConnectionSSLConfigurationStrict) {
                    
                    PNLog(PNLogConnectionLayerInfoLevel, self, @"[CONNECTION::%@] REDUCING SSL REQUIREMENTS",
                          self.name ? self.name : self);

                    shouldCloseConnection = NO;
                    
                    self.sslConfigurationLevel = PNConnectionSSLConfigurationBarelySecure;
                    PNBitOff(&_state, PNConnectionErrorCleanAll);

                    // Try to reconnect with new SSL security settings
                    [self reconnect];
                }
                // Check whether connection can fallback and use plain HTTP connection w/o SSL
                else if (self.configuration.canIgnoreSecureConnectionRequirement &&
                         self.sslConfigurationLevel == PNConnectionSSLConfigurationBarelySecure) {
                    
                    PNLog(PNLogConnectionLayerInfoLevel, self, @"[CONNECTION::%@] DISCARD SSL",
                          self.name ? self.name : self);

                    shouldCloseConnection = NO;
                    
                    self.sslConfigurationLevel = PNConnectionSSLConfigurationInsecure;
                    PNBitOff(&_state, PNConnectionErrorCleanAll);
                    
                    // Try to reconnect with new SSL security settings
                    [self reconnect];
                }
            }
            else {

                PNLog(PNLogConnectionLayerInfoLevel, self, @"[CONNECTION::%@] INTERNAL SSL ERROR OCCURRED (STATE: %d)",
                      self.name ? self.name : self, self.state);

                shouldCloseConnection = NO;
                PNBitOff(&_state, PNConnectionErrorCleanAll);
                
                [self reconnect];
            }
        }
        else if ([errorDomain isEqualToString:(NSString *)kCFErrorDomainPOSIX] ||
                [errorDomain isEqualToString:(NSString *)kCFErrorDomainCFNetwork]) {

            PNLog(PNLogConnectionLayerErrorLevel, self, @"[CONNECTION::%@] SOCKET GENERAL ERROR OCCURRED (STATE: %d)",
                  self.name ? self.name : self, self.state);

            // Check whether connection should be reconnected because of critical error
            if ([self isConnectionIssuesError:error]) {

                PNLog(PNLogConnectionLayerErrorLevel, self, @"[CONNECTION::%@] SOCKET ERROR BECAUSE OF INTERNET (STATE: %d)",
                        self.name ? self.name : self, self.state);

                // Mark that we should init streams close because of critical error
                shouldCloseConnection = YES;
            }
            
            if ([self isTemporaryServerError:error]) {

                PNLog(PNLogConnectionLayerErrorLevel, self, @"[CONNECTION::%@] SOCKET GENERAL ERROR BECAUSE OF TEMPORARY ISSUES WITH SERVER (STATE: %d)",
                        self.name ? self.name : self, self.state);

                shouldCloseConnection = NO;
                PNBitOff(&_state, PNConnectionErrorCleanAll);
                
                [self reconnect];
            }
        }

        if (shouldCloseConnection) {

            // Check whether we are tried to establish connection and some error occurred there
            if (PNBitIsOn(self.state, PNConnectionConnecting)) {

                shouldCloseConnection = PNBitIsOn(self.state, PNByUserRequest);
                if (!shouldCloseConnection) {

                    [self reconnect];
                }
            }
        }


        if (shouldCloseConnection) {

            // Check whether error occurred during data sending or not
            if (PNBitIsOn(self.state, PNConnectionProcessingRequests)) {

                [self handleRequestProcessingError:error];
            }


            if (PNBitIsOn(self.state, PNConnectionDisconnecting)) {

                [self.delegate connection:self willDisconnectFromHost:self.configuration.origin withError:errorObject];

                PNLog(PNLogConnectionLayerInfoLevel, self, @"[CONNECTION::%@] CLOSING STREAMS BECAUSE OF ERROR (STATE: %d)",
                      self.name ? self.name : self, self.state);

                BOOL byUserRequest = PNBitIsOn(self.state, PNByUserRequest);
                [self disconnectByUserRequest:byUserRequest];
            }
            else if (PNBitIsOn(self.state, PNConnectionConnecting)) {

                PNBitOff(&_state, PNByUserRequest);
                [self disconnectByUserRequest:NO];
                [self.delegate connection:self connectionDidFailToHost:self.configuration.origin withError:errorObject];
            }
        }
    }
}

- (void)handleStreamSetupError {

    if (PNBitsIsOn(self.state, YES, PNByUserRequest, PNConnectionPrepareToConnect, 0)) {

        // Prepare error message which will be
        // sent to connection channel delegate
        PNError *setupError = [PNError errorWithCode:kPNConnectionErrorOnSetup];

        [self.delegate connection:self connectionDidFailToHost:self.configuration.origin withError:setupError];
    }
    else {

        __pn_desired_weak __typeof__(self) weakSelf = self;
        int64_t delay = 1;
        if (PNBitsIsOn(self.state, YES, PNConnectionConfiguring, PNConnectionPrepareToConnect, 0)) {

            delay = kPNConnectionRetryDelay;
        }
        dispatch_time_t popTime = dispatch_time(DISPATCH_TIME_NOW, (int64_t) (delay * NSEC_PER_SEC));

        void(^delayedBlock)(void) = ^{

            // Check whether connection is still in bad state before issue connection
            if (PNBitIsOn(weakSelf.state, PNConnectionConfiguring)) {

                if (weakSelf.retryCount + 1 < kPNMaximumRetryCount) {

                    weakSelf.retryCount++;
                    if (PNBitsIsOn(weakSelf.state, YES, PNConnectionConfiguring, PNConnectionPrepareToConnect, 0)) {

                        [self connectByUserRequest:NO];
                    }
                    else {

                        [weakSelf prepareStreams];
                    }
                }
                else {

                    PNBitsOff(&_state, PNConnectionConfiguring, PNConnectionConnecting, 0);
                    weakSelf.retryCount = 0;
                    [weakSelf.delegate connectionConfigurationDidFail:weakSelf];
                }
            }
        };

        dispatch_after(popTime, dispatch_get_main_queue(), delayedBlock);
    }
}

- (void)handleRequestProcessingError:(CFErrorRef)error {

    if (error && CFErrorGetCode(error) != 0) {

        if (self.writeBuffer && PNBitIsOn(self.state, PNSendingData)) {

            [self.dataSource connection:self didFailToProcessRequestWithIdentifier:self.writeBuffer.requestIdentifier
                              withError:[self processStreamError:error]];
        }
    }
}


#pragma mark - Misc methods

- (void)startWakeUpTimer {

    if (self.wakeUpTimer == NULL) {

        self.wakeUpTimerSuspended = YES;

        dispatch_source_t timerSource = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, dispatch_get_main_queue());
        PNDispatchRetain(timerSource);
        self.wakeUpTimer = timerSource;
        __pn_desired_weak __typeof__(self) weakSelf = self;
        dispatch_source_set_event_handler(self.wakeUpTimer, ^{

            [weakSelf handleWakeUpTimer];
        });
        dispatch_source_set_cancel_handler(self.wakeUpTimer, ^{

            PNDispatchRelease(timerSource);
            weakSelf.wakeUpTimer = NULL;
        });

        [self resetWakeUpTimer];
    }

    if (self.isWakeUpTimerSuspended) {

        [self resumeWakeUpTimer];
    }
}

- (void)suspendWakeUpTimer {

    if (self.wakeUpTimer != NULL) {

        if (!self.isWakeUpTimerSuspended) {

            self.wakeUpTimerSuspended = YES;
            dispatch_suspend(self.wakeUpTimer);
        }
    }

    self.wakeUpTimerSuspended = NO;
}

- (void)resumeWakeUpTimer {

    if (self.wakeUpTimer == NULL) {

        [self startWakeUpTimer];
    }
    else {

        if (self.isWakeUpTimerSuspended) {

            self.wakeUpTimerSuspended = NO;
            [self resetWakeUpTimer];
            dispatch_resume(self.wakeUpTimer);
        }
    }
}

- (void)stopWakeUpTimer {

    if (self.wakeUpTimer != NULL) {

        [self suspendWakeUpTimer];
        dispatch_source_cancel(self.wakeUpTimer);
    }
}

- (void)resetWakeUpTimer {

    dispatch_time_t start = dispatch_time(DISPATCH_TIME_NOW, (int64_t)(kPNWakeUpTimerInterval * NSEC_PER_SEC));
    dispatch_source_set_timer(self.wakeUpTimer, start, (int64_t)(kPNWakeUpTimerInterval * NSEC_PER_SEC), NSEC_PER_SEC);
}

- (CFStreamClientContext)streamClientContext {

    return (CFStreamClientContext){0, (__bridge void *)(self), NULL, NULL, NULL};
}

- (CFMutableDictionaryRef)streamSecuritySettings {

    if (self.configuration.shouldUseSecureConnection && _streamSecuritySettings == NULL &&
        self.sslConfigurationLevel != PNConnectionSSLConfigurationInsecure) {

        // Configure security settings
        _streamSecuritySettings = CFDictionaryCreateMutable(CFAllocatorGetDefault(), 6, NULL, NULL);
        if (self.sslConfigurationLevel == PNConnectionSSLConfigurationStrict) {

            CFDictionarySetValue(_streamSecuritySettings, kCFStreamSSLLevel, kCFStreamSocketSecurityLevelSSLv3);
            CFDictionarySetValue(_streamSecuritySettings, kCFStreamSSLAllowsExpiredCertificates, kCFBooleanFalse);
            CFDictionarySetValue(_streamSecuritySettings, kCFStreamSSLValidatesCertificateChain, kCFBooleanTrue);
            CFDictionarySetValue(_streamSecuritySettings, kCFStreamSSLAllowsExpiredRoots, kCFBooleanFalse);
            CFDictionarySetValue(_streamSecuritySettings, kCFStreamSSLAllowsAnyRoot, kCFBooleanFalse);
            CFDictionarySetValue(_streamSecuritySettings, kCFStreamSSLPeerName, kCFNull);
        }
        else {

            CFDictionarySetValue(_streamSecuritySettings, kCFStreamSSLLevel, kCFStreamSocketSecurityLevelSSLv3);
            CFDictionarySetValue(_streamSecuritySettings, kCFStreamSSLAllowsExpiredCertificates, kCFBooleanTrue);
            CFDictionarySetValue(_streamSecuritySettings, kCFStreamSSLValidatesCertificateChain, kCFBooleanFalse);
            CFDictionarySetValue(_streamSecuritySettings, kCFStreamSSLAllowsExpiredRoots, kCFBooleanTrue);
            CFDictionarySetValue(_streamSecuritySettings, kCFStreamSSLAllowsAnyRoot, kCFBooleanTrue);
            CFDictionarySetValue(_streamSecuritySettings, kCFStreamSSLPeerName, kCFNull);
        }
    }
    else if (!self.configuration.shouldUseSecureConnection ||
             self.sslConfigurationLevel == PNConnectionSSLConfigurationInsecure) {

        PNCFRelease(&_streamSecuritySettings);
    }


    return _streamSecuritySettings;
}

- (void)retrieveSystemProxySettings {

    if (self.proxySettings == NULL) {

        self.proxySettings = CFBridgingRelease(CFNetworkCopySystemProxySettings());
    }
}

/**
 * Lazy data holder creation
 */
- (NSMutableData *)retrievedData {

    if (_retrievedData == nil) {

        _retrievedData = [NSMutableData dataWithCapacity:kPNStreamBufferSize];
    }


    return _retrievedData;
}

- (PNError *)processStreamError:(CFErrorRef)error {

    PNError *errorInstance = nil;

    if (error) {

        NSString *errorDomain = (__bridge NSString *)CFErrorGetDomain(error);

        if ([self isConnectionIssuesError:error]) {

            int errorCode = kPNClientConnectionClosedOnInternetFailureError;
            if (self.writeBuffer != nil && [self.writeBuffer hasData] && self.writeBuffer.isSendingBytes) {

                errorCode = kPNRequestExecutionFailedOnInternetFailureError;
            }

            errorInstance = [PNError errorWithCode:errorCode];
        }
        else if ([self isSecurityTransportError:error]) {

            errorInstance = [PNError errorWithCode:kPNClientConnectionClosedOnSSLNegotiationFailureError];
        }
        else {

            errorInstance = [PNError errorWithDomain:errorDomain code:CFErrorGetCode(error) userInfo:nil];
        }
    }


    return errorInstance;
}

- (NSString *)stateDescription {

    NSMutableString *connectionState = [NSMutableString stringWithFormat:@"\n[CONNECTION::%@ STATE DESCRIPTION",
                                        self.name ? self.name : self];
    if (PNBitIsOn(self.state, PNReadStreamConfiguring)) {

        [connectionState appendFormat:@"\n- READ STREAM CONFIGURATION..."];
    }
    if (PNBitIsOn(self.state, PNWriteStreamConfiguring)) {

        [connectionState appendFormat:@"\n- WRITE STREAM CONFIGURATION..."];
    }
    if (PNBitIsOn(self.state, PNReadStreamConfigured)) {

        [connectionState appendFormat:@"\n- READ STREAM CONFIGURED"];
    }
    if (PNBitIsOn(self.state, PNWriteStreamConfigured)) {

        [connectionState appendFormat:@"\n- WRITE STREAM CONFIGURED"];
    }
    if (PNBitIsOn(self.state, PNReadStreamConnecting)) {

        [connectionState appendFormat:@"\n- READ STREAM CONNECTING (BY USER REQUEST? %@)...",
                                      PNBitIsOn(self.state, PNByUserRequest) ? @"YES" : @"NO"];
    }
    if (PNBitIsOn(self.state, PNWriteStreamConnecting)) {

        [connectionState appendFormat:@"\n- WRITE STREAM CONNECTING (BY USER REQUEST? %@)...",
                                      PNBitIsOn(self.state, PNByUserRequest) ? @"YES" : @"NO"];
    }
    if (PNBitIsOn(self.state, PNReadStreamConnected)) {

        [connectionState appendFormat:@"\n- READ STREAM CONNECTED"];
    }
    if (PNBitIsOn(self.state, PNWriteStreamConnected)) {

        [connectionState appendFormat:@"\n- WRITE STREAM CONNECTED"];
    }
    if (PNBitIsOn(self.state, PNConnectionPrepareToConnect)) {

        [connectionState appendFormat:@"\n- PREPARING TO CONNECT..."];
    }
    if (PNBitIsOn(self.state, PNConnectionReconnecting)) {

        [connectionState appendFormat:@"\n- RECONNECTING..."];
    }
#if __IPHONE_OS_VERSION_MIN_REQUIRED
    if (PNBitIsOn(self.state, PNConnectionResuming)) {

        [connectionState appendFormat:@"\n- RESUMING..."];
    }
#endif
    if (PNBitIsOn(self.state, PNReadStreamDisconnecting)) {

        [connectionState appendFormat:@"\n- READ STREAM DISCONNECTING (BY USER REQUEST? %@)...",
                                      PNBitIsOn(self.state, PNByUserRequest) ? @"YES" : @"NO"];
    }
    if (PNBitIsOn(self.state, PNWriteStreamDisconnecting)) {

        [connectionState appendFormat:@"\n- WRITE STREAM DISCONNECTING (BY USER REQUEST? %@)...",
                                      PNBitIsOn(self.state, PNByUserRequest) ? @"YES" : @"NO"];
    }
#if __IPHONE_OS_VERSION_MIN_REQUIRED
    if (PNBitIsOn(self.state, PNConnectionSuspending)) {

        [connectionState appendFormat:@"\n- SUSPENDING..."];
    }
#endif
    if (PNBitIsOn(self.state, PNReadStreamDisconnected)) {

        [connectionState appendFormat:@"\n- READ STREAM DISCONNECTED"];
    }
    if (PNBitIsOn(self.state, PNWriteStreamDisconnected)) {

        [connectionState appendFormat:@"\n- WRITE STREAM DISCONNECTED"];
    }
    if (PNBitIsOn(self.state, PNConnectionReconnectOnDisconnection)) {

        [connectionState appendFormat:@"\n- WAITING FOR DISCONNECTION TO CONNECT BACK"];
    }
#if __IPHONE_OS_VERSION_MIN_REQUIRED
    if (PNBitIsOn(self.state, PNConnectionSuspended)) {

        [connectionState appendFormat:@"\n- SUSPENDED"];
    }
#endif
    if (PNBitIsOn(self.state, PNConnectionProcessingRequests)) {

        [connectionState appendFormat:@"\n- REQUEST PROCESSING ENABLED"];
    }
    if (PNBitIsOn(self.state, PNConnectionExpectingServerToCloseConnection)) {

        [connectionState appendFormat:@"\n- CONNECTINO CLOSE WAS EXPECTED (PROBABLY SERVER DOESN'T SUPPORT 'keep-alive' CONNECTION TYPE)"];
    }
    if (PNBitIsOn(self.state, PNSendingData)) {

        [connectionState appendFormat:@"\n- SENDING DATA"];
    }
    if (PNBitIsOn(self.state, PNReadStreamError)) {

        [connectionState appendFormat:@"\n- READ STREAM ERROR"];
    }
    if (PNBitIsOn(self.state, PNWriteStreamError)) {

        [connectionState appendFormat:@"\n- WRITE STREAM ERROR"];
    }


    return connectionState;
}


#pragma mark - Memory management

- (void)dealloc {

    // Closing all streams and free up resources which was allocated for their support
    [self destroyStreams];
    [self stopWakeUpTimer];
    _delegate = nil;
    _proxySettings = nil;
    PNLog(PNLogConnectionLayerInfoLevel, self, @"[CONNECTION::%@] DESTROYED (STATE: %d)",
          _name ? _name : self, _state);

    PNCFRelease(&_streamSecuritySettings);
}

#pragma mark -


@end
