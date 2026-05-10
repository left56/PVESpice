#import "AudioTapHelper.h"
#import <Foundation/Foundation.h>
#import <objc/message.h>

void EnterFullScreen(void) {
#if TARGET_OS_MACCATALYST
    // AppKit APIs are marked unavailable on Mac Catalyst at compile time even though
    // they exist at runtime. Use the ObjC runtime to bypass the restriction.
    Class cls = NSClassFromString(@"NSApplication");
    id app  = ((id(*)(Class,SEL))objc_msgSend)(cls, sel_getUid("sharedApplication"));
    id wins = ((id(*)(id,  SEL))objc_msgSend)(app, sel_getUid("windows"));
    id win  = ((id(*)(id,  SEL))objc_msgSend)(wins, sel_getUid("firstObject"));
    ((void(*)(id,SEL,id))objc_msgSend)(win, sel_getUid("toggleFullScreen:"), nil);
#endif
}
