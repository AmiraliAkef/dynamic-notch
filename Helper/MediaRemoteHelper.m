// Now Playing bridge.
//
// Since macOS 15.4, MediaRemote only answers Apple-signed processes, so the app
// runs this library inside /usr/bin/perl (see NowPlaying.swift). It prints one
// JSON object per line on stdout whenever playback changes and reads commands
// from stdin: "play", "pause", "toggle", "next", "previous", "seek <seconds>".

#import <Foundation/Foundation.h>
#include <dlfcn.h>
#include <stdio.h>

typedef void (*MRRegisterFn)(dispatch_queue_t);
typedef void (*MRGetInfoFn)(dispatch_queue_t, void (^)(NSDictionary *));
typedef void (*MRIsPlayingFn)(dispatch_queue_t, void (^)(Boolean));
typedef void (*MRGetClientFn)(dispatch_queue_t, void (^)(id));
typedef NSString *(*MRClientStringFn)(id);
typedef Boolean (*MRSendCommandFn)(int, NSDictionary *);
typedef void (*MRSetElapsedFn)(double);

static MRGetInfoFn getInfo;
static MRIsPlayingFn isPlaying;
static MRGetClientFn getClient;
static MRClientStringFn clientBundle;
static MRClientStringFn clientParentBundle;
static MRSendCommandFn sendCommand;
static MRSetElapsedFn setElapsed;

static dispatch_queue_t queue;
static NSString *lastArtworkKey;
static unsigned long generation;

static void emit(NSDictionary *object) {
    NSData *json = [NSJSONSerialization dataWithJSONObject:object options:0 error:nil];
    if (!json) return;
    fwrite(json.bytes, 1, json.length, stdout);
    fputc('\n', stdout);
    fflush(stdout);
}

static void copyValue(NSMutableDictionary *out, NSDictionary *info, NSString *from, NSString *to) {
    id value = info[from];
    if ([value isKindOfClass:NSString.class] || [value isKindOfClass:NSNumber.class]) out[to] = value;
}

static void refreshNow(void) {
    getInfo(queue, ^(NSDictionary *info) {
        getClient(queue, ^(id client) {
            isPlaying(queue, ^(Boolean playing) {
                NSMutableDictionary *out = [NSMutableDictionary dictionary];
                out[@"playing"] = @(playing);
                if (client && clientBundle) {
                    NSString *bundle = clientBundle(client);
                    if (bundle) out[@"bundle"] = bundle;
                }
                if (client && clientParentBundle) {
                    NSString *parent = clientParentBundle(client);
                    if (parent) out[@"parentBundle"] = parent;
                }
                copyValue(out, info, @"kMRMediaRemoteNowPlayingInfoTitle", @"title");
                copyValue(out, info, @"kMRMediaRemoteNowPlayingInfoArtist", @"artist");
                copyValue(out, info, @"kMRMediaRemoteNowPlayingInfoAlbum", @"album");
                copyValue(out, info, @"kMRMediaRemoteNowPlayingInfoDuration", @"duration");
                copyValue(out, info, @"kMRMediaRemoteNowPlayingInfoElapsedTime", @"elapsed");
                copyValue(out, info, @"kMRMediaRemoteNowPlayingInfoPlaybackRate", @"rate");
                NSDate *timestamp = info[@"kMRMediaRemoteNowPlayingInfoTimestamp"];
                if ([timestamp isKindOfClass:NSDate.class]) out[@"timestamp"] = @(timestamp.timeIntervalSince1970);

                // Artwork is large: only send it when it changes.
                NSData *artwork = info[@"kMRMediaRemoteNowPlayingInfoArtworkData"];
                NSString *key = info[@"kMRMediaRemoteNowPlayingInfoArtworkIdentifier"];
                if ([artwork isKindOfClass:NSData.class] && artwork.length > 0) {
                    if (![key isKindOfClass:NSString.class]) {
                        key = [NSString stringWithFormat:@"%lu-%lu", (unsigned long)artwork.length, (unsigned long)artwork.hash];
                    }
                    if (![key isEqualToString:lastArtworkKey]) {
                        out[@"artwork"] = [artwork base64EncodedStringWithOptions:0];
                        lastArtworkKey = key;
                    }
                    out[@"artworkKey"] = key;
                } else {
                    lastArtworkKey = nil;
                }
                emit(out);
            });
        });
    });
}

// Notifications arrive in bursts; coalesce them.
static void refresh(void) {
    unsigned long mine = ++generation;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 60 * NSEC_PER_MSEC), queue, ^{
        if (mine == generation) refreshNow();
    });
}

static void readCommands(void) {
    char line[256];
    while (fgets(line, sizeof line, stdin)) {
        NSString *text = [[NSString stringWithUTF8String:line]
                          stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
        if ([text isEqualToString:@"play"]) sendCommand(0, nil);
        else if ([text isEqualToString:@"pause"]) sendCommand(1, nil);
        else if ([text isEqualToString:@"toggle"]) sendCommand(2, nil);
        else if ([text isEqualToString:@"next"]) sendCommand(4, nil);
        else if ([text isEqualToString:@"previous"]) sendCommand(5, nil);
        else if ([text hasPrefix:@"seek "]) setElapsed([[text substringFromIndex:5] doubleValue]);
        else if ([text isEqualToString:@"refresh"]) dispatch_async(queue, ^{ refresh(); });
    }
    // The app went away.
    exit(0);
}

// Installed as a Perl XSUB; the two arguments (interpreter, CV) are unused.
// Never returns.
void nm_run(void *interpreter, void *cv) {
    void *mr = dlopen("/System/Library/PrivateFrameworks/MediaRemote.framework/MediaRemote", RTLD_NOW);
    if (!mr) { emit(@{@"error": @"MediaRemote not found"}); exit(1); }

    MRRegisterFn registerForNotifications = dlsym(mr, "MRMediaRemoteRegisterForNowPlayingNotifications");
    getInfo = dlsym(mr, "MRMediaRemoteGetNowPlayingInfo");
    isPlaying = dlsym(mr, "MRMediaRemoteGetNowPlayingApplicationIsPlaying");
    getClient = dlsym(mr, "MRMediaRemoteGetNowPlayingClient");
    clientBundle = dlsym(mr, "MRNowPlayingClientGetBundleIdentifier");
    clientParentBundle = dlsym(mr, "MRNowPlayingClientGetParentAppBundleIdentifier");
    sendCommand = dlsym(mr, "MRMediaRemoteSendCommand");
    setElapsed = dlsym(mr, "MRMediaRemoteSetElapsedTime");
    if (!registerForNotifications || !getInfo || !isPlaying || !getClient || !sendCommand || !setElapsed) {
        emit(@{@"error": @"MediaRemote symbols missing"});
        exit(1);
    }

    queue = dispatch_queue_create("nowplaying", DISPATCH_QUEUE_SERIAL);
    registerForNotifications(queue);
    for (NSString *name in @[@"kMRMediaRemoteNowPlayingInfoDidChangeNotification",
                             @"kMRMediaRemoteNowPlayingApplicationIsPlayingDidChangeNotification",
                             @"kMRMediaRemoteNowPlayingApplicationDidChangeNotification",
                             @"kMRMediaRemoteNowPlayingApplicationClientStateDidChange",
                             @"kMRNowPlayingPlaybackQueueChangedNotification"]) {
        [NSNotificationCenter.defaultCenter addObserverForName:name object:nil queue:nil
                                                    usingBlock:^(NSNotification *note) {
            dispatch_async(queue, ^{ refresh(); });
        }];
    }
    dispatch_async(queue, ^{ refresh(); });
    [NSThread detachNewThreadWithBlock:^{ readCommands(); }];
    CFRunLoopRun();
    exit(0);
}
