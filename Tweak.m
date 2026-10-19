#import <UIKit/UIKit.h>
#import <objc/runtime.h>

static void (*orig_layoutSubviews)(UITabBar *, SEL);
static void (*orig_setHidden)(UITabBar *, SEL, BOOL);
static void (*orig_tbc_layout)(UITabBarController *, SEL);

static void hideBar(UITabBar *bar) {
    if (!bar) return;
    if (orig_setHidden) orig_setHidden(bar, @selector(setHidden:), YES);
    bar.alpha = 0;
    bar.userInteractionEnabled = NO;
}

static void new_layoutSubviews(UITabBar *self, SEL _cmd) {
    if (orig_layoutSubviews) orig_layoutSubviews(self, _cmd);
    hideBar(self);
}

static void new_setHidden(UITabBar *self, SEL _cmd, BOOL hidden) {
    hideBar(self);
}

static void new_tbc_layout(UITabBarController *self, SEL _cmd) {
    if (orig_tbc_layout) orig_tbc_layout(self, _cmd);
    hideBar(self.tabBar);
}

static IMP hookMethod(Class cls, SEL sel, IMP newImp) {
    Method m = class_getInstanceMethod(cls, sel);
    if (!m) return NULL;
    IMP orig = method_getImplementation(m);
    if (!class_addMethod(cls, sel, newImp, method_getTypeEncoding(m))) {
        orig = method_setImplementation(m, newImp);
    }
    return orig;
}

static void showLoadedAlert(void) {
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(2.0 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        UIWindow *win = nil;
        for (UIScene *s in UIApplication.sharedApplication.connectedScenes) {
            if (![s isKindOfClass:[UIWindowScene class]]) continue;
            for (UIWindow *w in ((UIWindowScene *)s).windows) {
                if (w.isKeyWindow) win = w;
            }
        }
        UIViewController *vc = win.rootViewController;
        while (vc.presentedViewController) vc = vc.presentedViewController;
        if (!vc) return;
        UIAlertController *a = [UIAlertController
            alertControllerWithTitle:@"NuvioHideTabBar"
                             message:@"Tweak đã được nạp"
                      preferredStyle:UIAlertControllerStyleAlert];
        [a addAction:[UIAlertAction actionWithTitle:@"OK" style:UIAlertActionStyleDefault handler:nil]];
        [vc presentViewController:a animated:YES completion:nil];
    });
}

__attribute__((constructor)) static void NuvioHideTabBarInit(void) {
    Class bar = [UITabBar class];
    orig_layoutSubviews = (void *)hookMethod(bar, @selector(layoutSubviews), (IMP)new_layoutSubviews);
    orig_setHidden = (void *)hookMethod(bar, @selector(setHidden:), (IMP)new_setHidden);
    orig_tbc_layout = (void *)hookMethod([UITabBarController class],
                                         @selector(viewDidLayoutSubviews),
                                         (IMP)new_tbc_layout);

    __block id token = nil;
    token = [[NSNotificationCenter defaultCenter]
        addObserverForName:UIApplicationDidBecomeActiveNotification
                    object:nil
                     queue:[NSOperationQueue mainQueue]
                usingBlock:^(NSNotification *n) {
        [[NSNotificationCenter defaultCenter] removeObserver:token];
        showLoadedAlert();
    }];
}
