// 再生中の取得と操作だけを行う補助ライブラリ。GroupDock が Apple 署名の /usr/bin/perl に読み込ませて呼ぶ。
// macOS は MediaRemote の再生情報を Apple 署名のプロセスにしか返さないため（実測：自作の実行ファイルでは空）。
// 標準出力に JSON を 1 行書くだけ。通信しない。ファイルを書かない。
#import <Foundation/Foundation.h>
#include <dlfcn.h>
#include <stdio.h>

typedef void (*GetInfoFn)(dispatch_queue_t, void (^)(NSDictionary *));
typedef Boolean (*SendFn)(unsigned int, NSDictionary *);
typedef void *(*LocalOriginFn)(void);
typedef void (*GetCmdsFn)(void *, dispatch_queue_t, void (^)(CFArrayRef));
typedef unsigned int (*CmdOfFn)(id);
typedef Boolean (*EnabledFn)(id);

static void *mediaRemote(void) {
    static void *handle;
    if (!handle) handle = dlopen("/System/Library/PrivateFrameworks/MediaRemote.framework/MediaRemote", RTLD_NOW);
    return handle;
}

// いまの再生元が受け付ける命令の番号（有効なものだけ）。前へ・次へを灰色にするのに使う。
static NSArray *enabledCommands(void) {
    LocalOriginFn local = (LocalOriginFn)dlsym(mediaRemote(), "MRMediaRemoteGetLocalOrigin");
    GetCmdsFn get = (GetCmdsFn)dlsym(mediaRemote(), "MRMediaRemoteGetSupportedCommandsForOrigin");
    CmdOfFn cmdOf = (CmdOfFn)dlsym(mediaRemote(), "MRMediaRemoteCommandInfoGetCommand");
    EnabledFn enabled = (EnabledFn)dlsym(mediaRemote(), "MRMediaRemoteCommandInfoGetEnabled");
    if (!local || !get || !cmdOf || !enabled) return nil;
    __block NSMutableArray *out = [NSMutableArray array];
    get(local(), dispatch_get_main_queue(), ^(CFArrayRef list) {
        for (id info in (__bridge NSArray *)list) {
            if (enabled(info)) [out addObject:@(cmdOf(info))];
        }
        CFRunLoopStop(CFRunLoopGetMain());
    });
    CFRunLoopRunInMode(kCFRunLoopDefaultMode, 1.0, false);
    return out;
}

static void emit(id object) {
    NSData *data = object ? [NSJSONSerialization dataWithJSONObject:object options:0 error:nil] : nil;
    if (data) fwrite(data.bytes, 1, data.length, stdout);
    fputc('\n', stdout);
    fflush(stdout);
}

static void get(BOOL wantArtwork) {
    GetInfoFn fn = mediaRemote() ? (GetInfoFn)dlsym(mediaRemote(), "MRMediaRemoteGetNowPlayingInfo") : NULL;
    if (!fn) { emit(@{}); return; }
    __block NSMutableDictionary *out = [NSMutableDictionary dictionary];
    fn(dispatch_get_main_queue(), ^(NSDictionary *info) {
        for (NSString *key in @[@"kMRMediaRemoteNowPlayingInfoTitle", @"kMRMediaRemoteNowPlayingInfoArtist",
                                @"kMRMediaRemoteNowPlayingInfoAlbum"]) {
            id value = info[key];
            if ([value isKindOfClass:[NSString class]]) out[key] = value;
        }
        id rate = info[@"kMRMediaRemoteNowPlayingInfoPlaybackRate"];
        out[@"playing"] = @([rate isKindOfClass:[NSNumber class]] && [rate doubleValue] > 0);
        // 再生位置は「読んだ時刻の位置」なので、いままでの経過を足して返す。
        id elapsed = info[@"kMRMediaRemoteNowPlayingInfoElapsedTime"];
        id duration = info[@"kMRMediaRemoteNowPlayingInfoDuration"];
        id stamp = info[@"kMRMediaRemoteNowPlayingInfoTimestamp"];
        if ([elapsed isKindOfClass:[NSNumber class]]) {
            double value = [elapsed doubleValue];
            if ([rate isKindOfClass:[NSNumber class]] && [rate doubleValue] > 0 && [stamp isKindOfClass:[NSDate class]]) {
                value += -[stamp timeIntervalSinceNow] * [rate doubleValue];
            }
            out[@"elapsed"] = @(value);
        }
        if ([duration isKindOfClass:[NSNumber class]]) out[@"duration"] = duration;
        id artwork = info[@"kMRMediaRemoteNowPlayingInfoArtworkData"];
        if (wantArtwork && [artwork isKindOfClass:[NSData class]]) out[@"artwork"] = [artwork base64EncodedStringWithOptions:0];
        CFRunLoopStop(CFRunLoopGetMain());
    });
    CFRunLoopRunInMode(kCFRunLoopDefaultMode, 2.0, false);
    NSArray *commands = enabledCommands();
    if (commands) out[@"commands"] = commands;
    emit(out);
}

static void send(unsigned int command) {
    SendFn fn = mediaRemote() ? (SendFn)dlsym(mediaRemote(), "MRMediaRemoteSendCommand") : NULL;
    BOOL ok = fn ? (BOOL)fn(command, nil) : NO;
    // 送った直後に終わると届かない（実測：再生/停止は待たないと効かなかった）。届くまで少し待つ。
    CFRunLoopRunInMode(kCFRunLoopDefaultMode, 0.3, false);
    emit(@{@"sent": @(ok)});
}

// 再生位置を動かす。秒は環境変数 GD_SEEK で受け取る（数字以外・負の値は無視する）。
// 位置の命令（24）に位置を付けて送る（実測：MRMediaRemoteSetElapsedTime は成功を返すが動かなかった）。
static void seek(void) {
    const char *text = getenv("GD_SEEK");
    char *end = NULL;
    double seconds = text ? strtod(text, &end) : -1;
    SendFn fn = mediaRemote() ? (SendFn)dlsym(mediaRemote(), "MRMediaRemoteSendCommand") : NULL;
    __unsafe_unretained NSString **key = mediaRemote()
        ? (__unsafe_unretained NSString **)dlsym(mediaRemote(), "kMRMediaRemoteOptionPlaybackPosition") : NULL;
    BOOL valid = fn && key && text && end && *end == '\0' && seconds >= 0;
    BOOL ok = valid ? (BOOL)fn(24, @{*key: @(seconds)}) : NO;
    CFRunLoopRunInMode(kCFRunLoopDefaultMode, 0.2, false);
    emit(@{@"sent": @(ok)});
}

// perl から引数なしで呼ぶ入口（命令番号：再生/停止 2・次 4・前 5）。
void gd_get_artwork(void) { get(YES); }
void gd_get_plain(void) { get(NO); }
void gd_toggle(void) { send(2); }
void gd_next(void) { send(4); }
void gd_previous(void) { send(5); }
void gd_seek(void) { seek(); }
