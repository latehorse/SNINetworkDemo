//
//  SNIURLProtocol.m
//  SNINetwork
//
//  Created by thinker on 2019/5/29.
//  Copyright © 2019 wanma-studio. All rights reserved.
//

#import "SNIURLProtocol.h"
#import <arpa/inet.h>
#import <objc/runtime.h>

@interface NSURLRequest (NSURLProtocolExtension)

- (NSURLRequest *)sni_getPostRequestIncludeBody;

@end

@implementation NSURLRequest (NSURLProtocolExtension)

- (NSURLRequest *)sni_getPostRequestIncludeBody {
  //return [[self sni_getMutablePostRequestIncludeBody] copy];
  return [[self cyl_getMutablePostRequestIncludeBody] copy];
}

/*
- (NSMutableURLRequest *)sni_getMutablePostRequestIncludeBody {
  NSMutableURLRequest *request = [self mutableCopy];

  if ([self.HTTPMethod.uppercaseString isEqualToString:@"POST"] && !self.HTTPBody) {
    uint8_t buf[1024] = {0};
    NSInputStream *stream = self.HTTPBodyStream;
    NSMutableData *data = [NSMutableData data];
    [stream open];
    while ([stream hasBytesAvailable]) {
      NSInteger length = [stream read:buf maxLength:1024];
      if (length > 0 && stream.streamError == nil) {
        [data appendBytes:(void *)buf length:length];
      }
    }
    [stream close];
    request.HTTPBody = [data copy];
  }

  return request;
}
 */

//ref https://github.com/ChenYilong/iOSBlog/issues/12
- (NSMutableURLRequest *)cyl_getMutablePostRequestIncludeBody {
  NSMutableURLRequest *request = [self mutableCopy];
  if ([self.HTTPMethod.uppercaseString isEqualToString:@"POST"]) {
    if (!self.HTTPBody) {
      NSInteger maxLength = 1024;
      uint8_t buf[maxLength];
      NSInputStream *stream = self.HTTPBodyStream;
      NSMutableData *data = [NSMutableData data];
      [stream open];
      BOOL endOfStreamReached = NO;
      //不能用 [stream hasBytesAvailable]) 判断，处理图片文件的时候这里的[stream hasBytesAvailable]会始终返回YES，导致在while里面死循环。
      while (!endOfStreamReached) {
        NSInteger bytesRead = [stream read:buf maxLength:maxLength];
        if (bytesRead == 0) { //文件读取到最后
          endOfStreamReached = YES;
        } else if (bytesRead == -1) { //文件读取错误
          endOfStreamReached = YES;
        } else if (stream.streamError == nil) {
          [data appendBytes:(void *)buf length:bytesRead];
        }
      }
      request.HTTPBody = [data copy];
      [stream close];
    }
  }
  return request;
}

@end

#define protocolKey @"PropertyKey"
#define alreadyAddedKey @"AlreadyAddedKey"

@interface SNIURLProtocol()<NSStreamDelegate> {
  NSMutableURLRequest *currentRequest;
  NSRunLoop *currentRunLoop;
  NSInputStream *inputStream;
}

@end

@implementation SNIURLProtocol

+ (BOOL)isIPAddress:(NSString *)address {
  if (address) {
    const char *utf8 = [address UTF8String];
    struct in_addr addr4;
    if (inet_pton(AF_INET, utf8, &(addr4.s_addr))) {
      return YES;
    } else {
      struct in6_addr addr6;
      return inet_pton(AF_INET6, utf8, &addr6);
    }
  } else {
    return NO;
  }
}

+ (BOOL)canInitWithRequest:(NSURLRequest *)request {
  if ([NSURLProtocol propertyForKey:protocolKey inRequest:request]) {
    return NO;
  }

  NSURL *url = request.URL;
  if ([url.scheme.lowercaseString isEqualToString:@"https"] && [self isIPAddress:url.host]) {
    return YES;
  }

  return NO;
}

+ (NSURLRequest *)canonicalRequestForRequest:(NSURLRequest *)request {
  return [request sni_getPostRequestIncludeBody];
}

- (void)startLoading {
  NSMutableURLRequest *request = [self.request mutableCopy];
  [NSURLProtocol setProperty:@YES forKey:protocolKey inRequest:request];
  currentRequest = request;
  [self startRequest];
}

- (void)stopLoading {
  if (inputStream.streamStatus == NSStreamStatusOpen) {
    [inputStream removeFromRunLoop:currentRunLoop forMode:NSRunLoopCommonModes];
    [inputStream setDelegate:nil];
    [inputStream close];
  }
  [self.client URLProtocol:self didFailWithError:[[NSError alloc] initWithDomain:@"stop loading" code:-1 userInfo:nil]];
}

- (void)startRequest {
  // URL
  CFStringRef url = (__bridge CFStringRef)[currentRequest.URL absoluteString];
  CFURLRef requestURL = CFURLCreateWithString(kCFAllocatorDefault, url, NULL);

  // Method
  CFStringRef requestMethod = (__bridge CFStringRef)currentRequest.HTTPMethod;

  // Header
  NSDictionary *headerFields = currentRequest.allHTTPHeaderFields;

  // Body
  CFStringRef requestBody = CFSTR("");
  CFDataRef bodyData = CFStringCreateExternalRepresentation(kCFAllocatorDefault, requestBody, kCFStringEncodingUTF8, 0);
  if (currentRequest.HTTPBody) {
    bodyData = (__bridge_retained CFDataRef)currentRequest.HTTPBody;
  } else if(currentRequest.HTTPBodyStream) {
    NSData *data = [self inputStreamToNSData:currentRequest.HTTPBodyStream];
    bodyData = (__bridge_retained CFDataRef)data;
  }

  // Request
  CFHTTPMessageRef request = CFHTTPMessageCreateRequest(kCFAllocatorDefault, requestMethod, requestURL, kCFHTTPVersion1_1);
  CFHTTPMessageSetBody(request, bodyData);

  // Copy Header
  for (NSString *key in headerFields) {
    CFStringRef headerField = (__bridge CFStringRef)key;
    CFStringRef value = (__bridge CFStringRef)[headerFields valueForKey:key];
    CFHTTPMessageSetHeaderFieldValue(request, headerField, value);
  }

  // Read Stream
  CFReadStreamRef readStream = CFReadStreamCreateForHTTPRequest(kCFAllocatorDefault, request);
  inputStream = (__bridge_transfer NSInputStream *)readStream;

  // 设置 SNI host 信息
  NSString *host = [currentRequest.allHTTPHeaderFields objectForKey:@"Host"];
  if (!host) {
    host = currentRequest.URL.host;
  }
  [inputStream setProperty:NSStreamSocketSecurityLevelNegotiatedSSL forKey:NSStreamSocketSecurityLevelKey];
  NSDictionary *sslSettings = @{(id)kCFStreamSSLPeerName: (id)host};
  [inputStream setProperty:sslSettings forKey:(__bridge_transfer NSString *) kCFStreamPropertySSLSettings];
  [inputStream setDelegate:self];

  if (!currentRunLoop) {
    currentRunLoop = [NSRunLoop currentRunLoop];
  }

  [inputStream scheduleInRunLoop:currentRunLoop forMode:NSRunLoopCommonModes];
  [inputStream open];

  CFRelease(request);
  request = NULL;
  CFRelease(requestURL);
  CFRelease(bodyData);
}

- (NSData *)inputStreamToNSData:(NSInputStream *)stream {
  NSMutableData *data = [NSMutableData data];

  size_t size = 4096;
  uint8_t *buff = malloc(size);

  [stream open];
  while ([stream hasBytesAvailable]) {
    NSInteger bytesRead = [stream read:buff maxLength:size];
    if (bytesRead > 0) {
      NSData *readData = [NSData dataWithBytes:buff length:bytesRead];
      [data appendData:readData];
    } else if (bytesRead < 0) {
      [NSException raise:@"StreamReadError" format:@"An error occurred while reading HTTPBodyStream (%ld)", (long)bytesRead];
    } else if (bytesRead == 0) {
      break;
    }
  }
  [stream close];

  free(buff);

  return data;
}

#pragma mark - NSStreamDelegate

- (void)stream:(NSStream *)aStream handleEvent:(NSStreamEvent)eventCode {
  if (eventCode == NSStreamEventHasBytesAvailable) {
    CFReadStreamRef readStream = (__bridge_retained CFReadStreamRef)aStream;
    CFHTTPMessageRef message = (CFHTTPMessageRef)CFReadStreamCopyProperty(readStream, kCFStreamPropertyHTTPResponseHeader);

    if (CFHTTPMessageIsHeaderComplete(message)) {
      // 防止 response 的 header 信息不完整
      UInt8 buffer[16 * 1024];
      UInt8 *buf = NULL;
      NSUInteger length = 0;
      NSInputStream *inputStream = (NSInputStream *)aStream;

      NSNumber *alreadyAdded = objc_getAssociatedObject(aStream, alreadyAddedKey);
      if (!alreadyAdded || ![alreadyAdded boolValue]) {
        objc_setAssociatedObject(aStream, alreadyAddedKey, [NSNumber numberWithBool:YES], OBJC_ASSOCIATION_COPY);

        CFIndex statusCode = CFHTTPMessageGetResponseStatusCode(message);
        CFStringRef httpVersion = CFHTTPMessageCopyVersion(message);
        NSDictionary *headerFields = (__bridge NSDictionary *) (CFHTTPMessageCopyAllHeaderFields(message));
        NSHTTPURLResponse *response = [[NSHTTPURLResponse alloc] initWithURL:currentRequest.URL statusCode:statusCode HTTPVersion:(__bridge NSString *)httpVersion headerFields:headerFields];
        [self.client URLProtocol:self didReceiveResponse:response cacheStoragePolicy:NSURLCacheStorageNotAllowed];

        // 验证证书
        SecTrustRef trust = (__bridge SecTrustRef) [aStream propertyForKey:(__bridge NSString *) kCFStreamPropertySSLPeerTrust];
        SecTrustResultType res = kSecTrustResultInvalid;
        NSMutableArray *policies = [NSMutableArray array];
        NSString *host = [[currentRequest allHTTPHeaderFields] valueForKey:@"Host"];
        if (host) {
          [policies addObject:(__bridge_transfer id)SecPolicyCreateSSL(true, (__bridge CFStringRef)host)];
        } else {
          [policies addObject:(__bridge_transfer id)SecPolicyCreateBasicX509()];
        }

        // 绑定校验策略到服务端的证书上
        SecTrustSetPolicies(trust, (__bridge CFArrayRef) policies);
        if (SecTrustEvaluate(trust, &res) != errSecSuccess) {
          [aStream removeFromRunLoop:currentRunLoop forMode:NSRunLoopCommonModes];
          [aStream setDelegate:nil];
          [aStream close];
          [self.client URLProtocol:self didFailWithError:[[NSError alloc] initWithDomain:@"can not evaluate the server trust" code:-1 userInfo:nil]];
        }
        if (res != kSecTrustResultProceed && res != kSecTrustResultUnspecified) {
          // 证书验证不通过，关闭 stream
          [aStream removeFromRunLoop:currentRunLoop forMode:NSRunLoopCommonModes];
          [aStream setDelegate:nil];
          [aStream close];
          [self.client URLProtocol:self didFailWithError:[[NSError alloc] initWithDomain:@"fail to evaluate the server trust" code:-1 userInfo:nil]];
        } else {
          // 证书通过，返回数据
          if (![inputStream getBuffer:&buf length:&length]) {
            NSInteger amount = [inputStream read:buffer maxLength:sizeof(buffer)];
            buf = buffer;
            length = amount;
          }
          NSData *data = [[NSData alloc] initWithBytes:buf length:length];

          [self.client URLProtocol:self didLoadData:data];
        }
      } else {
        // 证书已验证过，返回数据
        if (![inputStream getBuffer:&buf length:&length]) {
          NSInteger amount = [inputStream read:buffer maxLength:sizeof(buffer)];
          buf = buffer;
          length = amount;
        }
        NSData *data = [[NSData alloc] initWithBytes:buf length:length];

        [self.client URLProtocol:self didLoadData:data];
      }
    }
  } else if (eventCode == NSStreamEventErrorOccurred) {
    [aStream removeFromRunLoop:currentRunLoop forMode:NSRunLoopCommonModes];
    [aStream setDelegate:nil];
    [aStream close];
    [self.client URLProtocol:self didFailWithError:[aStream streamError]];
  } else if (eventCode == NSStreamEventEndEncountered) {
    [self handleResponse];
  }
}

- (void)handleResponse {
  CFReadStreamRef readStream = (__bridge_retained CFReadStreamRef)inputStream;
  CFHTTPMessageRef message = (CFHTTPMessageRef) CFReadStreamCopyProperty(readStream, kCFStreamPropertyHTTPResponseHeader);

  if (CFHTTPMessageIsHeaderComplete(message)) {
    CFIndex statusCode = CFHTTPMessageGetResponseStatusCode(message);

    [inputStream removeFromRunLoop:currentRunLoop forMode:NSRunLoopCommonModes];
    [inputStream setDelegate:nil];
    [inputStream close];

    if (statusCode >= 200 && statusCode < 300) {
      [self.client URLProtocolDidFinishLoading:self];
    } else {
      // TODO: 301...
    }
  } else {
    // 头部信息不完整，关闭 inputStream，通知 client
    [inputStream removeFromRunLoop:currentRunLoop forMode:NSRunLoopCommonModes];
    [inputStream setDelegate:nil];
    [inputStream close];
    [self.client URLProtocolDidFinishLoading:self];
  }
}

@end
