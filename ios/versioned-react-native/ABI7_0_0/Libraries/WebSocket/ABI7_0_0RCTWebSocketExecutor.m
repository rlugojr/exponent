/**
 * Copyright (c) 2015-present, Facebook, Inc.
 * All rights reserved.
 *
 * This source code is licensed under the BSD-style license found in the
 * LICENSE file in the root directory of this source tree. An additional grant
 * of patent rights can be found in the PATENTS file in the same directory.
 */

#import "ABI7_0_0RCTDefines.h"

#if ABI7_0_0RCT_DEV // Debug executors are only supported in dev mode

#import "ABI7_0_0RCTWebSocketExecutor.h"

#import "ABI7_0_0RCTConvert.h"
#import "ABI7_0_0RCTLog.h"
#import "ABI7_0_0RCTUtils.h"
#import "ABI7_0_0RCTSRWebSocket.h"

typedef void (^ABI7_0_0RCTWSMessageCallback)(NSError *error, NSDictionary<NSString *, id> *reply);

@interface ABI7_0_0RCTWebSocketExecutor () <ABI7_0_0RCTSRWebSocketDelegate>

@end

@implementation ABI7_0_0RCTWebSocketExecutor
{
  ABI7_0_0RCTSRWebSocket *_socket;
  dispatch_queue_t _jsQueue;
  NSMutableDictionary<NSNumber *, ABI7_0_0RCTWSMessageCallback> *_callbacks;
  dispatch_semaphore_t _socketOpenSemaphore;
  NSMutableDictionary<NSString *, NSString *> *_injectedObjects;
  NSURL *_url;
}

ABI7_0_0RCT_EXPORT_MODULE()

- (instancetype)initWithURL:(NSURL *)URL
{
  ABI7_0_0RCTAssertParam(URL);

  if ((self = [self init])) {
    _url = URL;
  }
  return self;
}

- (void)setUp
{
  if (!_url) {
    NSUserDefaults *standardDefaults = [NSUserDefaults standardUserDefaults];
    NSString *host = [standardDefaults stringForKey:@"websocket-executor-hostname"] ?: @"localhost";
    NSInteger port = [standardDefaults integerForKey:@"websocket-executor-port"] ?: 8081;
    NSString *URLString = [NSString stringWithFormat:@"http://%@:%zd/debugger-proxy?role=client", host, port];
    _url = [ABI7_0_0RCTConvert NSURL:URLString];
  }

  _jsQueue = dispatch_queue_create("com.facebook.ReactABI7_0_0.WebSocketExecutor", DISPATCH_QUEUE_SERIAL);
  _socket = [[ABI7_0_0RCTSRWebSocket alloc] initWithURL:_url];
  _socket.delegate = self;
  _callbacks = [NSMutableDictionary new];
  _injectedObjects = [NSMutableDictionary new];
  [_socket setDelegateDispatchQueue:_jsQueue];

  NSURL *startDevToolsURL = [NSURL URLWithString:@"/launch-js-devtools" relativeToURL:_url];
  [NSURLConnection connectionWithRequest:[NSURLRequest requestWithURL:startDevToolsURL] delegate:nil];

  if (![self connectToProxy]) {
    ABI7_0_0RCTLogError(@"Connection to %@ timed out. Are you running node proxy? If "
                 "you are running on the device, check if you have the right IP "
                 "address in `ABI7_0_0RCTWebSocketExecutor.m`.", _url);
    [self invalidate];
    return;
  }

  NSInteger retries = 3;
  BOOL runtimeIsReady = [self prepareJSRuntime];
  while (!runtimeIsReady && retries > 0) {
    runtimeIsReady = [self prepareJSRuntime];
    retries--;
  }
  if (!runtimeIsReady) {
    ABI7_0_0RCTLogError(@"Runtime is not ready for debugging.\n "
                 "- Make sure Packager server is running.\n"
                 "- Make sure the JavaScript Debugger is running and not paused on a breakpoint or exception and try reloading again.");
    [self invalidate];
    return;
  }
}

- (BOOL)connectToProxy
{
  _socketOpenSemaphore = dispatch_semaphore_create(0);
  [_socket open];
  long connected = dispatch_semaphore_wait(_socketOpenSemaphore, dispatch_time(DISPATCH_TIME_NOW, NSEC_PER_SEC * 10));
  return connected == 0;
}

- (BOOL)prepareJSRuntime
{
  __block NSError *initError;
  dispatch_semaphore_t s = dispatch_semaphore_create(0);
  [self sendMessage:@{@"method": @"prepareJSRuntime"} waitForReply:^(NSError *error, NSDictionary<NSString *, id> *reply) {
    initError = error;
    dispatch_semaphore_signal(s);
  }];
  long runtimeIsReady = dispatch_semaphore_wait(s, dispatch_time(DISPATCH_TIME_NOW, (int64_t)(5 * NSEC_PER_SEC)));
  return runtimeIsReady == 0 && initError == nil;
}

- (void)webSocket:(ABI7_0_0RCTSRWebSocket *)webSocket didReceiveMessage:(id)message
{
  NSError *error = nil;
  NSDictionary<NSString *, id> *reply = ABI7_0_0RCTJSONParse(message, &error);
  NSNumber *messageID = reply[@"replyID"];
  ABI7_0_0RCTWSMessageCallback callback = _callbacks[messageID];
  if (callback) {
    callback(error, reply);
  }
}

- (void)webSocketDidOpen:(ABI7_0_0RCTSRWebSocket *)webSocket
{
  dispatch_semaphore_signal(_socketOpenSemaphore);
}

- (void)webSocket:(ABI7_0_0RCTSRWebSocket *)webSocket didFailWithError:(NSError *)error
{
  dispatch_semaphore_signal(_socketOpenSemaphore);
  dispatch_async(dispatch_get_main_queue(), ^{
    // Give the setUp method an opportunity to report an error first
    ABI7_0_0RCTLogError(@"WebSocket connection failed with error %@", error);
  });
}

- (void)sendMessage:(NSDictionary<NSString *, id> *)message waitForReply:(ABI7_0_0RCTWSMessageCallback)callback
{
  static NSUInteger lastID = 10000;

  dispatch_async(_jsQueue, ^{
    if (!self.valid) {
      NSError *error = [NSError errorWithDomain:@"WS" code:1 userInfo:@{
        NSLocalizedDescriptionKey: @"Runtime is not ready for debugging. Make sure Packager server is running."
      }];
      callback(error, nil);
      return;
    }

    NSNumber *expectedID = @(lastID++);
    _callbacks[expectedID] = [callback copy];
    NSMutableDictionary<NSString *, id> *messageWithID = [message mutableCopy];
    messageWithID[@"id"] = expectedID;
    [_socket send:ABI7_0_0RCTJSONStringify(messageWithID, NULL)];
  });
}

- (void)executeApplicationScript:(NSData *)script sourceURL:(NSURL *)URL onComplete:(ABI7_0_0RCTJavaScriptCompleteBlock)onComplete
{
  NSDictionary<NSString *, id> *message = @{
    @"method": @"executeApplicationScript",
    @"url": ABI7_0_0RCTNullIfNil(URL.absoluteString),
    @"inject": _injectedObjects,
  };
  [self sendMessage:message waitForReply:^(NSError *error, NSDictionary<NSString *, id> *reply) {
    onComplete(error);
  }];
}

- (void)flushedQueue:(ABI7_0_0RCTJavaScriptCallback)onComplete
{
  [self _executeJSCall:@"flushedQueue" arguments:@[] callback:onComplete];
}

- (void)callFunctionOnModule:(NSString *)module
                      method:(NSString *)method
                   arguments:(NSArray *)args
                    callback:(ABI7_0_0RCTJavaScriptCallback)onComplete
{
  [self _executeJSCall:@"callFunctionReturnFlushedQueue" arguments:@[module, method, args] callback:onComplete];
}

- (void)invokeCallbackID:(NSNumber *)cbID
               arguments:(NSArray *)args
                callback:(ABI7_0_0RCTJavaScriptCallback)onComplete
{
  [self _executeJSCall:@"invokeCallbackAndReturnFlushedQueue" arguments:@[cbID, args] callback:onComplete];
}

- (void)_executeJSCall:(NSString *)method arguments:(NSArray *)arguments callback:(ABI7_0_0RCTJavaScriptCallback)onComplete
{
  ABI7_0_0RCTAssert(onComplete != nil, @"callback was missing for exec JS call");
  NSDictionary<NSString *, id> *message = @{
    @"method": method,
    @"arguments": arguments
  };
  [self sendMessage:message waitForReply:^(NSError *socketError, NSDictionary<NSString *, id> *reply) {
    if (socketError) {
      onComplete(nil, socketError);
      return;
    }

    NSString *result = reply[@"result"];
    id objcValue = ABI7_0_0RCTJSONParse(result, NULL);
    onComplete(objcValue, nil);
  }];
}

- (void)injectJSONText:(NSString *)script asGlobalObjectNamed:(NSString *)objectName callback:(ABI7_0_0RCTJavaScriptCompleteBlock)onComplete
{
  dispatch_async(_jsQueue, ^{
    _injectedObjects[objectName] = script;
    onComplete(nil);
  });
}

- (void)executeBlockOnJavaScriptQueue:(dispatch_block_t)block
{
  ABI7_0_0RCTExecuteOnMainThread(block, NO);
}

- (void)executeAsyncBlockOnJavaScriptQueue:(dispatch_block_t)block
{
  dispatch_async(dispatch_get_main_queue(), block);
}

- (void)invalidate
{
  _socket.delegate = nil;
  [_socket closeWithCode:1000 reason:@"Invalidated"];
  _socket = nil;
}

- (BOOL)isValid
{
  return _socket != nil && _socket.readyState == ABI7_0_0RCTSR_OPEN;
}

- (void)dealloc
{
  ABI7_0_0RCTAssert(!self.valid, @"-invalidate must be called before -dealloc");
}

@end

#endif
