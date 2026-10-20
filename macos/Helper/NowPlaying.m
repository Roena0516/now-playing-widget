// Reads macOS's "now playing" information (MediaRemote) for the browser source (BrowserSource.swift).
//
// Since macOS 15.4, MediaRemote only answers processes Apple allows, and /usr/bin/perl is one of them. So the
// app runs perl, which loads this library and calls np_main as an XSUB (the perl arguments are ignored):
//   /usr/bin/perl -e '<loader>' <path of this library>
// np_main prints one JSON line a second with what is playing and in which process, and reads commands from stdin
// ("toggle", "next", "previous"). It exits when stdin closes, so it ends with the app.
#import <Foundation/Foundation.h>
#include <dlfcn.h>
#include <stdio.h>

typedef void (*GetInfo)(dispatch_queue_t, void (^)(NSDictionary *));
typedef void (*GetPid)(dispatch_queue_t, void (^)(int));
typedef Boolean (*SendCommand)(int, NSDictionary *);

static GetInfo getInfo;
static GetPid getPid;
static SendCommand sendCommand;

static void emit(NSDictionary *line) {
    NSData *data = [NSJSONSerialization dataWithJSONObject:line options:0 error:nil];
    if (!data) return;
    fwrite(data.bytes, 1, data.length, stdout);
    fputc('\n', stdout);
    fflush(stdout);
}

static NSString *text(id value) { return [value isKindOfClass:[NSString class]] ? value : @""; }
static NSNumber *number(id value) { return [value isKindOfClass:[NSNumber class]] ? value : @0; }

static void report(dispatch_queue_t queue) {
    dispatch_semaphore_t done = dispatch_semaphore_create(0);
    __block int pid = 0;
    getPid(queue, ^(int value) { pid = value; dispatch_semaphore_signal(done); });
    if (dispatch_semaphore_wait(done, dispatch_time(DISPATCH_TIME_NOW, 2 * NSEC_PER_SEC)) != 0) return;
    getInfo(queue, ^(NSDictionary *info) {
        NSMutableDictionary *line = [NSMutableDictionary dictionary];
        line[@"pid"] = @(pid);
        if (info) {
            line[@"title"] = text(info[@"kMRMediaRemoteNowPlayingInfoTitle"]);
            line[@"artist"] = text(info[@"kMRMediaRemoteNowPlayingInfoArtist"]);
            line[@"album"] = text(info[@"kMRMediaRemoteNowPlayingInfoAlbum"]);
            line[@"duration"] = number(info[@"kMRMediaRemoteNowPlayingInfoDuration"]);
            line[@"elapsed"] = number(info[@"kMRMediaRemoteNowPlayingInfoElapsedTime"]);
            line[@"rate"] = number(info[@"kMRMediaRemoteNowPlayingInfoPlaybackRate"]);
            id stamp = info[@"kMRMediaRemoteNowPlayingInfoTimestamp"];
            // seconds since 1970 when "elapsed" was measured
            line[@"timestamp"] = @([stamp isKindOfClass:[NSDate class]] ? [stamp timeIntervalSince1970] : 0);
        }
        emit(line);
        dispatch_semaphore_signal(done);
    });
    dispatch_semaphore_wait(done, dispatch_time(DISPATCH_TIME_NOW, 2 * NSEC_PER_SEC));
}

__attribute__((visibility("default"))) void np_main(void *perl, void *cv) {
    void *handle = dlopen("/System/Library/PrivateFrameworks/MediaRemote.framework/MediaRemote", RTLD_LAZY);
    getInfo = handle ? (GetInfo)dlsym(handle, "MRMediaRemoteGetNowPlayingInfo") : NULL;
    getPid = handle ? (GetPid)dlsym(handle, "MRMediaRemoteGetNowPlayingApplicationPID") : NULL;
    sendCommand = handle ? (SendCommand)dlsym(handle, "MRMediaRemoteSendCommand") : NULL;
    if (!getInfo || !getPid || !sendCommand) { emit(@{@"error": @"MediaRemote not available"}); exit(2); }

    // commands from the app; stdin closing means the app is gone
    [NSThread detachNewThreadWithBlock:^{
        char buffer[64];
        while (fgets(buffer, sizeof buffer, stdin)) {
            NSString *command = [[NSString stringWithUTF8String:buffer] stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
            // MRMediaRemoteCommand: 2 toggle play/pause, 4 next track, 5 previous track
            int code = [command isEqualToString:@"toggle"] ? 2 : [command isEqualToString:@"next"] ? 4 : [command isEqualToString:@"previous"] ? 5 : -1;
            if (code >= 0) sendCommand(code, nil);
        }
        exit(0);
    }];

    dispatch_queue_t queue = dispatch_queue_create("nowplaying", DISPATCH_QUEUE_SERIAL);
    for (;;) {
        @autoreleasepool { report(queue); }
        usleep(1000 * 1000);
    }
}
