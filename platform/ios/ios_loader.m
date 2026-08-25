/* iOS launcher for KOReader.

   Counterpart of base/osx_loader.c. SDL3's iOS support replaces
   `main` with a wrapper that calls UIApplicationMain first; once
   the runloop is up, it invokes our `SDL_main` (this file's main),
   which then boots Lua and hands off to reader.lua.

   Differences vs. macOS:
   - iOS apps have a flat bundle (no Contents/), and the working
     directory at launch is opaque, so we resolve paths via NSBundle.
   - `_NSGetExecutablePath` + `chdir(dirname/../koreader)` would land
     somewhere unrelated to the bundle.
*/

#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#include <SDL3/SDL_main.h>

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <sys/syslimits.h>

#include "lua.h"
#include "lualib.h"
#include "lauxlib.h"

#define LOGNAME "iOS loader"
#define LANGUAGE "en_US.UTF-8"
#define LUA_ERROR "failed to run lua chunk: %s\n"
/* -------------------------------------------------------------------------
 * TEMP DEBUG UI
 * 仅用于排查 iOS 黑屏问题，定位完成后可整段删除。
 * ------------------------------------------------------------------------- */

static NSString *gKOReaderLogPath = nil;

@interface KOReaderLogOverlay : NSObject
@property(nonatomic, weak) UIWindow *mainWindow;
@end

@implementation KOReaderLogOverlay

- (void)start
{
    [[NSNotificationCenter defaultCenter]
        addObserver:self
           selector:@selector(windowBecameVisible:)
               name:UIWindowDidBecomeVisibleNotification
             object:nil];

    [[NSNotificationCenter defaultCenter]
        addObserver:self
           selector:@selector(windowBecameKey:)
               name:UIWindowDidBecomeKeyNotification
             object:nil];

    if ([NSThread isMainThread]) {
        [self installOnCurrentWindow];
    } else {
        dispatch_async(dispatch_get_main_queue(), ^{
            [self installOnCurrentWindow];
        });
    }
}

- (void)windowBecameVisible:(NSNotification *)notification
{
    if ([notification.object isKindOfClass:[UIWindow class]]) {
        [self installButtonOnWindow:(UIWindow *)notification.object];
    }
}

- (void)windowBecameKey:(NSNotification *)notification
{
    if ([notification.object isKindOfClass:[UIWindow class]]) {
        [self installButtonOnWindow:(UIWindow *)notification.object];
    }
}

- (void)installOnCurrentWindow
{
    UIApplication *app = [UIApplication sharedApplication];

    for (UIScene *scene in app.connectedScenes) {
        if (![scene isKindOfClass:[UIWindowScene class]]) {
            continue;
        }

        UIWindowScene *windowScene = (UIWindowScene *)scene;

        for (UIWindow *window in windowScene.windows) {
            if (window.isKeyWindow) {
                [self installButtonOnWindow:window];
                return;
            }
        }

        if (windowScene.windows.count > 0) {
            [self installButtonOnWindow:windowScene.windows.firstObject];
            return;
        }
    }
}

- (void)installButtonOnWindow:(UIWindow *)window
{
    if (!window) {
        return;
    }

    /* 防止重复添加 */
    if ([window viewWithTag:987654] != nil) {
        return;
    }

    self.mainWindow = window;

    CGFloat top = MAX(window.safeAreaInsets.top, 20.0);

    UIButton *button = [UIButton buttonWithType:UIButtonTypeSystem];

    button.tag = 987654;

    button.frame = CGRectMake(
        window.bounds.size.width - 66.0,
        top + 6.0,
        56.0,
        34.0
    );

    button.autoresizingMask =
        UIViewAutoresizingFlexibleLeftMargin |
        UIViewAutoresizingFlexibleBottomMargin;

    button.backgroundColor =
        [UIColor colorWithWhite:0.0 alpha:0.75];

    [button setTitle:@"LOG"
            forState:UIControlStateNormal];

    [button setTitleColor:[UIColor whiteColor]
                 forState:UIControlStateNormal];

    button.titleLabel.font =
        [UIFont boldSystemFontOfSize:13.0];

    [button addTarget:self
               action:@selector(showLog:)
     forControlEvents:UIControlEventTouchUpInside];

    [window addSubview:button];
    [window bringSubviewToFront:button];

    fprintf(stderr, "[debug-ui] LOG button installed\n");
}

- (void)showLog:(UIButton *)sender
{
    NSString *content = @"";

    if (gKOReaderLogPath) {
        NSError *error = nil;

        NSString *fileContent =
            [NSString stringWithContentsOfFile:gKOReaderLogPath
                                      encoding:NSUTF8StringEncoding
                                         error:&error];

        if (fileContent) {
            content = fileContent;
        } else {
            content = [NSString stringWithFormat:
                @"Unable to read log file:\n%@",
                error ?: @"unknown error"];
        }
    } else {
        content = @"Log path is not initialized.";
    }

    /*
     * Alert 不适合显示几十 KB 内容。
     * 屏幕只显示最后 8000 字符，但“复制全部”复制完整日志。
     */
    NSString *displayContent = content;

    if (displayContent.length > 8000) {
        displayContent =
            [NSString stringWithFormat:
                @"... 前面的日志已省略 ...\n\n%@",
                [displayContent substringFromIndex:
                    displayContent.length - 8000]];
    }

    UIAlertController *alert =
        [UIAlertController
            alertControllerWithTitle:@"KOReader Debug Log"
                             message:displayContent
                      preferredStyle:UIAlertControllerStyleAlert];

    [alert addAction:
        [UIAlertAction
            actionWithTitle:@"复制全部"
                      style:UIAlertActionStyleDefault
                    handler:^(UIAlertAction *action) {
                        [UIPasteboard generalPasteboard].string = content;
                    }]];

    [alert addAction:
        [UIAlertAction
            actionWithTitle:@"关闭"
                      style:UIAlertActionStyleCancel
                    handler:nil]];

    UIWindow *window = sender.window ?: self.mainWindow;

    UIViewController *controller = window.rootViewController;

    while (controller.presentedViewController) {
        controller = controller.presentedViewController;
    }

    if (controller) {
        [controller presentViewController:alert
                                 animated:YES
                               completion:nil];
    }
}

@end

static KOReaderLogOverlay *gKOReaderLogOverlay = nil;


/*
 * stdout / stderr 全部写入 Documents/koreader-ios.log
 */
static void KOReaderSetupDebugLog(void)
{
    NSArray<NSString *> *docs =
        NSSearchPathForDirectoriesInDomains(
            NSDocumentDirectory,
            NSUserDomainMask,
            YES);

    if (docs.count == 0) {
        return;
    }

    gKOReaderLogPath =
        [docs[0] stringByAppendingPathComponent:@"koreader-ios.log"];

    const char *path =
        [gKOReaderLogPath fileSystemRepresentation];

    FILE *fp = freopen(path, "w", stderr);

    if (fp) {

        /*
         * stdout 和 stderr 写到同一个文件。
         */
        dup2(fileno(stderr), fileno(stdout));

        setvbuf(stderr, NULL, _IONBF, 0);
        setvbuf(stdout, NULL, _IONBF, 0);
    }

    fprintf(stderr,
            "\n"
            "========================================\n"
            " KOReader iOS Debug Log\n"
            "========================================\n");

    fprintf(stderr,
            "[debug] log path: %s\n",
            path);

    NSString *bundlePath =
        [[NSBundle mainBundle] bundlePath];

    NSString *resourcePath =
        [[NSBundle mainBundle] resourcePath];

    fprintf(stderr,
            "[debug] bundlePath: %s\n",
            [bundlePath fileSystemRepresentation]);

    fprintf(stderr,
            "[debug] resourcePath: %s\n",
            [resourcePath fileSystemRepresentation]);

    NSString *appPath =
        [resourcePath stringByAppendingPathComponent:@"app"];

    NSString *readerLua =
        [appPath stringByAppendingPathComponent:@"reader.lua"];

    NSString *frontend =
        [appPath stringByAppendingPathComponent:@"frontend"];

    NSString *common =
        [appPath stringByAppendingPathComponent:@"common"];

    NSFileManager *fm =
        [NSFileManager defaultManager];

    fprintf(stderr,
            "[debug] app directory exists: %s\n",
            [fm fileExistsAtPath:appPath] ? "YES" : "NO");

    fprintf(stderr,
            "[debug] reader.lua exists: %s\n",
            [fm fileExistsAtPath:readerLua] ? "YES" : "NO");

    fprintf(stderr,
            "[debug] frontend exists: %s\n",
            [fm fileExistsAtPath:frontend] ? "YES" : "NO");

    fprintf(stderr,
            "[debug] common exists: %s\n",
            [fm fileExistsAtPath:common] ? "YES" : "NO");

    char cwd[PATH_MAX];

    if (getcwd(cwd, sizeof(cwd))) {
        fprintf(stderr,
                "[debug] initial cwd: %s\n",
                cwd);
    }

    fprintf(stderr,
            "========================================\n\n");
}
int main(int argc, char *argv[]) {
    @autoreleasepool {
        /*
         * TEMP DEBUG
         */
        KOReaderSetupDebugLog();

        gKOReaderLogOverlay = [KOReaderLogOverlay new];
        [gKOReaderLogOverlay start];

        fprintf(stderr, "[startup] entered ios_loader main()\n");
        NSString *resourcePath = [[NSBundle mainBundle] resourcePath];
        if (!resourcePath) {
            fprintf(stderr, "[%s]: NSBundle resourcePath is nil\n", LOGNAME);
            return EXIT_FAILURE;
        }

        // The asset directory is `app/` rather than `koreader/` because the
        // launcher exec is named `KOReader` and APFS is case-insensitive by
        // default — `KOReader.app/KOReader` (file) and `KOReader.app/koreader/`
        // (dir) would collide.
        NSString *koreaderDir = [resourcePath stringByAppendingPathComponent:@"app"];
        if (chdir([koreaderDir fileSystemRepresentation]) != 0) {
            fprintf(stderr, "[%s]: chdir(%s) failed\n", LOGNAME,
                    [koreaderDir fileSystemRepresentation]);
            return EXIT_FAILURE;
        }
        fprintf(stderr,
                "[startup] chdir OK: %s\n",
                [koreaderDir fileSystemRepresentation]);

        char debugCwd[PATH_MAX];

        if (getcwd(debugCwd, sizeof(debugCwd))) {
            fprintf(stderr,
                    "[startup] cwd now: %s\n",
                    debugCwd);
        }

        fprintf(stderr,
            "[startup] reader.lua after chdir: %s\n",
            access("reader.lua", F_OK) == 0 ? "FOUND" : "MISSING");

        if (setenv("LC_ALL", LANGUAGE, 1) != 0) {
            fprintf(stderr, "[%s]: setenv LC_ALL failed\n", LOGNAME);
            return EXIT_FAILURE;
        }

        /* On iOS the SDL window must match the display, otherwise the
         * default 600x800 emulator window leaves touches outside its
         * bounds doing nothing. Triggering the SDL_FULLSCREEN code path
         * makes SDL query SDL_GetCurrentDisplayMode and size to the
         * actual screen. */
        setenv("SDL_FULLSCREEN", "1", 1);

        /* Disable SDL's synthesis of mouse events from touches. On iOS
         * SDL3 fires both a FINGER_DOWN and a synthetic MOUSE_BUTTON_DOWN
         * for every tap, and the synthesized event isn't reliably tagged
         * with SDL_TOUCH_MOUSEID — so KOReader's input filter accepts
         * both and registers each tap twice. We have the real finger
         * events; we don't need fake mouse ones. */
        setenv("SDL_TOUCH_MOUSE_EVENTS", "0", 1);

        /* Tell Lua plugins (e.g. iosfilepicker.koplugin) we're on iOS.
         * KOReader still self-identifies as the SDL emulator otherwise. */
        setenv("KO_IOS", "1", 1);

        /* iOS sandbox: use the per-app Documents dir for user data. */
        NSArray<NSString *> *docs = NSSearchPathForDirectoriesInDomains(
            NSDocumentDirectory, NSUserDomainMask, YES);
        if (docs.count > 0) {
            setenv("KO_HOME", [docs[0] fileSystemRepresentation], 1);
        }
        fprintf(stderr, "[startup] creating Lua state...\n");
        lua_State *L = luaL_newstate();
        if (!L) {
        fprintf(stderr, "[FATAL] luaL_newstate() failed\n");
        return EXIT_FAILURE;
        }

        fprintf(stderr, "[startup] Lua state created\n");
        luaL_openlibs(L);
        fprintf(stderr, "[startup] Lua standard libraries loaded\n");

        int retval = luaL_dostring(L, "arg = {}");
        if (retval) {
            fprintf(stderr, LUA_ERROR, lua_tostring(L, -1));
            goto quit;
        }

        char buffer[PATH_MAX];
        for (int i = 1; i < argc; ++i) {
            if (snprintf(buffer, PATH_MAX, "table.insert(arg, '%s')", argv[i]) >= 0) {
                retval = luaL_dostring(L, buffer);
                if (retval) {
                    fprintf(stderr, LUA_ERROR, lua_tostring(L, -1));
                    goto quit;
                }
            }
        }
        fprintf(stderr,
                "[startup] starting reader.lua...\n");
        
        fflush(stdout);
        fflush(stderr);
        retval = luaL_dofile(L, "reader.lua");
        fprintf(stderr,
        "[startup] reader.lua returned: %d\n",
        retval);
        if (retval) {
            fprintf(stderr, LUA_ERROR, lua_tostring(L, -1));
        }

quit:
        lua_close(L);
        unsetenv("LC_ALL");
        unsetenv("KO_HOME");
        unsetenv("SDL_FULLSCREEN");
        unsetenv("SDL_TOUCH_MOUSE_EVENTS");
        unsetenv("KO_IOS");
        return retval;
    }
}
