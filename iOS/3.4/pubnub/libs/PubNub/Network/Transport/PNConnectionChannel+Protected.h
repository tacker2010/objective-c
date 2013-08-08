//
//  PNConnectionChannel+Protected.h
//  pubnub
//
//  This header file used by library internal components which require to access to some methods and properties
//  which shouldn't be visible to other application components
//
//  Created by Sergey Mamontov.
//
//

#import "PNConnectionChannel.h"


@class PNBaseRequest;


@interface PNConnectionChannel (Protected)


#pragma mark - Instance methods

- (void)processResponse:(PNResponse *)response forRequest:(PNBaseRequest *)request;

/**
 * Returns whether communication channel is waiting for request processing completion from backend or not
 */
- (BOOL)isWaitingRequestCompletion:(NSString *)requestIdentifier;

/**
 * Clean up requests stack
 */
- (void)purgeObservedRequestsPool;

/**
 * Retrieve reference on request instance which is stored in one of "observed", "stored", "waiting for response"
 * storages
 */
- (PNBaseRequest *)requestWithIdentifier:(NSString *)identifier;

/**
 * Retrieve reference on request which was observed by communication channel by it's identifier
 */
- (PNBaseRequest *)observedRequestWithIdentifier:(NSString *)identifier;
- (void)removeObservationFromRequest:(PNBaseRequest *)request;

/**
 * Clean up stored requests stack
 */
- (void)purgeStoredRequestsPool;

/**
 * Retrieve reference on request which was stored by communication channel by it's identifier
 */
- (PNBaseRequest *)storedRequestWithIdentifier:(NSString *)identifier;
- (BOOL)isWaitingStoredRequestCompletion:(NSString *)identifier;
- (void)removeStoredRequest:(PNBaseRequest *)request;

/**
 * Retrieve reference on request which is waiting for response from server by it's identifier
 */
- (PNBaseRequest *)responseWaitingRequestWithIdentifier:(NSString *)identifier;
- (PNBaseRequest *)nextRequestWaitingForResponse;
- (BOOL)isWaitingResponseWaitingRequestCompletion:(NSString *)identifier;
- (void)removeResponseWaitingRequest:(PNBaseRequest *)request;

/**
 * Completely destroys request by removing it from queue and requests observation list
 */
- (void)destroyRequest:(PNBaseRequest *)request;

/**
 * Reconnect main communication channel on which this communication channel is working
 */
- (void)reconnect;

/**
 * Clear communication channel request pool
 */
- (void)clearScheduledRequestsQueue;

- (void)terminate;

- (void)cleanUp;

#pragma mark -


@end