// DockyMediaBridge
//
// Since macOS 15.4, MediaRemote only answers Apple-signed processes. Docky loads this
// library into /usr/bin/perl (an Apple platform binary) and talks to it over pipes:
//   stdout -> one JSON object per line describing the current Now Playing state
//   stdin  <- commands: play | pause | toggle | next | prev | seek <seconds> | refresh

#import <Foundation/Foundation.h>
#include <dlfcn.h>
#include <errno.h>
#include <pthread.h>
#include <unistd.h>

typedef void (*MRGetInfoFn)(dispatch_queue_t, void (^)(NSDictionary *));
typedef void (*MRGetIsPlayingFn)(dispatch_queue_t, void (^)(Boolean));
typedef void (*MRGetClientFn)(dispatch_queue_t, void (^)(id));
typedef NSString *(*MRClientStringFn)(id);
typedef void (*MRRegisterFn)(dispatch_queue_t);
typedef Boolean (*MRSendCommandFn)(uint32_t, NSDictionary *);
typedef void (*MRSetElapsedFn)(double);
typedef void (*MRGetClientsFn)(dispatch_queue_t, void (^)(NSArray *));
typedef Boolean (*MRSendCommandToAppFn)(uint32_t, NSDictionary *, void *, NSString *, int, dispatch_queue_t, void (^)(int, NSArray *));

static MRGetInfoFn MRGetInfo;
static MRGetIsPlayingFn MRGetIsPlaying;
static MRGetClientFn MRGetClient;
static MRClientStringFn MRClientBundleID;
static MRClientStringFn MRClientParentBundleID;
static MRRegisterFn MRRegister;
static MRSendCommandFn MRSendCommand;
static MRSetElapsedFn MRSetElapsed;
static MRSendCommandToAppFn MRSendCommandToApp;
static MRGetClientsFn MRGetClients;

/// Sends a command to one specific player — but only if that app really is a registered
/// Now Playing client. (Addressed to an unknown app, MediaRemote falls back to whatever is
/// Now Playing, which would pause the wrong thing.)
static void sendToApp(uint32_t command, NSString *target) {
    if (!MRSendCommandToApp || !MRGetClients || target.length == 0) return;
    MRGetClients(dispatch_get_main_queue(), ^(NSArray *clients) {
        for (id client in clients) {
            NSString *bundleID = MRClientBundleID ? MRClientBundleID(client) : nil;
            NSString *parentID = MRClientParentBundleID ? MRClientParentBundleID(client) : nil;
            if ([bundleID isEqualToString:target] || [parentID isEqualToString:target]) {
                MRSendCommandToApp(command, nil, NULL, bundleID, 0, dispatch_get_main_queue(), ^(int error, NSArray *statuses) {});
                return;
            }
        }
    });
}

static NSString *lastArtworkKey = nil;
static NSString *lastLine = nil;
static BOOL refreshScheduled = NO;

enum { kMRPlay = 0, kMRPause = 1, kMRTogglePlayPause = 2, kMRNextTrack = 4, kMRPreviousTrack = 5 };

static void writeLine(NSData *data) {
    const uint8_t *bytes = data.bytes;
    size_t left = data.length;
    while (left > 0) {
        ssize_t n = write(STDOUT_FILENO, bytes, left);
        if (n < 0) {
            if (errno == EINTR) continue;
            exit(0); // Docky went away.
        }
        bytes += n;
        left -= (size_t)n;
    }
}

static void emit(NSDictionary *object) {
    NSData *json = [NSJSONSerialization dataWithJSONObject:object options:0 error:nil];
    if (!json) return;
    NSMutableData *line = [json mutableCopy];
    [line appendBytes:"\n" length:1];
    writeLine(line);
}

static id stringOrEmpty(id value) {
    return [value isKindOfClass:[NSString class]] ? value : @"";
}

static id numberOrZero(id value) {
    return [value isKindOfClass:[NSNumber class]] ? value : @0;
}

static void refresh(void) {
    dispatch_queue_t q = dispatch_get_main_queue();
    MRGetInfo(q, ^(NSDictionary *info) {
        MRGetIsPlaying(q, ^(Boolean playing) {
            MRGetClient(q, ^(id client) {
                NSMutableDictionary *out = [NSMutableDictionary dictionary];
                out[@"type"] = @"now";
                out[@"title"] = stringOrEmpty(info[@"kMRMediaRemoteNowPlayingInfoTitle"]);
                out[@"artist"] = stringOrEmpty(info[@"kMRMediaRemoteNowPlayingInfoArtist"]);
                out[@"album"] = stringOrEmpty(info[@"kMRMediaRemoteNowPlayingInfoAlbum"]);
                out[@"duration"] = numberOrZero(info[@"kMRMediaRemoteNowPlayingInfoDuration"]);
                out[@"elapsed"] = numberOrZero(info[@"kMRMediaRemoteNowPlayingInfoElapsedTime"]);
                out[@"rate"] = numberOrZero(info[@"kMRMediaRemoteNowPlayingInfoPlaybackRate"]);
                id ts = info[@"kMRMediaRemoteNowPlayingInfoTimestamp"];
                out[@"timestamp"] = @([ts isKindOfClass:[NSDate class]] ? [ts timeIntervalSince1970] : [[NSDate date] timeIntervalSince1970]);
                out[@"playing"] = @(playing ? YES : NO);

                NSString *bundleID = nil, *parentID = nil;
                if (client) {
                    if (MRClientBundleID) bundleID = MRClientBundleID(client);
                    if (MRClientParentBundleID) parentID = MRClientParentBundleID(client);
                }
                out[@"bundleID"] = stringOrEmpty(bundleID);
                out[@"parentBundleID"] = stringOrEmpty(parentID);

                NSData *art = info[@"kMRMediaRemoteNowPlayingInfoArtworkData"];
                if (![art isKindOfClass:[NSData class]]) art = nil;
                NSString *artKey = stringOrEmpty(info[@"kMRMediaRemoteNowPlayingInfoArtworkIdentifier"]);
                if (art && [artKey length] == 0) artKey = [NSString stringWithFormat:@"%lu-%lu", (unsigned long)art.length, (unsigned long)art.hash];
                if (!art) artKey = @"";
                out[@"artworkKey"] = artKey;

                // Compare everything except artwork bytes so unchanged state is not re-sent.
                NSData *probe = [NSJSONSerialization dataWithJSONObject:out options:NSJSONWritingSortedKeys error:nil];
                NSString *probeLine = probe ? [[NSString alloc] initWithData:probe encoding:NSUTF8StringEncoding] : nil;
                BOOL artChanged = ![artKey isEqualToString:lastArtworkKey ?: @"<none>"];
                if (!artChanged && probeLine && [probeLine isEqualToString:lastLine]) return;
                lastLine = probeLine;

                if (artChanged) {
                    out[@"artwork"] = art ? [art base64EncodedStringWithOptions:0] : @"";
                    lastArtworkKey = artKey;
                }
                emit(out);
            });
        });
    });
}

static void scheduleRefresh(void) {
    if (refreshScheduled) return;
    refreshScheduled = YES;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(60 * NSEC_PER_MSEC)), dispatch_get_main_queue(), ^{
        refreshScheduled = NO;
        refresh();
    });
}

static void handleCommand(NSString *line) {
    NSArray<NSString *> *parts = [line componentsSeparatedByString:@" "];
    NSString *cmd = parts.firstObject;
    if ([cmd isEqualToString:@"play"]) MRSendCommand(kMRPlay, nil);
    else if ([cmd isEqualToString:@"pause"]) MRSendCommand(kMRPause, nil);
    else if ([cmd isEqualToString:@"toggle"]) MRSendCommand(kMRTogglePlayPause, nil);
    else if ([cmd isEqualToString:@"next"]) MRSendCommand(kMRNextTrack, nil);
    else if ([cmd isEqualToString:@"prev"]) MRSendCommand(kMRPreviousTrack, nil);
    else if ([cmd isEqualToString:@"seek"] && parts.count > 1 && MRSetElapsed) MRSetElapsed([parts[1] doubleValue]);
    else if ([cmd isEqualToString:@"refresh"]) { lastLine = nil; lastArtworkKey = nil; }
    else if ([cmd isEqualToString:@"pauseapp"] && parts.count > 1) sendToApp(kMRPause, parts[1]);
    scheduleRefresh();
}

static void *stdinLoop(void *unused) {
    char buffer[1024];
    while (fgets(buffer, sizeof buffer, stdin)) {
        NSString *line = [[NSString stringWithUTF8String:buffer] stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
        if (line.length == 0) continue;
        dispatch_async(dispatch_get_main_queue(), ^{ handleCommand(line); });
    }
    exit(0); // stdin closed: Docky quit.
    return NULL;
}

static void observe(void *handle, const char *symbol) {
    CFStringRef *name = (CFStringRef *)dlsym(handle, symbol);
    if (!name || !*name) return;
    [[NSNotificationCenter defaultCenter] addObserverForName:(__bridge NSString *)*name object:nil queue:[NSOperationQueue mainQueue] usingBlock:^(NSNotification *note) {
        scheduleRefresh();
    }];
}

__attribute__((visibility("default")))
void docky_bridge_main(void) {
    @autoreleasepool {
        signal(SIGPIPE, SIG_DFL);
        void *mr = dlopen("/System/Library/PrivateFrameworks/MediaRemote.framework/MediaRemote", RTLD_NOW);
        if (!mr) { emit(@{@"type": @"error", @"message": @"MediaRemote unavailable"}); exit(1); }

        MRGetInfo = (MRGetInfoFn)dlsym(mr, "MRMediaRemoteGetNowPlayingInfo");
        MRGetIsPlaying = (MRGetIsPlayingFn)dlsym(mr, "MRMediaRemoteGetNowPlayingApplicationIsPlaying");
        MRGetClient = (MRGetClientFn)dlsym(mr, "MRMediaRemoteGetNowPlayingClient");
        MRClientBundleID = (MRClientStringFn)dlsym(mr, "MRNowPlayingClientGetBundleIdentifier");
        MRClientParentBundleID = (MRClientStringFn)dlsym(mr, "MRNowPlayingClientGetParentAppBundleIdentifier");
        MRRegister = (MRRegisterFn)dlsym(mr, "MRMediaRemoteRegisterForNowPlayingNotifications");
        MRSendCommand = (MRSendCommandFn)dlsym(mr, "MRMediaRemoteSendCommand");
        MRSetElapsed = (MRSetElapsedFn)dlsym(mr, "MRMediaRemoteSetElapsedTime");
        MRSendCommandToApp = (MRSendCommandToAppFn)dlsym(mr, "MRMediaRemoteSendCommandToApp");
        MRGetClients = (MRGetClientsFn)dlsym(mr, "MRMediaRemoteGetNowPlayingClients");

        if (!MRGetInfo || !MRGetIsPlaying || !MRGetClient || !MRRegister || !MRSendCommand) {
            emit(@{@"type": @"error", @"message": @"MediaRemote symbols missing"});
            exit(1);
        }

        MRRegister(dispatch_get_main_queue());
        observe(mr, "kMRMediaRemoteNowPlayingInfoDidChangeNotification");
        observe(mr, "kMRMediaRemoteNowPlayingApplicationIsPlayingDidChangeNotification");
        observe(mr, "kMRMediaRemoteNowPlayingApplicationDidChangeNotification");
        observe(mr, "kMRMediaRemoteNowPlayingApplicationClientStateDidChange");
        observe(mr, "kMRMediaRemoteNowPlayingPlaybackQueueChangedNotification");

        pthread_t reader;
        pthread_create(&reader, NULL, stdinLoop, NULL);
        pthread_detach(reader);

        // Safety net in case a player forgets to post notifications.
        dispatch_source_t timer = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, dispatch_get_main_queue());
        dispatch_source_set_timer(timer, dispatch_time(DISPATCH_TIME_NOW, 3 * NSEC_PER_SEC), 3 * NSEC_PER_SEC, NSEC_PER_SEC / 2);
        dispatch_source_set_event_handler(timer, ^{ refresh(); });
        dispatch_resume(timer);

        emit(@{@"type": @"ready"});
        refresh();
    }
    CFRunLoopRun();
}
