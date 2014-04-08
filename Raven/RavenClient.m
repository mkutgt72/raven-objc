//
//  RavenClient.m
//  Raven
//
//  Created by Kevin Renskers on 25-05-12.
//  Copyright (c) 2012 Gangverk. All rights reserved.
//

#import <sys/utsname.h>
#import "RavenClient.h"
#import "RavenClient_Private.h"
#import "RavenConfig.h"

NSString *const kRavenLogLevelArray[] = {
    @"debug",
    @"info",
    @"warning",
    @"error",
    @"fatal"
};

NSString *const userDefaultsKey = @"nl.mixedCase.RavenClient.Exceptions";
NSString *const sentryClient = @"raven-objc/0.1.0";

static RavenClient *sharedClient = nil;

@implementation RavenClient

@synthesize protocolVersion;

void exceptionHandler(NSException *exception) {
	[[RavenClient sharedClient] captureException:exception sendNow:NO];
}

#pragma mark - Setters and getters

- (NSDateFormatter *)dateFormatter {
    if (!_dateFormatter) {
        NSTimeZone *timeZone = [NSTimeZone timeZoneWithName:@"UTC"];
        _dateFormatter = [[NSDateFormatter alloc] init];
        [_dateFormatter setTimeZone:timeZone];
        [_dateFormatter setDateFormat:@"yyyy-MM-dd'T'HH:mm:ss"];
    }

    return _dateFormatter;
}

- (void)setTags:(NSDictionary *)tags {
    [self setTags:tags withDefaultValues:YES];
}

- (void)setTags:(NSDictionary *)tags withDefaultValues:(BOOL)withDefaultValues {
    NSMutableDictionary *mTags = [[NSMutableDictionary alloc] initWithDictionary:tags];

    if (withDefaultValues && ![mTags objectForKey:@"Build version"]) {
        NSString *buildVersion = [[[NSBundle mainBundle] infoDictionary] objectForKey:@"CFBundleShortVersionString"];
        if (buildVersion) {
            [mTags setObject:buildVersion forKey:@"Build version"];
        }
    }

#if TARGET_OS_IPHONE
    if (withDefaultValues && ![mTags objectForKey:@"OS version"]) {
        NSString *osVersion = [[UIDevice currentDevice] systemVersion];
        [mTags setObject:osVersion forKey:@"OS version"];
    }

    if (withDefaultValues && ![mTags objectForKey:@"Device model"]) {
        struct utsname systemInfo;
        uname(&systemInfo);
        NSString *deviceModel = [NSString stringWithCString:systemInfo.machine
                                                   encoding:NSUTF8StringEncoding];
        [mTags setObject:deviceModel forKey:@"Device model"];
    }
#endif

    _tags = mTags;
}

#pragma mark - Singleton and initializers

+ (RavenClient *)clientWithDSN:(NSString *)DSN {
    return [[self alloc] initWithDSN:DSN];
}

+ (RavenClient *)clientWithDSN:(NSString *)DSN extra:(NSDictionary *)extra {
    return [[self alloc] initWithDSN:DSN extra:extra];
}

+ (RavenClient *)clientWithDSN:(NSString *)DSN extra:(NSDictionary *)extra tags:(NSDictionary *)tags {
    return [[self alloc] initWithDSN:DSN extra:extra tags:tags];
}

+ (RavenClient *)sharedClient {
    return sharedClient;
}

- (id)initWithDSN:(NSString *)DSN {
    return [self initWithDSN:DSN extra:@{}];
}

- (id)initWithDSN:(NSString *)DSN extra:(NSDictionary *)extra {
    return [self initWithDSN:DSN extra:extra tags:@{}];
}

- (id)initWithDSN:(NSString *)DSN extra:(NSDictionary *)extra tags:(NSDictionary *)tags {
    self = [super init];
    if (self) {
        self.config = [[RavenConfig alloc] init];
        self.extra = extra;
        self.tags = tags;
        self.protocolVersion = @"4";

        // Parse DSN
        if (![self.config setDSN:DSN]) {
            NSLog(@"Invalid DSN %@!", DSN);
            return nil;
        }

        // Save singleton
        if (sharedClient == nil) {
            sharedClient = self;
        }
    }

    return self;
}

#pragma mark - Messages

- (void)captureMessage:(NSString *)message {
    [self captureMessage:message level:kRavenLogLevelDebugInfo];
}

- (void)captureMessage:(NSString *)message level:(RavenLogLevel)level {
    [self captureMessage:message level:level method:nil file:nil line:0];
}

- (void)captureMessage:(NSString *)message level:(RavenLogLevel)level method:(const char *)method file:(const char *)file line:(NSInteger)line {

    [self captureMessage:message level:level additionalExtra:nil additionalTags:nil method:method file:file line:line];
}

- (void)captureMessage:(NSString *)message level:(RavenLogLevel)level additionalExtra:(NSDictionary *)additionalExtra additionalTags:(NSDictionary *)additionalTags {
    [self captureMessage:message level:level additionalExtra:additionalExtra additionalTags:additionalTags method:nil file:nil line:0];
}

- (void)captureMessage:(NSString *)message
                 level:(RavenLogLevel)level
       additionalExtra:(NSDictionary *)additionalExtra
        additionalTags:(NSDictionary *)additionalTags
                method:(const char *)method
                  file:(const char *)file
                  line:(NSInteger)line {
    NSArray *stacktrace;
    if (method && file && line) {
        NSDictionary *frame = [NSDictionary dictionaryWithObjectsAndKeys:
                               [[NSString stringWithUTF8String:file] lastPathComponent], @"filename",
                               [NSString stringWithUTF8String:method], @"function",
                               [NSNumber numberWithInt:line], @"lineno",
                               nil];

        stacktrace = [NSArray arrayWithObject:frame];
    }

    NSDictionary *data = [self prepareDictionaryForMessage:message
                                                     level:level
                                           additionalExtra:additionalExtra
                                            additionalTags:additionalTags
                                                   culprit:file ? [NSString stringWithUTF8String:file] : nil
                                                stacktrace:stacktrace
                                                 exception:nil];

    [self sendDictionary:data];
}

#pragma mark - Exceptions

- (void)captureException:(NSException *)exception {
    [self captureException:exception sendNow:YES];
}

- (void)captureException:(NSException *)exception sendNow:(BOOL)sendNow {
    [self captureException:exception additionalExtra:nil additionalTags:nil sendNow:sendNow];
}

- (void)captureException:(NSException *)exception additionalExtra:(NSDictionary *)additionalExtra additionalTags:(NSDictionary *)additionalTags sendNow:(BOOL)sendNow {
    NSString *message = [NSString stringWithFormat:@"%@: %@", exception.name, exception.reason];

    NSDictionary *exceptionDict = [NSDictionary dictionaryWithObjectsAndKeys:
                                   exception.name, @"type",
                                   exception.reason, @"value",
                                   nil];

    NSArray *callStack = [exception callStackSymbols];
    NSMutableArray *stacktrace = [[NSMutableArray alloc] initWithCapacity:[callStack count]];
    for (NSString *call in callStack) {
        [stacktrace addObject:[NSDictionary dictionaryWithObjectsAndKeys:call, @"function", nil]];
    }

    NSDictionary *data = [self prepareDictionaryForMessage:message
                                                     level:kRavenLogLevelDebugFatal
                                           additionalExtra:additionalExtra
                                            additionalTags:additionalTags
                                                   culprit:nil
                                                stacktrace:stacktrace
                                                 exception:exceptionDict];

    if (!sendNow) {
        // We can't send this exception to Sentry now, e.g. because the app is killed before the
        // connection can be made. So, save it into NSUserDefaults.
        NSArray *reports = [[NSUserDefaults standardUserDefaults] objectForKey:userDefaultsKey];
        if (reports != nil) {
            NSMutableArray *reportsCopy = [reports mutableCopy];
            [reportsCopy addObject:data];
            [[NSUserDefaults standardUserDefaults] setObject:reportsCopy forKey:userDefaultsKey];
        } else {
            reports = [NSArray arrayWithObject:data];
            [[NSUserDefaults standardUserDefaults] setObject:reports forKey:userDefaultsKey];
        }
        [[NSUserDefaults standardUserDefaults] synchronize];
    } else {
        [self sendDictionary:data];
    }
}

- (void)setupExceptionHandler {
    NSSetUncaughtExceptionHandler(&exceptionHandler);

    // Process saved crash reports
    NSArray *reports = [[NSUserDefaults standardUserDefaults] objectForKey:userDefaultsKey];
    if (reports != nil && [reports count]) {
        for (NSDictionary *data in reports) {
            [self sendDictionary:data];
        }
        [[NSUserDefaults standardUserDefaults] setObject:[NSArray array] forKey:userDefaultsKey];
        [[NSUserDefaults standardUserDefaults] synchronize];
    }
}

#pragma mark - Private methods

- (NSString *)generateUUID {
    CFUUIDRef theUUID = CFUUIDCreate(NULL);
    CFStringRef string = CFUUIDCreateString(NULL, theUUID);
    CFRelease(theUUID);
    NSString *res = [(__bridge NSString *)string stringByReplacingOccurrencesOfString:@"-" withString:@""];
    CFRelease(string);
    return res;
}

- (NSDictionary *)prepareDictionaryForMessage:(NSString *)message
                                        level:(RavenLogLevel)level
                              additionalExtra:(NSDictionary *)additionalExtra
                               additionalTags:(NSDictionary *)additionalTags
                                      culprit:(NSString *)culprit
                                   stacktrace:(NSArray *)stacktrace
                                    exception:(NSDictionary *)exceptionDict {
    NSDictionary *stacktraceDict = [NSDictionary dictionaryWithObjectsAndKeys:stacktrace, @"frames", nil];

    NSMutableDictionary *extra = [NSMutableDictionary dictionaryWithDictionary:self.extra];
    if (additionalExtra.count) {
        [extra addEntriesFromDictionary:additionalExtra];
    }

    NSMutableDictionary *tags = [NSMutableDictionary dictionaryWithDictionary:self.tags];
    if (additionalTags.count) {
        [tags addEntriesFromDictionary:additionalTags];
    }

    return [NSDictionary dictionaryWithObjectsAndKeys:
            [self generateUUID], @"event_id",
            self.config.projectId, @"project",
            [self.dateFormatter stringFromDate:[NSDate date]], @"timestamp",
            kRavenLogLevelArray[level], @"level",
            @"objc", @"platform",

            extra, @"extra",
            tags, @"tags",

            message, @"message",
            culprit ?: @"", @"culprit",
            stacktraceDict, @"stacktrace",
            exceptionDict, @"exception",
            nil];
}

- (void)sendDictionary:(NSDictionary *)dict {
    NSData *JSON = [self encodeJSON:dict];
    [self sendJSON:JSON];
}

- (void)sendJSON:(NSData *)JSON {
    NSString *header = [NSString stringWithFormat:@"Sentry sentry_version=%@, sentry_client=%@, sentry_timestamp=%d, sentry_key=%@, sentry_secret=%@",
                        self.protocolVersion,
                        sentryClient,
                        (NSInteger)[NSDate timeIntervalSinceReferenceDate],
                        self.config.publicKey,
                        self.config.secretKey];

    NSMutableURLRequest *request = [NSMutableURLRequest requestWithURL:self.config.serverURL];
    [request setHTTPMethod:@"POST"];
    [request setValue:@"application/json" forHTTPHeaderField:@"Accept"];
    [request setValue:@"application/json" forHTTPHeaderField:@"Content-Type"];
    [request setValue:[NSString stringWithFormat:@"%d", [JSON length]] forHTTPHeaderField:@"Content-Length"];
    [request setHTTPBody:JSON];
    [request setValue:header forHTTPHeaderField:@"X-Sentry-Auth"];

    [NSURLConnection sendAsynchronousRequest:request
                                       queue:[NSOperationQueue currentQueue]
                           completionHandler:^(NSURLResponse *response, NSData *data, NSError *error) {
                               NSHTTPURLResponse* urlResponse = (NSHTTPURLResponse*)response;

                               if (urlResponse.statusCode != 200) {
                                   switch (urlResponse.statusCode) {
                                       case 400:
                                           NSLog(@"Error when sent error report. Error: %@", [urlResponse.allHeaderFields objectForKey:@"X-Sentry-Error"]);
                                           break;

                                       default:
                                           break;
                                   }
                               }
                           }];
}

#pragma mark - JSON helpers

- (NSData *)encodeJSON:(id)obj {
    NSData *data = [NSJSONSerialization dataWithJSONObject:obj options:0 error:nil];
    return data;
}

@end
