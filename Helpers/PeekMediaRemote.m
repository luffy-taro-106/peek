// Peek's own MediaRemote bridge. Loaded into /usr/bin/perl (an Apple
// platform binary, which MediaRemote still serves) and writes now-playing
// state as one JSON object per line on stdout.
#import <Foundation/Foundation.h>
#import <AppKit/AppKit.h>
#include <dlfcn.h>

typedef void (*GetInfoFn)(dispatch_queue_t, void (^)(CFDictionaryRef));
typedef void (*GetPlayingFn)(dispatch_queue_t, void (^)(Boolean));
typedef void (*GetPIDFn)(dispatch_queue_t, void (^)(int));
typedef void (*RegisterFn)(dispatch_queue_t);
typedef Boolean (*SendFn)(int, CFDictionaryRef);
typedef void (*SetElapsedFn)(double);

static void *MR(void) {
    static void *h = NULL;
    if (!h) h = dlopen("/System/Library/PrivateFrameworks/MediaRemote.framework/MediaRemote", RTLD_LAZY);
    return h;
}

static NSString *lastArtworkKey = nil;

static void emit(void) {
    GetInfoFn getInfo = (GetInfoFn)dlsym(MR(), "MRMediaRemoteGetNowPlayingInfo");
    GetPlayingFn getPlaying = (GetPlayingFn)dlsym(MR(), "MRMediaRemoteGetNowPlayingApplicationIsPlaying");
    GetPIDFn getPID = (GetPIDFn)dlsym(MR(), "MRMediaRemoteGetNowPlayingApplicationPID");
    if (!getInfo) return;
    dispatch_queue_t q = dispatch_get_main_queue();
    getInfo(q, ^(CFDictionaryRef ref) {
        NSDictionary *info = (__bridge NSDictionary *)ref;
        getPlaying(q, ^(Boolean playing) {
            getPID(q, ^(int pid) {
                NSMutableDictionary *out = [NSMutableDictionary dictionary];
                out[@"playing"] = @(playing ? YES : NO);
                out[@"pid"] = @(pid);
                NSRunningApplication *app = pid > 0 ? [NSRunningApplication runningApplicationWithProcessIdentifier:pid] : nil;
                if (app.bundleIdentifier) out[@"bundle"] = app.bundleIdentifier;
                if (app.localizedName) out[@"appName"] = app.localizedName;
                if (info.count == 0) { out[@"empty"] = @YES; }
                NSDictionary *keys = @{
                    @"kMRMediaRemoteNowPlayingInfoTitle": @"title",
                    @"kMRMediaRemoteNowPlayingInfoArtist": @"artist",
                    @"kMRMediaRemoteNowPlayingInfoAlbum": @"album",
                    @"kMRMediaRemoteNowPlayingInfoDuration": @"duration",
                    @"kMRMediaRemoteNowPlayingInfoElapsedTime": @"elapsed",
                    @"kMRMediaRemoteNowPlayingInfoPlaybackRate": @"rate",
                    @"kMRMediaRemoteNowPlayingInfoUniqueIdentifier": @"uid",
                    @"kMRMediaRemoteNowPlayingInfoContentItemIdentifier": @"itemId",
                };
                for (NSString *k in keys) {
                    id v = info[k];
                    if ([v isKindOfClass:[NSString class]] || [v isKindOfClass:[NSNumber class]]) out[keys[k]] = v;
                }
                NSDate *ts = info[@"kMRMediaRemoteNowPlayingInfoTimestamp"];
                if ([ts isKindOfClass:[NSDate class]]) out[@"timestamp"] = @([ts timeIntervalSince1970]);
                NSData *art = info[@"kMRMediaRemoteNowPlayingInfoArtworkData"];
                NSString *key = [NSString stringWithFormat:@"%@|%@|%@|%lu", out[@"title"], out[@"artist"], out[@"album"], (unsigned long)art.length];
                if ([art isKindOfClass:[NSData class]] && art.length > 0 && ![key isEqualToString:lastArtworkKey]) {
                    out[@"artwork"] = [art base64EncodedStringWithOptions:0];
                    lastArtworkKey = key;
                }
                NSData *json = [NSJSONSerialization dataWithJSONObject:out options:0 error:nil];
                if (json) {
                    fwrite(json.bytes, 1, json.length, stdout);
                    fputc('\n', stdout);
                    fflush(stdout);
                }
            });
        });
    });
}

// Perl XS entry points: void name(PerlInterpreter*, CV*). They never return.
__attribute__((visibility("default")))
void peek_mr_stream(void *perl, void *cv) {
    @autoreleasepool {
        RegisterFn reg = (RegisterFn)dlsym(MR(), "MRMediaRemoteRegisterForNowPlayingNotifications");
        if (reg) reg(dispatch_get_main_queue());
        NSArray *names = @[@"kMRMediaRemoteNowPlayingInfoDidChangeNotification",
                           @"kMRMediaRemoteNowPlayingApplicationIsPlayingDidChangeNotification",
                           @"kMRMediaRemoteNowPlayingApplicationDidChangeNotification",
                           @"kMRMediaRemoteNowPlayingPlaybackQueueChangedNotification"];
        for (NSString *n in names) {
            [[NSNotificationCenter defaultCenter] addObserverForName:n object:nil queue:nil usingBlock:^(NSNotification *note) { emit(); }];
        }
        // Periodic refresh keeps elapsed time honest; exit if Peek goes away.
        [NSTimer scheduledTimerWithTimeInterval:5 repeats:YES block:^(NSTimer *t) {
            if (getppid() == 1) exit(0);
            emit();
        }];
        emit();
        [[NSRunLoop mainRunLoop] run];
    }
    exit(0);
}

// Command from env PEEK_MR_CMD: play pause toggle next previous seek:<seconds>
__attribute__((visibility("default")))
void peek_mr_send(void *perl, void *cv) {
    @autoreleasepool {
        const char *c = getenv("PEEK_MR_CMD");
        NSString *cmd = c ? [NSString stringWithUTF8String:c] : @"toggle";
        if ([cmd hasPrefix:@"seek:"]) {
            SetElapsedFn set = (SetElapsedFn)dlsym(MR(), "MRMediaRemoteSetElapsedTime");
            if (set) set([[cmd substringFromIndex:5] doubleValue]);
        } else {
            NSDictionary *map = @{@"play": @0, @"pause": @1, @"toggle": @2, @"stop": @3, @"next": @4, @"previous": @5};
            SendFn send = (SendFn)dlsym(MR(), "MRMediaRemoteSendCommand");
            NSNumber *n = map[cmd];
            if (send && n) send(n.intValue, NULL);
        }
        // Give the command a moment to be delivered.
        [[NSRunLoop mainRunLoop] runUntilDate:[NSDate dateWithTimeIntervalSinceNow:0.15]];
    }
    exit(0);
}
